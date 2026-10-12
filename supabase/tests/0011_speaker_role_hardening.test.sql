begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select no_plan();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-4000-8000-000000000201', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hardening-owner@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000202', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hardening-admin@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000203', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hardening-member@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000204', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hardening-outsider@example.com', '', now(), '{}', '{}', now(), now());

insert into public.workspaces (id, name, created_by) values
  ('10000000-0000-4000-8000-000000000201', 'Hardening workspace A', '00000000-0000-4000-8000-000000000201'),
  ('10000000-0000-4000-8000-000000000202', 'Hardening workspace B', '00000000-0000-4000-8000-000000000204');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000201', 'owner'),
  ('10000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000202', 'admin'),
  ('10000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000203', 'member'),
  ('10000000-0000-4000-8000-000000000202', '00000000-0000-4000-8000-000000000204', 'owner');

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, duration_seconds,
  upload_completed_at
)
select
  ('20000000-0000-4000-8000-' || pg_catalog.lpad(suffix::text, 12, '0'))::uuid,
  '10000000-0000-4000-8000-000000000201'::uuid,
  '00000000-0000-4000-8000-000000000201'::uuid,
  pg_catalog.format('hardening-%s.mp3', suffix),
  'call-audio',
  pg_catalog.format(
    '10000000-0000-4000-8000-000000000201/20000000-0000-4000-8000-%s/source.mp3',
    pg_catalog.lpad(suffix::text, 12, '0')
  ),
  'audio/mpeg',
  1000,
  'uploaded',
  case when suffix = 205 then null else 5 end,
  now()
from pg_catalog.generate_series(201, 216) as suffix;

insert into storage.objects (bucket_id, name, metadata)
select
  'call-audio',
  pg_catalog.format(
    '10000000-0000-4000-8000-000000000201/20000000-0000-4000-8000-%s/source.mp3',
    pg_catalog.lpad(suffix::text, 12, '0')
  ),
  '{"size":1000,"mimetype":"audio/mpeg"}'::jsonb
from pg_catalog.generate_series(201, 216) as suffix;

-- Eventless completed rows stand in for calls that predate the feature. The
-- migration contains no scan, so they remain untouched until a future event.
set local session_replication_role = replica;
update public.call_transcriptions
set
  status = 'completed',
  transcript_text = 'Historical transcript.',
  language_code = 'en',
  segments = '[{"start":0,"end":1,"text":"Historical transcript."}]',
  attempt_count = 1,
  claim_token = '50000000-0000-4000-8000-000000000201',
  started_at = now() - interval '1 minute',
  completed_at = now()
where call_id = '20000000-0000-4000-8000-000000000201';
set local session_replication_role = origin;

select is(
  (select count(*) from public.call_speaker_attributions
   where call_id = '20000000-0000-4000-8000-000000000201'),
  0::bigint,
  'the hardening migration performs no historical speaker-attribution backfill'
);

-- A transcription inserted in completed state is a future completion event.
delete from public.call_transcriptions
where call_id = '20000000-0000-4000-8000-000000000202';
insert into public.call_transcriptions (
  call_id, status, transcript_text, language_code, segments,
  attempt_count, claim_token, started_at, completed_at
) values (
  '20000000-0000-4000-8000-000000000202', 'completed',
  'Inserted completed transcript.', 'en',
  '[{"start":0,"end":1,"text":"Inserted completed transcript."}]',
  1, '50000000-0000-4000-8000-000000000202', now() - interval '1 minute', now()
);

select is(
  (select count(*) from public.call_speaker_attributions
   where call_id = '20000000-0000-4000-8000-000000000202'),
  1::bigint,
  'a future transcription inserted as completed automatically enqueues'
);

update public.call_transcriptions
set
  status = 'completed',
  transcript_text = 'Transitioned completed transcript.',
  language_code = 'en',
  segments = '[{"start":0,"end":1,"text":"Transitioned completed transcript."}]',
  attempt_count = 1,
  claim_token = '50000000-0000-4000-8000-000000000203',
  started_at = now() - interval '1 minute',
  completed_at = now()
where call_id = '20000000-0000-4000-8000-000000000203';

select is(
  (select count(*) from public.call_speaker_attributions
   where call_id = '20000000-0000-4000-8000-000000000203'),
  1::bigint,
  'a future transition to completed automatically enqueues'
);

set local session_replication_role = replica;
update public.call_transcriptions
set
  status = 'completed',
  transcript_text = 'Needs a relevant update.',
  language_code = 'en',
  segments = '[{"start":0,"end":1,"text":"Needs a relevant update."}]',
  attempt_count = 1,
  claim_token = '50000000-0000-4000-8000-000000000204',
  started_at = now() - interval '1 minute',
  completed_at = now()
where call_id = '20000000-0000-4000-8000-000000000204';
set local session_replication_role = origin;

update public.call_transcriptions
set transcript_text = 'Relevant update now eligible.'
where call_id = '20000000-0000-4000-8000-000000000204';

select is(
  (select count(*) from public.call_speaker_attributions
   where call_id = '20000000-0000-4000-8000-000000000204'),
  1::bigint,
  'a relevant update to a completed transcription self-heals a missing job'
);

update public.call_transcriptions
set
  status = 'completed',
  transcript_text = 'Waiting for trusted duration.',
  language_code = 'en',
  segments = '[{"start":0,"end":1,"text":"Waiting for trusted duration."}]',
  attempt_count = 1,
  claim_token = '50000000-0000-4000-8000-000000000205',
  started_at = now() - interval '1 minute',
  completed_at = now()
where call_id = '20000000-0000-4000-8000-000000000205';

select is(
  (select count(*) from public.call_speaker_attributions
   where call_id = '20000000-0000-4000-8000-000000000205'),
  0::bigint,
  'an incomplete trusted call does not enqueue prematurely'
);

update public.calls
set duration_seconds = 5
where id = '20000000-0000-4000-8000-000000000205';

select is(
  (select count(*) from public.call_speaker_attributions
   where call_id = '20000000-0000-4000-8000-000000000205'),
  1::bigint,
  'late trusted call metadata self-heals a missing job'
);

update public.call_transcriptions
set completed_at = completed_at
where call_id in (
  '20000000-0000-4000-8000-000000000202',
  '20000000-0000-4000-8000-000000000203',
  '20000000-0000-4000-8000-000000000204',
  '20000000-0000-4000-8000-000000000205'
);

select is(
  (select count(*) from public.call_speaker_attributions
   where call_id in (
     '20000000-0000-4000-8000-000000000202',
     '20000000-0000-4000-8000-000000000203',
     '20000000-0000-4000-8000-000000000204',
     '20000000-0000-4000-8000-000000000205'
   )),
  4::bigint,
  'repeated completion events remain idempotent'
);

-- Complete the remaining transcription fixtures so their canonical speaker
-- jobs are created by the normal automatic event path.
update public.call_transcriptions
set
  status = 'completed',
  transcript_text = 'Agent greeting. Customer request. Agent response. Customer close.',
  language_code = 'en',
  segments = '[
    {"start":0,"end":1,"text":"Agent greeting."},
    {"start":1,"end":2,"text":"Customer request."},
    {"start":2,"end":3,"text":"Agent response."},
    {"start":3,"end":4,"text":"Customer close."}
  ]',
  attempt_count = 1,
  claim_token = pg_catalog.gen_random_uuid(),
  started_at = now() - interval '1 minute',
  completed_at = now()
where call_id between
  '20000000-0000-4000-8000-000000000206'
  and '20000000-0000-4000-8000-000000000216';

select ok(
  exists (
    select 1
    from public.call_speaker_attributions
    where call_id = '20000000-0000-4000-8000-000000000210'
      and status = 'queued'
      and attempt_count = 0
      and claim_token is null
  ),
  'a worker-offline automatically queued job remains durable and unclaimed'
);

update public.call_speaker_attributions
set
  status = 'failed', attempt_count = 3,
  claim_token = pg_catalog.gen_random_uuid(), last_error_code = 'worker_error',
  started_at = now() - interval '5 minutes', failed_at = now()
where call_id in (
  '20000000-0000-4000-8000-000000000206',
  '20000000-0000-4000-8000-000000000207',
  '20000000-0000-4000-8000-000000000208',
  '20000000-0000-4000-8000-000000000209'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000201', true);
select is(
  (select status from public.retry_call_speaker_attribution(
    '10000000-0000-4000-8000-000000000201',
    '20000000-0000-4000-8000-000000000206'
  )),
  'queued'::text,
  'an owner can retry an eligible terminal failed speaker job'
);
reset role;

select ok(
  exists (
    select 1
    from public.call_speaker_attributions
    where call_id = '20000000-0000-4000-8000-000000000206'
      and status = 'queued'
      and attempt_count = 0
      and claim_token is null
      and lease_expires_at is null
      and next_attempt_at is null
      and last_error_code is null
      and started_at is null
      and completed_at is null
      and failed_at is null
  ),
  'failed retry resets only the bounded lifecycle to a clean queued state'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000202', true);
select is(
  (select status from public.retry_call_speaker_attribution(
    '10000000-0000-4000-8000-000000000201',
    '20000000-0000-4000-8000-000000000207'
  )),
  'queued'::text,
  'an admin can retry an eligible terminal failed speaker job'
);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000203', true);
select throws_ok(
  $$select public.retry_call_speaker_attribution('10000000-0000-4000-8000-000000000201', '20000000-0000-4000-8000-000000000208')$$,
  '42501',
  'Speaker attribution retry is not authorized',
  'an ordinary member cannot retry a failed speaker job'
);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000204', true);
select throws_ok(
  $$select public.retry_call_speaker_attribution('10000000-0000-4000-8000-000000000201', '20000000-0000-4000-8000-000000000209')$$,
  '42501',
  'Speaker attribution retry is not authorized',
  'a cross-workspace owner cannot retry a guessed speaker job'
);
reset role;

update public.call_speaker_attributions
set
  status = 'processing', attempt_count = 1,
  claim_token = '60000000-0000-4000-8000-000000000211',
  lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes',
  started_at = now()
where call_id = '20000000-0000-4000-8000-000000000211';

update public.call_speaker_attributions
set
  status = 'completed', attempt_count = 1,
  claim_token = '60000000-0000-4000-8000-000000000212',
  completed_at = now(), started_at = now()
where call_id = '20000000-0000-4000-8000-000000000212';

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000201', true);
select throws_ok(
  $$select public.retry_call_speaker_attribution('10000000-0000-4000-8000-000000000201', '20000000-0000-4000-8000-000000000210')$$,
  '55000',
  'Only a failed speaker attribution can be retried',
  'a queued speaker job cannot be manually retried'
);
select throws_ok(
  $$select public.retry_call_speaker_attribution('10000000-0000-4000-8000-000000000201', '20000000-0000-4000-8000-000000000211')$$,
  '55000',
  'Only a failed speaker attribution can be retried',
  'a processing speaker job cannot be manually retried'
);
select throws_ok(
  $$select public.retry_call_speaker_attribution('10000000-0000-4000-8000-000000000201', '20000000-0000-4000-8000-000000000212')$$,
  '55000',
  'Only a failed speaker attribution can be retried',
  'a completed speaker job cannot be manually retried'
);
reset role;

update public.call_speaker_attributions
set
  status = 'processing', attempt_count = 1,
  claim_token = ('60000000-0000-4000-8000-' || pg_catalog.lpad(suffix::text, 12, '0'))::uuid,
  lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes',
  started_at = now()
from pg_catalog.generate_series(213, 216) as suffix
where call_id = ('20000000-0000-4000-8000-' || pg_catalog.lpad(suffix::text, 12, '0'))::uuid;

set local role service_role;

select throws_ok(
  $$select public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000213',
    '60000000-0000-4000-8000-000000000213',
    '[
      {"turn_index":0,"start_ms":0,"end_ms":1000,"text":"A","speaker_key":"speaker_1","speaker_role":"agent"},
      {"turn_index":1,"start_ms":1000,"end_ms":2000,"text":"B","speaker_key":"speaker_1","speaker_role":"customer"},
      {"turn_index":2,"start_ms":2000,"end_ms":3000,"text":"C","speaker_key":"speaker_2","speaker_role":"customer"}
    ]'::jsonb
  )$$,
  '22023',
  'Speaker roles must be stable for each acoustic speaker',
  'one acoustic key cannot change role across turns'
);

select throws_ok(
  $$select public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000213',
    '60000000-0000-4000-8000-000000000213',
    '[{"turn_index":0,"start_ms":0,"end_ms":1000,"text":"A","speaker_key":"unknown","speaker_role":"agent"}]'::jsonb
  )$$,
  '22023',
  'Speaker turn is invalid',
  'an unknown acoustic key must have an unknown role'
);

select throws_ok(
  $$select public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000213',
    '60000000-0000-4000-8000-000000000213',
    '[{"turn_index":0,"start_ms":0,"end_ms":1000,"text":"A","speaker_key":"speaker_1","speaker_role":"agent"}]'::jsonb
  )$$,
  '22023',
  'One acoustic speaker must remain unknown',
  'one detected acoustic speaker cannot be assigned a business role'
);

select throws_ok(
  $$select public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000213',
    '60000000-0000-4000-8000-000000000213',
    '[
      {"turn_index":0,"start_ms":0,"end_ms":1000,"text":"A","speaker_key":"speaker_1","speaker_role":"agent"},
      {"turn_index":1,"start_ms":1000,"end_ms":2000,"text":"B","speaker_key":"speaker_2","speaker_role":"agent"}
    ]'::jsonb
  )$$,
  '22023',
  'Two acoustic speakers require a complete role pair or full uncertainty',
  'two agents are rejected for an ordinary two-speaker mapping'
);

select throws_ok(
  $$select public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000213',
    '60000000-0000-4000-8000-000000000213',
    '[
      {"turn_index":0,"start_ms":0,"end_ms":1000,"text":"A","speaker_key":"speaker_1","speaker_role":"customer"},
      {"turn_index":1,"start_ms":1000,"end_ms":2000,"text":"B","speaker_key":"speaker_2","speaker_role":"customer"}
    ]'::jsonb
  )$$,
  '22023',
  'Two acoustic speakers require a complete role pair or full uncertainty',
  'two customers are rejected for an ordinary two-speaker mapping'
);

select throws_ok(
  $$select public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000213',
    '60000000-0000-4000-8000-000000000213',
    '[
      {"turn_index":0,"start_ms":0,"end_ms":1000,"text":"A","speaker_key":"speaker_1","speaker_role":"agent"},
      {"turn_index":1,"start_ms":1000,"end_ms":2000,"text":"B","speaker_key":"speaker_2","speaker_role":"unknown"}
    ]'::jsonb
  )$$,
  '22023',
  'Two acoustic speakers require a complete role pair or full uncertainty',
  'an agent plus unknown is rejected without inference by elimination'
);

select throws_ok(
  $$select public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000213',
    '60000000-0000-4000-8000-000000000213',
    '[
      {"turn_index":0,"start_ms":0,"end_ms":1000,"text":"A","speaker_key":"speaker_1","speaker_role":"customer"},
      {"turn_index":1,"start_ms":1000,"end_ms":2000,"text":"B","speaker_key":"speaker_2","speaker_role":"unknown"}
    ]'::jsonb
  )$$,
  '22023',
  'Two acoustic speakers require a complete role pair or full uncertainty',
  'a customer plus unknown is rejected without inference by elimination'
);

select is(
  (select status from public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000213',
    '60000000-0000-4000-8000-000000000213',
    '[
      {"turn_index":0,"start_ms":0,"end_ms":1000,"text":"A","speaker_key":"speaker_1","speaker_role":"agent"},
      {"turn_index":1,"start_ms":1000,"end_ms":2000,"text":"B","speaker_key":"speaker_2","speaker_role":"customer"}
    ]'::jsonb
  )),
  'completed'::text,
  'exactly one agent and one customer is accepted for two acoustic speakers'
);

select is(
  (select status from public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000214',
    '60000000-0000-4000-8000-000000000214',
    '[
      {"turn_index":0,"start_ms":0,"end_ms":1000,"text":"A","speaker_key":"speaker_1","speaker_role":"unknown"},
      {"turn_index":1,"start_ms":1000,"end_ms":2000,"text":"B","speaker_key":"speaker_2","speaker_role":"unknown"}
    ]'::jsonb
  )),
  'completed'::text,
  'two fully unknown acoustic speakers are accepted as explicit uncertainty'
);

select is(
  (select status from public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000215',
    '60000000-0000-4000-8000-000000000215',
    '[{"turn_index":0,"start_ms":0,"end_ms":1000,"text":"A","speaker_key":"speaker_1","speaker_role":"unknown"}]'::jsonb
  )),
  'completed'::text,
  'one acoustic speaker remains unknown and completes safely'
);

select is(
  (select status from public.complete_speaker_attribution_job(
    '20000000-0000-4000-8000-000000000216',
    '60000000-0000-4000-8000-000000000216',
    '[
      {"turn_index":0,"start_ms":0,"end_ms":1000,"text":"A","speaker_key":"speaker_1","speaker_role":"agent"},
      {"turn_index":1,"start_ms":1000,"end_ms":2000,"text":"B","speaker_key":"speaker_2","speaker_role":"agent"},
      {"turn_index":2,"start_ms":2000,"end_ms":3000,"text":"C","speaker_key":"speaker_3","speaker_role":"customer"},
      {"turn_index":3,"start_ms":3000,"end_ms":4000,"text":"D","speaker_key":"speaker_4","speaker_role":"unknown"}
    ]'::jsonb
  )),
  'completed'::text,
  'three or more speakers may contain repeated legitimate business roles'
);

reset role;

select is(
  (select transcript_text from public.call_transcriptions
   where call_id = '20000000-0000-4000-8000-000000000213'),
  'Agent greeting. Customer request. Agent response. Customer close.'::text,
  'role hardening never changes the authoritative transcript text'
);

select ok(
  has_function_privilege('authenticated', 'public.retry_call_speaker_attribution(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.retry_call_speaker_attribution(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.retry_call_speaker_attribution(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.claim_speaker_attribution_jobs(integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.claim_speaker_attribution_jobs(integer)', 'EXECUTE'),
  'retry is authenticated-only while worker lifecycle RPCs remain service-role-only'
);

select ok(
  not has_table_privilege('authenticated', 'public.call_speaker_attributions', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.call_transcript_turns', 'INSERT')
  and (
    select procedure.prosecdef
      and pg_catalog.array_to_string(procedure.proconfig, ',') = 'search_path=""'
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.proname = 'retry_call_speaker_attribution'
  ),
  'retry adds no direct browser mutation and uses a safe SECURITY DEFINER boundary'
);

select * from finish();
rollback;
