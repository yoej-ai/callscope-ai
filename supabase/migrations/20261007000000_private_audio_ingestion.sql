begin;

alter table public.calls
  drop constraint calls_status_check;

alter table public.calls
  add constraint calls_status_check
  check (status in ('pending_upload', 'uploaded', 'processing', 'completed', 'failed'));

alter table public.calls
  add column storage_bucket text,
  add column content_type text,
  add column size_bytes bigint,
  add column upload_completed_at timestamptz,
  add constraint calls_storage_bucket_check
    check (storage_bucket is null or storage_bucket = 'call-audio'),
  add constraint calls_content_type_check
    check (
      content_type is null
      or content_type in (
        'audio/mpeg',
        'audio/mp4',
        'audio/x-m4a',
        'audio/wav',
        'audio/webm',
        'audio/ogg'
      )
    ),
  add constraint calls_size_bytes_check
    check (size_bytes is null or size_bytes between 1 and 26214400),
  add constraint calls_pending_upload_metadata_check
    check (
      status <> 'pending_upload'
      or (
        storage_bucket = 'call-audio'
        and content_type is not null
        and size_bytes is not null
        and upload_completed_at is null
      )
    );

create unique index calls_storage_object_unique_idx
on public.calls (storage_bucket, storage_path)
where storage_bucket is not null;

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'call-audio',
  'call-audio',
  false,
  26214400,
  array[
    'audio/mpeg',
    'audio/mp4',
    'audio/x-m4a',
    'audio/wav',
    'audio/webm',
    'audio/ogg'
  ]::text[]
)
on conflict (id) do update
set
  name = excluded.name,
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create function private.can_upload_call_audio(
  target_bucket text,
  target_path text
)
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
    where target_bucket = 'call-audio'
      and call.storage_bucket = target_bucket
      and call.storage_path = target_path
      and call.status = 'pending_upload'
      and call.uploaded_by = (select auth.uid())
      and member.user_id = (select auth.uid())
  );
$$;

revoke all on function private.can_upload_call_audio(text, text) from public;
grant execute on function private.can_upload_call_audio(text, text) to authenticated;

create policy call_audio_insert_pending
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'call-audio'
  and private.can_upload_call_audio(bucket_id, name)
);

create function public.create_call_upload(
  p_workspace_id uuid,
  p_original_filename text,
  p_content_type text,
  p_size_bytes bigint
)
returns table (
  call_id uuid,
  workspace_id uuid,
  storage_bucket text,
  storage_path text,
  content_type text,
  size_bytes bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  normalized_filename text := pg_catalog.btrim(p_original_filename);
  normalized_content_type text := pg_catalog.lower(pg_catalog.btrim(p_content_type));
  validated_extension text;
  expected_content_type text;
  new_call_id uuid := pg_catalog.gen_random_uuid();
  new_storage_path text;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null then
    raise exception 'Workspace is required' using errcode = '22023';
  end if;

  if not private.is_workspace_member(p_workspace_id) then
    return;
  end if;

  if normalized_filename is null
    or normalized_filename = ''
    or pg_catalog.length(normalized_filename) > 255
    or pg_catalog.strpos(normalized_filename, '/') > 0
    or pg_catalog.strpos(normalized_filename, pg_catalog.chr(92)) > 0
    or normalized_filename ~ '[[:cntrl:]]'
  then
    raise exception 'Invalid original filename' using errcode = '22023';
  end if;

  validated_extension := pg_catalog.lower(
    pg_catalog.substring(normalized_filename, '\.[^.]+$')
  );

  if validated_extension is null
    or pg_catalog.length(normalized_filename) <= pg_catalog.length(validated_extension)
  then
    raise exception 'Unsupported filename extension' using errcode = '22023';
  end if;

  expected_content_type := case validated_extension
    when '.mp3' then 'audio/mpeg'
    when '.mp4' then 'audio/mp4'
    when '.m4a' then 'audio/x-m4a'
    when '.wav' then 'audio/wav'
    when '.webm' then 'audio/webm'
    when '.ogg' then 'audio/ogg'
    else null
  end;

  if expected_content_type is null then
    raise exception 'Unsupported filename extension' using errcode = '22023';
  end if;

  if normalized_content_type is null or normalized_content_type not in (
    'audio/mpeg',
    'audio/mp4',
    'audio/x-m4a',
    'audio/wav',
    'audio/webm',
    'audio/ogg'
  ) then
    raise exception 'Unsupported content type' using errcode = '22023';
  end if;

  if normalized_content_type <> expected_content_type then
    raise exception 'Filename extension and content type do not match'
      using errcode = '22023';
  end if;

  if p_size_bytes is null or p_size_bytes < 1 or p_size_bytes > 26214400 then
    raise exception 'Invalid upload size' using errcode = '22023';
  end if;

  new_storage_path := pg_catalog.format(
    '%s/%s/source%s',
    p_workspace_id,
    new_call_id,
    validated_extension
  );

  insert into public.calls (
    id,
    workspace_id,
    uploaded_by,
    original_filename,
    storage_bucket,
    storage_path,
    content_type,
    size_bytes,
    status
  )
  values (
    new_call_id,
    p_workspace_id,
    current_user_id,
    normalized_filename,
    'call-audio',
    new_storage_path,
    normalized_content_type,
    p_size_bytes,
    'pending_upload'
  );

  return query
  select
    new_call_id,
    p_workspace_id,
    'call-audio'::text,
    new_storage_path,
    normalized_content_type,
    p_size_bytes;
end;
$$;

create function public.abort_call_upload(
  p_workspace_id uuid,
  p_call_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  deleted_count bigint;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  delete from public.calls as call
  where call.id = p_call_id
    and call.workspace_id = p_workspace_id
    and call.uploaded_by = current_user_id
    and call.status = 'pending_upload'
    and private.is_workspace_member(call.workspace_id)
    and not exists (
      select 1
      from storage.objects as object
      where object.bucket_id = call.storage_bucket
        and object.name = call.storage_path
    );

  get diagnostics deleted_count = row_count;
  return deleted_count = 1;
end;
$$;

create function public.finalize_call_upload(
  p_workspace_id uuid,
  p_call_id uuid
)
returns table (
  call_id uuid,
  status text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_call public.calls%rowtype;
  object_metadata jsonb;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  select call.*
  into target_call
  from public.calls as call
  where call.id = p_call_id
    and call.workspace_id = p_workspace_id
    and private.is_workspace_member(call.workspace_id)
  for update;

  if not found then
    return;
  end if;

  if target_call.status = 'uploaded'
    and target_call.storage_bucket = 'call-audio'
    and target_call.upload_completed_at is not null
  then
    return query select target_call.id, 'uploaded'::text;
    return;
  end if;

  if target_call.status <> 'pending_upload'
    or target_call.storage_bucket <> 'call-audio'
  then
    return;
  end if;

  select object.metadata
  into object_metadata
  from storage.objects as object
  where object.bucket_id = target_call.storage_bucket
    and object.name = target_call.storage_path
  limit 1;

  if object_metadata is null
    or not (object_metadata ? 'size')
    or not (object_metadata ? 'mimetype')
    or object_metadata ->> 'size' is null
    or object_metadata ->> 'mimetype' is null
    or object_metadata ->> 'size' !~ '^[0-9]+$'
    or (object_metadata ->> 'size')::numeric <> target_call.size_bytes
    or pg_catalog.lower(object_metadata ->> 'mimetype') <> target_call.content_type
  then
    return;
  end if;

  update public.calls as call
  set
    status = 'uploaded',
    upload_completed_at = pg_catalog.now()
  where call.id = target_call.id
    and call.status = 'pending_upload';

  if found then
    return query select target_call.id, 'uploaded'::text;
  end if;
end;
$$;

revoke all on function public.create_call_upload(uuid, text, text, bigint) from public;
revoke all on function public.create_call_upload(uuid, text, text, bigint) from anon;
grant execute on function public.create_call_upload(uuid, text, text, bigint) to authenticated;

revoke all on function public.abort_call_upload(uuid, uuid) from public;
revoke all on function public.abort_call_upload(uuid, uuid) from anon;
grant execute on function public.abort_call_upload(uuid, uuid) to authenticated;

revoke all on function public.finalize_call_upload(uuid, uuid) from public;
revoke all on function public.finalize_call_upload(uuid, uuid) from anon;
grant execute on function public.finalize_call_upload(uuid, uuid) to authenticated;

comment on function public.create_call_upload(uuid, text, text, bigint) is
  'Creates a tenant-authorized pending audio upload with a trusted object path for auth.uid().';
comment on function public.abort_call_upload(uuid, uuid) is
  'Deletes only auth.uid() pending upload records that have no Storage object.';
comment on function public.finalize_call_upload(uuid, uuid) is
  'Marks a pending upload as uploaded only after exact Storage object metadata verification.';

commit;
