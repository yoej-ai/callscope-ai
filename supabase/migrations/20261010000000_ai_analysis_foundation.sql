begin;

do $$
begin
  if exists (select 1 from public.call_analyses) then
    raise exception 'Legacy call analysis rows require review before this migration can continue'
      using errcode = '55000';
  end if;
end;
$$;

create function private.is_bounded_analysis_string_array(
  target jsonb,
  maximum_elements integer,
  maximum_serialized_bytes integer,
  maximum_item_characters integer
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when target is null
      or pg_catalog.jsonb_typeof(target) <> 'array'
      or maximum_elements < 0
      or maximum_serialized_bytes < 2
      or maximum_item_characters < 1
    then false
    else
      pg_catalog.jsonb_array_length(target) <= maximum_elements
      and pg_catalog.octet_length(target::text) <= maximum_serialized_bytes
      and not exists (
        select 1
        from pg_catalog.jsonb_array_elements(target) as item(value)
        where pg_catalog.jsonb_typeof(item.value) <> 'string'
          or pg_catalog.length(pg_catalog.btrim(item.value #>> '{}'))
            not between 1 and maximum_item_characters
      )
  end;
$$;

revoke all on function private.is_bounded_analysis_string_array(
  jsonb, integer, integer, integer
) from public, anon, authenticated, service_role;

alter table public.call_analyses
  rename column intent to primary_intent;

alter table public.call_analyses
  rename column lead_score to overall_score;

alter table public.call_analyses
  drop constraint call_analyses_lead_score_check,
  drop constraint call_analyses_objections_array,
  drop constraint call_analyses_action_items_array,
  drop column recommended_follow_up,
  drop column raw_analysis,
  add column status text not null default 'queued',
  add column topics jsonb not null default '[]'::jsonb,
  add column attempt_count integer not null default 0,
  add column claim_token uuid,
  add column lease_expires_at timestamptz,
  add column next_attempt_at timestamptz,
  add column last_error_code text,
  add column started_at timestamptz,
  add column completed_at timestamptz,
  add column failed_at timestamptz,
  add constraint call_analyses_status_check
    check (status in ('queued', 'processing', 'completed', 'failed')),
  add constraint call_analyses_attempt_count_check
    check (attempt_count between 0 and 3),
  add constraint call_analyses_summary_check
    check (
      summary is null
      or (
        pg_catalog.length(pg_catalog.btrim(summary)) between 1 and 10000
        and summary = pg_catalog.btrim(summary)
      )
    ),
  add constraint call_analyses_sentiment_check
    check (sentiment is null or sentiment in ('positive', 'neutral', 'negative', 'mixed')),
  add constraint call_analyses_primary_intent_check
    check (
      primary_intent is null
      or (
        pg_catalog.length(pg_catalog.btrim(primary_intent)) between 1 and 500
        and primary_intent = pg_catalog.btrim(primary_intent)
      )
    ),
  add constraint call_analyses_objections_check
    check (private.is_bounded_analysis_string_array(objections, 25, 8192, 1000)),
  add constraint call_analyses_action_items_check
    check (private.is_bounded_analysis_string_array(action_items, 50, 32768, 1000)),
  add constraint call_analyses_topics_check
    check (private.is_bounded_analysis_string_array(topics, 50, 8192, 200)),
  add constraint call_analyses_overall_score_check
    check (overall_score is null or overall_score between 0 and 100),
  add constraint call_analyses_error_code_check
    check (
      last_error_code is null
      or (
        pg_catalog.length(last_error_code) between 1 and 64
        and last_error_code ~ '^[a-z][a-z0-9_]*$'
      )
    ),
  add constraint call_analyses_lifecycle_check
    check (
      (
        status = 'queued'
        and attempt_count < 3
        and lease_expires_at is null
        and completed_at is null
        and failed_at is null
        and summary is null
        and sentiment is null
        and primary_intent is null
        and objections = '[]'::jsonb
        and action_items = '[]'::jsonb
        and topics = '[]'::jsonb
        and overall_score is null
        and (
          (
            next_attempt_at is null
            and last_error_code is null
            and claim_token is null
            and attempt_count = 0
            and started_at is null
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
        and summary is null
        and sentiment is null
        and primary_intent is null
        and objections = '[]'::jsonb
        and action_items = '[]'::jsonb
        and topics = '[]'::jsonb
        and overall_score is null
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
        and summary is not null
        and sentiment is not null
        and primary_intent is not null
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
        and summary is null
        and sentiment is null
        and primary_intent is null
        and objections = '[]'::jsonb
        and action_items = '[]'::jsonb
        and topics = '[]'::jsonb
        and overall_score is null
      )
    );

create index call_analyses_queued_claim_idx
on public.call_analyses (next_attempt_at, created_at, id)
where status = 'queued';

create index call_analyses_expired_lease_idx
on public.call_analyses (lease_expires_at, created_at, id)
where status = 'processing';

create function private.is_call_analysis_eligible(
  target_status text,
  target_transcript_text text,
  target_completed_at timestamptz
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(
    target_status = 'completed'
    and target_transcript_text is not null
    and pg_catalog.length(pg_catalog.btrim(target_transcript_text))
      between 1 and 1000000
    and target_completed_at is not null,
    false
  );
$$;

create function private.enqueue_call_analysis()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.is_call_analysis_eligible(
    new.status,
    new.transcript_text,
    new.completed_at
  ) then
    insert into public.call_analyses (call_id)
    values (new.call_id)
    on conflict (call_id) do nothing;
  end if;

  return new;
end;
$$;

create function private.backfill_call_analyses()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  inserted_count bigint;
begin
  insert into public.call_analyses (call_id)
  select transcription.call_id
  from public.call_transcriptions as transcription
  where private.is_call_analysis_eligible(
    transcription.status,
    transcription.transcript_text,
    transcription.completed_at
  )
  on conflict (call_id) do nothing;

  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

revoke all on function private.is_call_analysis_eligible(text, text, timestamptz)
from public, anon, authenticated, service_role;
revoke all on function private.enqueue_call_analysis()
from public, anon, authenticated, service_role;
revoke all on function private.backfill_call_analyses()
from public, anon, authenticated, service_role;

create trigger call_transcriptions_enqueue_analysis
after insert or update of status, transcript_text, completed_at
on public.call_transcriptions
for each row execute function private.enqueue_call_analysis();

select private.backfill_call_analyses();

create function public.claim_analysis_jobs(p_limit integer default 1)
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
    for update of analysis skip locked
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

create function public.renew_analysis_lease(
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

  update public.call_analyses as analysis
  set lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes'
  where analysis.call_id = p_call_id
    and analysis.status = 'processing'
    and analysis.claim_token = p_claim_token
    and analysis.lease_expires_at > pg_catalog.clock_timestamp();

  get diagnostics updated_count = row_count;
  return updated_count = 1;
end;
$$;

create function public.complete_analysis_job(
  p_call_id uuid,
  p_claim_token uuid,
  p_summary text,
  p_sentiment text,
  p_primary_intent text,
  p_objections jsonb,
  p_action_items jsonb,
  p_topics jsonb,
  p_overall_score integer
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
  target_job public.call_analyses%rowtype;
  normalized_summary text;
  normalized_sentiment text;
  normalized_primary_intent text;
begin
  if p_call_id is null or p_claim_token is null then
    return;
  end if;

  select analysis.*
  into target_job
  from public.call_analyses as analysis
  where analysis.call_id = p_call_id
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

  normalized_summary := pg_catalog.btrim(p_summary);
  if normalized_summary is null
    or pg_catalog.length(normalized_summary) not between 1 and 10000
  then
    raise exception 'Summary must contain between 1 and 10000 characters'
      using errcode = '22023';
  end if;

  normalized_sentiment := pg_catalog.lower(pg_catalog.btrim(p_sentiment));
  if normalized_sentiment is null
    or normalized_sentiment not in ('positive', 'neutral', 'negative', 'mixed')
  then
    raise exception 'Sentiment is invalid' using errcode = '22023';
  end if;

  normalized_primary_intent := pg_catalog.btrim(p_primary_intent);
  if normalized_primary_intent is null
    or pg_catalog.length(normalized_primary_intent) not between 1 and 500
  then
    raise exception 'Primary intent must contain between 1 and 500 characters'
      using errcode = '22023';
  end if;

  if not private.is_bounded_analysis_string_array(p_objections, 25, 8192, 1000) then
    raise exception 'Objections must be a bounded JSON string array'
      using errcode = '22023';
  end if;

  if not private.is_bounded_analysis_string_array(p_action_items, 50, 32768, 1000) then
    raise exception 'Action items must be a bounded JSON string array'
      using errcode = '22023';
  end if;

  if not private.is_bounded_analysis_string_array(p_topics, 50, 8192, 200) then
    raise exception 'Topics must be a bounded JSON string array'
      using errcode = '22023';
  end if;

  if p_overall_score is not null and p_overall_score not between 0 and 100 then
    raise exception 'Overall score must be between 0 and 100'
      using errcode = '22023';
  end if;

  perform 1
  from public.call_transcriptions as transcription
  where transcription.call_id = p_call_id
    and private.is_call_analysis_eligible(
      transcription.status,
      transcription.transcript_text,
      transcription.completed_at
    )
  for update;

  if not found then
    return;
  end if;

  update public.call_analyses as analysis
  set
    status = 'completed',
    summary = normalized_summary,
    sentiment = normalized_sentiment,
    primary_intent = normalized_primary_intent,
    objections = p_objections,
    action_items = p_action_items,
    topics = p_topics,
    overall_score = p_overall_score,
    lease_expires_at = null,
    next_attempt_at = null,
    last_error_code = null,
    completed_at = pg_catalog.now(),
    failed_at = null
  where analysis.id = target_job.id
    and analysis.status = 'processing'
    and analysis.claim_token = p_claim_token;

  if found then
    return query select target_job.call_id, 'completed'::text;
  end if;
end;
$$;

create function public.fail_analysis_job(
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
  target_job public.call_analyses%rowtype;
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

  select analysis.*
  into target_job
  from public.call_analyses as analysis
  where analysis.call_id = p_call_id
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
    update public.call_analyses as analysis
    set
      status = 'queued',
      lease_expires_at = null,
      next_attempt_at = pg_catalog.now() + interval '5 minutes',
      last_error_code = normalized_error_code,
      failed_at = null
    where analysis.id = target_job.id;
  else
    result_status := 'failed';
    update public.call_analyses as analysis
    set
      status = 'failed',
      lease_expires_at = null,
      next_attempt_at = null,
      last_error_code = normalized_error_code,
      failed_at = pg_catalog.now()
    where analysis.id = target_job.id;
  end if;

  return query select target_job.call_id, result_status;
end;
$$;

alter table public.call_analyses enable row level security;

drop policy if exists call_analyses_select_member on public.call_analyses;
create policy call_analyses_select_member
on public.call_analyses
for select
to authenticated
using (private.is_call_workspace_member(call_id));

revoke all on table public.call_analyses
from public, anon, authenticated, service_role;
grant select (
  id,
  call_id,
  status,
  summary,
  sentiment,
  primary_intent,
  objections,
  action_items,
  topics,
  overall_score,
  started_at,
  completed_at,
  created_at,
  updated_at
) on table public.call_analyses to authenticated;

revoke all on function public.claim_analysis_jobs(integer)
from public, anon, authenticated, service_role;
grant execute on function public.claim_analysis_jobs(integer) to service_role;

revoke all on function public.renew_analysis_lease(uuid, uuid)
from public, anon, authenticated, service_role;
grant execute on function public.renew_analysis_lease(uuid, uuid) to service_role;

revoke all on function public.complete_analysis_job(
  uuid, uuid, text, text, text, jsonb, jsonb, jsonb, integer
) from public, anon, authenticated, service_role;
grant execute on function public.complete_analysis_job(
  uuid, uuid, text, text, text, jsonb, jsonb, jsonb, integer
) to service_role;

revoke all on function public.fail_analysis_job(uuid, uuid, text, boolean)
from public, anon, authenticated, service_role;
grant execute on function public.fail_analysis_job(uuid, uuid, text, boolean)
to service_role;

comment on table public.call_analyses is
  'Tenant-readable bounded analysis results with worker-only claim, lease, retry, and error fields.';
comment on column public.call_analyses.claim_token is
  'Retained after completion or failure for same-token response recovery; browser roles cannot select it.';
comment on function public.claim_analysis_jobs(integer) is
  'Claims completed transcripts as untrusted input for a future isolated service-role analysis worker.';
comment on function public.complete_analysis_job(
  uuid, uuid, text, text, text, jsonb, jsonb, jsonb, integer
) is
  'Validates and stores the bounded structured result for the exact active analysis claim.';
comment on function public.fail_analysis_job(uuid, uuid, text, boolean) is
  'Records a bounded safe error code and applies the fixed analysis retry or terminal-failure policy.';

commit;
