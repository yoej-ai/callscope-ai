begin;

create table public.workspace_scorecard_settings (
  workspace_id uuid primary key
    references public.workspaces(id) on delete cascade,
  playbook_id uuid not null
    references public.playbooks(id) on delete restrict,
  updated_by uuid not null
    references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.call_scorecards (
  id uuid primary key default gen_random_uuid(),
  call_id uuid not null references public.calls(id) on delete cascade,
  playbook_version_id uuid not null
    references public.playbook_versions(id) on delete restrict,
  status text not null default 'queued',
  attempt_count integer not null default 0,
  claim_token uuid,
  lease_expires_at timestamptz,
  next_attempt_at timestamptz,
  last_error_code text,
  overall_score numeric(5,2),
  review_required boolean not null default false,
  started_at timestamptz,
  completed_at timestamptz,
  failed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint call_scorecards_call_unique unique (call_id),
  constraint call_scorecards_status_check
    check (status in ('queued', 'processing', 'completed', 'failed')),
  constraint call_scorecards_attempt_count_check
    check (attempt_count between 0 and 3),
  constraint call_scorecards_overall_score_check
    check (overall_score is null or overall_score between 0 and 100),
  constraint call_scorecards_error_code_check
    check (
      last_error_code is null
      or (
        pg_catalog.length(last_error_code) between 1 and 64
        and last_error_code ~ '^[a-z][a-z0-9_]*$'
      )
    ),
  constraint call_scorecards_lifecycle_check
    check (
      (
        status = 'queued'
        and attempt_count < 3
        and lease_expires_at is null
        and overall_score is null
        and not review_required
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
        and overall_score is null
        and not review_required
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
        and overall_score is null
        and not review_required
        and started_at is not null
        and completed_at is null
        and failed_at is not null
      )
    )
);

create table public.call_scorecard_results (
  scorecard_id uuid not null
    references public.call_scorecards(id) on delete cascade,
  criterion_id uuid not null
    references public.playbook_criteria(id) on delete restrict,
  outcome text not null,
  created_at timestamptz not null default now(),
  primary key (scorecard_id, criterion_id),
  constraint call_scorecard_results_outcome_check
    check (
      outcome in (
        'pass',
        'fail',
        'not_applicable',
        'insufficient_evidence'
      )
    )
);

create index call_scorecards_queued_claim_idx
on public.call_scorecards (next_attempt_at, created_at, id)
where status = 'queued';

create index call_scorecards_expired_lease_idx
on public.call_scorecards (lease_expires_at, created_at, id)
where status = 'processing';

create index call_scorecards_version_idx
on public.call_scorecards (playbook_version_id, created_at, id);

create index call_scorecard_results_criterion_idx
on public.call_scorecard_results (criterion_id, scorecard_id);

create function private.guard_workspace_scorecard_setting()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.workspace_id <> old.workspace_id then
    raise exception 'Scorecard setting workspace is immutable'
      using errcode = '55000';
  end if;

  perform 1
  from public.playbooks as playbook
  where playbook.id = new.playbook_id
    and playbook.workspace_id = new.workspace_id
    and exists (
      select 1
      from public.playbook_versions as version
      where version.playbook_id = playbook.id
        and version.status = 'published'
    );

  if not found then
    raise exception 'Scorecard setting requires a same-workspace published Playbook'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create function private.guard_call_scorecard_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.call_id <> old.call_id
      or new.playbook_version_id <> old.playbook_version_id
    then
      raise exception 'Scorecard call and Playbook version are immutable'
        using errcode = '55000';
    end if;
    return new;
  end if;

  perform 1
  from public.calls as call
  join public.playbook_versions as version
    on version.id = new.playbook_version_id
   and version.status = 'published'
  join public.playbooks as playbook
    on playbook.id = version.playbook_id
   and playbook.workspace_id = call.workspace_id
  where call.id = new.call_id;

  if not found then
    raise exception 'Scorecard requires a same-workspace published Playbook version'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create function private.guard_call_scorecard_result_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
    and (
      new.scorecard_id <> old.scorecard_id
      or new.criterion_id <> old.criterion_id
    )
  then
    raise exception 'Scorecard result identity is immutable'
      using errcode = '55000';
  end if;

  perform 1
  from public.call_scorecards as scorecard
  join public.playbook_criteria as criterion
    on criterion.id = new.criterion_id
   and criterion.playbook_version_id = scorecard.playbook_version_id
  where scorecard.id = new.scorecard_id;

  if not found then
    raise exception 'Scorecard result criterion must belong to the pinned version'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function private.guard_workspace_scorecard_setting()
from public, anon, authenticated, service_role;
revoke all on function private.guard_call_scorecard_identity()
from public, anon, authenticated, service_role;
revoke all on function private.guard_call_scorecard_result_identity()
from public, anon, authenticated, service_role;

create trigger workspace_scorecard_settings_guard
before insert or update on public.workspace_scorecard_settings
for each row execute function private.guard_workspace_scorecard_setting();

create trigger call_scorecards_guard_identity
before insert or update on public.call_scorecards
for each row execute function private.guard_call_scorecard_identity();

create trigger call_scorecard_results_guard_identity
before insert or update on public.call_scorecard_results
for each row execute function private.guard_call_scorecard_result_identity();

create trigger workspace_scorecard_settings_set_updated_at
before update on public.workspace_scorecard_settings
for each row execute function private.set_updated_at();

create trigger call_scorecards_set_updated_at
before update on public.call_scorecards
for each row execute function private.set_updated_at();

create function private.can_view_scorecard(target_scorecard_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.call_scorecards as scorecard
    join public.calls as call on call.id = scorecard.call_id
    join public.workspace_members as member
      on member.workspace_id = call.workspace_id
     and member.user_id = (select auth.uid())
    where scorecard.id = target_scorecard_id
  );
$$;

create function private.is_scorecard_transcription_eligible(
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

create function private.try_enqueue_call_scorecard(
  target_call_id uuid,
  target_workspace_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  configured_playbook_id uuid;
  published_version_id uuid;
  result_id uuid;
begin
  select setting.playbook_id
  into configured_playbook_id
  from public.workspace_scorecard_settings as setting
  where setting.workspace_id = target_workspace_id
  for share of setting;

  if configured_playbook_id is null then
    return null;
  end if;

  perform 1
  from public.playbooks as playbook
  where playbook.id = configured_playbook_id
    and playbook.workspace_id = target_workspace_id
  for share of playbook;

  if not found then
    return null;
  end if;

  perform 1
  from public.playbook_versions as version
  where version.playbook_id = configured_playbook_id
    and version.status = 'draft'
  for share of version;

  select version.id
  into published_version_id
  from public.playbook_versions as version
  join public.playbooks as playbook on playbook.id = version.playbook_id
  where version.playbook_id = configured_playbook_id
    and playbook.workspace_id = target_workspace_id
    and version.status = 'published'
  order by version.version_number desc, version.id
  limit 1;

  if published_version_id is null then
    return null;
  end if;

  perform 1
  from public.calls as call
  join public.call_transcriptions as transcription
    on transcription.call_id = call.id
  where call.id = target_call_id
    and call.workspace_id = target_workspace_id
    and call.status <> 'deleting'
    and private.is_scorecard_transcription_eligible(
      transcription.status,
      transcription.transcript_text,
      transcription.completed_at
    )
  for update of call;

  if not found then
    return null;
  end if;

  insert into public.call_scorecards (call_id, playbook_version_id)
  values (target_call_id, published_version_id)
  on conflict (call_id) do nothing
  returning id into result_id;

  if result_id is null then
    select scorecard.id
    into result_id
    from public.call_scorecards as scorecard
    where scorecard.call_id = target_call_id;
  end if;

  return result_id;
end;
$$;

create function private.enqueue_call_scorecard_after_transcription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_workspace_id uuid;
begin
  if private.is_scorecard_transcription_eligible(
    new.status,
    new.transcript_text,
    new.completed_at
  ) then
    select call.workspace_id
    into target_workspace_id
    from public.calls as call
    where call.id = new.call_id;

    if target_workspace_id is not null then
      perform private.try_enqueue_call_scorecard(
        new.call_id,
        target_workspace_id
      );
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.can_view_scorecard(uuid)
from public, anon, authenticated, service_role;
revoke all on function private.is_scorecard_transcription_eligible(text, text, timestamptz)
from public, anon, authenticated, service_role;
revoke all on function private.try_enqueue_call_scorecard(uuid, uuid)
from public, anon, authenticated, service_role;
revoke all on function private.enqueue_call_scorecard_after_transcription()
from public, anon, authenticated, service_role;

grant execute on function private.can_view_scorecard(uuid)
to authenticated;

create trigger call_transcriptions_enqueue_scorecard
after insert or update of status, transcript_text, completed_at
on public.call_transcriptions
for each row execute function private.enqueue_call_scorecard_after_transcription();

create function public.set_workspace_scorecard_playbook(
  p_workspace_id uuid,
  p_playbook_id uuid
)
returns table (
  workspace_id uuid,
  playbook_id uuid
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null or p_playbook_id is null then
    raise exception 'Workspace and Playbook are required' using errcode = '22023';
  end if;

  perform 1
  from public.workspace_members as member
  where member.workspace_id = p_workspace_id
    and member.user_id = current_user_id
    and member.role in ('owner', 'admin')
  for share of member;

  if not found then
    raise exception 'Scorecard Playbook management is not authorized'
      using errcode = '42501';
  end if;

  perform 1
  from public.playbooks as playbook
  where playbook.id = p_playbook_id
    and playbook.workspace_id = p_workspace_id
    and exists (
      select 1
      from public.playbook_versions as version
      where version.playbook_id = playbook.id
        and version.status = 'published'
    );

  if not found then
    raise exception 'A published Playbook in this workspace is required'
      using errcode = '22023';
  end if;

  insert into public.workspace_scorecard_settings (
    workspace_id,
    playbook_id,
    updated_by
  )
  values (
    p_workspace_id,
    p_playbook_id,
    current_user_id
  )
  on conflict on constraint workspace_scorecard_settings_pkey do update
  set
    playbook_id = excluded.playbook_id,
    updated_by = excluded.updated_by;

  return query select p_workspace_id, p_playbook_id;
end;
$$;

create function public.queue_call_scorecard(
  p_workspace_id uuid,
  p_call_id uuid
)
returns table (
  scorecard_id uuid,
  status text,
  created boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  existing_id uuid;
  queued_id uuid;
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
    raise exception 'Call scoring is not authorized' using errcode = '42501';
  end if;

  select scorecard.id
  into existing_id
  from public.call_scorecards as scorecard
  join public.calls as call on call.id = scorecard.call_id
  where scorecard.call_id = p_call_id
    and call.workspace_id = p_workspace_id;

  if existing_id is not null then
    return query select existing_id, 'existing'::text, false;
    return;
  end if;

  queued_id := private.try_enqueue_call_scorecard(p_call_id, p_workspace_id);

  if queued_id is null then
    return query select null::uuid, 'ineligible'::text, false;
    return;
  end if;

  return query select queued_id, 'queued'::text, true;
end;
$$;

create function public.claim_scorecard_jobs(p_limit integer default 1)
returns table (
  scorecard_id uuid,
  call_id uuid,
  workspace_id uuid,
  playbook_version_id uuid,
  transcript_text text,
  language_code text,
  criteria jsonb,
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
    select scorecard.id
    from public.call_scorecards as scorecard
    where scorecard.status = 'processing'
      and scorecard.lease_expires_at <= pg_catalog.clock_timestamp()
      and scorecard.attempt_count >= 3
    order by scorecard.lease_expires_at, scorecard.created_at, scorecard.id
    for update of scorecard skip locked
    limit p_limit
  )
  update public.call_scorecards as scorecard
  set
    status = 'failed',
    lease_expires_at = null,
    next_attempt_at = null,
    last_error_code = 'worker_lease_expired',
    failed_at = pg_catalog.now()
  from exhausted
  where scorecard.id = exhausted.id;

  for target_job in
    select
      scorecard.id as scorecard_id,
      scorecard.call_id,
      call.workspace_id,
      scorecard.playbook_version_id,
      transcription.transcript_text,
      transcription.language_code,
      (
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'criterion_id', criterion.id,
            'name', criterion.name,
            'description', criterion.description,
            'weight', criterion.weight,
            'pass_guidance', criterion.pass_guidance,
            'fail_guidance', criterion.fail_guidance,
            'position', criterion.position
          )
          order by criterion.position
        )
        from public.playbook_criteria as criterion
        where criterion.playbook_version_id = scorecard.playbook_version_id
      ) as criteria
    from public.call_scorecards as scorecard
    join public.calls as call on call.id = scorecard.call_id
    join public.call_transcriptions as transcription
      on transcription.call_id = scorecard.call_id
    join public.playbook_versions as version
      on version.id = scorecard.playbook_version_id
    where (
        (
          scorecard.status = 'queued'
          and (
            scorecard.next_attempt_at is null
            or scorecard.next_attempt_at <= pg_catalog.now()
          )
        )
        or (
          scorecard.status = 'processing'
          and scorecard.lease_expires_at <= pg_catalog.clock_timestamp()
        )
      )
      and scorecard.attempt_count < 3
      and call.status <> 'deleting'
      and version.status = 'published'
      and private.is_scorecard_transcription_eligible(
        transcription.status,
        transcription.transcript_text,
        transcription.completed_at
      )
    order by
      case
        when scorecard.status = 'queued'
          then coalesce(scorecard.next_attempt_at, scorecard.created_at)
        else scorecard.lease_expires_at
      end,
      scorecard.created_at,
      scorecard.id
    for update of scorecard skip locked
    limit p_limit
  loop
    new_claim_token := pg_catalog.gen_random_uuid();

    update public.call_scorecards as scorecard
    set
      status = 'processing',
      attempt_count = scorecard.attempt_count + 1,
      claim_token = new_claim_token,
      lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes',
      next_attempt_at = null,
      last_error_code = null,
      started_at = coalesce(scorecard.started_at, pg_catalog.now()),
      failed_at = null
    where scorecard.id = target_job.scorecard_id
    returning scorecard.attempt_count into new_attempt_count;

    scorecard_id := target_job.scorecard_id;
    call_id := target_job.call_id;
    workspace_id := target_job.workspace_id;
    playbook_version_id := target_job.playbook_version_id;
    transcript_text := target_job.transcript_text;
    language_code := target_job.language_code;
    criteria := target_job.criteria;
    claim_token := new_claim_token;
    attempt_count := new_attempt_count;
    return next;
  end loop;
end;
$$;

create function public.renew_scorecard_lease(
  p_scorecard_id uuid,
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
  if p_scorecard_id is null or p_claim_token is null then
    return false;
  end if;

  update public.call_scorecards as scorecard
  set lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes'
  where scorecard.id = p_scorecard_id
    and scorecard.status = 'processing'
    and scorecard.claim_token = p_claim_token
    and scorecard.lease_expires_at > pg_catalog.clock_timestamp();

  get diagnostics updated_count = row_count;
  return updated_count = 1;
end;
$$;

create function public.complete_scorecard_job(
  p_scorecard_id uuid,
  p_claim_token uuid,
  p_criteria jsonb
)
returns table (
  scorecard_id uuid,
  status text,
  overall_score numeric,
  review_required boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_job public.call_scorecards%rowtype;
  expected_count integer;
  submitted_count integer;
  eligible_weight integer;
  passed_weight integer;
  calculated_score numeric(5,2);
  calculated_review boolean;
begin
  if p_scorecard_id is null or p_claim_token is null then
    return;
  end if;

  select scorecard.*
  into target_job
  from public.call_scorecards as scorecard
  where scorecard.id = p_scorecard_id
  for update;

  if not found then
    return;
  end if;

  if target_job.status = 'completed' then
    if target_job.claim_token = p_claim_token then
      return query
      select
        target_job.id,
        'completed'::text,
        target_job.overall_score,
        target_job.review_required;
    end if;
    return;
  end if;

  if target_job.status <> 'processing'
    or target_job.claim_token <> p_claim_token
    or target_job.lease_expires_at <= pg_catalog.clock_timestamp()
  then
    return;
  end if;

  perform 1
  from public.playbook_versions as version
  where version.id = target_job.playbook_version_id
    and version.status = 'published'
  for share;

  if not found then
    raise exception 'Pinned Playbook version is not published'
      using errcode = '22023';
  end if;

  if p_criteria is null
    or pg_catalog.jsonb_typeof(p_criteria) <> 'array'
    or pg_catalog.pg_column_size(p_criteria) > 16384
  then
    raise exception 'Criterion outcomes must be a bounded JSON array'
      using errcode = '22023';
  end if;

  select pg_catalog.count(*)::integer
  into expected_count
  from public.playbook_criteria as criterion
  where criterion.playbook_version_id = target_job.playbook_version_id;

  select pg_catalog.jsonb_array_length(p_criteria)
  into submitted_count;

  if expected_count not between 1 and 20 or submitted_count <> expected_count then
    raise exception 'Criterion outcomes must contain the exact criterion set'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(p_criteria) as item(value)
    where pg_catalog.jsonb_typeof(item.value) <> 'object'
      or case
        when pg_catalog.jsonb_typeof(item.value) = 'object' then (
          select pg_catalog.count(*)
          from pg_catalog.jsonb_object_keys(item.value)
        ) <> 2
        else false
      end
      or not (item.value ? 'criterion_id')
      or not (item.value ? 'outcome')
      or pg_catalog.jsonb_typeof(item.value -> 'criterion_id') <> 'string'
      or pg_catalog.jsonb_typeof(item.value -> 'outcome') <> 'string'
      or (item.value ->> 'outcome') not in (
        'pass',
        'fail',
        'not_applicable',
        'insufficient_evidence'
      )
      or (item.value ->> 'criterion_id') !~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
  ) then
    raise exception 'Criterion outcome is invalid' using errcode = '22023';
  end if;

  if (
    select pg_catalog.count(distinct item.value ->> 'criterion_id')
    from pg_catalog.jsonb_array_elements(p_criteria) as item(value)
  ) <> submitted_count then
    raise exception 'Criterion outcomes contain duplicates' using errcode = '22023';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(p_criteria) as item(value)
    left join public.playbook_criteria as criterion
      on criterion.id = (item.value ->> 'criterion_id')::uuid
     and criterion.playbook_version_id = target_job.playbook_version_id
    where criterion.id is null
  ) then
    raise exception 'Criterion outcomes contain an unknown criterion'
      using errcode = '22023';
  end if;

  select
    coalesce(pg_catalog.sum(criterion.weight) filter (
      where item.value ->> 'outcome' in ('pass', 'fail')
    ), 0)::integer,
    coalesce(pg_catalog.sum(criterion.weight) filter (
      where item.value ->> 'outcome' = 'pass'
    ), 0)::integer,
    pg_catalog.bool_or(
      item.value ->> 'outcome' = 'insufficient_evidence'
    )
  into eligible_weight, passed_weight, calculated_review
  from pg_catalog.jsonb_array_elements(p_criteria) as item(value)
  join public.playbook_criteria as criterion
    on criterion.id = (item.value ->> 'criterion_id')::uuid
   and criterion.playbook_version_id = target_job.playbook_version_id;

  if eligible_weight = 0 then
    calculated_score := null;
    calculated_review := true;
  else
    calculated_score := pg_catalog.round(
      passed_weight::numeric * 100 / eligible_weight::numeric,
      2
    );
    calculated_review := coalesce(calculated_review, false);
  end if;

  insert into public.call_scorecard_results (
    scorecard_id,
    criterion_id,
    outcome
  )
  select
    target_job.id,
    (item.value ->> 'criterion_id')::uuid,
    item.value ->> 'outcome'
  from pg_catalog.jsonb_array_elements(p_criteria) as item(value);

  update public.call_scorecards as scorecard
  set
    status = 'completed',
    overall_score = calculated_score,
    review_required = calculated_review,
    lease_expires_at = null,
    next_attempt_at = null,
    last_error_code = null,
    completed_at = pg_catalog.now(),
    failed_at = null
  where scorecard.id = target_job.id
    and scorecard.status = 'processing'
    and scorecard.claim_token = p_claim_token;

  if not found then
    raise exception 'Scorecard claim changed during completion'
      using errcode = '40001';
  end if;

  return query
  select
    target_job.id,
    'completed'::text,
    calculated_score,
    calculated_review;
end;
$$;

create function public.fail_scorecard_job(
  p_scorecard_id uuid,
  p_claim_token uuid,
  p_error_code text,
  p_retryable boolean
)
returns table (
  scorecard_id uuid,
  status text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_job public.call_scorecards%rowtype;
  normalized_error_code text := pg_catalog.lower(pg_catalog.btrim(p_error_code));
  result_status text;
begin
  if normalized_error_code is null
    or pg_catalog.length(normalized_error_code) not between 1 and 64
    or normalized_error_code !~ '^[a-z][a-z0-9_]*$'
  then
    raise exception 'Error code is invalid' using errcode = '22023';
  end if;

  if p_scorecard_id is null or p_claim_token is null or p_retryable is null then
    return;
  end if;

  select scorecard.*
  into target_job
  from public.call_scorecards as scorecard
  where scorecard.id = p_scorecard_id
  for update;

  if not found or target_job.claim_token <> p_claim_token then
    return;
  end if;

  if target_job.status = 'queued'
    and p_retryable
    and target_job.last_error_code = normalized_error_code
    and target_job.next_attempt_at is not null
  then
    return query select target_job.id, 'queued'::text;
    return;
  end if;

  if target_job.status = 'failed'
    and target_job.last_error_code = normalized_error_code
    and (not p_retryable or target_job.attempt_count >= 3)
  then
    return query select target_job.id, 'failed'::text;
    return;
  end if;

  if target_job.status <> 'processing'
    or target_job.lease_expires_at <= pg_catalog.clock_timestamp()
  then
    return;
  end if;

  if p_retryable and target_job.attempt_count < 3 then
    result_status := 'queued';
    update public.call_scorecards as scorecard
    set
      status = 'queued',
      lease_expires_at = null,
      next_attempt_at = pg_catalog.now() + interval '5 minutes',
      last_error_code = normalized_error_code,
      failed_at = null
    where scorecard.id = target_job.id;
  else
    result_status := 'failed';
    update public.call_scorecards as scorecard
    set
      status = 'failed',
      lease_expires_at = null,
      next_attempt_at = null,
      last_error_code = normalized_error_code,
      failed_at = pg_catalog.now()
    where scorecard.id = target_job.id;
  end if;

  return query select target_job.id, result_status;
end;
$$;

alter table public.workspace_scorecard_settings enable row level security;
alter table public.call_scorecards enable row level security;
alter table public.call_scorecard_results enable row level security;

create policy workspace_scorecard_settings_select_member
on public.workspace_scorecard_settings
for select
to authenticated
using (private.is_workspace_member(workspace_id));

create policy call_scorecards_select_member
on public.call_scorecards
for select
to authenticated
using (private.is_call_workspace_member(call_id));

create policy call_scorecard_results_select_member
on public.call_scorecard_results
for select
to authenticated
using (private.can_view_scorecard(scorecard_id));

revoke all on table public.workspace_scorecard_settings
from public, anon, authenticated, service_role;
revoke all on table public.call_scorecards
from public, anon, authenticated, service_role;
revoke all on table public.call_scorecard_results
from public, anon, authenticated, service_role;

grant select (
  workspace_id,
  playbook_id,
  created_at,
  updated_at
) on table public.workspace_scorecard_settings to authenticated;

grant select (
  id,
  call_id,
  playbook_version_id,
  status,
  overall_score,
  review_required,
  started_at,
  completed_at,
  created_at,
  updated_at
) on table public.call_scorecards to authenticated;

grant select (
  scorecard_id,
  criterion_id,
  outcome,
  created_at
) on table public.call_scorecard_results to authenticated;

revoke all on function public.set_workspace_scorecard_playbook(uuid, uuid)
from public, anon, authenticated, service_role;
grant execute on function public.set_workspace_scorecard_playbook(uuid, uuid)
to authenticated;

revoke all on function public.queue_call_scorecard(uuid, uuid)
from public, anon, authenticated, service_role;
grant execute on function public.queue_call_scorecard(uuid, uuid)
to authenticated;

revoke all on function public.claim_scorecard_jobs(integer)
from public, anon, authenticated, service_role;
grant execute on function public.claim_scorecard_jobs(integer)
to service_role;

revoke all on function public.renew_scorecard_lease(uuid, uuid)
from public, anon, authenticated, service_role;
grant execute on function public.renew_scorecard_lease(uuid, uuid)
to service_role;

revoke all on function public.complete_scorecard_job(uuid, uuid, jsonb)
from public, anon, authenticated, service_role;
grant execute on function public.complete_scorecard_job(uuid, uuid, jsonb)
to service_role;

revoke all on function public.fail_scorecard_job(uuid, uuid, text, boolean)
from public, anon, authenticated, service_role;
grant execute on function public.fail_scorecard_job(uuid, uuid, text, boolean)
to service_role;

comment on table public.workspace_scorecard_settings is
  'Selects one stable workspace Playbook identity for future AI scorecards.';
comment on table public.call_scorecards is
  'Canonical per-call scorecard jobs pinned permanently to one immutable published Playbook version.';
comment on table public.call_scorecard_results is
  'Criterion outcomes only; evidence and model reasoning are intentionally not stored.';
comment on function public.complete_scorecard_job(uuid, uuid, jsonb) is
  'Validates the exact criterion set and computes the deterministic weighted score in the database.';

commit;
