begin;

create or replace function private.enqueue_speaker_attribution_after_transcription()
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

drop trigger if exists call_transcriptions_enqueue_speaker_attribution
on public.call_transcriptions;

create trigger call_transcriptions_enqueue_speaker_attribution
after insert or update of status, transcript_text, segments, completed_at
on public.call_transcriptions
for each row
execute function private.enqueue_speaker_attribution_after_transcription();

create function private.enqueue_speaker_attribution_after_call_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.try_enqueue_speaker_attribution(
    new.id,
    new.workspace_id
  );
  return new;
end;
$$;

create trigger calls_recheck_speaker_attribution
after insert or update of
  status,
  storage_bucket,
  storage_path,
  content_type,
  size_bytes,
  upload_completed_at,
  duration_seconds
on public.calls
for each row
execute function private.enqueue_speaker_attribution_after_call_change();

create function public.retry_call_speaker_attribution(
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
  target_job public.call_speaker_attributions%rowtype;
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
    raise exception 'Speaker attribution retry is not authorized'
      using errcode = '42501';
  end if;

  select attribution.*
  into target_job
  from public.call_speaker_attributions as attribution
  join public.calls as call on call.id = attribution.call_id
  join public.call_transcriptions as transcription
    on transcription.call_id = attribution.call_id
  where attribution.call_id = p_call_id
    and call.workspace_id = p_workspace_id
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
  for update of call, attribution;

  if not found then
    return;
  end if;

  if target_job.status <> 'failed' then
    raise exception 'Only a failed speaker attribution can be retried'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from public.call_transcript_turns as turn
    where turn.call_id = p_call_id
  ) then
    raise exception 'Failed speaker attribution contains unexpected completed turns'
      using errcode = '55000';
  end if;

  update public.call_speaker_attributions as attribution
  set
    status = 'queued',
    attempt_count = 0,
    claim_token = null,
    lease_expires_at = null,
    next_attempt_at = null,
    last_error_code = null,
    started_at = null,
    completed_at = null,
    failed_at = null
  where attribution.call_id = p_call_id
    and attribution.status = 'failed';

  if found then
    return query select p_call_id, 'queued'::text;
  end if;
end;
$$;

create or replace function public.complete_speaker_attribution_job(
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
  detected_speaker_count integer;
  agent_speaker_count integer;
  customer_speaker_count integer;
  unknown_speaker_count integer;
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
      or (
        current_speaker_key = 'unknown'
        and current_speaker_role <> 'unknown'
      )
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

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(p_turns) as item(value)
    where item.value ->> 'speaker_key' <> 'unknown'
    group by item.value ->> 'speaker_key'
    having count(distinct item.value ->> 'speaker_role') <> 1
  ) then
    raise exception 'Speaker roles must be stable for each acoustic speaker'
      using errcode = '22023';
  end if;

  select
    count(*),
    count(*) filter (where speaker_role = 'agent'),
    count(*) filter (where speaker_role = 'customer'),
    count(*) filter (where speaker_role = 'unknown')
  into
    detected_speaker_count,
    agent_speaker_count,
    customer_speaker_count,
    unknown_speaker_count
  from (
    select
      item.value ->> 'speaker_key' as speaker_key,
      min(item.value ->> 'speaker_role') as speaker_role
    from pg_catalog.jsonb_array_elements(p_turns) as item(value)
    where item.value ->> 'speaker_key' <> 'unknown'
    group by item.value ->> 'speaker_key'
  ) as detected;

  if detected_speaker_count = 1
    and unknown_speaker_count <> 1
  then
    raise exception 'One acoustic speaker must remain unknown'
      using errcode = '22023';
  end if;

  if detected_speaker_count = 2
    and not (
      (
        agent_speaker_count = 1
        and customer_speaker_count = 1
        and unknown_speaker_count = 0
      )
      or (
        agent_speaker_count = 0
        and customer_speaker_count = 0
        and unknown_speaker_count = 2
      )
    )
  then
    raise exception 'Two acoustic speakers require a complete role pair or full uncertainty'
      using errcode = '22023';
  end if;

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

revoke all on function private.enqueue_speaker_attribution_after_transcription()
from public, anon, authenticated, service_role;
revoke all on function private.enqueue_speaker_attribution_after_call_change()
from public, anon, authenticated, service_role;

revoke all on function public.retry_call_speaker_attribution(uuid, uuid)
from public, anon, authenticated, service_role;
grant execute on function public.retry_call_speaker_attribution(uuid, uuid)
to authenticated;

comment on function public.retry_call_speaker_attribution(uuid, uuid) is
  'Allows an owner or admin to reset one eligible terminal failed speaker job without changing transcript or Storage data.';

comment on function public.complete_speaker_attribution_job(uuid, uuid, jsonb) is
  'Atomically validates stable call-wide speaker roles and persists one complete bounded turn set for an active worker lease.';

commit;
