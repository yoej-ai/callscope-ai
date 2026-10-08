begin;

create table public.call_transcriptions (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  call_id uuid not null references public.calls (id) on delete cascade,
  status text not null default 'queued',
  transcript_text text,
  language_code text,
  segments jsonb not null default '[]'::jsonb,
  attempt_count integer not null default 0,
  claim_token uuid,
  lease_expires_at timestamptz,
  next_attempt_at timestamptz,
  last_error_code text,
  started_at timestamptz,
  completed_at timestamptz,
  failed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint call_transcriptions_call_unique unique (call_id),
  constraint call_transcriptions_status_check
    check (status in ('queued', 'processing', 'completed', 'failed')),
  constraint call_transcriptions_attempt_count_check
    check (attempt_count between 0 and 3),
  constraint call_transcriptions_segments_array_check
    check (pg_catalog.jsonb_typeof(segments) = 'array'),
  constraint call_transcriptions_segments_size_check
    check (pg_catalog.pg_column_size(segments) <= 5000000),
  constraint call_transcriptions_transcript_size_check
    check (transcript_text is null or pg_catalog.length(transcript_text) <= 1000000),
  constraint call_transcriptions_language_code_check
    check (
      language_code is null
      or (
        pg_catalog.length(language_code) between 2 and 24
        and language_code ~ '^[a-z]{2,3}(-[a-z0-9]{2,8}){0,2}$'
      )
    ),
  constraint call_transcriptions_error_code_check
    check (
      last_error_code is null
      or (
        pg_catalog.length(last_error_code) between 1 and 64
        and last_error_code ~ '^[a-z][a-z0-9_]*$'
      )
    ),
  constraint call_transcriptions_lifecycle_check
    check (
      (
        status = 'queued'
        and attempt_count < 3
        and lease_expires_at is null
        and completed_at is null
        and failed_at is null
        and transcript_text is null
        and language_code is null
        and segments = '[]'::jsonb
        and (
          (
            next_attempt_at is null
            and last_error_code is null
          )
          or (
            next_attempt_at is not null
            and last_error_code is not null
            and claim_token is not null
            and attempt_count > 0
            and started_at is not null
          )
        )
      )
      or (
        status = 'processing'
        and attempt_count > 0
        and claim_token is not null
        and lease_expires_at is not null
        and next_attempt_at is null
        and last_error_code is null
        and started_at is not null
        and completed_at is null
        and failed_at is null
        and transcript_text is null
        and language_code is null
        and segments = '[]'::jsonb
      )
      or (
        status = 'completed'
        and attempt_count > 0
        and claim_token is not null
        and lease_expires_at is null
        and next_attempt_at is null
        and last_error_code is null
        and started_at is not null
        and completed_at is not null
        and failed_at is null
        and transcript_text is not null
        and pg_catalog.length(pg_catalog.btrim(transcript_text)) > 0
      )
      or (
        status = 'failed'
        and attempt_count > 0
        and claim_token is not null
        and lease_expires_at is null
        and next_attempt_at is null
        and last_error_code is not null
        and started_at is not null
        and completed_at is null
        and failed_at is not null
        and transcript_text is null
        and language_code is null
        and segments = '[]'::jsonb
      )
    )
);

create index call_transcriptions_queued_claim_idx
on public.call_transcriptions (next_attempt_at, created_at, id)
where status = 'queued';

create index call_transcriptions_expired_lease_idx
on public.call_transcriptions (lease_expires_at, created_at, id)
where status = 'processing';

create trigger call_transcriptions_set_updated_at
before update on public.call_transcriptions
for each row execute function private.set_updated_at();

create function private.is_call_transcription_eligible(
  target_call_id uuid,
  target_workspace_id uuid,
  target_status text,
  target_storage_bucket text,
  target_storage_path text,
  target_content_type text,
  target_size_bytes bigint,
  target_upload_completed_at timestamptz
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(
    target_status = 'uploaded'
    and target_storage_bucket = 'call-audio'
    and target_content_type in (
      'audio/mpeg',
      'audio/mp4',
      'audio/x-m4a',
      'audio/wav',
      'audio/webm',
      'audio/ogg'
    )
    and target_storage_path = pg_catalog.format(
      '%s/%s/source%s',
      target_workspace_id,
      target_call_id,
      case target_content_type
        when 'audio/mpeg' then '.mp3'
        when 'audio/mp4' then '.mp4'
        when 'audio/x-m4a' then '.m4a'
        when 'audio/wav' then '.wav'
        when 'audio/webm' then '.webm'
        when 'audio/ogg' then '.ogg'
        else null
      end
    )
    and target_size_bytes between 1 and 26214400
    and target_upload_completed_at is not null,
    false
  );
$$;

create function private.enqueue_call_transcription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.is_call_transcription_eligible(
    new.id,
    new.workspace_id,
    new.status,
    new.storage_bucket,
    new.storage_path,
    new.content_type,
    new.size_bytes,
    new.upload_completed_at
  ) then
    insert into public.call_transcriptions (call_id)
    values (new.id)
    on conflict (call_id) do nothing;
  end if;

  return new;
end;
$$;

create function private.backfill_call_transcriptions()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  inserted_count bigint;
begin
  insert into public.call_transcriptions (call_id)
  select call.id
  from public.calls as call
  where private.is_call_transcription_eligible(
    call.id,
    call.workspace_id,
    call.status,
    call.storage_bucket,
    call.storage_path,
    call.content_type,
    call.size_bytes,
    call.upload_completed_at
  )
  on conflict (call_id) do nothing;

  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

revoke all on function private.is_call_transcription_eligible(
  uuid, uuid, text, text, text, text, bigint, timestamptz
) from public, anon, authenticated, service_role;
revoke all on function private.enqueue_call_transcription()
from public, anon, authenticated, service_role;
revoke all on function private.backfill_call_transcriptions()
from public, anon, authenticated, service_role;

create trigger calls_enqueue_transcription
after insert or update of
  status,
  storage_bucket,
  storage_path,
  content_type,
  size_bytes,
  upload_completed_at
on public.calls
for each row execute function private.enqueue_call_transcription();

select private.backfill_call_transcriptions();

create function public.claim_transcription_jobs(p_limit integer default 1)
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
    for update of transcription skip locked
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

create function public.renew_transcription_lease(
  p_call_id uuid,
  p_claim_token uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  updated_count bigint;
begin
  if p_call_id is null or p_claim_token is null then
    return false;
  end if;

  update public.call_transcriptions as transcription
  set lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes'
  where transcription.call_id = p_call_id
    and transcription.status = 'processing'
    and transcription.claim_token = p_claim_token
    and transcription.lease_expires_at > pg_catalog.clock_timestamp();

  get diagnostics updated_count = row_count;
  return updated_count = 1;
end;
$$;

create function public.complete_transcription_job(
  p_call_id uuid,
  p_claim_token uuid,
  p_transcript_text text,
  p_language_code text,
  p_segments jsonb,
  p_duration_seconds integer
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
  target_job public.call_transcriptions%rowtype;
  normalized_transcript text;
  normalized_language_code text;
begin
  if p_call_id is null or p_claim_token is null then
    return;
  end if;

  select transcription.*
  into target_job
  from public.call_transcriptions as transcription
  where transcription.call_id = p_call_id
  for update;

  if not found then
    return;
  end if;

  if target_job.status = 'completed' then
    if target_job.claim_token = p_claim_token then
      return query select target_job.call_id, 'completed'::text;
    end if;
    return;
  end if;

  if target_job.status <> 'processing'
    or target_job.claim_token <> p_claim_token
    or target_job.lease_expires_at <= pg_catalog.clock_timestamp()
  then
    return;
  end if;

  normalized_transcript := pg_catalog.btrim(p_transcript_text);
  if normalized_transcript is null
    or normalized_transcript = ''
    or pg_catalog.length(normalized_transcript) > 1000000
  then
    raise exception 'Transcript text must contain between 1 and 1000000 characters'
      using errcode = '22023';
  end if;

  if p_segments is null
    or pg_catalog.jsonb_typeof(p_segments) <> 'array'
    or pg_catalog.pg_column_size(p_segments) > 5000000
  then
    raise exception 'Segments must be a JSON array within the size limit'
      using errcode = '22023';
  end if;

  if p_language_code is null then
    normalized_language_code := null;
  else
    normalized_language_code := pg_catalog.lower(pg_catalog.btrim(p_language_code));
    if pg_catalog.length(normalized_language_code) not between 2 and 24
      or normalized_language_code !~ '^[a-z]{2,3}(-[a-z0-9]{2,8}){0,2}$'
    then
      raise exception 'Language code is invalid' using errcode = '22023';
    end if;
  end if;

  if p_duration_seconds is not null
    and (p_duration_seconds < 0 or p_duration_seconds > 604800)
  then
    raise exception 'Duration must be between 0 and 604800 seconds'
      using errcode = '22023';
  end if;

  perform 1
  from public.calls as call
  where call.id = p_call_id
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
  for update;

  if not found then
    return;
  end if;

  if p_duration_seconds is not null then
    update public.calls as call
    set duration_seconds = p_duration_seconds
    where call.id = p_call_id;
  end if;

  update public.call_transcriptions as transcription
  set
    status = 'completed',
    transcript_text = normalized_transcript,
    language_code = normalized_language_code,
    segments = p_segments,
    lease_expires_at = null,
    next_attempt_at = null,
    last_error_code = null,
    completed_at = pg_catalog.now(),
    failed_at = null
  where transcription.id = target_job.id
    and transcription.status = 'processing'
    and transcription.claim_token = p_claim_token;

  if found then
    return query select target_job.call_id, 'completed'::text;
  end if;
end;
$$;

create function public.fail_transcription_job(
  p_call_id uuid,
  p_claim_token uuid,
  p_error_code text,
  p_retryable boolean
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
  target_job public.call_transcriptions%rowtype;
  normalized_error_code text := pg_catalog.lower(pg_catalog.btrim(p_error_code));
  result_status text;
begin
  if normalized_error_code is null
    or pg_catalog.length(normalized_error_code) not between 1 and 64
    or normalized_error_code !~ '^[a-z][a-z0-9_]*$'
  then
    raise exception 'Error code is invalid' using errcode = '22023';
  end if;

  if p_call_id is null or p_claim_token is null or p_retryable is null then
    return;
  end if;

  select transcription.*
  into target_job
  from public.call_transcriptions as transcription
  where transcription.call_id = p_call_id
  for update;

  if not found or target_job.claim_token <> p_claim_token then
    return;
  end if;

  if target_job.status = 'queued'
    and p_retryable
    and target_job.last_error_code = normalized_error_code
    and target_job.next_attempt_at is not null
  then
    return query select target_job.call_id, 'queued'::text;
    return;
  end if;

  if target_job.status = 'failed'
    and target_job.last_error_code = normalized_error_code
    and (not p_retryable or target_job.attempt_count >= 3)
  then
    return query select target_job.call_id, 'failed'::text;
    return;
  end if;

  if target_job.status <> 'processing'
    or target_job.lease_expires_at <= pg_catalog.clock_timestamp()
  then
    return;
  end if;

  if p_retryable and target_job.attempt_count < 3 then
    result_status := 'queued';
    update public.call_transcriptions as transcription
    set
      status = 'queued',
      lease_expires_at = null,
      next_attempt_at = pg_catalog.now() + interval '5 minutes',
      last_error_code = normalized_error_code,
      failed_at = null
    where transcription.id = target_job.id;
  else
    result_status := 'failed';
    update public.call_transcriptions as transcription
    set
      status = 'failed',
      lease_expires_at = null,
      next_attempt_at = null,
      last_error_code = normalized_error_code,
      failed_at = pg_catalog.now()
    where transcription.id = target_job.id;
  end if;

  return query select target_job.call_id, result_status;
end;
$$;

alter table public.call_transcriptions enable row level security;

create policy call_transcriptions_select_member
on public.call_transcriptions
for select
to authenticated
using (private.is_call_workspace_member(call_id));

revoke all on table public.call_transcriptions
from public, anon, authenticated, service_role;
grant select (
  id,
  call_id,
  status,
  transcript_text,
  language_code,
  segments,
  started_at,
  completed_at,
  created_at,
  updated_at
) on table public.call_transcriptions to authenticated;

revoke all on function public.claim_transcription_jobs(integer)
from public, anon, authenticated;
grant execute on function public.claim_transcription_jobs(integer) to service_role;

revoke all on function public.renew_transcription_lease(uuid, uuid)
from public, anon, authenticated;
grant execute on function public.renew_transcription_lease(uuid, uuid) to service_role;

revoke all on function public.complete_transcription_job(
  uuid, uuid, text, text, jsonb, integer
) from public, anon, authenticated;
grant execute on function public.complete_transcription_job(
  uuid, uuid, text, text, jsonb, integer
) to service_role;

revoke all on function public.fail_transcription_job(uuid, uuid, text, boolean)
from public, anon, authenticated;
grant execute on function public.fail_transcription_job(uuid, uuid, text, boolean)
to service_role;

comment on table public.call_transcriptions is
  'Tenant-readable transcription state with worker-only claim, lease, retry, and error fields.';
comment on column public.call_transcriptions.claim_token is
  'Retained after completion or failure so a worker can safely retry a lost RPC response; browser roles cannot select it.';
comment on function public.claim_transcription_jobs(integer) is
  'Claims a bounded oldest-first batch of eligible transcription jobs for the isolated service-role worker.';
comment on function public.renew_transcription_lease(uuid, uuid) is
  'Renews an active transcription claim for a fixed fifteen-minute lease.';
comment on function public.complete_transcription_job(uuid, uuid, text, text, jsonb, integer) is
  'Completes the exact active claim and permits same-token idempotent response recovery.';
comment on function public.fail_transcription_job(uuid, uuid, text, boolean) is
  'Records a bounded safe error code and applies the fixed retry or terminal-failure policy.';

commit;
