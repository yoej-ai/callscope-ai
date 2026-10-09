begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(67);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'transcription-owner@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000042', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'transcription-member@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000043', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'transcription-outsider@example.com', '', now(), '{}', '{}', now(), now());

insert into public.workspaces (id, name, created_by) values
  ('10000000-0000-0000-0000-000000000041', 'Transcription workspace', '00000000-0000-0000-0000-000000000041'),
  ('10000000-0000-0000-0000-000000000042', 'Hidden transcription workspace', '00000000-0000-0000-0000-000000000043');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000041', 'owner'),
  ('10000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000042', 'member'),
  ('10000000-0000-0000-0000-000000000042', '00000000-0000-0000-0000-000000000043', 'owner');

select has_table('public', 'call_transcriptions', 'the transcription table exists');

select ok(
  (select class.relrowsecurity
   from pg_catalog.pg_class as class
   join pg_catalog.pg_namespace as namespace on namespace.oid = class.relnamespace
   where namespace.nspname = 'public' and class.relname = 'call_transcriptions'),
  'row level security is enabled on transcription rows'
);

select ok(
  has_column_privilege('authenticated', 'public.call_transcriptions', 'id', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_transcriptions', 'call_id', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_transcriptions', 'status', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_transcriptions', 'transcript_text', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_transcriptions', 'language_code', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_transcriptions', 'segments', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_transcriptions', 'started_at', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_transcriptions', 'completed_at', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_transcriptions', 'created_at', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_transcriptions', 'updated_at', 'SELECT'),
  'authenticated users receive select permission only on safe transcript columns'
);

select ok(
  not has_column_privilege('authenticated', 'public.call_transcriptions', 'attempt_count', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_transcriptions', 'claim_token', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_transcriptions', 'lease_expires_at', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_transcriptions', 'next_attempt_at', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_transcriptions', 'last_error_code', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_transcriptions', 'failed_at', 'SELECT'),
  'worker claim, lease, retry, and error columns are not browser-readable'
);

select ok(
  not has_table_privilege('authenticated', 'public.call_transcriptions', 'INSERT')
  and not has_table_privilege('authenticated', 'public.call_transcriptions', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.call_transcriptions', 'DELETE'),
  'authenticated users have no transcription mutation privileges'
);

select ok(
  not has_table_privilege('service_role', 'public.call_transcriptions', 'SELECT')
  and not has_table_privilege('service_role', 'public.call_transcriptions', 'INSERT')
  and not has_table_privilege('service_role', 'public.call_transcriptions', 'UPDATE')
  and not has_table_privilege('service_role', 'public.call_transcriptions', 'DELETE'),
  'the worker role must use the narrow RPC boundary instead of direct table access'
);

select ok(
  has_function_privilege('service_role', 'public.claim_transcription_jobs(integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.renew_transcription_lease(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.complete_transcription_job(uuid,uuid,text,text,jsonb,integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.fail_transcription_job(uuid,uuid,text,boolean)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.claim_transcription_jobs(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.renew_transcription_lease(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.complete_transcription_job(uuid,uuid,text,text,jsonb,integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.fail_transcription_job(uuid,uuid,text,boolean)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.claim_transcription_jobs(integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.renew_transcription_lease(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.complete_transcription_job(uuid,uuid,text,text,jsonb,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.fail_transcription_job(uuid,uuid,text,boolean)', 'EXECUTE'),
  'only service_role can execute worker RPCs'
);

select ok(
  (select count(*) = 6
      and pg_catalog.bool_and(
        procedure.prosecdef
        and pg_catalog.array_to_string(procedure.proconfig, ',') = 'search_path=""'
      )
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where (
       namespace.nspname = 'public'
       and procedure.proname in (
         'claim_transcription_jobs',
         'renew_transcription_lease',
         'complete_transcription_job',
         'fail_transcription_job'
       )
     ) or (
       namespace.nspname = 'private'
       and procedure.proname in (
         'enqueue_call_transcription',
         'backfill_call_transcriptions'
       )
     )),
  'worker and enqueue functions are security definer with an empty search path'
);

select ok(
  (select pg_catalog.lower(procedure.prosrc) like '%for update of transcription, call skip locked%'
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where namespace.nspname = 'public'
     and procedure.proname = 'claim_transcription_jobs'),
  'claiming structurally locks both the job and parent call with skip-locked row locks'
);

select ok(
  not exists (
    select 1 from pg_catalog.pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and cmd = 'UPDATE'
  )
  and (select count(*) from pg_catalog.pg_policies
       where schemaname = 'storage' and tablename = 'objects'
         and cmd = 'SELECT') = 1
  and (select count(*) from pg_catalog.pg_policies
       where schemaname = 'storage' and tablename = 'objects'
         and policyname = 'call_audio_select_managed_deleting_for_delete'
         and cmd = 'SELECT'
         and pg_catalog.lower(qual) like '%storage.allow_delete_query%') = 1
  and (select count(*) from pg_catalog.pg_policies
       where schemaname = 'storage' and tablename = 'objects'
         and cmd = 'DELETE') = 1
  and (select count(*) from pg_catalog.pg_policies
       where schemaname = 'storage' and tablename = 'objects'
         and policyname = 'call_audio_delete_managed_deleting'
         and cmd = 'DELETE') = 1,
  'transcription keeps Storage reads delete-transaction-only and deletion exact-object scoped'
);

select ok(
  exists (
    select 1
    from pg_catalog.pg_trigger as trigger
    join pg_catalog.pg_class as class on class.oid = trigger.tgrelid
    join pg_catalog.pg_namespace as namespace on namespace.oid = class.relnamespace
    where namespace.nspname = 'public'
      and class.relname = 'calls'
      and trigger.tgname = 'calls_enqueue_transcription'
      and not trigger.tgisinternal
  ),
  'calls have a dedicated transcription enqueue trigger'
);

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values
  ('20000000-0000-0000-0000-000000000041', '10000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000041', 'trigger.mp3', 'call-audio', '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000041/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('20000000-0000-0000-0000-000000000042', '10000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000041', 'pending.mp3', 'call-audio', '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000042/source.mp3', 'audio/mpeg', 1000, 'pending_upload', null),
  ('20000000-0000-0000-0000-000000000043', '10000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000041', 'failed.mp3', 'call-audio', '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000043/source.mp3', 'audio/mpeg', 1000, 'failed', null),
  ('20000000-0000-0000-0000-000000000044', '10000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000041', 'legacy.mp3', 'call-audio', '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000044/source', null, 1000, 'uploaded', now());

select is(
  (select count(*) from public.call_transcriptions
   where call_id = '20000000-0000-0000-0000-000000000041'),
  1::bigint,
  'a securely uploaded call automatically queues one transcription'
);

update public.calls set status = 'uploaded'
where id = '20000000-0000-0000-0000-000000000041';
select is(
  (select count(*) from public.call_transcriptions
   where call_id = '20000000-0000-0000-0000-000000000041'),
  1::bigint,
  'repeated uploaded-state finalization cannot duplicate a transcription row'
);

select is(
  (select count(*) from public.call_transcriptions
   where call_id = '20000000-0000-0000-0000-000000000042'),
  0::bigint,
  'pending uploads are not enqueued'
);

select is(
  (select count(*) from public.call_transcriptions
   where call_id = '20000000-0000-0000-0000-000000000043'),
  0::bigint,
  'failed ingestion rows are not enqueued'
);

select is(
  (select count(*) from public.call_transcriptions
   where call_id = '20000000-0000-0000-0000-000000000044'),
  0::bigint,
  'incomplete legacy-style uploaded rows are not enqueued'
);

alter table public.calls disable trigger calls_enqueue_transcription;
insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values
  ('20000000-0000-0000-0000-000000000045', '10000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000041', 'backfill.mp3', 'call-audio', '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000045/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('20000000-0000-0000-0000-000000000046', '10000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000041', 'backfill-pending.mp3', 'call-audio', '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000046/source.mp3', 'audio/mpeg', 1000, 'pending_upload', null),
  ('20000000-0000-0000-0000-000000000047', '10000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000041', 'backfill-failed.mp3', 'call-audio', '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000047/source.mp3', 'audio/mpeg', 1000, 'failed', null),
  ('20000000-0000-0000-0000-000000000048', '10000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000041', 'backfill-legacy.mp3', 'call-audio', '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000048/source', null, 1000, 'uploaded', now());
alter table public.calls enable trigger calls_enqueue_transcription;

select is(
  private.backfill_call_transcriptions(),
  1::bigint,
  'backfill inserts only the eligible securely uploaded call'
);

select results_eq(
  $$select call_id from public.call_transcriptions
    where call_id between '20000000-0000-0000-0000-000000000045'::uuid
                      and '20000000-0000-0000-0000-000000000048'::uuid$$,
  $$values ('20000000-0000-0000-0000-000000000045'::uuid)$$,
  'backfill excludes pending, failed, and incomplete legacy rows'
);

select is(
  private.backfill_call_transcriptions(),
  0::bigint,
  'backfill is idempotent'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000042', true);
select is(
  (select count(status) from public.call_transcriptions
   where call_id = '20000000-0000-0000-0000-000000000041'),
  1::bigint,
  'a workspace member can read the safe transcription state'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000043', true);
select is(
  (select count(status) from public.call_transcriptions
   where call_id = '20000000-0000-0000-0000-000000000041'),
  0::bigint,
  'a non-member cannot read another tenant transcription'
);

select throws_ok(
  $$select claim_token from public.call_transcriptions limit 1$$,
  '42501',
  'permission denied for table call_transcriptions',
  'authenticated users cannot select internal claim tokens'
);

select throws_ok(
  $$insert into public.call_transcriptions (call_id)
    values ('20000000-0000-0000-0000-000000000042')$$,
  '42501',
  'permission denied for table call_transcriptions',
  'authenticated users cannot insert transcription rows'
);

select throws_ok(
  $$update public.call_transcriptions set status = 'failed'
    where call_id = '20000000-0000-0000-0000-000000000041'$$,
  '42501',
  'permission denied for table call_transcriptions',
  'authenticated users cannot update transcription rows'
);

select throws_ok(
  $$delete from public.call_transcriptions
    where call_id = '20000000-0000-0000-0000-000000000041'$$,
  '42501',
  'permission denied for table call_transcriptions',
  'authenticated users cannot delete transcription rows'
);

set local role anon;
select throws_ok(
  $$select status from public.call_transcriptions limit 1$$,
  '42501',
  'permission denied for table call_transcriptions',
  'anonymous users cannot read transcription rows'
);

set local role authenticated;
select throws_ok(
  $$select * from public.claim_transcription_jobs(1)$$,
  '42501',
  'permission denied for function claim_transcription_jobs',
  'authenticated users cannot claim worker jobs'
);

set local role anon;
select throws_ok(
  $$select * from public.claim_transcription_jobs(1)$$,
  '42501',
  'permission denied for function claim_transcription_jobs',
  'anonymous users cannot claim worker jobs'
);

reset role;
delete from public.call_transcriptions;

create temporary table claim_result (
  call_id uuid,
  workspace_id uuid,
  storage_bucket text,
  storage_path text,
  content_type text,
  size_bytes bigint,
  claim_token uuid,
  attempt_count integer
) on commit drop;
create temporary table token_snapshot (claim_token uuid) on commit drop;
create temporary table time_snapshot (value timestamptz) on commit drop;
create temporary table action_result (call_id uuid, status text) on commit drop;
grant insert, select on table pg_temp.claim_result to service_role;
grant select on table pg_temp.token_snapshot to service_role;
grant insert, truncate on table pg_temp.action_result to service_role;

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values
  ('20000000-0000-0000-0000-000000000051', '10000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000041', 'claim-old.mp3', 'call-audio', '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000051/source.mp3', 'audio/mpeg', 1500, 'uploaded', now()),
  ('20000000-0000-0000-0000-000000000052', '10000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000041', 'claim-new.mp3', 'call-audio', '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000052/source.mp3', 'audio/mpeg', 1600, 'uploaded', now());

update public.call_transcriptions
set created_at = case call_id
  when '20000000-0000-0000-0000-000000000051' then now() - interval '2 hours'
  else now() - interval '1 hour'
end
where call_id in (
  '20000000-0000-0000-0000-000000000051',
  '20000000-0000-0000-0000-000000000052'
);

set local role service_role;
select throws_ok(
  $$select * from public.claim_transcription_jobs(0)$$,
  '22023',
  'Claim limit must be between 1 and 5',
  'claim limit rejects zero'
);
select throws_ok(
  $$select * from public.claim_transcription_jobs(6)$$,
  '22023',
  'Claim limit must be between 1 and 5',
  'claim limit rejects values above five'
);
insert into claim_result select * from public.claim_transcription_jobs(1);
reset role;

select is(
  (select call_id from claim_result),
  '20000000-0000-0000-0000-000000000051'::uuid,
  'claiming uses deterministic oldest-first ordering'
);

select ok(
  (select workspace_id = '10000000-0000-0000-0000-000000000041'
      and storage_bucket = 'call-audio'
      and storage_path = '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000051/source.mp3'
      and content_type = 'audio/mpeg'
      and size_bytes = 1500
      and claim_token is not null
      and attempt_count = 1
   from claim_result),
  'a claim returns only the exact worker input metadata and claim identity'
);

select ok(
  (select status = 'processing'
      and attempt_count = 1
      and claim_token is not null
      and lease_expires_at > pg_catalog.clock_timestamp()
      and lease_expires_at <= pg_catalog.clock_timestamp() + interval '15 minutes 5 seconds'
      and started_at is not null
   from public.call_transcriptions
   where call_id = '20000000-0000-0000-0000-000000000051'),
  'claiming starts processing, increments attempts, and creates a fixed lease'
);

delete from public.call_transcriptions
where call_id = '20000000-0000-0000-0000-000000000052';
truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_transcription_jobs(1);
reset role;
select is(
  (select count(*) from claim_result),
  0::bigint,
  'a second claim cannot take an actively leased row'
);

insert into token_snapshot
select claim_token from public.call_transcriptions
where call_id = '20000000-0000-0000-0000-000000000051';
update public.call_transcriptions
set lease_expires_at = now() - interval '1 minute'
where call_id = '20000000-0000-0000-0000-000000000051';
truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_transcription_jobs(1);
reset role;

select ok(
  (select call_id = '20000000-0000-0000-0000-000000000051'
      and attempt_count = 2
   from claim_result),
  'an expired processing lease can be reclaimed'
);

select ok(
  (select result.claim_token <> snapshot.claim_token
   from claim_result as result cross join token_snapshot as snapshot),
  'reclaiming replaces the old claim token'
);

set local role service_role;
select is(
  public.renew_transcription_lease(
    '20000000-0000-0000-0000-000000000051',
    (select claim_token from token_snapshot)
  ),
  false,
  'an old claim token cannot renew after reclaim'
);
reset role;

truncate time_snapshot;
insert into time_snapshot
select lease_expires_at from public.call_transcriptions
where call_id = '20000000-0000-0000-0000-000000000051';
set local role service_role;
select is(
  public.renew_transcription_lease(
    '20000000-0000-0000-0000-000000000051',
    (select claim_token from claim_result)
  ),
  true,
  'the current active claim token can renew its lease'
);
reset role;

select ok(
  (select transcription.lease_expires_at > snapshot.value
   from public.call_transcriptions as transcription
   cross join time_snapshot as snapshot
   where transcription.call_id = '20000000-0000-0000-0000-000000000051'),
  'lease renewal extends by the fixed server-side interval'
);

set local role service_role;
select is(
  public.renew_transcription_lease(
    '20000000-0000-0000-0000-000000000051',
    'ffffffff-ffff-4fff-8fff-ffffffffffff'
  ),
  false,
  'a wrong token cannot renew a lease'
);
reset role;

update public.call_transcriptions
set lease_expires_at = now() - interval '1 minute'
where call_id = '20000000-0000-0000-0000-000000000051';
set local role service_role;
select is(
  public.renew_transcription_lease(
    '20000000-0000-0000-0000-000000000051',
    (select claim_token from claim_result)
  ),
  false,
  'an expired lease cannot be revived by its old worker'
);
reset role;

truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_transcription_jobs(1);
reset role;
select is(
  (select attempt_count from claim_result),
  3,
  'a second reclaim creates the bounded third attempt'
);

set local role service_role;
select throws_ok(
  $$select * from public.complete_transcription_job(
    '20000000-0000-0000-0000-000000000051',
    (select claim_token from claim_result), '', 'en', '[]'::jsonb, 30
  )$$,
  '22023',
  'Transcript text must contain between 1 and 1000000 characters',
  'completion rejects an empty transcript'
);
select throws_ok(
  $$select * from public.complete_transcription_job(
    '20000000-0000-0000-0000-000000000051',
    (select claim_token from claim_result), 'Hello', 'en', '{}'::jsonb, 30
  )$$,
  '22023',
  'Segments must be a JSON array within the size limit',
  'completion rejects non-array segments'
);
select throws_ok(
  $$select * from public.complete_transcription_job(
    '20000000-0000-0000-0000-000000000051',
    (select claim_token from claim_result), 'Hello', 'not_a_language', '[]'::jsonb, 30
  )$$,
  '22023',
  'Language code is invalid',
  'completion rejects malformed language codes'
);
select throws_ok(
  $$select * from public.complete_transcription_job(
    '20000000-0000-0000-0000-000000000051',
    (select claim_token from claim_result), 'Hello', 'en', '[]'::jsonb, -1
  )$$,
  '22023',
  'Duration must be between 0 and 604800 seconds',
  'completion rejects negative duration'
);
truncate action_result;
insert into action_result
select * from public.complete_transcription_job(
  '20000000-0000-0000-0000-000000000051',
  (select claim_token from claim_result),
  ' Customer said hello. ',
  'EN',
  '[{"start":0,"end":1,"text":"Customer said hello."}]'::jsonb,
  31
);
reset role;

select results_eq(
  $$select call_id, status from action_result$$,
  $$values ('20000000-0000-0000-0000-000000000051'::uuid, 'completed'::text)$$,
  'the exact active token completes the transcription'
);

select ok(
  (select status = 'completed'
      and transcript_text = 'Customer said hello.'
      and language_code = 'en'
      and jsonb_typeof(segments) = 'array'
      and completed_at is not null
      and lease_expires_at is null
      and next_attempt_at is null
      and last_error_code is null
   from public.call_transcriptions
   where call_id = '20000000-0000-0000-0000-000000000051'),
  'completion stores bounded result data and clears active worker state'
);

select is(
  (select duration_seconds from public.calls
   where id = '20000000-0000-0000-0000-000000000051'),
  31,
  'completion updates call duration through the trusted path'
);

set local role service_role;
select is(
  public.renew_transcription_lease(
    '20000000-0000-0000-0000-000000000051',
    (select claim_token from claim_result)
  ),
  false,
  'a completed job cannot renew a lease'
);
reset role;

truncate action_result;
set local role service_role;
insert into action_result
select * from public.complete_transcription_job(
  '20000000-0000-0000-0000-000000000051',
  (select claim_token from claim_result),
  'Different retry payload',
  'fr',
  '[]'::jsonb,
  99
);
reset role;
select results_eq(
  $$select call_id, status from action_result$$,
  $$values ('20000000-0000-0000-0000-000000000051'::uuid, 'completed'::text)$$,
  'same-token completion retry is idempotently successful'
);

truncate action_result;
set local role service_role;
insert into action_result
select * from public.complete_transcription_job(
  '20000000-0000-0000-0000-000000000051',
  'ffffffff-ffff-4fff-8fff-ffffffffffff',
  'Overwrite attempt',
  'fr',
  '[]'::jsonb,
  99
);
reset role;
select is(
  (select count(*) from action_result),
  0::bigint,
  'a different token cannot overwrite a completed transcription'
);

select ok(
  (select transcript_text = 'Customer said hello.'
      and language_code = 'en'
      and duration_seconds = 31
   from public.call_transcriptions as transcription
   join public.calls as call on call.id = transcription.call_id
   where transcription.call_id = '20000000-0000-0000-0000-000000000051'),
  'idempotent and stale completion calls preserve the original result'
);

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values (
  '20000000-0000-0000-0000-000000000061',
  '10000000-0000-0000-0000-000000000041',
  '00000000-0000-0000-0000-000000000041',
  'retry.mp3',
  'call-audio',
  '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000061/source.mp3',
  'audio/mpeg',
  2000,
  'uploaded',
  now()
);

truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_transcription_jobs(1);
select throws_ok(
  $$select * from public.fail_transcription_job(
    '20000000-0000-0000-0000-000000000061',
    (select claim_token from claim_result), 'Unsafe message!', true
  )$$,
  '22023',
  'Error code is invalid',
  'failure rejects unsafe arbitrary error text'
);
truncate action_result;
insert into action_result
select * from public.fail_transcription_job(
  '20000000-0000-0000-0000-000000000061',
  (select claim_token from claim_result), 'decode_failed', true
);
reset role;

select results_eq(
  $$select call_id, status from action_result$$,
  $$values ('20000000-0000-0000-0000-000000000061'::uuid, 'queued'::text)$$,
  'retryable failure below the maximum returns the job to queued'
);

select ok(
  (select status = 'queued'
      and attempt_count = 1
      and lease_expires_at is null
      and next_attempt_at > now()
      and last_error_code = 'decode_failed'
      and failed_at is null
   from public.call_transcriptions
   where call_id = '20000000-0000-0000-0000-000000000061'),
  'retryable failure applies a fixed delay and preserves only a safe code'
);

truncate time_snapshot;
insert into time_snapshot
select next_attempt_at from public.call_transcriptions
where call_id = '20000000-0000-0000-0000-000000000061';
truncate action_result;
set local role service_role;
insert into action_result
select * from public.fail_transcription_job(
  '20000000-0000-0000-0000-000000000061',
  (select claim_token from claim_result), 'decode_failed', true
);
reset role;
select ok(
  (select result.status = 'queued' and transcription.next_attempt_at = snapshot.value
   from action_result as result
   join public.call_transcriptions as transcription on transcription.call_id = result.call_id
   cross join time_snapshot as snapshot),
  'repeating the same retryable failure is idempotent'
);

truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_transcription_jobs(1);
reset role;
select is(
  (select count(*) from claim_result),
  0::bigint,
  'the fixed retry delay prevents immediate reclaim'
);

update public.call_transcriptions
set next_attempt_at = now() - interval '1 minute'
where call_id = '20000000-0000-0000-0000-000000000061';
truncate token_snapshot;
insert into token_snapshot
select claim_token from public.call_transcriptions
where call_id = '20000000-0000-0000-0000-000000000061';
truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_transcription_jobs(1);
reset role;
select ok(
  (select attempt_count = 2
      and claim_token <> (select claim_token from token_snapshot)
   from claim_result),
  'a delayed retry receives a new token and increments the attempt count'
);

truncate action_result;
set local role service_role;
insert into action_result
select * from public.fail_transcription_job(
  '20000000-0000-0000-0000-000000000061',
  (select claim_token from token_snapshot), 'decode_failed', false
);
reset role;
select is(
  (select count(*) from action_result),
  0::bigint,
  'a stale token cannot fail the current worker job'
);

truncate action_result;
set local role service_role;
insert into action_result
select * from public.fail_transcription_job(
  '20000000-0000-0000-0000-000000000061',
  (select claim_token from claim_result), 'decode_failed', true
);
reset role;
select is(
  (select status from action_result),
  'queued',
  'a second retryable failure below the maximum queues another retry'
);

update public.call_transcriptions
set next_attempt_at = now() - interval '1 minute'
where call_id = '20000000-0000-0000-0000-000000000061';
truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_transcription_jobs(1);
reset role;
select is(
  (select attempt_count from claim_result),
  3,
  'the final allowed claim is attempt three'
);

truncate action_result;
set local role service_role;
insert into action_result
select * from public.fail_transcription_job(
  '20000000-0000-0000-0000-000000000061',
  (select claim_token from claim_result), 'decode_failed', true
);
reset role;
select ok(
  (select result.status = 'failed'
      and transcription.status = 'failed'
      and transcription.failed_at is not null
      and transcription.lease_expires_at is null
      and transcription.next_attempt_at is null
   from action_result as result
   join public.call_transcriptions as transcription on transcription.call_id = result.call_id),
  'retryable failure at the maximum attempt becomes terminal failed'
);

truncate action_result;
set local role service_role;
insert into action_result
select * from public.fail_transcription_job(
  '20000000-0000-0000-0000-000000000061',
  (select claim_token from claim_result), 'decode_failed', true
);
reset role;
select is(
  (select status from action_result),
  'failed',
  'repeating the terminal failure with the same token is idempotent'
);

truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_transcription_jobs(1);
reset role;
select is(
  (select count(*) from claim_result),
  0::bigint,
  'failed jobs are not automatically claimable'
);

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values (
  '20000000-0000-0000-0000-000000000062',
  '10000000-0000-0000-0000-000000000041',
  '00000000-0000-0000-0000-000000000041',
  'permanent.mp3',
  'call-audio',
  '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000062/source.mp3',
  'audio/mpeg',
  2100,
  'uploaded',
  now()
);
truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_transcription_jobs(1);
truncate action_result;
insert into action_result
select * from public.fail_transcription_job(
  '20000000-0000-0000-0000-000000000062',
  (select claim_token from claim_result), 'unsupported_audio', false
);
reset role;
select ok(
  (select result.status = 'failed'
      and transcription.status = 'failed'
      and transcription.attempt_count = 1
      and transcription.last_error_code = 'unsupported_audio'
   from action_result as result
   join public.call_transcriptions as transcription on transcription.call_id = result.call_id),
  'a permanent failure becomes failed without consuming extra attempts'
);

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values (
  '20000000-0000-0000-0000-000000000063',
  '10000000-0000-0000-0000-000000000041',
  '00000000-0000-0000-0000-000000000041',
  'expired-max.mp3',
  'call-audio',
  '10000000-0000-0000-0000-000000000041/20000000-0000-0000-0000-000000000063/source.mp3',
  'audio/mpeg',
  2200,
  'uploaded',
  now()
);
update public.call_transcriptions
set
  status = 'processing',
  attempt_count = 3,
  claim_token = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
  lease_expires_at = now() - interval '1 minute',
  started_at = now() - interval '1 hour'
where call_id = '20000000-0000-0000-0000-000000000063';
truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_transcription_jobs(1);
reset role;
select ok(
  (select status = 'failed'
      and last_error_code = 'worker_lease_expired'
      and failed_at is not null
      and lease_expires_at is null
   from public.call_transcriptions
   where call_id = '20000000-0000-0000-0000-000000000063')
  and (select count(*) from claim_result) = 0,
  'an expired maximum-attempt lease becomes failed instead of being reclaimed'
);

select * from finish();
rollback;
