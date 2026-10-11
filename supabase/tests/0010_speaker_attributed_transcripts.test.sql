begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-4000-8000-000000000101', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'speaker-owner@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000102', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'speaker-admin@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000103', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'speaker-member@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000104', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'speaker-outsider@example.com', '', now(), '{}', '{}', now(), now());

insert into public.workspaces (id, name, created_by) values
  ('10000000-0000-4000-8000-000000000101', 'Speaker workspace A', '00000000-0000-4000-8000-000000000101'),
  ('10000000-0000-4000-8000-000000000102', 'Speaker workspace B', '00000000-0000-4000-8000-000000000104');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000101', 'owner'),
  ('10000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000102', 'admin'),
  ('10000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000103', 'member'),
  ('10000000-0000-4000-8000-000000000102', '00000000-0000-4000-8000-000000000104', 'owner');

select ok(
  to_regclass('public.call_speaker_attributions') is not null
  and to_regclass('public.call_transcript_turns') is not null,
  'Phase 9B creates the canonical speaker job and stable transcript-turn tables'
);

select ok(
  (select relrowsecurity from pg_catalog.pg_class where oid = 'public.call_speaker_attributions'::regclass)
  and (select relrowsecurity from pg_catalog.pg_class where oid = 'public.call_transcript_turns'::regclass),
  'RLS is enabled on both speaker-attribution tables'
);

select is(
  (select count(*) from pg_catalog.pg_indexes
   where schemaname = 'public'
     and indexname in (
       'call_speaker_attributions_queued_claim_idx',
       'call_speaker_attributions_expired_lease_idx',
       'call_transcript_turns_timeline_idx',
       'call_transcript_turns_call_ordinal_unique'
     )),
  4::bigint,
  'queue, lease, stable ordinal, and timeline indexes exist'
);

select ok(
  has_column_privilege('authenticated', 'public.call_speaker_attributions', 'status', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_transcript_turns', 'text', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_transcript_turns', 'speaker_role', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_speaker_attributions', 'claim_token', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_speaker_attributions', 'lease_expires_at', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_speaker_attributions', 'last_error_code', 'SELECT'),
  'browser reads expose safe presentation state but no worker metadata'
);

select ok(
  not has_table_privilege('authenticated', 'public.call_speaker_attributions', 'INSERT')
  and not has_table_privilege('authenticated', 'public.call_speaker_attributions', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.call_speaker_attributions', 'DELETE')
  and not has_table_privilege('authenticated', 'public.call_transcript_turns', 'INSERT')
  and not has_table_privilege('authenticated', 'public.call_transcript_turns', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.call_transcript_turns', 'DELETE')
  and not has_table_privilege('service_role', 'public.call_speaker_attributions', 'UPDATE')
  and not has_table_privilege('service_role', 'public.call_transcript_turns', 'INSERT'),
  'browser and service roles have no direct mutation grants'
);

select ok(
  has_function_privilege('authenticated', 'public.queue_call_speaker_attribution(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.queue_call_speaker_attribution(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.claim_speaker_attribution_jobs(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.renew_speaker_attribution_lease(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.complete_speaker_attribution_job(uuid,uuid,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.fail_speaker_attribution_job(uuid,uuid,text,boolean)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.claim_speaker_attribution_jobs(integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.renew_speaker_attribution_lease(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.complete_speaker_attribution_job(uuid,uuid,jsonb)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.fail_speaker_attribution_job(uuid,uuid,text,boolean)', 'EXECUTE'),
  'manual queue is authenticated-only and lifecycle RPCs are service-role-only'
);

select is(
  (select count(*)
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where namespace.nspname = 'public'
     and procedure.proname in (
       'queue_call_speaker_attribution',
       'claim_speaker_attribution_jobs',
       'renew_speaker_attribution_lease',
       'complete_speaker_attribution_job',
       'fail_speaker_attribution_job'
     )
     and procedure.prosecdef
     and pg_catalog.array_to_string(procedure.proconfig, ',') = 'search_path=""'),
  5::bigint,
  'every public speaker RPC is SECURITY DEFINER with an empty search path'
);

select ok(
  (
    select pg_catalog.strpos(pg_catalog.lower(procedure.prosrc), 'skip locked') > 0
      and pg_catalog.strpos(pg_catalog.lower(procedure.prosrc), 'attempt_count < 3') > 0
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.proname = 'claim_speaker_attribution_jobs'
  ),
  'claim uses skip-locked selection and a maximum of three attempts'
);

-- Simulate a call completed before the migration existed. No backfill function
-- or migration-time insert may create a speaker job for it.
set local session_replication_role = replica;
insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, duration_seconds,
  upload_completed_at
) values (
  '20000000-0000-4000-8000-000000000101',
  '10000000-0000-4000-8000-000000000101',
  '00000000-0000-4000-8000-000000000101',
  'historical-speakers.mp3', 'call-audio',
  '10000000-0000-4000-8000-000000000101/20000000-0000-4000-8000-000000000101/source.mp3',
  'audio/mpeg', 1000, 'uploaded', 3, now()
);
insert into public.call_transcriptions (
  call_id, status, transcript_text, language_code, segments,
  attempt_count, claim_token, started_at, completed_at
) values (
  '20000000-0000-4000-8000-000000000101', 'completed',
  'Hello. Hi there.', 'en',
  '[{"start":0,"end":1,"text":"Hello."},{"start":1,"end":2,"text":"Hi there."}]',
  1, '50000000-0000-4000-8000-000000000101', now() - interval '1 minute', now()
);
set local session_replication_role = origin;

insert into storage.objects (bucket_id, name, metadata) values (
  'call-audio',
  '10000000-0000-4000-8000-000000000101/20000000-0000-4000-8000-000000000101/source.mp3',
  '{"size":1000,"mimetype":"audio/mpeg"}'
);

select is(
  (select count(*) from public.call_speaker_attributions
   where call_id = '20000000-0000-4000-8000-000000000101'),
  0::bigint,
  'migration performs no historical speaker-attribution backfill'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000103', true);
select throws_ok(
  $$select public.queue_call_speaker_attribution('10000000-0000-4000-8000-000000000101', '20000000-0000-4000-8000-000000000101')$$,
  '42501',
  'Speaker attribution is not authorized',
  'ordinary members cannot manually queue speaker attribution'
);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000104', true);
select throws_ok(
  $$select public.queue_call_speaker_attribution('10000000-0000-4000-8000-000000000101', '20000000-0000-4000-8000-000000000101')$$,
  '42501',
  'Speaker attribution is not authorized',
  'cross-workspace users cannot queue a guessed call'
);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000102', true);
select is(
  (select created from public.queue_call_speaker_attribution(
    '10000000-0000-4000-8000-000000000101',
    '20000000-0000-4000-8000-000000000101'
  )),
  true,
  'an admin can queue an eligible existing completed call'
);
select is(
  (select created from public.queue_call_speaker_attribution(
    '10000000-0000-4000-8000-000000000101',
    '20000000-0000-4000-8000-000000000101'
  )),
  false,
  'manual queue is idempotent for the canonical per-call job'
);
reset role;

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, duration_seconds,
  upload_completed_at
) values
  (
    '20000000-0000-4000-8000-000000000102',
    '10000000-0000-4000-8000-000000000101',
    '00000000-0000-4000-8000-000000000101',
    'future-speakers.mp3', 'call-audio',
    '10000000-0000-4000-8000-000000000101/20000000-0000-4000-8000-000000000102/source.mp3',
    'audio/mpeg', 1000, 'uploaded', 3, now()
  ),
  (
    '20000000-0000-4000-8000-000000000103',
    '10000000-0000-4000-8000-000000000101',
    '00000000-0000-4000-8000-000000000101',
    'missing-storage.mp3', 'call-audio',
    '10000000-0000-4000-8000-000000000101/20000000-0000-4000-8000-000000000103/source.mp3',
    'audio/mpeg', 1000, 'uploaded', 3, now()
  );

insert into storage.objects (bucket_id, name, metadata) values (
  'call-audio',
  '10000000-0000-4000-8000-000000000101/20000000-0000-4000-8000-000000000102/source.mp3',
  '{"size":1000,"mimetype":"audio/mpeg"}'
);

update public.call_transcriptions
set
  status = 'completed',
  transcript_text = 'Agent greeting. Customer reply.',
  language_code = 'en',
  segments = '[{"start":0,"end":1,"text":"Agent greeting."},{"start":1,"end":2,"text":"Customer reply."}]',
  attempt_count = 1,
  claim_token = pg_catalog.gen_random_uuid(),
  started_at = now() - interval '1 minute',
  completed_at = now()
where call_id in (
  '20000000-0000-4000-8000-000000000102',
  '20000000-0000-4000-8000-000000000103'
);

select is(
  (select count(*) from public.call_speaker_attributions
   where call_id = '20000000-0000-4000-8000-000000000102'),
  1::bigint,
  'a future legitimate transcription completion automatically enqueues one job'
);
select is(
  (select count(*) from public.call_speaker_attributions
   where call_id = '20000000-0000-4000-8000-000000000103'),
  0::bigint,
  'auto-enqueue requires the exact source recording to still exist'
);

update public.call_transcriptions
set completed_at = completed_at
where call_id = '20000000-0000-4000-8000-000000000102';
select is(
  (select count(*) from public.call_speaker_attributions
   where call_id = '20000000-0000-4000-8000-000000000102'),
  1::bigint,
  'non-transition transcript updates do not duplicate or re-enqueue jobs'
);

create temporary table speaker_claims (
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
) on commit drop;
grant all on table speaker_claims to service_role;

set local role service_role;
insert into speaker_claims
select * from public.claim_speaker_attribution_jobs(5);
reset role;

select is((select count(*) from speaker_claims), 2::bigint, 'a bounded claim leases each eligible queued job once');
select ok(
  (select bool_and(
    storage_bucket = 'call-audio'
    and storage_path = pg_catalog.format('%s/%s/source.mp3', workspace_id, call_id)
    and jsonb_array_length(segments) = 2
    and duration_seconds = 3
  ) from speaker_claims),
  'claim returns only trusted audio metadata, bounded transcript segments, and lifecycle data'
);

set local role service_role;
select is((select count(*) from public.claim_speaker_attribution_jobs(5)), 0::bigint, 'processing jobs cannot be claimed concurrently');
select is(
  public.renew_speaker_attribution_lease(
    '20000000-0000-4000-8000-000000000101',
    '50000000-0000-4000-8000-000000000199'
  ),
  false,
  'a wrong token cannot renew a speaker lease'
);
select is(
  public.renew_speaker_attribution_lease(
    '20000000-0000-4000-8000-000000000101',
    (select claim_token from speaker_claims where call_id = '20000000-0000-4000-8000-000000000101')
  ),
  true,
  'the active token renews its speaker lease'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000102', true);
select is(
  (select outcome from public.prepare_call_deletion(
    '10000000-0000-4000-8000-000000000101',
    '20000000-0000-4000-8000-000000000102'
  )),
  'processing_active'::text,
  'active speaker processing prevents private source deletion'
);
reset role;

set local role service_role;
select throws_ok(
  format(
    'select public.complete_speaker_attribution_job(%L, %L, %L::jsonb)',
    '20000000-0000-4000-8000-000000000101',
    (select claim_token from speaker_claims where call_id = '20000000-0000-4000-8000-000000000101'),
    jsonb_build_array(
      jsonb_build_object(
        'turn_index', 0, 'start_ms', 0, 'end_ms', 1000,
        'text', 'Hello.', 'speaker_key', 'speaker_1', 'speaker_role', 'agent',
        'reasoning', 'not allowed'
      )
    )::text
  ),
  '22023',
  'Speaker turn is invalid',
  'completion rejects extra fields and hidden reasoning'
);
select throws_ok(
  format(
    'select public.complete_speaker_attribution_job(%L, %L, %L::jsonb)',
    '20000000-0000-4000-8000-000000000101',
    (select claim_token from speaker_claims where call_id = '20000000-0000-4000-8000-000000000101'),
    jsonb_build_array(
      jsonb_build_object('turn_index', 1, 'start_ms', 0, 'end_ms', 1000, 'text', 'Hello.', 'speaker_key', 'speaker_1', 'speaker_role', 'agent')
    )::text
  ),
  '22023',
  'Speaker turn is invalid',
  'completion rejects incomplete or duplicate-prone ordinals'
);
select throws_ok(
  format(
    'select public.complete_speaker_attribution_job(%L, %L, %L::jsonb)',
    '20000000-0000-4000-8000-000000000101',
    (select claim_token from speaker_claims where call_id = '20000000-0000-4000-8000-000000000101'),
    jsonb_build_array(
      jsonb_build_object('turn_index', 0, 'start_ms', 0, 'end_ms', 4000, 'text', 'Hello.', 'speaker_key', 'speaker_1', 'speaker_role', 'agent')
    )::text
  ),
  '22023',
  'Speaker turn is invalid',
  'completion rejects timestamps beyond the trusted call duration'
);
select throws_ok(
  format(
    'select public.complete_speaker_attribution_job(%L, %L, %L::jsonb)',
    '20000000-0000-4000-8000-000000000101',
    (select claim_token from speaker_claims where call_id = '20000000-0000-4000-8000-000000000101'),
    jsonb_build_array(
      jsonb_build_object('turn_index', 0, 'start_ms', 0, 'end_ms', 1000, 'text', 'Hello.', 'speaker_key', 'speaker_1', 'speaker_role', 'manager')
    )::text
  ),
  '22023',
  'Speaker turn is invalid',
  'completion rejects arbitrary role labels'
);
reset role;

select is(
  (select count(*) from public.call_transcript_turns
   where call_id = '20000000-0000-4000-8000-000000000101'),
  0::bigint,
  'invalid completion leaves no partial turn set'
);
select is(
  (select status from public.call_speaker_attributions
   where call_id = '20000000-0000-4000-8000-000000000101'),
  'processing'::text,
  'invalid completion rolls back job-state mutation atomically'
);

set local role service_role;
select is(
  (select status from public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000101',
    (select claim_token from speaker_claims where call_id = '20000000-0000-4000-8000-000000000101'),
    jsonb_build_array(
      jsonb_build_object('turn_index', 0, 'start_ms', 0, 'end_ms', 1000, 'text', 'Hello.', 'speaker_key', 'speaker_1', 'speaker_role', 'agent'),
      jsonb_build_object('turn_index', 1, 'start_ms', 1000, 'end_ms', 2000, 'text', 'Hi there.', 'speaker_key', 'speaker_2', 'speaker_role', 'customer')
    )
  )),
  'completed'::text,
  'valid completion atomically stores the exact ordered turn set'
);
reset role;

create temporary table completed_turn_ids as
select id, turn_index
from public.call_transcript_turns
where call_id = '20000000-0000-4000-8000-000000000101';

set local role service_role;
select is(
  (select status from public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000101',
    (select claim_token from speaker_claims where call_id = '20000000-0000-4000-8000-000000000101'),
    '[]'::jsonb
  )),
  'completed'::text,
  'same-token completed retry is idempotent without replacing turns'
);
reset role;

select is(
  (select count(*)
   from completed_turn_ids as saved
   join public.call_transcript_turns as turn
     on turn.id = saved.id and turn.turn_index = saved.turn_index
   where turn.call_id = '20000000-0000-4000-8000-000000000101'),
  2::bigint,
  'database-generated turn IDs remain stable after completion'
);
select is(
  (select transcript_text from public.call_transcriptions
   where call_id = '20000000-0000-4000-8000-000000000101'),
  'Hello. Hi there.'::text,
  'speaker completion never mutates the authoritative plain transcript'
);

update public.call_speaker_attributions
set lease_expires_at = pg_catalog.clock_timestamp() - interval '1 second'
where call_id = '20000000-0000-4000-8000-000000000102';

set local role service_role;
select is(
  (select count(*) from public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000102',
    (select claim_token from speaker_claims where call_id = '20000000-0000-4000-8000-000000000102'),
    jsonb_build_array(
      jsonb_build_object('turn_index', 0, 'start_ms', 0, 'end_ms', 1000, 'text', 'Stale.', 'speaker_key', 'speaker_1', 'speaker_role', 'unknown')
    )
  )),
  0::bigint,
  'a stale worker cannot complete after its lease expires'
);
reset role;

truncate table speaker_claims;
set local role service_role;
insert into speaker_claims select * from public.claim_speaker_attribution_jobs(1);
select is((select attempt_count from speaker_claims), 2, 'an expired job can be reclaimed with a new attempt');
select is(
  (select status from public.fail_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000102',
    (select claim_token from speaker_claims),
    'diarization_unavailable',
    true
  )),
  'queued'::text,
  'retryable failure schedules a bounded retry before the attempt limit'
);
reset role;

update public.call_speaker_attributions
set next_attempt_at = now() - interval '1 second'
where call_id = '20000000-0000-4000-8000-000000000102';
truncate table speaker_claims;
set local role service_role;
insert into speaker_claims select * from public.claim_speaker_attribution_jobs(1);
select is((select attempt_count from speaker_claims), 3, 'the final speaker attempt is bounded at three');
select is(
  (select status from public.fail_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000102',
    (select claim_token from speaker_claims),
    'diarization_unavailable',
    true
  )),
  'failed'::text,
  'retryable failure becomes terminal at the maximum attempt'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000103', true);
select is(
  (select count(*) from public.call_speaker_attributions),
  2::bigint,
  'same-workspace members can read safe speaker lifecycle state'
);
select is(
  (select count(*) from public.call_transcript_turns),
  2::bigint,
  'same-workspace members can read completed safe transcript turns'
);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000104', true);
select is((select count(*) from public.call_speaker_attributions), 0::bigint, 'cross-workspace users cannot read speaker jobs');
select is((select count(*) from public.call_transcript_turns), 0::bigint, 'cross-workspace users cannot read transcript turns');
reset role;

set local role anon;
select throws_ok(
  $$select count(*) from public.call_transcript_turns$$,
  '42501',
  'permission denied for table call_transcript_turns',
  'anonymous users cannot read speaker-attributed transcript turns'
);
reset role;

select * from finish();
rollback;
