begin;

create table public.call_speaker_attributions (
  call_id uuid primary key references public.calls(id) on delete cascade,
  status text not null default 'queued',
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
  constraint call_speaker_attributions_status_check
    check (status in ('queued', 'processing', 'completed', 'failed')),
  constraint call_speaker_attributions_attempt_count_check
    check (attempt_count between 0 and 3),
  constraint call_speaker_attributions_error_code_check
    check (
      last_error_code is null
      or (
        pg_catalog.length(last_error_code) between 1 and 64
        and last_error_code ~ '^[a-z][a-z0-9_]*$'
      )
    ),
  constraint call_speaker_attributions_lifecycle_check
    check (
      (
        status = 'queued'
        and attempt_count < 3
        and lease_expires_at is null
        and completed_at is null
        and failed_at is null
        and (
          (
            attempt_count = 0
            and claim_token is null
            and next_attempt_at is null
            and last_error_code is null
            and started_at is null
          )
          or (
            attempt_count > 0
            and claim_token is not null
            and next_attempt_at is not null
            and last_error_code is not null
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
      )
    )
);

create table public.call_transcript_turns (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  call_id uuid not null references public.call_speaker_attributions(call_id)
    on delete cascade,
  turn_index integer not null,
  start_ms integer not null,
  end_ms integer not null,
  text text not null,
  speaker_key text not null,
  speaker_role text not null default 'unknown',
  created_at timestamptz not null default now(),
  constraint call_transcript_turns_call_ordinal_unique unique (call_id, turn_index),
  constraint call_transcript_turns_ordinal_check
    check (turn_index between 0 and 9999),
  constraint call_transcript_turns_timing_check
    check (start_ms >= 0 and end_ms >= start_ms and end_ms <= 3600000),
  constraint call_transcript_turns_text_check
    check (pg_catalog.length(pg_catalog.btrim(text)) between 1 and 5000),
  constraint call_transcript_turns_speaker_key_check
    check (speaker_key = 'unknown' or speaker_key ~ '^speaker_[1-8]$'),
  constraint call_transcript_turns_speaker_role_check
    check (speaker_role in ('agent', 'customer', 'unknown'))
);

create index call_speaker_attributions_queued_claim_idx
on public.call_speaker_attributions (next_attempt_at, created_at, call_id)
where status = 'queued';

create index call_speaker_attributions_expired_lease_idx
on public.call_speaker_attributions (lease_expires_at, created_at, call_id)
where status = 'processing';

create index call_transcript_turns_timeline_idx
on public.call_transcript_turns (call_id, turn_index);

create trigger call_speaker_attributions_set_updated_at
before update on public.call_speaker_attributions
for each row execute function private.set_updated_at();

create function private.is_speaker_attribution_eligible(
  target_call_id uuid,
  target_workspace_id uuid,
  target_call_status text,
  target_storage_bucket text,
  target_storage_path text,
  target_content_type text,
  target_size_bytes bigint,
  target_upload_completed_at timestamptz,
  target_duration_seconds integer,
  target_transcription_status text,
  target_transcript_text text,
  target_segments jsonb,
  target_transcription_completed_at timestamptz
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(
    target_call_status <> 'deleting'
    and target_storage_bucket = 'call-audio'
    and target_content_type in (
      'audio/mpeg', 'audio/mp4', 'audio/x-m4a',
      'audio/wav', 'audio/webm', 'audio/ogg'
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
    and target_upload_completed_at is not null
    and target_duration_seconds between 1 and 3600
    and target_transcription_status = 'completed'
    and target_transcript_text is not null
    and pg_catalog.length(pg_catalog.btrim(target_transcript_text)) between 1 and 1000000
    and target_segments is not null
    and pg_catalog.jsonb_typeof(target_segments) = 'array'
    and pg_catalog.jsonb_array_length(target_segments) between 1 and 10000
    and pg_catalog.pg_column_size(target_segments) <= 5000000
    and target_transcription_completed_at is not null,
    false
  );
$$;

create function private.try_enqueue_speaker_attribution(
  target_call_id uuid,
  target_workspace_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  result_call_id uuid;
begin
  perform 1
  from public.calls as call
  join public.call_transcriptions as transcription
    on transcription.call_id = call.id
  where call.id = target_call_id
    and call.workspace_id = target_workspace_id
    and private.is_speaker_attribution_eligible(
      call.id,
      call.workspace_id,
      call.status,
      call.storage_bucket,
      call.storage_path,
      call.content_type,
      call.size_bytes,
      call.upload_completed_at,
      call.duration_seconds,
      transcription.status,
      transcription.transcript_text,
      transcription.segments,
      transcription.completed_at
    )
    and exists (
      select 1
      from storage.objects as object
      where object.bucket_id = call.storage_bucket
        and object.name = call.storage_path
    )
  for update of call;

  if not found then
    return null;
  end if;

  insert into public.call_speaker_attributions (call_id)
  values (target_call_id)
  on conflict (call_id) do nothing
  returning call_id into result_call_id;

  if result_call_id is null then
    select attribution.call_id
    into result_call_id
    from public.call_speaker_attributions as attribution
    where attribution.call_id = target_call_id;
  end if;

  return result_call_id;
end;
$$;

create function private.enqueue_speaker_attribution_after_transcription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_workspace_id uuid;
begin
  select call.workspace_id
  into target_workspace_id
  from public.calls as call
  where call.id = new.call_id;

  if target_workspace_id is not null then
    perform private.try_enqueue_speaker_attribution(
      new.call_id,
      target_workspace_id
    );
  end if;

  return new;
end;
$$;

create trigger call_transcriptions_enqueue_speaker_attribution
after update of status on public.call_transcriptions
for each row
when (old.status is distinct from new.status and new.status = 'completed')
execute function private.enqueue_speaker_attribution_after_transcription();

create function public.queue_call_speaker_attribution(
  p_workspace_id uuid,
  p_call_id uuid
)
returns table (
  call_id uuid,
  status text,
  created boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  existing_status text;
  queued_call_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_call_id is null then
    raise exception 'Workspace and call are required' using errcode = '22023';
  end if;

  perform 1
  from public.workspace_members as member
  where member.workspace_id = p_workspace_id
    and member.user_id = current_user_id
    and member.role in ('owner', 'admin')
  for share of member;

  if not found then
    raise exception 'Speaker attribution is not authorized'
      using errcode = '42501';
  end if;

  select attribution.status
  into existing_status
  from public.call_speaker_attributions as attribution
  join public.calls as call on call.id = attribution.call_id
  where attribution.call_id = p_call_id
    and call.workspace_id = p_workspace_id;

  if existing_status is not null then
    return query select p_call_id, existing_status, false;
    return;
  end if;

  queued_call_id := private.try_enqueue_speaker_attribution(
    p_call_id,
    p_workspace_id
  );

  if queued_call_id is null then
    return query select null::uuid, 'ineligible'::text, false;
    return;
  end if;

  return query select queued_call_id, 'queued'::text, true;
end;
$$;

create function public.claim_speaker_attribution_jobs(p_limit integer default 1)
returns table (
  call_id uuid,
  workspace_id uuid,
  storage_bucket text,
  storage_path text,
  content_type text,
  size_bytes bigint,
  duration_seconds integer,
  segments jsonb,
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
    select attribution.call_id
    from public.call_speaker_attributions as attribution
    where attribution.status = 'processing'
      and attribution.lease_expires_at <= pg_catalog.clock_timestamp()
      and attribution.attempt_count >= 3
    order by attribution.lease_expires_at, attribution.created_at, attribution.call_id
    for update of attribution skip locked
    limit p_limit
  )
  update public.call_speaker_attributions as attribution
  set
    status = 'failed',
    lease_expires_at = null,
    next_attempt_at = null,
    last_error_code = 'worker_lease_expired',
    failed_at = pg_catalog.now()
  from exhausted
  where attribution.call_id = exhausted.call_id;

  for target_job in
    select
      attribution.call_id,
      call.workspace_id,
      call.storage_bucket,
      call.storage_path,
      call.content_type,
      call.size_bytes,
      call.duration_seconds,
      transcription.segments
    from public.call_speaker_attributions as attribution
    join public.calls as call on call.id = attribution.call_id
    join public.call_transcriptions as transcription
      on transcription.call_id = attribution.call_id
    where (
        (
          attribution.status = 'queued'
          and (
            attribution.next_attempt_at is null
            or attribution.next_attempt_at <= pg_catalog.now()
          )
        )
        or (
          attribution.status = 'processing'
          and attribution.lease_expires_at <= pg_catalog.clock_timestamp()
        )
      )
      and attribution.attempt_count < 3
      and private.is_speaker_attribution_eligible(
        call.id,
        call.workspace_id,
        call.status,
        call.storage_bucket,
        call.storage_path,
        call.content_type,
        call.size_bytes,
        call.upload_completed_at,
        call.duration_seconds,
        transcription.status,
        transcription.transcript_text,
        transcription.segments,
        transcription.completed_at
      )
    order by
      case
        when attribution.status = 'queued'
          then coalesce(attribution.next_attempt_at, attribution.created_at)
        else attribution.lease_expires_at
      end,
      attribution.created_at,
      attribution.call_id
    for update of attribution skip locked
    limit p_limit
  loop
    new_claim_token := pg_catalog.gen_random_uuid();

    update public.call_speaker_attributions as attribution
    set
      status = 'processing',
      attempt_count = attribution.attempt_count + 1,
      claim_token = new_claim_token,
      lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes',
      next_attempt_at = null,
      last_error_code = null,
      started_at = coalesce(attribution.started_at, pg_catalog.now()),
      failed_at = null
    where attribution.call_id = target_job.call_id
    returning attribution.attempt_count into new_attempt_count;

    call_id := target_job.call_id;
    workspace_id := target_job.workspace_id;
    storage_bucket := target_job.storage_bucket;
    storage_path := target_job.storage_path;
    content_type := target_job.content_type;
    size_bytes := target_job.size_bytes;
    duration_seconds := target_job.duration_seconds;
    segments := target_job.segments;
    claim_token := new_claim_token;
    attempt_count := new_attempt_count;
    return next;
  end loop;
end;
$$;

create function public.renew_speaker_attribution_lease(
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

  update public.call_speaker_attributions as attribution
  set lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes'
  where attribution.call_id = p_call_id
    and attribution.status = 'processing'
    and attribution.claim_token = p_claim_token
    and attribution.lease_expires_at > pg_catalog.clock_timestamp();

  get diagnostics updated_count = row_count;
  return updated_count = 1;
end;
$$;

create function public.complete_speaker_attribution_job(
  p_call_id uuid,
  p_claim_token uuid,
  p_turns jsonb
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
  target_job public.call_speaker_attributions%rowtype;
  target_duration_ms integer;
  turn_value jsonb;
  expected_index integer := 0;
  previous_start integer := -1;
  current_index integer;
  current_start integer;
  current_end integer;
  current_text text;
  current_speaker_key text;
  current_speaker_role text;
  total_characters integer := 0;
  key_count integer;
begin
  if p_call_id is null or p_claim_token is null then
    return;
  end if;

  select attribution.*
  into target_job
  from public.call_speaker_attributions as attribution
  where attribution.call_id = p_call_id
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

  select call.duration_seconds * 1000
  into target_duration_ms
  from public.calls as call
  join public.call_transcriptions as transcription
    on transcription.call_id = call.id
  where call.id = p_call_id
    and private.is_speaker_attribution_eligible(
      call.id,
      call.workspace_id,
      call.status,
      call.storage_bucket,
      call.storage_path,
      call.content_type,
      call.size_bytes,
      call.upload_completed_at,
      call.duration_seconds,
      transcription.status,
      transcription.transcript_text,
      transcription.segments,
      transcription.completed_at
    )
  for update of call;

  if not found then
    return;
  end if;

  if p_turns is null
    or pg_catalog.jsonb_typeof(p_turns) <> 'array'
    or pg_catalog.jsonb_array_length(p_turns) not between 1 and 10000
    or pg_catalog.pg_column_size(p_turns) > 5000000
  then
    raise exception 'Speaker turns must be a bounded JSON array'
      using errcode = '22023';
  end if;

  for turn_value in
    select value from pg_catalog.jsonb_array_elements(p_turns)
  loop
    if pg_catalog.jsonb_typeof(turn_value) <> 'object' then
      raise exception 'Speaker turn is invalid' using errcode = '22023';
    end if;

    select count(*) into key_count
    from pg_catalog.jsonb_object_keys(turn_value);
    if key_count <> 6
      or not (turn_value ?& array[
        'turn_index', 'start_ms', 'end_ms', 'text',
        'speaker_key', 'speaker_role'
      ])
      or pg_catalog.jsonb_typeof(turn_value -> 'turn_index') <> 'number'
      or pg_catalog.jsonb_typeof(turn_value -> 'start_ms') <> 'number'
      or pg_catalog.jsonb_typeof(turn_value -> 'end_ms') <> 'number'
      or pg_catalog.jsonb_typeof(turn_value -> 'text') <> 'string'
      or pg_catalog.jsonb_typeof(turn_value -> 'speaker_key') <> 'string'
      or pg_catalog.jsonb_typeof(turn_value -> 'speaker_role') <> 'string'
      or turn_value ->> 'turn_index' !~ '^[0-9]+$'
      or turn_value ->> 'start_ms' !~ '^[0-9]+$'
      or turn_value ->> 'end_ms' !~ '^[0-9]+$'
    then
      raise exception 'Speaker turn is invalid' using errcode = '22023';
    end if;

    current_index := (turn_value ->> 'turn_index')::integer;
    current_start := (turn_value ->> 'start_ms')::integer;
    current_end := (turn_value ->> 'end_ms')::integer;
    current_text := pg_catalog.btrim(turn_value ->> 'text');
    current_speaker_key := turn_value ->> 'speaker_key';
    current_speaker_role := turn_value ->> 'speaker_role';

    if current_index <> expected_index
      or current_start < previous_start
      or current_end < current_start
      or current_end > target_duration_ms
      or current_text is null
      or pg_catalog.length(current_text) not between 1 and 5000
      or (
        current_speaker_key <> 'unknown'
        and current_speaker_key !~ '^speaker_[1-8]$'
      )
      or current_speaker_role not in ('agent', 'customer', 'unknown')
    then
      raise exception 'Speaker turn is invalid' using errcode = '22023';
    end if;

    total_characters := total_characters + pg_catalog.length(current_text);
    if total_characters > 1000000 then
      raise exception 'Speaker turn text exceeds the call limit'
        using errcode = '22023';
    end if;

    expected_index := expected_index + 1;
    previous_start := current_start;
  end loop;

  delete from public.call_transcript_turns as turn
  where turn.call_id = p_call_id;

  insert into public.call_transcript_turns (
    call_id,
    turn_index,
    start_ms,
    end_ms,
    text,
    speaker_key,
    speaker_role
  )
  select
    p_call_id,
    (item.value ->> 'turn_index')::integer,
    (item.value ->> 'start_ms')::integer,
    (item.value ->> 'end_ms')::integer,
    pg_catalog.btrim(item.value ->> 'text'),
    item.value ->> 'speaker_key',
    item.value ->> 'speaker_role'
  from pg_catalog.jsonb_array_elements(p_turns) as item(value)
  order by (item.value ->> 'turn_index')::integer;

  update public.call_speaker_attributions as attribution
  set
    status = 'completed',
    lease_expires_at = null,
    next_attempt_at = null,
    last_error_code = null,
    completed_at = pg_catalog.now(),
    failed_at = null
  where attribution.call_id = p_call_id
    and attribution.status = 'processing'
    and attribution.claim_token = p_claim_token
    and attribution.lease_expires_at > pg_catalog.clock_timestamp();

  if not found then
    raise exception 'Speaker attribution lease is no longer active'
      using errcode = '55000';
  end if;

  return query select p_call_id, 'completed'::text;
end;
$$;

create function public.fail_speaker_attribution_job(
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
  target_job public.call_speaker_attributions%rowtype;
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

  select attribution.*
  into target_job
  from public.call_speaker_attributions as attribution
  where attribution.call_id = p_call_id
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
    update public.call_speaker_attributions as attribution
    set
      status = 'queued',
      lease_expires_at = null,
      next_attempt_at = pg_catalog.now() + interval '5 minutes',
      last_error_code = normalized_error_code,
      failed_at = null
    where attribution.call_id = target_job.call_id;
  else
    result_status := 'failed';
    update public.call_speaker_attributions as attribution
    set
      status = 'failed',
      lease_expires_at = null,
      next_attempt_at = null,
      last_error_code = normalized_error_code,
      failed_at = pg_catalog.now()
    where attribution.call_id = target_job.call_id;
  end if;

  return query select target_job.call_id, result_status;
end;
$$;

create or replace function public.prepare_call_deletion(
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
  speaker_status text;
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
    select 'already_deleting'::text, target_call.storage_bucket, target_call.storage_path;
    return;
  end if;

  select analysis.status into analysis_status
  from public.call_analyses as analysis
  where analysis.call_id = p_call_id;

  select transcription.status into transcription_status
  from public.call_transcriptions as transcription
  where transcription.call_id = p_call_id;

  select attribution.status into speaker_status
  from public.call_speaker_attributions as attribution
  where attribution.call_id = p_call_id;

  if transcription_status = 'processing'
    or analysis_status = 'processing'
    or speaker_status = 'processing'
  then
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
    return query select 'prepared'::text, target_call.storage_bucket, target_call.storage_path;
  end if;
end;
$$;

create function private.can_view_completed_speaker_turn(target_call_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.call_speaker_attributions as attribution
    join public.calls as call on call.id = attribution.call_id
    join public.workspace_members as member
      on member.workspace_id = call.workspace_id
     and member.user_id = (select auth.uid())
    where attribution.call_id = target_call_id
      and attribution.status = 'completed'
  );
$$;

revoke all on function private.is_speaker_attribution_eligible(
  uuid, uuid, text, text, text, text, bigint, timestamptz, integer,
  text, text, jsonb, timestamptz
) from public, anon, authenticated, service_role;
revoke all on function private.try_enqueue_speaker_attribution(uuid, uuid)
from public, anon, authenticated, service_role;
revoke all on function private.enqueue_speaker_attribution_after_transcription()
from public, anon, authenticated, service_role;
revoke all on function private.can_view_completed_speaker_turn(uuid)
from public, anon, authenticated, service_role;
grant execute on function private.can_view_completed_speaker_turn(uuid)
to authenticated;

alter table public.call_speaker_attributions enable row level security;
alter table public.call_transcript_turns enable row level security;

create policy call_speaker_attributions_select_member
on public.call_speaker_attributions
for select
to authenticated
using (private.is_call_workspace_member(call_id));

create policy call_transcript_turns_select_completed_member
on public.call_transcript_turns
for select
to authenticated
using (private.can_view_completed_speaker_turn(call_id));

revoke all on table public.call_speaker_attributions
from public, anon, authenticated, service_role;
revoke all on table public.call_transcript_turns
from public, anon, authenticated, service_role;

grant select (
  call_id,
  status,
  started_at,
  completed_at,
  created_at,
  updated_at
) on table public.call_speaker_attributions to authenticated;

grant select (
  id,
  call_id,
  turn_index,
  start_ms,
  end_ms,
  text,
  speaker_key,
  speaker_role,
  created_at
) on table public.call_transcript_turns to authenticated;

revoke all on function public.queue_call_speaker_attribution(uuid, uuid)
from public, anon, authenticated, service_role;
grant execute on function public.queue_call_speaker_attribution(uuid, uuid)
to authenticated;

revoke all on function public.claim_speaker_attribution_jobs(integer)
from public, anon, authenticated, service_role;
grant execute on function public.claim_speaker_attribution_jobs(integer)
to service_role;

revoke all on function public.renew_speaker_attribution_lease(uuid, uuid)
from public, anon, authenticated, service_role;
grant execute on function public.renew_speaker_attribution_lease(uuid, uuid)
to service_role;

revoke all on function public.complete_speaker_attribution_job(uuid, uuid, jsonb)
from public, anon, authenticated, service_role;
grant execute on function public.complete_speaker_attribution_job(uuid, uuid, jsonb)
to service_role;

revoke all on function public.fail_speaker_attribution_job(uuid, uuid, text, boolean)
from public, anon, authenticated, service_role;
grant execute on function public.fail_speaker_attribution_job(uuid, uuid, text, boolean)
to service_role;

comment on table public.call_speaker_attributions is
  'Canonical per-call local speaker-attribution job with browser-private worker lifecycle metadata.';
comment on table public.call_transcript_turns is
  'Derived timestamped transcript turns with stable IDs for future explainable evidence.';
comment on function public.queue_call_speaker_attribution(uuid, uuid) is
  'Allows an owner or admin to idempotently queue an eligible existing completed call.';
comment on function public.complete_speaker_attribution_job(uuid, uuid, jsonb) is
  'Atomically validates and persists one complete bounded turn set for an active worker lease.';

commit;
