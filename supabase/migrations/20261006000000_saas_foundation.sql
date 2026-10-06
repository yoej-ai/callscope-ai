begin;

create schema if not exists private;
revoke all on schema private from public;

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_full_name_not_blank
    check (full_name is null or length(btrim(full_name)) > 0)
);

create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint workspaces_name_not_blank check (length(btrim(name)) > 0),
  constraint workspaces_name_length check (length(name) <= 120)
);

create table public.workspace_members (
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null,
  created_at timestamptz not null default now(),
  primary key (workspace_id, user_id),
  constraint workspace_members_role_check check (role in ('owner', 'admin', 'member'))
);

create table public.calls (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  uploaded_by uuid references auth.users (id) on delete set null,
  original_filename text not null,
  storage_path text not null,
  status text not null,
  duration_seconds integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint calls_original_filename_not_blank check (length(btrim(original_filename)) > 0),
  constraint calls_storage_path_not_blank check (length(btrim(storage_path)) > 0),
  constraint calls_status_check check (status in ('uploaded', 'processing', 'completed', 'failed')),
  constraint calls_duration_nonnegative check (duration_seconds is null or duration_seconds >= 0)
);

create table public.call_analyses (
  id uuid primary key default gen_random_uuid(),
  call_id uuid not null references public.calls (id) on delete cascade,
  summary text,
  intent text,
  sentiment text,
  lead_score integer,
  objections jsonb not null default '[]'::jsonb,
  action_items jsonb not null default '[]'::jsonb,
  recommended_follow_up text,
  raw_analysis jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint call_analyses_call_unique unique (call_id),
  constraint call_analyses_lead_score_check
    check (lead_score is null or lead_score between 0 and 100),
  constraint call_analyses_objections_array check (jsonb_typeof(objections) = 'array'),
  constraint call_analyses_action_items_array check (jsonb_typeof(action_items) = 'array')
);

create table public.usage_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  user_id uuid references auth.users (id) on delete set null,
  event_type text not null,
  quantity integer not null default 1,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint usage_events_event_type_not_blank check (length(btrim(event_type)) > 0),
  constraint usage_events_quantity_positive check (quantity > 0),
  constraint usage_events_metadata_object check (jsonb_typeof(metadata) = 'object')
);

create index workspace_members_user_id_idx on public.workspace_members (user_id);
create index workspace_members_workspace_id_idx on public.workspace_members (workspace_id);
create index calls_workspace_id_idx on public.calls (workspace_id);
create index calls_uploaded_by_idx on public.calls (uploaded_by);
create index calls_status_idx on public.calls (status);
create index calls_created_at_idx on public.calls (created_at desc);
create index call_analyses_call_id_idx on public.call_analyses (call_id);
create index usage_events_workspace_id_idx on public.usage_events (workspace_id);
create index usage_events_user_id_idx on public.usage_events (user_id);
create index usage_events_created_at_idx on public.usage_events (created_at desc);

create function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = pg_catalog.now();
  return new;
end;
$$;

revoke all on function private.set_updated_at() from public;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function private.set_updated_at();

create trigger workspaces_set_updated_at
before update on public.workspaces
for each row execute function private.set_updated_at();

create trigger calls_set_updated_at
before update on public.calls
for each row execute function private.set_updated_at();

create trigger call_analyses_set_updated_at
before update on public.call_analyses
for each row execute function private.set_updated_at();

create function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (
    new.id,
    nullif(pg_catalog.btrim(new.raw_user_meta_data ->> 'full_name'), '')
  );
  return new;
end;
$$;

revoke all on function private.handle_new_user() from public;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function private.handle_new_user();

create function private.is_workspace_member(target_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.workspace_members as member
    where member.workspace_id = target_workspace_id
      and member.user_id = (select auth.uid())
  );
$$;

create function private.workspace_role(target_workspace_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select member.role
  from public.workspace_members as member
  where member.workspace_id = target_workspace_id
    and member.user_id = (select auth.uid())
  limit 1;
$$;

create function private.can_assign_workspace_role(
  target_workspace_id uuid,
  proposed_role text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case private.workspace_role(target_workspace_id)
    when 'owner' then proposed_role in ('admin', 'member')
    when 'admin' then proposed_role = 'member'
    else false
  end;
$$;

create function private.can_remove_workspace_member(
  target_workspace_id uuid,
  target_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case private.workspace_role(target_workspace_id)
    when 'owner' then coalesce((
      select member.role <> 'owner'
      from public.workspace_members as member
      where member.workspace_id = target_workspace_id
        and member.user_id = target_user_id
    ), false)
    when 'admin' then coalesce((
      select member.role = 'member'
      from public.workspace_members as member
      where member.workspace_id = target_workspace_id
        and member.user_id = target_user_id
    ), false)
    else false
  end;
$$;

create function private.is_call_workspace_member(target_call_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.calls as call
    join public.workspace_members as member
      on member.workspace_id = call.workspace_id
    where call.id = target_call_id
      and member.user_id = (select auth.uid())
  );
$$;

revoke all on function private.is_workspace_member(uuid) from public;
revoke all on function private.workspace_role(uuid) from public;
revoke all on function private.can_assign_workspace_role(uuid, text) from public;
revoke all on function private.can_remove_workspace_member(uuid, uuid) from public;
revoke all on function private.is_call_workspace_member(uuid) from public;

grant usage on schema private to authenticated;
grant execute on function private.is_workspace_member(uuid) to authenticated;
grant execute on function private.workspace_role(uuid) to authenticated;
grant execute on function private.can_assign_workspace_role(uuid, text) to authenticated;
grant execute on function private.can_remove_workspace_member(uuid, uuid) to authenticated;
grant execute on function private.is_call_workspace_member(uuid) to authenticated;

create function public.create_workspace(p_name text)
returns table (workspace_id uuid, workspace_name text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  normalized_name text := pg_catalog.btrim(p_name);
  new_workspace_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if normalized_name is null or normalized_name = '' or pg_catalog.length(normalized_name) > 120 then
    raise exception 'Workspace name must contain between 1 and 120 characters'
      using errcode = '22023';
  end if;

  insert into public.workspaces (name, created_by)
  values (normalized_name, current_user_id)
  returning id into new_workspace_id;

  insert into public.workspace_members (workspace_id, user_id, role)
  values (new_workspace_id, current_user_id, 'owner');

  return query select new_workspace_id, normalized_name;
end;
$$;

revoke all on function public.create_workspace(text) from public;
revoke all on function public.create_workspace(text) from anon;
grant execute on function public.create_workspace(text) to authenticated;

alter table public.profiles enable row level security;
alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.calls enable row level security;
alter table public.call_analyses enable row level security;
alter table public.usage_events enable row level security;

create policy profiles_select_own
on public.profiles for select to authenticated
using (id = (select auth.uid()));

create policy profiles_update_own
on public.profiles for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

create policy workspaces_select_member
on public.workspaces for select to authenticated
using (private.is_workspace_member(id));

create policy workspaces_update_admin
on public.workspaces for update to authenticated
using (private.workspace_role(id) in ('owner', 'admin'))
with check (private.workspace_role(id) in ('owner', 'admin'));

create policy workspaces_delete_owner
on public.workspaces for delete to authenticated
using (private.workspace_role(id) = 'owner');

create policy workspace_members_select_member
on public.workspace_members for select to authenticated
using (private.is_workspace_member(workspace_id));

create policy workspace_members_insert_manager
on public.workspace_members for insert to authenticated
with check (private.can_assign_workspace_role(workspace_id, role));

create policy workspace_members_update_owner
on public.workspace_members for update to authenticated
using (
  private.workspace_role(workspace_id) = 'owner'
  and user_id <> (select auth.uid())
  and role in ('admin', 'member')
)
with check (
  private.workspace_role(workspace_id) = 'owner'
  and user_id <> (select auth.uid())
  and role in ('admin', 'member')
);

create policy workspace_members_delete_manager
on public.workspace_members for delete to authenticated
using (private.can_remove_workspace_member(workspace_id, user_id));

create policy calls_select_member
on public.calls for select to authenticated
using (private.is_workspace_member(workspace_id));

create policy call_analyses_select_member
on public.call_analyses for select to authenticated
using (private.is_call_workspace_member(call_id));

revoke all on table public.profiles from anon, authenticated;
revoke all on table public.workspaces from anon, authenticated;
revoke all on table public.workspace_members from anon, authenticated;
revoke all on table public.calls from anon, authenticated;
revoke all on table public.call_analyses from anon, authenticated;
revoke all on table public.usage_events from anon, authenticated;

grant select on table public.profiles to authenticated;
grant update (full_name) on table public.profiles to authenticated;
grant select on table public.workspaces to authenticated;
grant update (name) on table public.workspaces to authenticated;
grant delete on table public.workspaces to authenticated;
grant select on table public.workspace_members to authenticated;
grant insert (workspace_id, user_id, role) on table public.workspace_members to authenticated;
grant update (role) on table public.workspace_members to authenticated;
grant delete on table public.workspace_members to authenticated;
grant select on table public.calls to authenticated;
grant select on table public.call_analyses to authenticated;

comment on function public.create_workspace(text) is
  'Atomically creates a workspace and owner membership for auth.uid().';
comment on table public.usage_events is
  'Append-only internal telemetry and billing usage. Browser roles have no direct table access; expose only a future trusted aggregate RPC or backend API.';

commit;

