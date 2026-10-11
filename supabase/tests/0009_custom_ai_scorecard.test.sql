begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-4000-8000-000000000091', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'scorecard-owner@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000092', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'scorecard-admin@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000093', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'scorecard-member@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000094', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'scorecard-outsider@example.com', '', now(), '{}', '{}', now(), now());

insert into public.workspaces (id, name, created_by) values
  ('10000000-0000-4000-8000-000000000091', 'Scorecard workspace A', '00000000-0000-4000-8000-000000000091'),
  ('10000000-0000-4000-8000-000000000092', 'Scorecard workspace B', '00000000-0000-4000-8000-000000000094');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-4000-8000-000000000091', '00000000-0000-4000-8000-000000000091', 'owner'),
  ('10000000-0000-4000-8000-000000000091', '00000000-0000-4000-8000-000000000092', 'admin'),
  ('10000000-0000-4000-8000-000000000091', '00000000-0000-4000-8000-000000000093', 'member'),
  ('10000000-0000-4000-8000-000000000092', '00000000-0000-4000-8000-000000000094', 'owner');

insert into public.playbooks (id, workspace_id, created_by) values
  ('20000000-0000-4000-8000-000000000091', '10000000-0000-4000-8000-000000000091', '00000000-0000-4000-8000-000000000091'),
  ('20000000-0000-4000-8000-000000000092', '10000000-0000-4000-8000-000000000091', '00000000-0000-4000-8000-000000000091'),
  ('20000000-0000-4000-8000-000000000093', '10000000-0000-4000-8000-000000000092', '00000000-0000-4000-8000-000000000094');

insert into public.playbook_versions (
  id, playbook_id, version_number, status, name, vertical, created_by,
  published_by, published_at
) values
  ('21000000-0000-4000-8000-000000000091', '20000000-0000-4000-8000-000000000091', 1, 'draft', 'Workspace A Sales', 'sales', '00000000-0000-4000-8000-000000000091', null, null),
  ('21000000-0000-4000-8000-000000000092', '20000000-0000-4000-8000-000000000092', 1, 'draft', 'Draft only', 'sales', '00000000-0000-4000-8000-000000000091', null, null),
  ('21000000-0000-4000-8000-000000000093', '20000000-0000-4000-8000-000000000093', 1, 'draft', 'Workspace B Sales', 'sales', '00000000-0000-4000-8000-000000000094', null, null);

insert into public.playbook_criteria (
  id, playbook_version_id, name, description, weight,
  pass_guidance, fail_guidance, position
) values
  ('22000000-0000-4000-8000-000000000091', '21000000-0000-4000-8000-000000000091', 'Discovery', 'Understand the customer.', 60, 'Uses relevant questions.', 'Misses customer context.', 1),
  ('22000000-0000-4000-8000-000000000092', '21000000-0000-4000-8000-000000000091', 'Next steps', 'Agree a clear next action.', 40, 'Confirms owner and timing.', 'Leaves the next action vague.', 2),
  ('22000000-0000-4000-8000-000000000093', '21000000-0000-4000-8000-000000000093', 'Other tenant criterion', '', 100, '', '', 1);

update public.playbook_versions
set status = 'published', published_by = created_by, published_at = now()
where id in (
  '21000000-0000-4000-8000-000000000091',
  '21000000-0000-4000-8000-000000000093'
);

select ok(
  to_regclass('public.workspace_scorecard_settings') is not null
  and to_regclass('public.call_scorecards') is not null
  and to_regclass('public.call_scorecard_results') is not null,
  'Phase 9A creates all scorecard tables'
);

select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.workspace_scorecard_settings'::regclass)
  and (select relrowsecurity from pg_catalog.pg_class where oid = 'public.call_scorecards'::regclass)
  and (select relrowsecurity from pg_catalog.pg_class where oid = 'public.call_scorecard_results'::regclass),
  'RLS is enabled on every scorecard table'
);

select is(
  (select count(*) from pg_catalog.pg_indexes
   where schemaname = 'public'
     and indexname in (
       'call_scorecards_queued_claim_idx',
       'call_scorecards_expired_lease_idx',
       'call_scorecards_version_idx',
       'call_scorecard_results_criterion_idx'
     )),
  4::bigint,
  'scorecard claim, lease, version, and result indexes exist'
);

select ok(
  has_column_privilege('authenticated', 'public.workspace_scorecard_settings', 'workspace_id', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_scorecards', 'overall_score', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_scorecard_results', 'outcome', 'SELECT')
  and not has_column_privilege('authenticated', 'public.workspace_scorecard_settings', 'updated_by', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_scorecards', 'claim_token', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_scorecards', 'last_error_code', 'SELECT'),
  'browser reads expose presentation state but not worker or updater metadata'
);

select ok(
  not has_table_privilege('authenticated', 'public.workspace_scorecard_settings', 'INSERT')
  and not has_table_privilege('authenticated', 'public.workspace_scorecard_settings', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.workspace_scorecard_settings', 'DELETE')
  and not has_table_privilege('authenticated', 'public.call_scorecards', 'INSERT')
  and not has_table_privilege('authenticated', 'public.call_scorecards', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.call_scorecards', 'DELETE')
  and not has_table_privilege('authenticated', 'public.call_scorecard_results', 'INSERT')
  and not has_table_privilege('authenticated', 'public.call_scorecard_results', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.call_scorecard_results', 'DELETE')
  and not has_table_privilege('service_role', 'public.call_scorecards', 'INSERT')
  and not has_table_privilege('service_role', 'public.call_scorecards', 'UPDATE')
  and not has_table_privilege('service_role', 'public.call_scorecard_results', 'INSERT'),
  'browser and service roles have no direct scorecard mutation grants'
);

select ok(
  has_function_privilege('authenticated', 'public.set_workspace_scorecard_playbook(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.queue_call_scorecard(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.set_workspace_scorecard_playbook(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.queue_call_scorecard(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.claim_scorecard_jobs(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.renew_scorecard_lease(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.complete_scorecard_job(uuid,uuid,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.fail_scorecard_job(uuid,uuid,text,boolean)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.claim_scorecard_jobs(integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.renew_scorecard_lease(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.complete_scorecard_job(uuid,uuid,jsonb)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.fail_scorecard_job(uuid,uuid,text,boolean)', 'EXECUTE'),
  'configuration RPCs are authenticated-only and worker RPCs are service-role-only'
);

select is(
  (select count(*)
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where namespace.nspname = 'public'
     and procedure.proname in (
       'set_workspace_scorecard_playbook', 'queue_call_scorecard',
       'claim_scorecard_jobs', 'renew_scorecard_lease',
       'complete_scorecard_job', 'fail_scorecard_job'
     )
     and procedure.prosecdef
     and pg_catalog.array_to_string(procedure.proconfig, ',') = 'search_path=""'),
  6::bigint,
  'every public scorecard RPC is SECURITY DEFINER with an empty search path'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000093', true);
select throws_ok(
  $$select public.set_workspace_scorecard_playbook('10000000-0000-4000-8000-000000000091', '20000000-0000-4000-8000-000000000091')$$,
  '42501',
  'Scorecard Playbook management is not authorized',
  'members cannot change scorecard configuration'
);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000091', true);
select throws_ok(
  $$select public.set_workspace_scorecard_playbook('10000000-0000-4000-8000-000000000091', '20000000-0000-4000-8000-000000000092')$$,
  '22023',
  'A published Playbook in this workspace is required',
  'a draft-only Playbook cannot be selected'
);
select throws_ok(
  $$select public.set_workspace_scorecard_playbook('10000000-0000-4000-8000-000000000091', '20000000-0000-4000-8000-000000000093')$$,
  '22023',
  'A published Playbook in this workspace is required',
  'a cross-workspace Playbook cannot be selected'
);

reset role;

select throws_ok(
  $$insert into public.workspace_scorecard_settings (workspace_id, playbook_id, updated_by)
    values ('10000000-0000-4000-8000-000000000091', '20000000-0000-4000-8000-000000000093', '00000000-0000-4000-8000-000000000091')$$,
  '23514',
  'Scorecard setting requires a same-workspace published Playbook',
  'the table guard rejects a cross-workspace Playbook even outside the RPC'
);
select throws_ok(
  $$insert into public.workspace_scorecard_settings (workspace_id, playbook_id, updated_by)
    values ('10000000-0000-4000-8000-000000000091', '20000000-0000-4000-8000-000000000092', '00000000-0000-4000-8000-000000000091')$$,
  '23514',
  'Scorecard setting requires a same-workspace published Playbook',
  'the table guard rejects a draft-only Playbook even outside the RPC'
);

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values
  ('25000000-0000-4000-8000-000000000091', '10000000-0000-4000-8000-000000000091', '00000000-0000-4000-8000-000000000091', 'historical.mp3', 'call-audio', '10000000-0000-4000-8000-000000000091/25000000-0000-4000-8000-000000000091/source.mp3', 'audio/mpeg', 1000, 'uploaded', now());

update public.call_transcriptions
set status = 'completed', transcript_text = 'Historical completed call.', language_code = 'en',
    attempt_count = 1, claim_token = '50000000-0000-4000-8000-000000000091',
    started_at = now() - interval '1 minute', completed_at = now()
where call_id = '25000000-0000-4000-8000-000000000091';

select is(
  (select count(*) from public.call_scorecards where call_id = '25000000-0000-4000-8000-000000000091'),
  0::bigint,
  'completed transcripts are not backfilled before configuration exists'
);

select throws_ok(
  $$insert into public.call_scorecards (call_id, playbook_version_id)
    values ('25000000-0000-4000-8000-000000000091', '21000000-0000-4000-8000-000000000093')$$,
  '23514',
  'Scorecard requires a same-workspace published Playbook version',
  'the scorecard table guard rejects a cross-workspace pinned version'
);
select throws_ok(
  $$insert into public.call_scorecards (call_id, playbook_version_id)
    values ('25000000-0000-4000-8000-000000000091', '21000000-0000-4000-8000-000000000092')$$,
  '23514',
  'Scorecard requires a same-workspace published Playbook version',
  'the scorecard table guard rejects a mutable draft version'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000092', true);
select lives_ok(
  $$select public.set_workspace_scorecard_playbook('10000000-0000-4000-8000-000000000091', '20000000-0000-4000-8000-000000000091')$$,
  'an admin can select a same-workspace published Playbook'
);
reset role;

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values
  ('25000000-0000-4000-8000-000000000092', '10000000-0000-4000-8000-000000000091', '00000000-0000-4000-8000-000000000091', 'auto-one.mp3', 'call-audio', '10000000-0000-4000-8000-000000000091/25000000-0000-4000-8000-000000000092/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('25000000-0000-4000-8000-000000000093', '10000000-0000-4000-8000-000000000091', '00000000-0000-4000-8000-000000000091', 'auto-two.mp3', 'call-audio', '10000000-0000-4000-8000-000000000091/25000000-0000-4000-8000-000000000093/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('25000000-0000-4000-8000-000000000094', '10000000-0000-4000-8000-000000000091', '00000000-0000-4000-8000-000000000091', 'auto-three.mp3', 'call-audio', '10000000-0000-4000-8000-000000000091/25000000-0000-4000-8000-000000000094/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('25000000-0000-4000-8000-000000000095', '10000000-0000-4000-8000-000000000091', '00000000-0000-4000-8000-000000000091', 'auto-four.mp3', 'call-audio', '10000000-0000-4000-8000-000000000091/25000000-0000-4000-8000-000000000095/source.mp3', 'audio/mpeg', 1000, 'uploaded', now());

update public.call_transcriptions
set status = 'completed', transcript_text = 'A valid completed customer conversation.', language_code = 'en',
    attempt_count = 1, claim_token = gen_random_uuid(), started_at = now() - interval '1 minute', completed_at = now()
where call_id in (
  '25000000-0000-4000-8000-000000000092',
  '25000000-0000-4000-8000-000000000093',
  '25000000-0000-4000-8000-000000000094',
  '25000000-0000-4000-8000-000000000095'
);

select is(
  (select count(*) from public.call_scorecards
   where call_id in (
     '25000000-0000-4000-8000-000000000092',
     '25000000-0000-4000-8000-000000000093',
     '25000000-0000-4000-8000-000000000094',
     '25000000-0000-4000-8000-000000000095'
   )),
  4::bigint,
  'future valid completed transcripts automatically enqueue scorecards'
);

update public.call_transcriptions set completed_at = completed_at
where call_id = '25000000-0000-4000-8000-000000000092';
select is(
  (select count(*) from public.call_scorecards where call_id = '25000000-0000-4000-8000-000000000092'),
  1::bigint,
  'automatic enqueue is idempotent when completion updates repeat'
);

select ok(
  (
    select pg_catalog.strpos(pg_catalog.lower(procedure.prosrc), 'for share of setting') > 0
      and pg_catalog.strpos(pg_catalog.lower(procedure.prosrc), 'for share of playbook') > 0
      and pg_catalog.strpos(pg_catalog.lower(procedure.prosrc), 'for share of version') > 0
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'private'
      and procedure.proname = 'try_enqueue_call_scorecard'
  ),
  'enqueue locks configuration, stable Playbook identity, and draft publication before pinning'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000091', true);
select is(
  (select created from public.queue_call_scorecard('10000000-0000-4000-8000-000000000091', '25000000-0000-4000-8000-000000000091')),
  true,
  'a manager can manually queue an eligible historical call'
);
select is(
  (select status from public.queue_call_scorecard('10000000-0000-4000-8000-000000000091', '25000000-0000-4000-8000-000000000091')),
  'existing'::text,
  'manual queue is idempotent for the canonical per-call scorecard'
);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000093', true);
select throws_ok(
  $$select public.queue_call_scorecard('10000000-0000-4000-8000-000000000091', '25000000-0000-4000-8000-000000000091')$$,
  '42501',
  'Call scoring is not authorized',
  'members cannot manually queue calls'
);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000094', true);
select throws_ok(
  $$select public.queue_call_scorecard('10000000-0000-4000-8000-000000000091', '25000000-0000-4000-8000-000000000091')$$,
  '42501',
  'Call scoring is not authorized',
  'cross-workspace users cannot queue a guessed call'
);
reset role;

select is(
  (select count(*) from public.call_scorecards where playbook_version_id = '21000000-0000-4000-8000-000000000091'),
  5::bigint,
  'all initial scorecards pin the exact published Version 1'
);

select throws_ok(
  $$update public.call_scorecards
    set playbook_version_id = '21000000-0000-4000-8000-000000000093'
    where call_id = '25000000-0000-4000-8000-000000000091'$$,
  '55000',
  'Scorecard call and Playbook version are immutable',
  'a pinned scorecard version cannot be rewritten after creation'
);

create temporary table scorecard_claims (
  row_number integer,
  scorecard_id uuid,
  call_id uuid,
  playbook_version_id uuid,
  claim_token uuid,
  attempt_count integer,
  criteria jsonb
) on commit drop;
grant all on table scorecard_claims to service_role;

set local role service_role;
insert into scorecard_claims
select row_number() over (order by claimed.call_id), claimed.scorecard_id, claimed.call_id,
       claimed.playbook_version_id, claimed.claim_token, claimed.attempt_count, claimed.criteria
from public.claim_scorecard_jobs(5) as claimed;
reset role;

select is((select count(*) from scorecard_claims), 5::bigint, 'a bounded claim leases all five queued jobs once');
select is(
  (select count(*) from scorecard_claims where jsonb_array_length(criteria) = 2),
  5::bigint,
  'claims return only the pinned ordered criterion definition needed by the scorer'
);

set local role service_role;
select is((select count(*) from public.claim_scorecard_jobs(5)), 0::bigint, 'processing jobs cannot be claimed concurrently');
select is(
  public.renew_scorecard_lease(
    (select scorecard_id from scorecard_claims where row_number = 1),
    '50000000-0000-4000-8000-000000000099'
  ),
  false,
  'a wrong claim token cannot renew a lease'
);
select is(
  public.renew_scorecard_lease(
    (select scorecard_id from scorecard_claims where row_number = 1),
    (select claim_token from scorecard_claims where row_number = 1)
  ),
  true,
  'the active claim token renews its lease'
);
reset role;
select throws_ok(
  format(
    'insert into public.call_scorecard_results (scorecard_id, criterion_id, outcome) values (%L, %L, %L)',
    (select scorecard_id from scorecard_claims where row_number = 1),
    '22000000-0000-4000-8000-000000000093',
    'pass'
  ),
  '23514',
  'Scorecard result criterion must belong to the pinned version',
  'the result table guard rejects a criterion outside the pinned version'
);
set local role service_role;

select throws_ok(
  format(
    'select public.complete_scorecard_job(%L, %L, %L::jsonb)',
    (select scorecard_id from scorecard_claims where row_number = 1),
    (select claim_token from scorecard_claims where row_number = 1),
    jsonb_build_array(jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000091', 'outcome', 'pass'))::text
  ),
  '22023',
  'Criterion outcomes must contain the exact criterion set',
  'completion rejects missing criteria'
);
select throws_ok(
  format(
    'select public.complete_scorecard_job(%L, %L, %L::jsonb)',
    (select scorecard_id from scorecard_claims where row_number = 1),
    (select claim_token from scorecard_claims where row_number = 1),
    jsonb_build_array(
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000091', 'outcome', 'pass'),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000091', 'outcome', 'fail')
    )::text
  ),
  '22023',
  'Criterion outcomes contain duplicates',
  'completion rejects duplicate criteria'
);
select throws_ok(
  format(
    'select public.complete_scorecard_job(%L, %L, %L::jsonb)',
    (select scorecard_id from scorecard_claims where row_number = 1),
    (select claim_token from scorecard_claims where row_number = 1),
    jsonb_build_array(
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000091', 'outcome', 'pass'),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000099', 'outcome', 'fail')
    )::text
  ),
  '22023',
  'Criterion outcomes contain an unknown criterion',
  'completion rejects criteria outside the pinned version'
);
select throws_ok(
  format(
    'select public.complete_scorecard_job(%L, %L, %L::jsonb)',
    (select scorecard_id from scorecard_claims where row_number = 1),
    (select claim_token from scorecard_claims where row_number = 1),
    jsonb_build_array(
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000091', 'outcome', 'pass', 'overall_score', 100),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000092', 'outcome', 'pass')
    )::text
  ),
  '22023',
  'Criterion outcome is invalid',
  'completion rejects model-supplied scores and extra fields'
);
select throws_ok(
  format(
    'select public.complete_scorecard_job(%L, %L, %L::jsonb)',
    (select scorecard_id from scorecard_claims where row_number = 1),
    (select claim_token from scorecard_claims where row_number = 1),
    jsonb_build_array(
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000091', 'outcome', 'maybe'),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000092', 'outcome', 'pass')
    )::text
  ),
  '22023',
  'Criterion outcome is invalid',
  'completion rejects unsupported outcomes'
);
select throws_ok(
  format(
    'select public.complete_scorecard_job(%L, %L, %L::jsonb)',
    (select scorecard_id from scorecard_claims where row_number = 1),
    (select claim_token from scorecard_claims where row_number = 1),
    jsonb_build_array(
      42,
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000092', 'outcome', 'pass')
    )::text
  ),
  '22023',
  'Criterion outcome is invalid',
  'completion safely rejects non-object criterion rows'
);

select is(
  (select overall_score from public.complete_scorecard_job(
    (select scorecard_id from scorecard_claims where row_number = 1),
    (select claim_token from scorecard_claims where row_number = 1),
    jsonb_build_array(
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000091', 'outcome', 'pass'),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000092', 'outcome', 'fail')
    )
  )),
  60.00::numeric,
  'database-authoritative weighted pass/fail score is deterministic'
);
select is(
  (select overall_score from public.complete_scorecard_job(
    (select scorecard_id from scorecard_claims where row_number = 2),
    (select claim_token from scorecard_claims where row_number = 2),
    jsonb_build_array(
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000091', 'outcome', 'pass'),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000092', 'outcome', 'not_applicable')
    )
  )),
  100.00::numeric,
  'not-applicable criteria are excluded from the denominator'
);
select ok(
  (select overall_score = 100.00 and review_required
   from public.complete_scorecard_job(
    (select scorecard_id from scorecard_claims where row_number = 3),
    (select claim_token from scorecard_claims where row_number = 3),
    jsonb_build_array(
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000091', 'outcome', 'pass'),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000092', 'outcome', 'insufficient_evidence')
    )
  )),
  'insufficient evidence is excluded from the denominator and requires review'
);
select ok(
  (select overall_score is null and review_required
   from public.complete_scorecard_job(
    (select scorecard_id from scorecard_claims where row_number = 4),
    (select claim_token from scorecard_claims where row_number = 4),
    jsonb_build_array(
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000091', 'outcome', 'not_applicable'),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000092', 'outcome', 'insufficient_evidence')
    )
  )),
  'zero eligible weight produces a null score and requires review'
);
select is(
  (select overall_score from public.complete_scorecard_job(
    (select scorecard_id from scorecard_claims where row_number = 5),
    (select claim_token from scorecard_claims where row_number = 5),
    jsonb_build_array(
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000091', 'outcome', 'fail'),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000092', 'outcome', 'pass')
    )
  )),
  40.00::numeric,
  'database calculates the complementary weighted score without model totals'
);
reset role;

select is((select count(*) from public.call_scorecard_results), 10::bigint, 'completion persists one atomic result per pinned criterion');

insert into public.playbook_versions (
  id, playbook_id, version_number, status, name, vertical, created_by,
  published_by, published_at
) values (
  '21000000-0000-4000-8000-000000000094', '20000000-0000-4000-8000-000000000091',
  2, 'draft', 'Workspace A Sales', 'sales', '00000000-0000-4000-8000-000000000091',
  null, null
);
insert into public.playbook_criteria (
  id, playbook_version_id, name, description, weight, pass_guidance, fail_guidance, position
) values
  ('22000000-0000-4000-8000-000000000094', '21000000-0000-4000-8000-000000000094', 'Opening', '', 1, '', '', 1),
  ('22000000-0000-4000-8000-000000000095', '21000000-0000-4000-8000-000000000094', 'Discovery', '', 31, '', '', 2),
  ('22000000-0000-4000-8000-000000000096', '21000000-0000-4000-8000-000000000094', 'Next steps', '', 68, '', '', 3);

update public.playbook_versions
set status = 'published', published_by = created_by, published_at = now()
where id = '21000000-0000-4000-8000-000000000094';

select is(
  (select count(*) from public.call_scorecards where playbook_version_id = '21000000-0000-4000-8000-000000000091'),
  5::bigint,
  'publishing Version 2 does not mutate historical scorecard attribution'
);

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values (
  '25000000-0000-4000-8000-000000000096', '10000000-0000-4000-8000-000000000091',
  '00000000-0000-4000-8000-000000000091', 'version-two.mp3', 'call-audio',
  '10000000-0000-4000-8000-000000000091/25000000-0000-4000-8000-000000000096/source.mp3',
  'audio/mpeg', 1000, 'uploaded', now()
);
update public.call_transcriptions
set status = 'completed', transcript_text = 'A future completed call.', language_code = 'en',
    attempt_count = 1, claim_token = gen_random_uuid(), started_at = now() - interval '1 minute', completed_at = now()
where call_id = '25000000-0000-4000-8000-000000000096';

select is(
  (select playbook_version_id from public.call_scorecards where call_id = '25000000-0000-4000-8000-000000000096'),
  '21000000-0000-4000-8000-000000000094'::uuid,
  'future scorecards resolve and permanently pin the newest published version'
);

create temporary table rounding_claim (
  scorecard_id uuid,
  claim_token uuid
) on commit drop;
grant all on table rounding_claim to service_role;

set local role service_role;
insert into rounding_claim
select scorecard_id, claim_token from public.claim_scorecard_jobs(1);
select is(
  (select overall_score from public.complete_scorecard_job(
    (select scorecard_id from rounding_claim),
    (select claim_token from rounding_claim),
    jsonb_build_array(
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000094', 'outcome', 'pass'),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000095', 'outcome', 'fail'),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000096', 'outcome', 'not_applicable')
    )
  )),
  3.13::numeric,
  'database scoring rounds an exact 3.125 boundary half-up to 3.13'
);
reset role;

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values (
  '25000000-0000-4000-8000-000000000097', '10000000-0000-4000-8000-000000000091',
  '00000000-0000-4000-8000-000000000091', 'retry-version-two.mp3', 'call-audio',
  '10000000-0000-4000-8000-000000000091/25000000-0000-4000-8000-000000000097/source.mp3',
  'audio/mpeg', 1000, 'uploaded', now()
);
update public.call_transcriptions
set status = 'completed', transcript_text = 'A retry lifecycle call.', language_code = 'en',
    attempt_count = 1, claim_token = gen_random_uuid(), started_at = now() - interval '1 minute', completed_at = now()
where call_id = '25000000-0000-4000-8000-000000000097';

create temporary table retry_claim (
  scorecard_id uuid,
  claim_token uuid,
  attempt_count integer
) on commit drop;
grant all on table retry_claim to service_role;

set local role service_role;
insert into retry_claim
select scorecard_id, claim_token, attempt_count from public.claim_scorecard_jobs(1);
select is((select count(*) from retry_claim), 1::bigint, 'the Version 2 scorecard can be claimed');
select is(
  (select status from public.fail_scorecard_job(
    (select scorecard_id from retry_claim), (select claim_token from retry_claim),
    'model_unavailable', true
  )),
  'queued'::text,
  'retryable worker failure safely requeues before the attempt limit'
);
reset role;

update public.call_scorecards
set next_attempt_at = now() - interval '1 second'
where id = (select scorecard_id from retry_claim);
truncate table retry_claim;
set local role service_role;
insert into retry_claim
select scorecard_id, claim_token, attempt_count from public.claim_scorecard_jobs(1);
reset role;

update public.call_scorecards
set lease_expires_at = clock_timestamp() - interval '1 second'
where id = (select scorecard_id from retry_claim);
set local role service_role;
select is(
  (select count(*) from public.complete_scorecard_job(
    (select scorecard_id from retry_claim), (select claim_token from retry_claim),
    jsonb_build_array(
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000094', 'outcome', 'pass'),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000095', 'outcome', 'pass'),
      jsonb_build_object('criterion_id', '22000000-0000-4000-8000-000000000096', 'outcome', 'pass')
    )
  )),
  0::bigint,
  'a stale worker cannot complete after its lease expires'
);

truncate table retry_claim;
insert into retry_claim
select scorecard_id, claim_token, attempt_count from public.claim_scorecard_jobs(1);
select is((select attempt_count from retry_claim), 3, 'an expired lease is reclaimed only up to the maximum attempt');
select is(
  (select status from public.fail_scorecard_job(
    (select scorecard_id from retry_claim), (select claim_token from retry_claim),
    'model_unavailable', true
  )),
  'failed'::text,
  'retryable failure becomes terminal at the maximum attempt'
);
reset role;

select throws_ok(
  $$update public.playbook_versions set name = 'Changed' where id = '21000000-0000-4000-8000-000000000091'$$,
  '55000',
  'Published playbook versions are immutable',
  'published Playbook immutability remains enforced'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000093', true);
select is((select count(*) from public.call_scorecards), 7::bigint, 'same-workspace members can read scorecard state');
select is((select count(*) from public.call_scorecard_results), 13::bigint, 'same-workspace members can read criterion outcomes');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000094', true);
select is((select count(*) from public.call_scorecards), 0::bigint, 'cross-workspace users cannot read scorecards');
select is((select count(*) from public.call_scorecard_results), 0::bigint, 'cross-workspace users cannot read scorecard results');
reset role;

set local role anon;
select throws_ok(
  $$select count(*) from public.call_scorecards$$,
  '42501',
  'permission denied for table call_scorecards',
  'anonymous users cannot read scorecard state'
);
reset role;

select * from finish();
rollback;
