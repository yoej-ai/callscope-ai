begin;

alter table public.calls
  drop constraint calls_status_check;

alter table public.calls
  add column display_name text,
  add constraint calls_status_check
    check (status in ('pending_upload', 'uploaded', 'processing', 'completed', 'failed', 'deleting')),
  add constraint calls_display_name_check
    check (
      display_name is null
      or (
        display_name = pg_catalog.btrim(display_name)
        and pg_catalog.length(display_name) between 1 and 120
        and display_name !~ '[[:cntrl:]]'
      )
    );

create function private.can_manage_call(target_call_id uuid)
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
     and member.user_id = (select auth.uid())
    where call.id = target_call_id
      and (
        call.uploaded_by = (select auth.uid())
        or member.role in ('owner', 'admin')
      )
  );
$$;

create function private.can_delete_call_audio(
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
    where target_bucket = 'call-audio'
      and call.storage_bucket = target_bucket
      and call.storage_path = target_path
      and call.status = 'deleting'
      and private.can_manage_call(call.id)
  );
$$;

create or replace function private.can_upload_call_audio(
  target_bucket text,
  target_path text
)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform 1
  from public.calls as call
  join public.workspace_members as member
    on member.workspace_id = call.workspace_id
  where target_bucket = 'call-audio'
    and call.storage_bucket = target_bucket
    and call.storage_path = target_path
    and call.status = 'pending_upload'
    and call.uploaded_by = (select auth.uid())
    and member.user_id = (select auth.uid())
  for share of call;

  return found;
end;
$$;

revoke all on function private.can_manage_call(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.can_delete_call_audio(text, text)
from public, anon, authenticated, service_role;
revoke all on function private.can_upload_call_audio(text, text)
from public, anon, authenticated, service_role;
grant execute on function private.can_manage_call(uuid) to authenticated;
grant execute on function private.can_delete_call_audio(text, text) to authenticated;
grant execute on function private.can_upload_call_audio(text, text) to authenticated;

create policy call_audio_select_managed_deleting_for_delete
on storage.objects
for select
to authenticated
using (
  pg_catalog.current_setting('storage.allow_delete_query', true) = 'true'
  and bucket_id = 'call-audio'
  and private.can_delete_call_audio(bucket_id, name)
);

create policy call_audio_delete_managed_deleting
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'call-audio'
  and private.can_delete_call_audio(bucket_id, name)
);

create function public.rename_call(
  p_workspace_id uuid,
  p_call_id uuid,
  p_display_name text
)
returns table (
  call_id uuid,
  display_name text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  normalized_display_name text := pg_catalog.btrim(p_display_name);
  target_call public.calls%rowtype;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_call_id is null then
    raise exception 'Workspace and call are required' using errcode = '22023';
  end if;

  if normalized_display_name is null
    or pg_catalog.length(normalized_display_name) not between 1 and 120
    or normalized_display_name ~ '[[:cntrl:]]'
  then
    raise exception 'Call name must contain between 1 and 120 visible characters'
      using errcode = '22023';
  end if;

  select call.*
  into target_call
  from public.calls as call
  where call.id = p_call_id
    and call.workspace_id = p_workspace_id
    and private.can_manage_call(call.id)
  for update;

  if not found or target_call.status = 'deleting' then
    return;
  end if;

  update public.calls as call
  set display_name = normalized_display_name
  where call.id = target_call.id
    and call.workspace_id = p_workspace_id
    and call.status <> 'deleting';

  if found then
    return query select target_call.id, normalized_display_name;
  end if;
end;
$$;

create function public.prepare_call_deletion(
  p_workspace_id uuid,
  p_call_id uuid
)
returns table (
  outcome text,
  storage_bucket text,
  storage_path text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_call public.calls%rowtype;
  transcription_status text;
  analysis_status text;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_call_id is null then
    raise exception 'Workspace and call are required' using errcode = '22023';
  end if;

  select call.*
  into target_call
  from public.calls as call
  where call.id = p_call_id
    and call.workspace_id = p_workspace_id
    and private.can_manage_call(call.id)
  for update;

  if not found then
    return;
  end if;

  if target_call.status = 'deleting' then
    return query
    select
      'already_deleting'::text,
      target_call.storage_bucket,
      target_call.storage_path;
    return;
  end if;

  select analysis.status
  into analysis_status
  from public.call_analyses as analysis
  where analysis.call_id = p_call_id;

  select transcription.status
  into transcription_status
  from public.call_transcriptions as transcription
  where transcription.call_id = p_call_id;

  if transcription_status = 'processing' or analysis_status = 'processing' then
    return query select 'processing_active'::text, null::text, null::text;
    return;
  end if;

  if target_call.storage_bucket <> 'call-audio'
    or target_call.storage_path is null
    or target_call.storage_path = ''
  then
    return;
  end if;

  update public.calls as call
  set status = 'deleting'
  where call.id = target_call.id
    and call.workspace_id = p_workspace_id
    and call.status <> 'deleting';

  if found then
    return query
    select
      'prepared'::text,
      target_call.storage_bucket,
      target_call.storage_path;
  end if;
end;
$$;

create function public.finalize_call_deletion(
  p_workspace_id uuid,
  p_call_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_call public.calls%rowtype;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_call_id is null then
    raise exception 'Workspace and call are required' using errcode = '22023';
  end if;

  select call.*
  into target_call
  from public.calls as call
  where call.id = p_call_id
    and call.workspace_id = p_workspace_id
    and private.can_manage_call(call.id)
  for update;

  if not found then
    return 'none';
  end if;

  if target_call.status <> 'deleting' then
    return 'not_ready';
  end if;

  if exists (
    select 1
    from storage.objects as object
    where object.bucket_id = target_call.storage_bucket
      and object.name = target_call.storage_path
  ) then
    return 'storage_present';
  end if;

  delete from public.calls as call
  where call.id = target_call.id
    and call.workspace_id = p_workspace_id
    and call.status = 'deleting';

  if found then
    return 'deleted';
  end if;

  return 'none';
end;
$$;

create function public.retry_failed_call_processing(
  p_workspace_id uuid,
  p_call_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_call public.calls%rowtype;
  target_transcription public.call_transcriptions%rowtype;
  target_analysis public.call_analyses%rowtype;
  transcription_found boolean := false;
  analysis_found boolean := false;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_call_id is null then
    raise exception 'Workspace and call are required' using errcode = '22023';
  end if;

  select call.*
  into target_call
  from public.calls as call
  where call.id = p_call_id
    and call.workspace_id = p_workspace_id
    and private.can_manage_call(call.id)
  for update;

  if not found or target_call.status <> 'uploaded' then
    return 'none';
  end if;

  select transcription.*
  into target_transcription
  from public.call_transcriptions as transcription
  where transcription.call_id = p_call_id;
  transcription_found := found;

  if transcription_found
    and target_transcription.status = 'failed'
    and private.is_call_transcription_eligible(
      target_call.id,
      target_call.workspace_id,
      target_call.status,
      target_call.storage_bucket,
      target_call.storage_path,
      target_call.content_type,
      target_call.size_bytes,
      target_call.upload_completed_at
    )
  then
    update public.call_transcriptions as transcription
    set
      status = 'queued',
      transcript_text = null,
      language_code = null,
      segments = '[]'::jsonb,
      attempt_count = 0,
      claim_token = null,
      lease_expires_at = null,
      next_attempt_at = null,
      last_error_code = null,
      started_at = null,
      completed_at = null,
      failed_at = null
    where transcription.id = target_transcription.id
      and transcription.status = 'failed';

    if found then
      return 'transcription';
    end if;
  end if;

  select analysis.*
  into target_analysis
  from public.call_analyses as analysis
  where analysis.call_id = p_call_id;
  analysis_found := found;

  if analysis_found
    and target_analysis.status = 'failed'
    and transcription_found
    and private.is_call_analysis_eligible(
      target_transcription.status,
      target_transcription.transcript_text,
      target_transcription.completed_at
    )
  then
    update public.call_analyses as analysis
    set
      status = 'queued',
      summary = null,
      sentiment = null,
      primary_intent = null,
      objections = '[]'::jsonb,
      action_items = '[]'::jsonb,
      topics = '[]'::jsonb,
      overall_score = null,
      attempt_count = 0,
      claim_token = null,
      lease_expires_at = null,
      next_attempt_at = null,
      last_error_code = null,
      started_at = null,
      completed_at = null,
      failed_at = null
    where analysis.id = target_analysis.id
      and analysis.status = 'failed';

    if found then
      return 'analysis';
    end if;
  end if;

  return 'none';
end;
$$;

create or replace function public.claim_transcription_jobs(p_limit integer default 1)
returns table (
  call_id uuid,
  workspace_id uuid,
  storage_bucket text,
  storage_path text,
  content_type text,
  size_bytes bigint,
  claim_token uuid,
  attempt_count integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_job record;
  new_claim_token uuid;
  new_attempt_count integer;
begin
  if p_limit is null or p_limit < 1 or p_limit > 5 then
    raise exception 'Claim limit must be between 1 and 5'
      using errcode = '22023';
  end if;

  with exhausted as (
    select transcription.id
    from public.call_transcriptions as transcription
    where transcription.status = 'processing'
      and transcription.lease_expires_at <= pg_catalog.clock_timestamp()
      and transcription.attempt_count >= 3
    order by transcription.lease_expires_at, transcription.created_at, transcription.id
    for update of transcription skip locked
    limit p_limit
  )
  update public.call_transcriptions as transcription
  set
    status = 'failed',
    lease_expires_at = null,
    next_attempt_at = null,
    last_error_code = 'worker_lease_expired',
    failed_at = pg_catalog.now()
  from exhausted
  where transcription.id = exhausted.id;

  for target_job in
    select
      transcription.id as transcription_id,
      transcription.call_id,
      call.workspace_id,
      call.storage_bucket,
      call.storage_path,
      call.content_type,
      call.size_bytes
    from public.call_transcriptions as transcription
    join public.calls as call on call.id = transcription.call_id
    where (
        (
          transcription.status = 'queued'
          and (
            transcription.next_attempt_at is null
            or transcription.next_attempt_at <= pg_catalog.now()
          )
        )
        or (
          transcription.status = 'processing'
          and transcription.lease_expires_at <= pg_catalog.clock_timestamp()
        )
      )
      and transcription.attempt_count < 3
      and private.is_call_transcription_eligible(
        call.id,
        call.workspace_id,
        call.status,
        call.storage_bucket,
        call.storage_path,
        call.content_type,
        call.size_bytes,
        call.upload_completed_at
      )
    order by
      case
        when transcription.status = 'queued'
          then coalesce(transcription.next_attempt_at, transcription.created_at)
        else transcription.lease_expires_at
      end,
      transcription.created_at,
      transcription.id
    for update of transcription, call skip locked
    limit p_limit
  loop
    new_claim_token := pg_catalog.gen_random_uuid();

    update public.call_transcriptions as transcription
    set
      status = 'processing',
      attempt_count = transcription.attempt_count + 1,
      claim_token = new_claim_token,
      lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes',
      next_attempt_at = null,
      last_error_code = null,
      started_at = coalesce(transcription.started_at, pg_catalog.now()),
      failed_at = null
    where transcription.id = target_job.transcription_id
    returning transcription.attempt_count into new_attempt_count;

    call_id := target_job.call_id;
    workspace_id := target_job.workspace_id;
    storage_bucket := target_job.storage_bucket;
    storage_path := target_job.storage_path;
    content_type := target_job.content_type;
    size_bytes := target_job.size_bytes;
    claim_token := new_claim_token;
    attempt_count := new_attempt_count;
    return next;
  end loop;
end;
$$;

create or replace function public.claim_analysis_jobs(p_limit integer default 1)
returns table (
  call_id uuid,
  workspace_id uuid,
  transcript_text text,
  language_code text,
  claim_token uuid,
  attempt_count integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_job record;
  new_claim_token uuid;
  new_attempt_count integer;
begin
  if p_limit is null or p_limit < 1 or p_limit > 5 then
    raise exception 'Claim limit must be between 1 and 5'
      using errcode = '22023';
  end if;

  with exhausted as (
    select analysis.id
    from public.call_analyses as analysis
    where analysis.status = 'processing'
      and analysis.lease_expires_at <= pg_catalog.clock_timestamp()
      and analysis.attempt_count >= 3
    order by analysis.lease_expires_at, analysis.created_at, analysis.id
    for update of analysis skip locked
    limit p_limit
  )
  update public.call_analyses as analysis
  set
    status = 'failed',
    lease_expires_at = null,
    next_attempt_at = null,
    last_error_code = 'worker_lease_expired',
    failed_at = pg_catalog.now()
  from exhausted
  where analysis.id = exhausted.id;

  for target_job in
    select
      analysis.id as analysis_id,
      analysis.call_id,
      call.workspace_id,
      transcription.transcript_text,
      transcription.language_code
    from public.call_analyses as analysis
    join public.call_transcriptions as transcription
      on transcription.call_id = analysis.call_id
    join public.calls as call on call.id = analysis.call_id
    where (
        (
          analysis.status = 'queued'
          and (
            analysis.next_attempt_at is null
            or analysis.next_attempt_at <= pg_catalog.now()
          )
        )
        or (
          analysis.status = 'processing'
          and analysis.lease_expires_at <= pg_catalog.clock_timestamp()
        )
      )
      and analysis.attempt_count < 3
      and call.status = 'uploaded'
      and private.is_call_analysis_eligible(
        transcription.status,
        transcription.transcript_text,
        transcription.completed_at
      )
    order by
      case
        when analysis.status = 'queued'
          then coalesce(analysis.next_attempt_at, analysis.created_at)
        else analysis.lease_expires_at
      end,
      analysis.created_at,
      analysis.id
    for update of analysis, call skip locked
    limit p_limit
  loop
    new_claim_token := pg_catalog.gen_random_uuid();

    update public.call_analyses as analysis
    set
      status = 'processing',
      attempt_count = analysis.attempt_count + 1,
      claim_token = new_claim_token,
      lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes',
      next_attempt_at = null,
      last_error_code = null,
      started_at = coalesce(analysis.started_at, pg_catalog.now()),
      failed_at = null
    where analysis.id = target_job.analysis_id
    returning analysis.attempt_count into new_attempt_count;

    call_id := target_job.call_id;
    workspace_id := target_job.workspace_id;
    transcript_text := target_job.transcript_text;
    language_code := target_job.language_code;
    claim_token := new_claim_token;
    attempt_count := new_attempt_count;
    return next;
  end loop;
end;
$$;

revoke all on function public.rename_call(uuid, uuid, text)
from public, anon, authenticated, service_role;
revoke all on function public.prepare_call_deletion(uuid, uuid)
from public, anon, authenticated, service_role;
revoke all on function public.finalize_call_deletion(uuid, uuid)
from public, anon, authenticated, service_role;
revoke all on function public.retry_failed_call_processing(uuid, uuid)
from public, anon, authenticated, service_role;

grant execute on function public.rename_call(uuid, uuid, text) to authenticated;
grant execute on function public.prepare_call_deletion(uuid, uuid) to authenticated;
grant execute on function public.finalize_call_deletion(uuid, uuid) to authenticated;
grant execute on function public.retry_failed_call_processing(uuid, uuid) to authenticated;

revoke all on function public.claim_analysis_jobs(integer)
from public, anon, authenticated, service_role;
grant execute on function public.claim_analysis_jobs(integer) to service_role;

revoke all on function public.claim_transcription_jobs(integer)
from public, anon, authenticated, service_role;
grant execute on function public.claim_transcription_jobs(integer) to service_role;

comment on column public.calls.display_name is
  'Optional normalized user-facing call name; original_filename remains the immutable source filename.';
comment on function private.can_manage_call(uuid) is
  'Authorizes a current workspace member who uploaded the call or holds the owner/admin role.';
comment on function private.can_delete_call_audio(text, text) is
  'Allows deletion only for the exact private object of an authorized call already marked deleting.';
comment on function private.can_upload_call_audio(text, text) is
  'Authorizes the exact pending object while row-locking its call against a concurrent deleting transition.';
comment on function public.rename_call(uuid, uuid, text) is
  'Renames an authorized call without changing its immutable source filename.';
comment on function public.prepare_call_deletion(uuid, uuid) is
  'Locks an authorized call, blocks active processing, and returns only its trusted private object.';
comment on function public.finalize_call_deletion(uuid, uuid) is
  'Deletes an authorized deleting call only after its exact private Storage object is absent.';
comment on function public.retry_failed_call_processing(uuid, uuid) is
  'Resets one terminal failed transcription or analysis job to a clean user-requested queued state.';
comment on function public.claim_analysis_jobs(integer) is
  'Claims eligible analysis jobs while row-locking the still-uploaded parent call against deletion races.';
comment on function public.claim_transcription_jobs(integer) is
  'Claims eligible transcription jobs while row-locking the still-uploaded parent call against deletion races.';

commit;
