begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- Mirror the local Storage service's transaction flag so DELETE reaches RLS.
select set_config('storage.allow_delete_query', 'true', true);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'management-owner@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000062', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'management-admin@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000063', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'management-uploader@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000064', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'management-member@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000065', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'management-outsider@example.com', '', now(), '{}', '{}', now(), now());

insert into public.workspaces (id, name, created_by) values
  ('10000000-0000-0000-0000-000000000061', 'Management workspace', '00000000-0000-0000-0000-000000000061'),
  ('10000000-0000-0000-0000-000000000062', 'Other management workspace', '00000000-0000-0000-0000-000000000065');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000061', 'owner'),
  ('10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000062', 'admin'),
  ('10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'member'),
  ('10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000064', 'member'),
  ('10000000-0000-0000-0000-000000000062', '00000000-0000-0000-0000-000000000065', 'owner');

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values
  ('26000000-0000-0000-0000-000000000601', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'rename.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000601/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000602', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'managed.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000602/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000603', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000061', 'member-denied.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000603/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000604', '10000000-0000-0000-0000-000000000062', '00000000-0000-0000-0000-000000000065', 'other-tenant.mp3', 'call-audio', '10000000-0000-0000-0000-000000000062/26000000-0000-0000-0000-000000000604/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000605', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'delete.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000605/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000606', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'active-transcription.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000606/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000607', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'cascade.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000607/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000608', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'active-analysis.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000608/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000609', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'retry-transcription.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000609/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000610', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'retry-analysis.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000610/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000611', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'queued.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000611/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000612', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'deleting-analysis.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000612/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000613', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'deleting-transcription.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000613/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('26000000-0000-0000-0000-000000000615', '10000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000063', 'storage-present.mp3', 'call-audio', '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000615/source.mp3', 'audio/mpeg', 1000, 'uploaded', now());

insert into storage.objects (bucket_id, name, metadata)
select
  call.storage_bucket,
  call.storage_path,
  '{"size":1000,"mimetype":"audio/mpeg"}'::jsonb
from public.calls as call
where call.id::text like '26000000-0000-0000-0000-0000000006%';

update public.call_transcriptions
set
  status = 'processing',
  attempt_count = 1,
  claim_token = '56000000-0000-4000-8000-000000000606',
  lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes',
  started_at = now()
where call_id = '26000000-0000-0000-0000-000000000606';

update public.call_transcriptions
set
  status = 'failed',
  attempt_count = 2,
  claim_token = '56000000-0000-4000-8000-000000000609',
  last_error_code = 'decode_failed',
  started_at = now() - interval '1 minute',
  failed_at = now()
where call_id = '26000000-0000-0000-0000-000000000609';

update public.call_transcriptions
set
  status = 'completed',
  transcript_text = 'Preserved completed transcript.',
  language_code = 'en',
  attempt_count = 1,
  claim_token = '56000000-0000-4000-8000-000000000607',
  started_at = now() - interval '2 minutes',
  completed_at = now()
where call_id in (
  '26000000-0000-0000-0000-000000000607',
  '26000000-0000-0000-0000-000000000608',
  '26000000-0000-0000-0000-000000000610',
  '26000000-0000-0000-0000-000000000612'
);

update public.call_analyses
set
  status = 'completed',
  summary = 'Completed summary',
  sentiment = 'positive',
  primary_intent = 'evaluation',
  attempt_count = 1,
  claim_token = '57000000-0000-4000-8000-000000000607',
  started_at = now() - interval '1 minute',
  completed_at = now()
where call_id = '26000000-0000-0000-0000-000000000607';

update public.call_analyses
set
  status = 'processing',
  attempt_count = 1,
  claim_token = '57000000-0000-4000-8000-000000000608',
  lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes',
  started_at = now()
where call_id = '26000000-0000-0000-0000-000000000608';

update public.call_analyses
set
  status = 'failed',
  attempt_count = 3,
  claim_token = '57000000-0000-4000-8000-000000000610',
  last_error_code = 'model_unavailable',
  started_at = now() - interval '1 minute',
  failed_at = now()
where call_id = '26000000-0000-0000-0000-000000000610';

select has_column('public', 'calls', 'display_name', 'calls expose a separate display name');

select ok(
  (select pg_catalog.lower(pg_catalog.pg_get_constraintdef(call_constraint.oid)) like '%deleting%'
   from pg_catalog.pg_constraint as call_constraint
   where call_constraint.conrelid = 'public.calls'::regclass
     and call_constraint.conname = 'calls_status_check'),
  'the call status constraint includes deleting'
);

select ok(
  not has_table_privilege('authenticated', 'public.calls', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.calls', 'DELETE'),
  'authenticated users receive no broad calls update or delete privilege'
);

select ok(
  not has_table_privilege('authenticated', 'public.call_transcriptions', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.call_transcriptions', 'DELETE')
  and not has_table_privilege('authenticated', 'public.call_analyses', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.call_analyses', 'DELETE'),
  'authenticated users receive no worker-table mutation privilege'
);

select ok(
  has_function_privilege('authenticated', 'public.rename_call(uuid,uuid,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.prepare_call_deletion(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.finalize_call_deletion(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.retry_failed_call_processing(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.rename_call(uuid,uuid,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.prepare_call_deletion(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.finalize_call_deletion(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.retry_failed_call_processing(uuid,uuid)', 'EXECUTE'),
  'only authenticated callers can execute management RPCs'
);

select ok(
  has_function_privilege('service_role', 'public.claim_transcription_jobs(integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.claim_analysis_jobs(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.claim_transcription_jobs(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.claim_analysis_jobs(integer)', 'EXECUTE'),
  'worker claim RPC permissions remain service-role only'
);

select ok(
  (select count(*) = 7 and pg_catalog.bool_and(
      procedure.prosecdef
      and pg_catalog.array_to_string(procedure.proconfig, ',') = 'search_path=""'
    )
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where (namespace.nspname, procedure.proname) in (
     ('private', 'can_manage_call'),
     ('private', 'can_delete_call_audio'),
     ('private', 'can_upload_call_audio'),
     ('public', 'rename_call'),
     ('public', 'prepare_call_deletion'),
     ('public', 'finalize_call_deletion'),
     ('public', 'retry_failed_call_processing')
   )),
  'management functions are security definer with an empty search path'
);

select ok(
  (select pg_catalog.lower(procedure.prosrc) not like '%delete from storage.objects%'
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where namespace.nspname = 'public'
     and procedure.proname = 'finalize_call_deletion'),
  'finalization verifies Storage state without deleting Storage metadata directly'
);

select ok(
  (select pg_catalog.lower(procedure.prosrc) like '%for share of call%'
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where namespace.nspname = 'private'
     and procedure.proname = 'can_upload_call_audio'),
  'pending uploads row-lock their call against a concurrent deleting transition'
);

set local role anon;
select throws_ok(
  $$select * from public.rename_call(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000601',
    'Denied'
  )$$,
  '42501',
  'permission denied for function rename_call',
  'unauthenticated callers cannot rename calls'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000063', true);
select results_eq(
  $$select * from public.rename_call(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000601',
    '  Discovery review  '
  )$$,
  $$values ('26000000-0000-0000-0000-000000000601'::uuid, 'Discovery review'::text)$$,
  'the uploader can rename their call and receives the normalized name'
);

select is(
  (select display_name from public.calls where id = '26000000-0000-0000-0000-000000000601'),
  'Discovery review',
  'rename stores the trimmed display name'
);

select is(
  (select original_filename from public.calls where id = '26000000-0000-0000-0000-000000000601'),
  'rename.mp3',
  'rename preserves the source filename'
);

select throws_ok(
  $$select * from public.rename_call(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000601', '   '
  )$$,
  '22023', 'Call name must contain between 1 and 120 visible characters',
  'blank display names are rejected'
);

select throws_ok(
  $$select * from public.rename_call(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000601', E'bad\nname'
  )$$,
  '22023', 'Call name must contain between 1 and 120 visible characters',
  'control characters are rejected from display names'
);

select throws_ok(
  $$select * from public.rename_call(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000601', repeat('x', 121)
  )$$,
  '22023', 'Call name must contain between 1 and 120 visible characters',
  'overlong display names are rejected'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000061', true);
select isnt_empty(
  $$select * from public.rename_call(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000602', 'Owner managed'
  )$$,
  'workspace owners can manage calls uploaded by members'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000062', true);
select isnt_empty(
  $$select * from public.rename_call(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000602', 'Admin managed'
  )$$,
  'workspace admins can manage calls uploaded by members'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000064', true);
select is_empty(
  $$select * from public.rename_call(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000602', 'Member denied'
  )$$,
  'ordinary members cannot rename another uploader''s call'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000065', true);
select is_empty(
  $$select * from public.rename_call(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000602', 'Cross tenant denied'
  )$$,
  'another tenant cannot rename a call'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000064', true);
select is_empty(
  $$select * from public.prepare_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000603'
  )$$,
  'ordinary members cannot prepare deletion of another uploader''s call'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000063', true);
select results_eq(
  $$select * from public.prepare_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000605'
  )$$,
  $$values (
    'prepared'::text,
    'call-audio'::text,
    '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000605/source.mp3'::text
  )$$,
  'delete preparation returns only the exact trusted Storage object'
);

select is(
  (select status from public.calls where id = '26000000-0000-0000-0000-000000000605'),
  'deleting',
  'delete preparation transitions the call to deleting'
);

select ok(
  not private.can_delete_call_audio(
    'call-audio',
    '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000603/source.mp3'
  ),
  'the Storage authorization helper rejects another call object'
);

delete from storage.objects
where bucket_id = 'call-audio'
  and name = '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000603/source.mp3';

reset role;
select ok(
  exists (
    select 1 from storage.objects
    where bucket_id = 'call-audio'
      and name = '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000603/source.mp3'
  ),
  'an arbitrary Storage object remains intact'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000063', true);
select ok(
  private.can_delete_call_audio(
    'call-audio',
    '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000605/source.mp3'
  ),
  'the Storage authorization helper accepts the exact authorized deleting-call object'
);

delete from storage.objects
where bucket_id = 'call-audio'
  and name = '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000605/source.mp3';

select is(
  public.finalize_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000605'
  ),
  'deleted',
  'finalization deletes the call only after Storage is empty'
);

reset role;
select is(
  (select count(*) from public.calls where id = '26000000-0000-0000-0000-000000000605'),
  0::bigint,
  'successful finalization removes the call row'
);

select is(
  (select count(*) from public.call_transcriptions where call_id = '26000000-0000-0000-0000-000000000605'),
  0::bigint,
  'call deletion cascades its transcription row'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000063', true);
select results_eq(
  $$select outcome from public.prepare_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000606'
  )$$,
  $$values ('processing_active'::text)$$,
  'active transcription blocks delete preparation'
);

select is(
  (select status from public.calls where id = '26000000-0000-0000-0000-000000000606'),
  'uploaded',
  'a blocked transcription deletion leaves the call uploaded'
);

select results_eq(
  $$select outcome from public.prepare_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000608'
  )$$,
  $$values ('processing_active'::text)$$,
  'active analysis blocks delete preparation'
);

select results_eq(
  $$select outcome from public.prepare_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000615'
  )$$,
  $$values ('prepared'::text)$$,
  'the first delete preparation succeeds'
);

select results_eq(
  $$select outcome from public.prepare_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000615'
  )$$,
  $$values ('already_deleting'::text)$$,
  'duplicate delete preparation is idempotent and recoverable'
);

select is(
  public.finalize_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000615'
  ),
  'storage_present',
  'finalization refuses while the exact Storage object exists'
);

select is(
  public.retry_failed_call_processing(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000607'
  ),
  'none',
  'retry does not reset completed processing'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000061', true);
select results_eq(
  $$select outcome from public.prepare_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000607'
  )$$,
  $$values ('prepared'::text)$$,
  'a workspace owner can prepare a member-uploaded completed call for deletion'
);

delete from storage.objects
where bucket_id = 'call-audio'
  and name = '10000000-0000-0000-0000-000000000061/26000000-0000-0000-0000-000000000607/source.mp3';

select is(
  public.finalize_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000607'
  ),
  'deleted',
  'owner-authorized deletion finalizes after Storage removal'
);

reset role;
select is(
  (select count(*) from public.call_transcriptions where call_id = '26000000-0000-0000-0000-000000000607'),
  0::bigint,
  'deleting a call cascades completed transcription data'
);

select is(
  (select count(*) from public.call_analyses where call_id = '26000000-0000-0000-0000-000000000607'),
  0::bigint,
  'deleting a call cascades completed analysis data'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000064', true);
select is(
  public.retry_failed_call_processing(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000609'
  ),
  'none',
  'ordinary members cannot retry another uploader''s failed call'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000065', true);
select is(
  public.retry_failed_call_processing(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000609'
  ),
  'none',
  'retry cannot cross a workspace boundary'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000063', true);
select is(
  public.retry_failed_call_processing(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000609'
  ),
  'transcription',
  'a terminal failed transcription is manually queued'
);

reset role;
select ok(
  (select status = 'queued'
      and attempt_count = 0
      and claim_token is null
      and lease_expires_at is null
      and next_attempt_at is null
      and last_error_code is null
      and started_at is null
      and completed_at is null
      and failed_at is null
      and transcript_text is null
      and language_code is null
      and segments = '[]'::jsonb
   from public.call_transcriptions
   where call_id = '26000000-0000-0000-0000-000000000609'),
  'manual transcription retry clears all prior lifecycle state'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000063', true);
select is(
  public.retry_failed_call_processing(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000609'
  ),
  'none',
  'duplicate retry does not create or requeue another job'
);

select is(
  public.retry_failed_call_processing(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000610'
  ),
  'analysis',
  'a terminal failed analysis is manually queued'
);

reset role;
select is(
  (select transcript_text from public.call_transcriptions
   where call_id = '26000000-0000-0000-0000-000000000610'),
  'Preserved completed transcript.',
  'analysis retry preserves the completed transcript'
);

select ok(
  (select status = 'queued'
      and attempt_count = 0
      and claim_token is null
      and lease_expires_at is null
      and next_attempt_at is null
      and last_error_code is null
      and started_at is null
      and completed_at is null
      and failed_at is null
      and summary is null
      and sentiment is null
      and primary_intent is null
      and objections = '[]'::jsonb
      and action_items = '[]'::jsonb
      and topics = '[]'::jsonb
      and overall_score is null
   from public.call_analyses
   where call_id = '26000000-0000-0000-0000-000000000610'),
  'manual analysis retry clears prior lifecycle and output state'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000063', true);
select is(
  public.retry_failed_call_processing(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000611'
  ),
  'none',
  'retry does not apply to an already queued job'
);

select is(
  public.retry_failed_call_processing(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000606'
  ),
  'none',
  'retry does not apply to an active processing job'
);

select results_eq(
  $$select outcome from public.prepare_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000612'
  )$$,
  $$values ('prepared'::text)$$,
  'a queued analysis call can enter deleting safely'
);

select is(
  public.retry_failed_call_processing(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000612'
  ),
  'none',
  'retry does not apply to a deleting call'
);

select results_eq(
  $$select outcome from public.prepare_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000613'
  )$$,
  $$values ('prepared'::text)$$,
  'a queued transcription call can enter deleting safely'
);

reset role;
create temporary table transcription_claims as
select * from public.claim_transcription_jobs(5);

select is(
  (select count(*) from transcription_claims
   where call_id = '26000000-0000-0000-0000-000000000613'),
  0::bigint,
  'the worker cannot claim a transcription after the call starts deleting'
);

create temporary table analysis_claims as
select * from public.claim_analysis_jobs(5);

select is(
  (select count(*) from analysis_claims
   where call_id = '26000000-0000-0000-0000-000000000612'),
  0::bigint,
  'the worker cannot claim an analysis after the call starts deleting'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000063', true);
select throws_ok(
  $$update public.call_transcriptions set status = 'failed'
    where call_id = '26000000-0000-0000-0000-000000000611'$$,
  '42501', 'permission denied for table call_transcriptions',
  'authenticated users still cannot directly mutate transcription jobs'
);

select throws_ok(
  $$update public.call_analyses set status = 'failed'
    where call_id = '26000000-0000-0000-0000-000000000610'$$,
  '42501', 'permission denied for table call_analyses',
  'authenticated users still cannot directly mutate analysis jobs'
);

select throws_ok(
  $$select * from public.claim_transcription_jobs(1)$$,
  '42501', 'permission denied for function claim_transcription_jobs',
  'authenticated users still cannot execute worker transcription claims'
);

select throws_ok(
  $$select * from public.claim_analysis_jobs(1)$$,
  '42501', 'permission denied for function claim_analysis_jobs',
  'authenticated users still cannot execute worker analysis claims'
);

reset role;
select ok(
  not has_table_privilege('service_role', 'public.call_transcriptions', 'UPDATE')
  and not has_table_privilege('service_role', 'public.call_analyses', 'UPDATE'),
  'service role direct table-mutation restrictions remain unchanged'
);

set local role anon;
select throws_ok(
  $$select public.finalize_call_deletion(
    '10000000-0000-0000-0000-000000000061',
    '26000000-0000-0000-0000-000000000615'
  )$$,
  '42501', 'permission denied for function finalize_call_deletion',
  'unauthenticated callers cannot finalize deletion'
);

reset role;
select * from finish();
rollback;
