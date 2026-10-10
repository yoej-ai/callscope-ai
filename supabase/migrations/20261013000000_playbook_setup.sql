begin;

create table public.playbooks (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index playbooks_workspace_created_idx
on public.playbooks (workspace_id, created_at, id);

create table public.playbook_versions (
  id uuid primary key default gen_random_uuid(),
  playbook_id uuid not null references public.playbooks(id) on delete cascade,
  version_number integer not null,
  status text not null default 'draft',
  name text not null,
  vertical text not null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  published_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz,
  constraint playbook_versions_number_check
    check (version_number between 1 and 10000),
  constraint playbook_versions_status_check
    check (status in ('draft', 'published')),
  constraint playbook_versions_name_check
    check (
      name = pg_catalog.btrim(name)
      and pg_catalog.length(name) between 1 and 120
      and name !~ '[[:cntrl:]]'
    ),
  constraint playbook_versions_vertical_check
    check (
      vertical = pg_catalog.lower(pg_catalog.btrim(vertical))
      and pg_catalog.length(vertical) between 1 and 50
      and vertical ~ '^[a-z][a-z0-9_-]{0,49}$'
    ),
  constraint playbook_versions_publication_check
    check (
      (status = 'draft' and published_at is null and published_by is null)
      or
      (status = 'published' and published_at is not null and published_by is not null)
    ),
  constraint playbook_versions_playbook_number_key
    unique (playbook_id, version_number)
);

create unique index playbook_versions_one_draft_idx
on public.playbook_versions (playbook_id)
where status = 'draft';

create index playbook_versions_playbook_status_idx
on public.playbook_versions (playbook_id, status, version_number desc);

create table public.playbook_criteria (
  id uuid primary key default gen_random_uuid(),
  playbook_version_id uuid not null
    references public.playbook_versions(id) on delete cascade,
  name text not null,
  description text not null default '',
  weight integer not null,
  pass_guidance text not null default '',
  fail_guidance text not null default '',
  position integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint playbook_criteria_name_check
    check (
      name = pg_catalog.btrim(name)
      and pg_catalog.length(name) between 1 and 120
      and name !~ '[[:cntrl:]]'
    ),
  constraint playbook_criteria_description_check
    check (
      description = pg_catalog.btrim(description, E' \n\r\t')
      and pg_catalog.length(description) <= 1000
      and pg_catalog.regexp_replace(description, E'[\n\t]', '', 'g') !~ '[[:cntrl:]]'
    ),
  constraint playbook_criteria_pass_guidance_check
    check (
      pass_guidance = pg_catalog.btrim(pass_guidance, E' \n\r\t')
      and pg_catalog.length(pass_guidance) <= 2000
      and pg_catalog.regexp_replace(pass_guidance, E'[\n\t]', '', 'g') !~ '[[:cntrl:]]'
    ),
  constraint playbook_criteria_fail_guidance_check
    check (
      fail_guidance = pg_catalog.btrim(fail_guidance, E' \n\r\t')
      and pg_catalog.length(fail_guidance) <= 2000
      and pg_catalog.regexp_replace(fail_guidance, E'[\n\t]', '', 'g') !~ '[[:cntrl:]]'
    ),
  constraint playbook_criteria_weight_check
    check (weight between 1 and 100),
  constraint playbook_criteria_position_check
    check (position between 1 and 20),
  constraint playbook_criteria_version_position_key
    unique (playbook_version_id, position)
    deferrable initially immediate
);

create unique index playbook_criteria_version_name_key
on public.playbook_criteria (playbook_version_id, pg_catalog.lower(name));

comment on table public.playbooks is
  'Workspace-owned stable playbook identities. Versioned metadata lives in playbook_versions.';
comment on table public.playbook_versions is
  'Draft or immutable published playbook configurations addressable by future scores.';
comment on table public.playbook_criteria is
  'Ordered immutable-after-publication scoring criteria for one exact playbook version.';

create function private.normalize_playbook_text(
  value text,
  maximum_length integer,
  allow_blank boolean
)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  normalized text := pg_catalog.btrim(
    pg_catalog.replace(
      pg_catalog.replace(coalesce(value, ''), E'\r\n', E'\n'),
      E'\r',
      E'\n'
    ),
    E' \n\r\t'
  );
begin
  if maximum_length < 1
    or pg_catalog.length(normalized) > maximum_length
    or (not allow_blank and normalized = '')
    or pg_catalog.regexp_replace(normalized, E'[\n\t]', '', 'g') ~ '[[:cntrl:]]'
  then
    raise exception 'Playbook field is invalid' using errcode = '22023';
  end if;

  return normalized;
end;
$$;

create function private.normalize_playbook_vertical(value text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  normalized text := pg_catalog.lower(pg_catalog.btrim(value));
begin
  if normalized is null
    or pg_catalog.length(normalized) not between 1 and 50
    or normalized !~ '^[a-z][a-z0-9_-]{0,49}$'
  then
    raise exception 'Playbook vertical is invalid' using errcode = '22023';
  end if;

  return normalized;
end;
$$;

create function private.can_manage_playbooks(target_workspace_id uuid)
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
      and member.role in ('owner', 'admin')
  );
$$;

create function private.can_view_playbook(target_playbook_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.playbooks as playbook
    join public.workspace_members as member
      on member.workspace_id = playbook.workspace_id
     and member.user_id = (select auth.uid())
    where playbook.id = target_playbook_id
      and (
        member.role in ('owner', 'admin')
        or exists (
          select 1
          from public.playbook_versions as version
          where version.playbook_id = playbook.id
            and version.status = 'published'
        )
      )
  );
$$;

create function private.can_view_playbook_version(target_version_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.playbook_versions as version
    join public.playbooks as playbook on playbook.id = version.playbook_id
    join public.workspace_members as member
      on member.workspace_id = playbook.workspace_id
     and member.user_id = (select auth.uid())
    where version.id = target_version_id
      and (member.role in ('owner', 'admin') or version.status = 'published')
  );
$$;

create function private.can_view_playbook_criterion(target_criterion_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.playbook_criteria as criterion
    join public.playbook_versions as version
      on version.id = criterion.playbook_version_id
    join public.playbooks as playbook on playbook.id = version.playbook_id
    join public.workspace_members as member
      on member.workspace_id = playbook.workspace_id
     and member.user_id = (select auth.uid())
    where criterion.id = target_criterion_id
      and (member.role in ('owner', 'admin') or version.status = 'published')
  );
$$;

create function private.protect_playbook_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Playbook identities cannot be changed or deleted'
    using errcode = '55000';
end;
$$;

create function private.guard_playbook_version_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  expected_version integer;
begin
  perform 1
  from public.playbooks as playbook
  where playbook.id = new.playbook_id
  for update;

  if not found then
    raise exception 'Playbook does not exist' using errcode = '23503';
  end if;

  if new.status <> 'draft'
    or new.published_at is not null
    or new.published_by is not null
  then
    raise exception 'New playbook versions must start as drafts'
      using errcode = '22023';
  end if;

  select coalesce(pg_catalog.max(version.version_number), 0) + 1
  into expected_version
  from public.playbook_versions as version
  where version.playbook_id = new.playbook_id;

  if new.version_number <> expected_version then
    raise exception 'Playbook version number is not the next deterministic value'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.playbook_versions as version
    where version.playbook_id = new.playbook_id
      and version.status = 'draft'
  ) then
    raise exception 'A draft version already exists' using errcode = '23505';
  end if;

  return new;
end;
$$;

create function private.guard_playbook_version_change()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  criterion_count integer;
  total_weight integer;
  minimum_position integer;
  maximum_position integer;
  distinct_positions integer;
  distinct_names integer;
begin
  if tg_op = 'DELETE' then
    if old.status = 'published' then
      raise exception 'Published playbook versions are immutable'
        using errcode = '55000';
    end if;
    return old;
  end if;

  if old.status = 'published' then
    raise exception 'Published playbook versions are immutable'
      using errcode = '55000';
  end if;

  if new.playbook_id <> old.playbook_id
    or new.version_number <> old.version_number
    or new.created_by <> old.created_by
    or new.created_at <> old.created_at
  then
    raise exception 'Playbook version identity is immutable'
      using errcode = '55000';
  end if;

  if new.status = 'draft' then
    if new.published_at is not null or new.published_by is not null then
      raise exception 'Draft publication metadata must be empty'
        using errcode = '22023';
    end if;
    return new;
  end if;

  if new.status <> 'published'
    or new.published_at is null
    or new.published_by is null
  then
    raise exception 'Invalid playbook version transition'
      using errcode = '22023';
  end if;

  select
    pg_catalog.count(*)::integer,
    coalesce(pg_catalog.sum(criterion.weight), 0)::integer,
    pg_catalog.min(criterion.position),
    pg_catalog.max(criterion.position),
    pg_catalog.count(distinct criterion.position)::integer,
    pg_catalog.count(distinct pg_catalog.lower(criterion.name))::integer
  into
    criterion_count,
    total_weight,
    minimum_position,
    maximum_position,
    distinct_positions,
    distinct_names
  from public.playbook_criteria as criterion
  where criterion.playbook_version_id = old.id;

  if criterion_count not between 1 and 20 then
    raise exception 'A playbook must contain between 1 and 20 criteria'
      using errcode = '22023';
  end if;

  if total_weight <> 100 then
    raise exception 'Criterion weights must total exactly 100'
      using errcode = '22023';
  end if;

  if minimum_position <> 1
    or maximum_position <> criterion_count
    or distinct_positions <> criterion_count
  then
    raise exception 'Criterion positions must form a complete ordered sequence'
      using errcode = '22023';
  end if;

  if distinct_names <> criterion_count then
    raise exception 'Criterion names must be unique within a version'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

create function private.guard_playbook_criterion_change()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_version_id uuid := case
    when tg_op = 'DELETE' then old.playbook_version_id
    else new.playbook_version_id
  end;
  version_status text;
  criterion_count integer;
begin
  if tg_op = 'UPDATE'
    and new.playbook_version_id <> old.playbook_version_id
  then
    raise exception 'Criterion version identity is immutable'
      using errcode = '55000';
  end if;

  select version.status
  into version_status
  from public.playbook_versions as version
  where version.id = target_version_id
  for update;

  if not found then
    raise exception 'Playbook version does not exist' using errcode = '23503';
  end if;

  if version_status = 'published' then
    raise exception 'Published playbook criteria are immutable'
      using errcode = '55000';
  end if;

  if tg_op = 'INSERT' then
    select pg_catalog.count(*)::integer
    into criterion_count
    from public.playbook_criteria as criterion
    where criterion.playbook_version_id = target_version_id;

    if criterion_count >= 20 then
      raise exception 'A playbook cannot contain more than 20 criteria'
        using errcode = '22023';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

revoke all on function private.normalize_playbook_text(text, integer, boolean)
from public, anon, authenticated, service_role;
revoke all on function private.normalize_playbook_vertical(text)
from public, anon, authenticated, service_role;
revoke all on function private.can_manage_playbooks(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.can_view_playbook(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.can_view_playbook_version(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.can_view_playbook_criterion(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.protect_playbook_identity()
from public, anon, authenticated, service_role;
revoke all on function private.guard_playbook_version_insert()
from public, anon, authenticated, service_role;
revoke all on function private.guard_playbook_version_change()
from public, anon, authenticated, service_role;
revoke all on function private.guard_playbook_criterion_change()
from public, anon, authenticated, service_role;

grant execute on function private.can_manage_playbooks(uuid) to authenticated;
grant execute on function private.can_view_playbook(uuid) to authenticated;
grant execute on function private.can_view_playbook_version(uuid) to authenticated;
grant execute on function private.can_view_playbook_criterion(uuid) to authenticated;

create trigger playbooks_protect_identity
before update or delete on public.playbooks
for each row execute function private.protect_playbook_identity();

create trigger playbook_versions_guard_insert
before insert on public.playbook_versions
for each row execute function private.guard_playbook_version_insert();

create trigger playbook_versions_guard_change
before update or delete on public.playbook_versions
for each row execute function private.guard_playbook_version_change();

create trigger playbook_versions_set_updated_at
before update on public.playbook_versions
for each row execute function private.set_updated_at();

create trigger playbook_criteria_guard_change
before insert or update or delete on public.playbook_criteria
for each row execute function private.guard_playbook_criterion_change();

create trigger playbook_criteria_set_updated_at
before update on public.playbook_criteria
for each row execute function private.set_updated_at();

create function public.create_playbook(
  p_workspace_id uuid,
  p_name text,
  p_vertical text default 'sales'
)
returns table (
  playbook_id uuid,
  version_id uuid,
  version_number integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  normalized_name text;
  normalized_vertical text;
  new_playbook_id uuid;
  new_version_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null
    or not private.can_manage_playbooks(p_workspace_id)
  then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  normalized_name := private.normalize_playbook_text(p_name, 120, false);
  normalized_vertical := private.normalize_playbook_vertical(p_vertical);

  insert into public.playbooks (workspace_id, created_by)
  values (p_workspace_id, current_user_id)
  returning id into new_playbook_id;

  insert into public.playbook_versions (
    playbook_id,
    version_number,
    status,
    name,
    vertical,
    created_by
  ) values (
    new_playbook_id,
    1,
    'draft',
    normalized_name,
    normalized_vertical,
    current_user_id
  )
  returning id into new_version_id;

  return query select new_playbook_id, new_version_id, 1;
end;
$$;

create function public.update_playbook_draft(
  p_workspace_id uuid,
  p_version_id uuid,
  p_name text,
  p_vertical text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_version public.playbook_versions%rowtype;
  normalized_name text;
  normalized_vertical text;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_version_id is null
    or not private.can_manage_playbooks(p_workspace_id)
  then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  select version.*
  into target_version
  from public.playbook_versions as version
  join public.playbooks as playbook on playbook.id = version.playbook_id
  where version.id = p_version_id
    and playbook.workspace_id = p_workspace_id
  for update of version;

  if not found or target_version.status <> 'draft' then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  normalized_name := private.normalize_playbook_text(p_name, 120, false);
  normalized_vertical := private.normalize_playbook_vertical(p_vertical);

  update public.playbook_versions as version
  set name = normalized_name, vertical = normalized_vertical
  where version.id = target_version.id;

  return 'updated';
end;
$$;

create function public.add_playbook_criterion(
  p_workspace_id uuid,
  p_version_id uuid,
  p_name text,
  p_description text,
  p_weight integer,
  p_pass_guidance text,
  p_fail_guidance text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_version public.playbook_versions%rowtype;
  normalized_name text;
  normalized_description text;
  normalized_pass_guidance text;
  normalized_fail_guidance text;
  next_position integer;
  new_criterion_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_version_id is null
    or not private.can_manage_playbooks(p_workspace_id)
  then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  select version.*
  into target_version
  from public.playbook_versions as version
  join public.playbooks as playbook on playbook.id = version.playbook_id
  where version.id = p_version_id
    and playbook.workspace_id = p_workspace_id
  for update of version;

  if not found or target_version.status <> 'draft' then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  normalized_name := private.normalize_playbook_text(p_name, 120, false);
  normalized_description := private.normalize_playbook_text(p_description, 1000, true);
  normalized_pass_guidance := private.normalize_playbook_text(p_pass_guidance, 2000, true);
  normalized_fail_guidance := private.normalize_playbook_text(p_fail_guidance, 2000, true);

  if p_weight is null or p_weight not between 1 and 100 then
    raise exception 'Criterion weight must be between 1 and 100'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.playbook_criteria as criterion
    where criterion.playbook_version_id = target_version.id
      and pg_catalog.lower(criterion.name) = pg_catalog.lower(normalized_name)
  ) then
    raise exception 'Criterion name must be unique within the version'
      using errcode = '22023';
  end if;

  select coalesce(pg_catalog.max(criterion.position), 0) + 1
  into next_position
  from public.playbook_criteria as criterion
  where criterion.playbook_version_id = target_version.id;

  if next_position > 20 then
    raise exception 'A playbook cannot contain more than 20 criteria'
      using errcode = '22023';
  end if;

  insert into public.playbook_criteria (
    playbook_version_id,
    name,
    description,
    weight,
    pass_guidance,
    fail_guidance,
    position
  ) values (
    target_version.id,
    normalized_name,
    normalized_description,
    p_weight,
    normalized_pass_guidance,
    normalized_fail_guidance,
    next_position
  )
  returning id into new_criterion_id;

  return new_criterion_id;
end;
$$;

create function public.update_playbook_criterion(
  p_workspace_id uuid,
  p_criterion_id uuid,
  p_name text,
  p_description text,
  p_weight integer,
  p_pass_guidance text,
  p_fail_guidance text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_version public.playbook_versions%rowtype;
  target_criterion public.playbook_criteria%rowtype;
  normalized_name text;
  normalized_description text;
  normalized_pass_guidance text;
  normalized_fail_guidance text;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_criterion_id is null
    or not private.can_manage_playbooks(p_workspace_id)
  then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  select version.*
  into target_version
  from public.playbook_criteria as criterion
  join public.playbook_versions as version
    on version.id = criterion.playbook_version_id
  join public.playbooks as playbook on playbook.id = version.playbook_id
  where criterion.id = p_criterion_id
    and playbook.workspace_id = p_workspace_id
  for update of version;

  if not found or target_version.status <> 'draft' then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  select criterion.*
  into target_criterion
  from public.playbook_criteria as criterion
  where criterion.id = p_criterion_id
    and criterion.playbook_version_id = target_version.id
  for update;

  if not found then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  normalized_name := private.normalize_playbook_text(p_name, 120, false);
  normalized_description := private.normalize_playbook_text(p_description, 1000, true);
  normalized_pass_guidance := private.normalize_playbook_text(p_pass_guidance, 2000, true);
  normalized_fail_guidance := private.normalize_playbook_text(p_fail_guidance, 2000, true);

  if p_weight is null or p_weight not between 1 and 100 then
    raise exception 'Criterion weight must be between 1 and 100'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.playbook_criteria as criterion
    where criterion.playbook_version_id = target_version.id
      and criterion.id <> target_criterion.id
      and pg_catalog.lower(criterion.name) = pg_catalog.lower(normalized_name)
  ) then
    raise exception 'Criterion name must be unique within the version'
      using errcode = '22023';
  end if;

  update public.playbook_criteria as criterion
  set
    name = normalized_name,
    description = normalized_description,
    weight = p_weight,
    pass_guidance = normalized_pass_guidance,
    fail_guidance = normalized_fail_guidance
  where criterion.id = target_criterion.id;

  return 'updated';
end;
$$;

create function public.remove_playbook_criterion(
  p_workspace_id uuid,
  p_criterion_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_version public.playbook_versions%rowtype;
  target_criterion public.playbook_criteria%rowtype;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_criterion_id is null
    or not private.can_manage_playbooks(p_workspace_id)
  then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  select version.*
  into target_version
  from public.playbook_criteria as criterion
  join public.playbook_versions as version
    on version.id = criterion.playbook_version_id
  join public.playbooks as playbook on playbook.id = version.playbook_id
  where criterion.id = p_criterion_id
    and playbook.workspace_id = p_workspace_id
  for update of version;

  if not found or target_version.status <> 'draft' then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  select criterion.*
  into target_criterion
  from public.playbook_criteria as criterion
  where criterion.id = p_criterion_id
    and criterion.playbook_version_id = target_version.id
  for update;

  if not found then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  set constraints public.playbook_criteria_version_position_key deferred;

  delete from public.playbook_criteria as criterion
  where criterion.id = target_criterion.id;

  update public.playbook_criteria as criterion
  set position = criterion.position - 1
  where criterion.playbook_version_id = target_version.id
    and criterion.position > target_criterion.position;

  return 'removed';
end;
$$;

create function public.move_playbook_criterion(
  p_workspace_id uuid,
  p_criterion_id uuid,
  p_direction text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_version public.playbook_versions%rowtype;
  target_criterion public.playbook_criteria%rowtype;
  adjacent_position integer;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_criterion_id is null
    or p_direction is null
    or p_direction not in ('up', 'down')
    or not private.can_manage_playbooks(p_workspace_id)
  then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  select version.*
  into target_version
  from public.playbook_criteria as criterion
  join public.playbook_versions as version
    on version.id = criterion.playbook_version_id
  join public.playbooks as playbook on playbook.id = version.playbook_id
  where criterion.id = p_criterion_id
    and playbook.workspace_id = p_workspace_id
  for update of version;

  if not found or target_version.status <> 'draft' then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  select criterion.*
  into target_criterion
  from public.playbook_criteria as criterion
  where criterion.id = p_criterion_id
    and criterion.playbook_version_id = target_version.id
  for update;

  if not found then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  adjacent_position := target_criterion.position +
    case when p_direction = 'up' then -1 else 1 end;

  if not exists (
    select 1
    from public.playbook_criteria as criterion
    where criterion.playbook_version_id = target_version.id
      and criterion.position = adjacent_position
  ) then
    return 'unchanged';
  end if;

  set constraints public.playbook_criteria_version_position_key deferred;

  update public.playbook_criteria as criterion
  set position = case
    when criterion.id = target_criterion.id then adjacent_position
    else target_criterion.position
  end
  where criterion.playbook_version_id = target_version.id
    and criterion.position in (target_criterion.position, adjacent_position);

  return 'moved';
end;
$$;

create function public.publish_playbook_version(
  p_workspace_id uuid,
  p_version_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_version public.playbook_versions%rowtype;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_version_id is null
    or not private.can_manage_playbooks(p_workspace_id)
  then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  select version.*
  into target_version
  from public.playbook_versions as version
  join public.playbooks as playbook on playbook.id = version.playbook_id
  where version.id = p_version_id
    and playbook.workspace_id = p_workspace_id
  for update of version;

  if not found or target_version.status <> 'draft' then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  update public.playbook_versions as version
  set
    status = 'published',
    published_at = pg_catalog.clock_timestamp(),
    published_by = current_user_id
  where version.id = target_version.id;

  return 'published';
end;
$$;

create function public.create_next_playbook_version(
  p_workspace_id uuid,
  p_playbook_id uuid
)
returns table (
  version_id uuid,
  version_number integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_playbook public.playbooks%rowtype;
  source_version public.playbook_versions%rowtype;
  next_version_number integer;
  new_version_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_playbook_id is null
    or not private.can_manage_playbooks(p_workspace_id)
  then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  select playbook.*
  into target_playbook
  from public.playbooks as playbook
  where playbook.id = p_playbook_id
    and playbook.workspace_id = p_workspace_id
  for update;

  if not found then
    raise exception 'Playbook operation is not permitted' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.playbook_versions as version
    where version.playbook_id = target_playbook.id
      and version.status = 'draft'
  ) then
    raise exception 'A draft version already exists' using errcode = '23505';
  end if;

  select version.*
  into source_version
  from public.playbook_versions as version
  where version.playbook_id = target_playbook.id
    and version.status = 'published'
  order by version.version_number desc
  limit 1;

  if not found then
    raise exception 'A published version is required' using errcode = '22023';
  end if;

  select pg_catalog.max(version.version_number) + 1
  into next_version_number
  from public.playbook_versions as version
  where version.playbook_id = target_playbook.id;

  insert into public.playbook_versions (
    playbook_id,
    version_number,
    status,
    name,
    vertical,
    created_by
  ) values (
    target_playbook.id,
    next_version_number,
    'draft',
    source_version.name,
    source_version.vertical,
    current_user_id
  )
  returning id into new_version_id;

  insert into public.playbook_criteria (
    playbook_version_id,
    name,
    description,
    weight,
    pass_guidance,
    fail_guidance,
    position
  )
  select
    new_version_id,
    criterion.name,
    criterion.description,
    criterion.weight,
    criterion.pass_guidance,
    criterion.fail_guidance,
    criterion.position
  from public.playbook_criteria as criterion
  where criterion.playbook_version_id = source_version.id
  order by criterion.position;

  return query select new_version_id, next_version_number;
end;
$$;

alter table public.playbooks enable row level security;
alter table public.playbook_versions enable row level security;
alter table public.playbook_criteria enable row level security;

create policy playbooks_select_authorized
on public.playbooks
for select
to authenticated
using (private.can_view_playbook(id));

create policy playbook_versions_select_authorized
on public.playbook_versions
for select
to authenticated
using (private.can_view_playbook_version(id));

create policy playbook_criteria_select_authorized
on public.playbook_criteria
for select
to authenticated
using (private.can_view_playbook_criterion(id));

revoke all on table public.playbooks
from public, anon, authenticated, service_role;
revoke all on table public.playbook_versions
from public, anon, authenticated, service_role;
revoke all on table public.playbook_criteria
from public, anon, authenticated, service_role;

grant select on table public.playbooks to authenticated;
grant select on table public.playbook_versions to authenticated;
grant select on table public.playbook_criteria to authenticated;

revoke all on function public.create_playbook(uuid, text, text)
from public, anon, authenticated, service_role;
revoke all on function public.update_playbook_draft(uuid, uuid, text, text)
from public, anon, authenticated, service_role;
revoke all on function public.add_playbook_criterion(uuid, uuid, text, text, integer, text, text)
from public, anon, authenticated, service_role;
revoke all on function public.update_playbook_criterion(uuid, uuid, text, text, integer, text, text)
from public, anon, authenticated, service_role;
revoke all on function public.remove_playbook_criterion(uuid, uuid)
from public, anon, authenticated, service_role;
revoke all on function public.move_playbook_criterion(uuid, uuid, text)
from public, anon, authenticated, service_role;
revoke all on function public.publish_playbook_version(uuid, uuid)
from public, anon, authenticated, service_role;
revoke all on function public.create_next_playbook_version(uuid, uuid)
from public, anon, authenticated, service_role;

grant execute on function public.create_playbook(uuid, text, text) to authenticated;
grant execute on function public.update_playbook_draft(uuid, uuid, text, text) to authenticated;
grant execute on function public.add_playbook_criterion(uuid, uuid, text, text, integer, text, text) to authenticated;
grant execute on function public.update_playbook_criterion(uuid, uuid, text, text, integer, text, text) to authenticated;
grant execute on function public.remove_playbook_criterion(uuid, uuid) to authenticated;
grant execute on function public.move_playbook_criterion(uuid, uuid, text) to authenticated;
grant execute on function public.publish_playbook_version(uuid, uuid) to authenticated;
grant execute on function public.create_next_playbook_version(uuid, uuid) to authenticated;

commit;
