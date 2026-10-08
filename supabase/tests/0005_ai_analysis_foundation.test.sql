begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(82);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'analysis-owner@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000052', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'analysis-member@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000053', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'analysis-outsider@example.com', '', now(), '{}', '{}', now(), now());

insert into public.workspaces (id, name, created_by) values
  ('10000000-0000-0000-0000-000000000051', 'Analysis workspace', '00000000-0000-0000-0000-000000000051'),
  ('10000000-0000-0000-0000-000000000052', 'Hidden analysis workspace', '00000000-0000-0000-0000-000000000053');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000051', 'owner'),
  ('10000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000052', 'member'),
  ('10000000-0000-0000-0000-000000000052', '00000000-0000-0000-0000-000000000053', 'owner');

select has_table('public', 'call_analyses', 'the analysis table exists');

select ok(
  (select class.relrowsecurity
   from pg_catalog.pg_class as class
   join pg_catalog.pg_namespace as namespace on namespace.oid = class.relnamespace
   where namespace.nspname = 'public' and class.relname = 'call_analyses'),
  'row level security is enabled on analysis rows'
);

select ok(
  has_column_privilege('authenticated', 'public.call_analyses', 'id', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'call_id', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'status', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'summary', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'sentiment', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'primary_intent', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'objections', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'action_items', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'topics', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'overall_score', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'started_at', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'completed_at', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'created_at', 'SELECT')
  and has_column_privilege('authenticated', 'public.call_analyses', 'updated_at', 'SELECT'),
  'authenticated users receive select permission only on safe analysis columns'
);

select ok(
  not has_column_privilege('authenticated', 'public.call_analyses', 'attempt_count', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_analyses', 'claim_token', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_analyses', 'lease_expires_at', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_analyses', 'next_attempt_at', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_analyses', 'last_error_code', 'SELECT')
  and not has_column_privilege('authenticated', 'public.call_analyses', 'failed_at', 'SELECT'),
  'worker claim, lease, retry, and error columns are not browser-readable'
);

select ok(
  not has_table_privilege('authenticated', 'public.call_analyses', 'INSERT')
  and not has_table_privilege('authenticated', 'public.call_analyses', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.call_analyses', 'DELETE'),
  'authenticated users have no analysis mutation privileges'
);

select ok(
  not has_table_privilege('service_role', 'public.call_analyses', 'SELECT')
  and not has_table_privilege('service_role', 'public.call_analyses', 'INSERT')
  and not has_table_privilege('service_role', 'public.call_analyses', 'UPDATE')
  and not has_table_privilege('service_role', 'public.call_analyses', 'DELETE'),
  'the worker role must use the narrow analysis RPC boundary'
);

select ok(
  has_function_privilege('service_role', 'public.claim_analysis_jobs(integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.renew_analysis_lease(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.complete_analysis_job(uuid,uuid,text,text,text,jsonb,jsonb,jsonb,integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.fail_analysis_job(uuid,uuid,text,boolean)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.claim_analysis_jobs(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.renew_analysis_lease(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.complete_analysis_job(uuid,uuid,text,text,text,jsonb,jsonb,jsonb,integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.fail_analysis_job(uuid,uuid,text,boolean)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.claim_analysis_jobs(integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.renew_analysis_lease(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.complete_analysis_job(uuid,uuid,text,text,text,jsonb,jsonb,jsonb,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.fail_analysis_job(uuid,uuid,text,boolean)', 'EXECUTE'),
  'only service_role can execute analysis worker RPCs'
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
         'claim_analysis_jobs',
         'renew_analysis_lease',
         'complete_analysis_job',
         'fail_analysis_job'
       )
     ) or (
       namespace.nspname = 'private'
       and procedure.proname in (
         'enqueue_call_analysis',
         'backfill_call_analyses'
       )
     )),
  'worker and enqueue functions are security definer with an empty search path'
);

select ok(
  (select pg_catalog.lower(procedure.prosrc) like '%for update of analysis skip locked%'
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where namespace.nspname = 'public'
     and procedure.proname = 'claim_analysis_jobs'),
  'claiming structurally uses skip-locked row locks'
);

select ok(
  (select pg_catalog.lower(procedure.prosrc) like '%clock_timestamp() + interval ''15 minutes''%'
      and pg_catalog.lower(procedure.prosrc) like '%lease_expires_at <= pg_catalog.clock_timestamp()%'
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where namespace.nspname = 'public'
     and procedure.proname = 'claim_analysis_jobs')
  and (select pg_catalog.lower(procedure.prosrc) like '%clock_timestamp() + interval ''15 minutes''%'
      and pg_catalog.lower(procedure.prosrc) like '%lease_expires_at > pg_catalog.clock_timestamp()%'
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where namespace.nspname = 'public'
     and procedure.proname = 'renew_analysis_lease')
  and (select pg_catalog.lower(procedure.prosrc) like '%lease_expires_at <= pg_catalog.clock_timestamp()%'
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where namespace.nspname = 'public'
     and procedure.proname = 'complete_analysis_job')
  and (select pg_catalog.lower(procedure.prosrc) like '%lease_expires_at <= pg_catalog.clock_timestamp()%'
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where namespace.nspname = 'public'
     and procedure.proname = 'fail_analysis_job'),
  'all lease authority decisions use wall-clock timestamps'
);

select ok(
  exists (
    select 1
    from pg_catalog.pg_trigger as trigger
    join pg_catalog.pg_class as class on class.oid = trigger.tgrelid
    join pg_catalog.pg_namespace as namespace on namespace.oid = class.relnamespace
    where namespace.nspname = 'public'
      and class.relname = 'call_transcriptions'
      and trigger.tgname = 'call_transcriptions_enqueue_analysis'
      and not trigger.tgisinternal
  ),
  'completed transcriptions have a dedicated analysis enqueue trigger'
);

select ok(
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'call_analyses'
      and column_name in ('raw_analysis', 'recommended_follow_up', 'intent', 'lead_score')
  ),
  'legacy raw and superseded analysis columns are absent'
);

select is(
  (select count(*) from pg_catalog.pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and cmd in ('SELECT', 'UPDATE', 'DELETE')),
  0::bigint,
  'analysis adds no browser Storage read, update, or delete policy'
);

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values
  ('25000000-0000-0000-0000-000000000501', '10000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000051', 'complete.mp3', 'call-audio', '10000000-0000-0000-0000-000000000051/25000000-0000-0000-0000-000000000501/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('25000000-0000-0000-0000-000000000502', '10000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000051', 'queued.mp3', 'call-audio', '10000000-0000-0000-0000-000000000051/25000000-0000-0000-0000-000000000502/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('25000000-0000-0000-0000-000000000503', '10000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000051', 'processing.mp3', 'call-audio', '10000000-0000-0000-0000-000000000051/25000000-0000-0000-0000-000000000503/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('25000000-0000-0000-0000-000000000504', '10000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000051', 'failed.mp3', 'call-audio', '10000000-0000-0000-0000-000000000051/25000000-0000-0000-0000-000000000504/source.mp3', 'audio/mpeg', 1000, 'uploaded', now());

update public.call_transcriptions
set
  status = 'completed',
  transcript_text = 'A completed customer conversation.',
  language_code = 'en',
  attempt_count = 1,
  claim_token = '50000000-0000-4000-8000-000000000501',
  started_at = now() - interval '1 minute',
  completed_at = now()
where call_id = '25000000-0000-0000-0000-000000000501';

update public.call_transcriptions
set
  status = 'processing',
  attempt_count = 1,
  claim_token = '50000000-0000-4000-8000-000000000503',
  lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes',
  started_at = now()
where call_id = '25000000-0000-0000-0000-000000000503';

update public.call_transcriptions
set
  status = 'failed',
  attempt_count = 1,
  claim_token = '50000000-0000-4000-8000-000000000504',
  last_error_code = 'decode_failed',
  started_at = now(),
  failed_at = now()
where call_id = '25000000-0000-0000-0000-000000000504';

select is(
  (select count(*) from public.call_analyses
   where call_id = '25000000-0000-0000-0000-000000000501'),
  1::bigint,
  'a valid completed transcription automatically queues one analysis'
);

update public.call_transcriptions set completed_at = completed_at
where call_id = '25000000-0000-0000-0000-000000000501';
select is(
  (select count(*) from public.call_analyses
   where call_id = '25000000-0000-0000-0000-000000000501'),
  1::bigint,
  'repeated completed-transcript updates cannot duplicate an analysis row'
);

select is(
  (select count(*) from public.call_analyses
   where call_id = '25000000-0000-0000-0000-000000000502'),
  0::bigint,
  'queued transcriptions are not enqueued for analysis'
);

select is(
  (select count(*) from public.call_analyses
   where call_id = '25000000-0000-0000-0000-000000000503'),
  0::bigint,
  'processing transcriptions are not enqueued for analysis'
);

select is(
  (select count(*) from public.call_analyses
   where call_id = '25000000-0000-0000-0000-000000000504'),
  0::bigint,
  'failed transcriptions are not enqueued for analysis'
);

select is(
  private.is_call_analysis_eligible('completed', '   ', now()),
  false,
  'a blank completed transcript is ineligible for analysis'
);

select is(
  private.is_call_analysis_eligible('completed', 'Valid text', null),
  false,
  'a completed transcript without completed_at is ineligible for analysis'
);

alter table public.call_transcriptions disable trigger call_transcriptions_enqueue_analysis;
insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values
  ('25000000-0000-0000-0000-000000000505', '10000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000051', 'backfill.mp3', 'call-audio', '10000000-0000-0000-0000-000000000051/25000000-0000-0000-0000-000000000505/source.mp3', 'audio/mpeg', 1000, 'uploaded', now()),
  ('25000000-0000-0000-0000-000000000506', '10000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000051', 'backfill-queued.mp3', 'call-audio', '10000000-0000-0000-0000-000000000051/25000000-0000-0000-0000-000000000506/source.mp3', 'audio/mpeg', 1000, 'uploaded', now());
update public.call_transcriptions
set
  status = 'completed',
  transcript_text = 'Existing completed transcript.',
  language_code = 'en',
  attempt_count = 1,
  claim_token = '50000000-0000-4000-8000-000000000505',
  started_at = now() - interval '1 minute',
  completed_at = now()
where call_id = '25000000-0000-0000-0000-000000000505';
alter table public.call_transcriptions enable trigger call_transcriptions_enqueue_analysis;

select is(
  private.backfill_call_analyses(),
  1::bigint,
  'backfill inserts only the valid completed transcription'
);

select results_eq(
  $$select call_id from public.call_analyses
    where call_id in (
      '25000000-0000-0000-0000-000000000505'::uuid,
      '25000000-0000-0000-0000-000000000506'::uuid
    ) order by call_id$$,
  $$values ('25000000-0000-0000-0000-000000000505'::uuid)$$,
  'backfill excludes incomplete transcription states'
);

select is(
  private.backfill_call_analyses(),
  0::bigint,
  'analysis backfill is idempotent'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000052', true);
select is(
  (select count(status) from public.call_analyses
   where call_id = '25000000-0000-0000-0000-000000000501'),
  1::bigint,
  'a workspace member can read safe analysis state'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000053', true);
select is(
  (select count(status) from public.call_analyses
   where call_id = '25000000-0000-0000-0000-000000000501'),
  0::bigint,
  'a non-member cannot read another tenant analysis'
);

select throws_ok(
  $$select claim_token from public.call_analyses limit 1$$,
  '42501',
  'permission denied for table call_analyses',
  'authenticated users cannot select internal claim tokens'
);

select throws_ok(
  $$select lease_expires_at, attempt_count, next_attempt_at from public.call_analyses limit 1$$,
  '42501',
  'permission denied for table call_analyses',
  'authenticated users cannot select lease, attempt, or retry internals'
);

select throws_ok(
  $$select last_error_code, failed_at from public.call_analyses limit 1$$,
  '42501',
  'permission denied for table call_analyses',
  'authenticated users cannot select worker error internals'
);

select throws_ok(
  $$insert into public.call_analyses (call_id)
    values ('25000000-0000-0000-0000-000000000502')$$,
  '42501',
  'permission denied for table call_analyses',
  'authenticated users cannot insert analysis rows'
);

select throws_ok(
  $$update public.call_analyses set status = 'failed'
    where call_id = '25000000-0000-0000-0000-000000000501'$$,
  '42501',
  'permission denied for table call_analyses',
  'authenticated users cannot update analysis rows'
);

select throws_ok(
  $$delete from public.call_analyses
    where call_id = '25000000-0000-0000-0000-000000000501'$$,
  '42501',
  'permission denied for table call_analyses',
  'authenticated users cannot delete analysis rows'
);

set local role anon;
select throws_ok(
  $$select status from public.call_analyses limit 1$$,
  '42501',
  'permission denied for table call_analyses',
  'anonymous users cannot read analysis rows'
);

set local role authenticated;
select throws_ok(
  $$select * from public.claim_analysis_jobs(1)$$,
  '42501',
  'permission denied for function claim_analysis_jobs',
  'authenticated users cannot claim analysis jobs'
);

set local role anon;
select throws_ok(
  $$select * from public.claim_analysis_jobs(1)$$,
  '42501',
  'permission denied for function claim_analysis_jobs',
  'anonymous users cannot claim analysis jobs'
);

reset role;
delete from public.call_analyses;

create temporary table claim_result (
  call_id uuid,
  workspace_id uuid,
  transcript_text text,
  language_code text,
  claim_token uuid,
  attempt_count integer
) on commit drop;
create temporary table token_snapshot (claim_token uuid) on commit drop;
create temporary table time_snapshot (value timestamptz) on commit drop;
create temporary table action_result (call_id uuid, status text) on commit drop;
grant insert, select on table pg_temp.claim_result to service_role;
grant select on table pg_temp.token_snapshot to service_role;
grant insert, select, truncate on table pg_temp.action_result to service_role;

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values
  ('25000000-0000-0000-0000-000000000510', '10000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000051', 'ineligible.mp3', 'call-audio', '10000000-0000-0000-0000-000000000051/25000000-0000-0000-0000-000000000510/source.mp3', 'audio/mpeg', 1500, 'uploaded', now()),
  ('25000000-0000-0000-0000-000000000511', '10000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000051', 'claim-old.mp3', 'call-audio', '10000000-0000-0000-0000-000000000051/25000000-0000-0000-0000-000000000511/source.mp3', 'audio/mpeg', 1500, 'uploaded', now()),
  ('25000000-0000-0000-0000-000000000512', '10000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000051', 'claim-new.mp3', 'call-audio', '10000000-0000-0000-0000-000000000051/25000000-0000-0000-0000-000000000512/source.mp3', 'audio/mpeg', 1600, 'uploaded', now());

update public.call_transcriptions
set
  status = 'completed',
  transcript_text = 'Transcript for analysis claim.',
  language_code = 'en',
  attempt_count = 1,
  claim_token = pg_catalog.gen_random_uuid(),
  started_at = now(),
  completed_at = now()
where call_id in (
  '25000000-0000-0000-0000-000000000510',
  '25000000-0000-0000-0000-000000000511',
  '25000000-0000-0000-0000-000000000512'
);

update public.call_transcriptions
set
  status = 'queued',
  transcript_text = null,
  language_code = null,
  segments = '[]'::jsonb,
  attempt_count = 0,
  claim_token = null,
  started_at = null,
  completed_at = null
where call_id = '25000000-0000-0000-0000-000000000510';

update public.call_analyses
set created_at = case call_id
  when '25000000-0000-0000-0000-000000000510' then now() - interval '3 hours'
  when '25000000-0000-0000-0000-000000000511' then now() - interval '2 hours'
  else now() - interval '1 hour'
end
where call_id in (
  '25000000-0000-0000-0000-000000000510',
  '25000000-0000-0000-0000-000000000511',
  '25000000-0000-0000-0000-000000000512'
);

set local role service_role;
select throws_ok(
  $$select * from public.claim_analysis_jobs(0)$$,
  '22023',
  'Claim limit must be between 1 and 5',
  'claim limit rejects zero'
);
select throws_ok(
  $$select * from public.claim_analysis_jobs(6)$$,
  '22023',
  'Claim limit must be between 1 and 5',
  'claim limit rejects values above five'
);
insert into claim_result select * from public.claim_analysis_jobs(1);
reset role;

select is(
  (select call_id from claim_result),
  '25000000-0000-0000-0000-000000000511'::uuid,
  'claiming skips ineligible rows and uses deterministic oldest-first ordering'
);

select ok(
  (select workspace_id = '10000000-0000-0000-0000-000000000051'
      and transcript_text = 'Transcript for analysis claim.'
      and language_code = 'en'
      and claim_token is not null
      and attempt_count = 1
   from claim_result),
  'a claim returns only required transcript, tenant, and claim data'
);

select ok(
  (select status = 'processing'
      and attempt_count = 1
      and claim_token is not null
      and lease_expires_at > pg_catalog.clock_timestamp()
      and lease_expires_at <= pg_catalog.clock_timestamp() + interval '15 minutes 5 seconds'
      and started_at is not null
   from public.call_analyses
   where call_id = '25000000-0000-0000-0000-000000000511'),
  'claiming starts processing, increments attempts, and creates a fixed lease'
);

delete from public.call_analyses
where call_id in (
  '25000000-0000-0000-0000-000000000510',
  '25000000-0000-0000-0000-000000000512'
);
truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_analysis_jobs(1);
reset role;
select is(
  (select count(*) from claim_result),
  0::bigint,
  'a second claim cannot take an actively leased row'
);

insert into token_snapshot
select claim_token from public.call_analyses
where call_id = '25000000-0000-0000-0000-000000000511';
update public.call_analyses
set lease_expires_at = now() - interval '1 minute'
where call_id = '25000000-0000-0000-0000-000000000511';
truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_analysis_jobs(1);
reset role;

select ok(
  (select call_id = '25000000-0000-0000-0000-000000000511'
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
  public.renew_analysis_lease(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from token_snapshot)
  ),
  false,
  'an old claim token cannot renew after reclaim'
);
reset role;

insert into time_snapshot
select lease_expires_at from public.call_analyses
where call_id = '25000000-0000-0000-0000-000000000511';
set local role service_role;
select is(
  public.renew_analysis_lease(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result)
  ),
  true,
  'the current active claim token can renew its lease'
);
reset role;

select ok(
  (select analysis.lease_expires_at > snapshot.value
   from public.call_analyses as analysis
   cross join time_snapshot as snapshot
   where analysis.call_id = '25000000-0000-0000-0000-000000000511'),
  'lease renewal advances from the current wall clock without stacking'
);

set local role service_role;
select is(
  public.renew_analysis_lease(
    '25000000-0000-0000-0000-000000000511',
    'ffffffff-ffff-4fff-8fff-ffffffffffff'
  ),
  false,
  'a wrong token cannot renew a lease'
);
reset role;

update public.call_analyses
set lease_expires_at = now() - interval '1 minute'
where call_id = '25000000-0000-0000-0000-000000000511';
set local role service_role;
select is(
  public.renew_analysis_lease(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result)
  ),
  false,
  'an expired lease cannot be revived by its old worker'
);
reset role;

truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_analysis_jobs(1);
reset role;
select is(
  (select attempt_count from claim_result),
  3,
  'a second reclaim creates the bounded third attempt'
);

truncate action_result;
set local role service_role;
insert into action_result
select * from public.complete_analysis_job(
  '25000000-0000-0000-0000-000000000511',
  (select claim_token from token_snapshot),
  'Stale result', 'neutral', 'No authority', '[]'::jsonb,
  '[]'::jsonb, '[]'::jsonb, null
);
reset role;
select is(
  (select count(*) from action_result),
  0::bigint,
  'a reclaimed stale token cannot complete the current analysis lease'
);

set local role service_role;
select throws_ok(
  $$select * from public.complete_analysis_job(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result),
    '', 'positive', 'Retention', '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, 80
  )$$,
  '22023',
  'Summary must contain between 1 and 10000 characters',
  'completion rejects a blank summary'
);
select throws_ok(
  $$select * from public.complete_analysis_job(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result),
    repeat('x', 10001), 'positive', 'Retention', '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, 80
  )$$,
  '22023',
  'Summary must contain between 1 and 10000 characters',
  'completion rejects an oversized summary'
);
select throws_ok(
  $$select * from public.complete_analysis_job(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result),
    'Summary', 'uncertain', 'Retention', '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, 80
  )$$,
  '22023',
  'Sentiment is invalid',
  'completion rejects an invalid sentiment'
);
select throws_ok(
  $$select * from public.complete_analysis_job(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result),
    'Summary', 'positive', '', '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, 80
  )$$,
  '22023',
  'Primary intent must contain between 1 and 500 characters',
  'completion rejects a blank primary intent'
);
select throws_ok(
  $$select * from public.complete_analysis_job(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result),
    'Summary', 'positive', repeat('x', 501), '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, 80
  )$$,
  '22023',
  'Primary intent must contain between 1 and 500 characters',
  'completion rejects an oversized primary intent'
);
select throws_ok(
  $$select * from public.complete_analysis_job(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result),
    'Summary', 'positive', 'Retention', '{}'::jsonb, '[]'::jsonb, '[]'::jsonb, 80
  )$$,
  '22023',
  'Objections must be a bounded JSON string array',
  'objections must be an array'
);
select throws_ok(
  $$select * from public.complete_analysis_job(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result),
    'Summary', 'positive', 'Retention', '[1]'::jsonb, '[]'::jsonb, '[]'::jsonb, 80
  )$$,
  '22023',
  'Objections must be a bounded JSON string array',
  'objections must contain only strings'
);
select throws_ok(
  $$select * from public.complete_analysis_job(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result),
    'Summary', 'positive', 'Retention',
    to_jsonb(pg_catalog.array_fill('x'::text, array[26])),
    '[]'::jsonb, '[]'::jsonb, 80
  )$$,
  '22023',
  'Objections must be a bounded JSON string array',
  'objections reject too many elements'
);
select throws_ok(
  $$select * from public.complete_analysis_job(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result),
    'Summary', 'positive', 'Retention',
    to_jsonb(pg_catalog.array_fill(repeat('x', 1000), array[9])),
    '[]'::jsonb, '[]'::jsonb, 80
  )$$,
  '22023',
  'Objections must be a bounded JSON string array',
  'objections reject an oversized serialized result'
);
select throws_ok(
  $$select * from public.complete_analysis_job(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result),
    'Summary', 'positive', 'Retention', '[]'::jsonb, '[true]'::jsonb, '[]'::jsonb, 80
  )$$,
  '22023',
  'Action items must be a bounded JSON string array',
  'action items must contain only strings'
);
select throws_ok(
  $$select * from public.complete_analysis_job(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result),
    'Summary', 'positive', 'Retention', '[]'::jsonb, '[]'::jsonb, '[{}]'::jsonb, 80
  )$$,
  '22023',
  'Topics must be a bounded JSON string array',
  'topics must contain only strings'
);
select throws_ok(
  $$select * from public.complete_analysis_job(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result),
    'Summary', 'positive', 'Retention', '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, 101
  )$$,
  '22023',
  'Overall score must be between 0 and 100',
  'completion rejects a score above one hundred'
);
truncate action_result;
insert into action_result
select * from public.complete_analysis_job(
  '25000000-0000-0000-0000-000000000511',
  (select claim_token from claim_result),
  ' Concise customer summary. ',
  'POSITIVE',
  ' Retain the account ',
  '["Price concern"]'::jsonb,
  '["Send revised proposal"]'::jsonb,
  '["renewal","pricing"]'::jsonb,
  87
);
reset role;

select results_eq(
  $$select call_id, status from action_result$$,
  $$values ('25000000-0000-0000-0000-000000000511'::uuid, 'completed'::text)$$,
  'the exact active token completes the analysis'
);

select ok(
  (select status = 'completed'
      and summary = 'Concise customer summary.'
      and sentiment = 'positive'
      and primary_intent = 'Retain the account'
      and objections = '["Price concern"]'::jsonb
      and action_items = '["Send revised proposal"]'::jsonb
      and topics = '["renewal","pricing"]'::jsonb
      and overall_score = 87
      and completed_at is not null
      and lease_expires_at is null
      and next_attempt_at is null
      and last_error_code is null
   from public.call_analyses
   where call_id = '25000000-0000-0000-0000-000000000511'),
  'completion stores the bounded structured result and clears active worker state'
);

set local role service_role;
select is(
  public.renew_analysis_lease(
    '25000000-0000-0000-0000-000000000511',
    (select claim_token from claim_result)
  ),
  false,
  'a completed analysis cannot renew a lease'
);
reset role;

truncate action_result;
set local role service_role;
insert into action_result
select * from public.complete_analysis_job(
  '25000000-0000-0000-0000-000000000511',
  (select claim_token from claim_result),
  'Different retry payload', 'negative', 'Overwrite', '[]'::jsonb,
  '[]'::jsonb, '[]'::jsonb, 1
);
reset role;
select results_eq(
  $$select call_id, status from action_result$$,
  $$values ('25000000-0000-0000-0000-000000000511'::uuid, 'completed'::text)$$,
  'same-token completion retry is idempotently successful'
);

truncate action_result;
set local role service_role;
insert into action_result
select * from public.complete_analysis_job(
  '25000000-0000-0000-0000-000000000511',
  'ffffffff-ffff-4fff-8fff-ffffffffffff',
  'Overwrite attempt', 'negative', 'Overwrite', '[]'::jsonb,
  '[]'::jsonb, '[]'::jsonb, 1
);
reset role;
select is(
  (select count(*) from action_result),
  0::bigint,
  'a different token cannot overwrite a completed analysis'
);

select ok(
  (select summary = 'Concise customer summary.'
      and sentiment = 'positive'
      and overall_score = 87
   from public.call_analyses
   where call_id = '25000000-0000-0000-0000-000000000511'),
  'idempotent and stale completion calls preserve the original analysis'
);

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values (
  '25000000-0000-0000-0000-000000000521',
  '10000000-0000-0000-0000-000000000051',
  '00000000-0000-0000-0000-000000000051',
  'retry.mp3',
  'call-audio',
  '10000000-0000-0000-0000-000000000051/25000000-0000-0000-0000-000000000521/source.mp3',
  'audio/mpeg', 2000, 'uploaded', now()
);
update public.call_transcriptions
set
  status = 'completed', transcript_text = 'Retry analysis transcript.', language_code = 'en',
  attempt_count = 1, claim_token = pg_catalog.gen_random_uuid(),
  started_at = now(), completed_at = now()
where call_id = '25000000-0000-0000-0000-000000000521';

truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_analysis_jobs(1);
select throws_ok(
  $$select * from public.fail_analysis_job(
    '25000000-0000-0000-0000-000000000521',
    (select claim_token from claim_result), 'Unsafe message!', true
  )$$,
  '22023',
  'Error code is invalid',
  'failure rejects unsafe arbitrary error text'
);
truncate action_result;
insert into action_result
select * from public.fail_analysis_job(
  '25000000-0000-0000-0000-000000000521',
  (select claim_token from claim_result), 'model_output_invalid', true
);
reset role;

select results_eq(
  $$select call_id, status from action_result$$,
  $$values ('25000000-0000-0000-0000-000000000521'::uuid, 'queued'::text)$$,
  'retryable failure below the maximum returns the analysis to queued'
);

select ok(
  (select status = 'queued'
      and attempt_count = 1
      and lease_expires_at is null
      and next_attempt_at > now()
      and last_error_code = 'model_output_invalid'
      and failed_at is null
   from public.call_analyses
   where call_id = '25000000-0000-0000-0000-000000000521'),
  'retryable failure applies a fixed delay and stores only a safe code'
);

truncate time_snapshot;
insert into time_snapshot
select next_attempt_at from public.call_analyses
where call_id = '25000000-0000-0000-0000-000000000521';
truncate action_result;
set local role service_role;
insert into action_result
select * from public.fail_analysis_job(
  '25000000-0000-0000-0000-000000000521',
  (select claim_token from claim_result), 'model_output_invalid', true
);
reset role;
select ok(
  (select result.status = 'queued' and analysis.next_attempt_at = snapshot.value
   from action_result as result
   join public.call_analyses as analysis on analysis.call_id = result.call_id
   cross join time_snapshot as snapshot),
  'repeating the same retryable failure is idempotent'
);

truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_analysis_jobs(1);
reset role;
select is(
  (select count(*) from claim_result),
  0::bigint,
  'the fixed retry delay prevents immediate reclaim'
);

update public.call_analyses
set next_attempt_at = now() - interval '1 minute'
where call_id = '25000000-0000-0000-0000-000000000521';
truncate token_snapshot;
insert into token_snapshot
select claim_token from public.call_analyses
where call_id = '25000000-0000-0000-0000-000000000521';
truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_analysis_jobs(1);
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
select * from public.fail_analysis_job(
  '25000000-0000-0000-0000-000000000521',
  (select claim_token from token_snapshot), 'model_output_invalid', false
);
reset role;
select is(
  (select count(*) from action_result),
  0::bigint,
  'a stale token cannot fail the current analysis lease'
);

truncate action_result;
set local role service_role;
insert into action_result
select * from public.fail_analysis_job(
  '25000000-0000-0000-0000-000000000521',
  (select claim_token from claim_result), 'model_output_invalid', true
);
reset role;
select is(
  (select status from action_result),
  'queued',
  'a second retryable failure below the maximum queues another retry'
);

update public.call_analyses
set next_attempt_at = now() - interval '1 minute'
where call_id = '25000000-0000-0000-0000-000000000521';
truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_analysis_jobs(1);
reset role;
select is(
  (select attempt_count from claim_result),
  3,
  'the final allowed analysis claim is attempt three'
);

truncate action_result;
set local role service_role;
insert into action_result
select * from public.fail_analysis_job(
  '25000000-0000-0000-0000-000000000521',
  (select claim_token from claim_result), 'model_output_invalid', true
);
reset role;
select ok(
  (select result.status = 'failed'
      and analysis.status = 'failed'
      and analysis.failed_at is not null
      and analysis.lease_expires_at is null
      and analysis.next_attempt_at is null
   from action_result as result
   join public.call_analyses as analysis on analysis.call_id = result.call_id),
  'retryable failure at the maximum attempt becomes terminal failed'
);

set local role service_role;
select is(
  public.renew_analysis_lease(
    '25000000-0000-0000-0000-000000000521',
    (select claim_token from claim_result)
  ),
  false,
  'a failed analysis cannot renew a lease'
);
reset role;

truncate action_result;
set local role service_role;
insert into action_result
select * from public.fail_analysis_job(
  '25000000-0000-0000-0000-000000000521',
  (select claim_token from claim_result), 'model_output_invalid', true
);
reset role;
select is(
  (select status from action_result),
  'failed',
  'repeating terminal failure with the same token is idempotent'
);

truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_analysis_jobs(1);
reset role;
select is(
  (select count(*) from claim_result),
  0::bigint,
  'failed analysis jobs are not automatically claimable'
);

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values (
  '25000000-0000-0000-0000-000000000522',
  '10000000-0000-0000-0000-000000000051',
  '00000000-0000-0000-0000-000000000051',
  'permanent.mp3', 'call-audio',
  '10000000-0000-0000-0000-000000000051/25000000-0000-0000-0000-000000000522/source.mp3',
  'audio/mpeg', 2100, 'uploaded', now()
);
update public.call_transcriptions
set
  status = 'completed', transcript_text = 'Permanent failure transcript.', language_code = 'en',
  attempt_count = 1, claim_token = pg_catalog.gen_random_uuid(),
  started_at = now(), completed_at = now()
where call_id = '25000000-0000-0000-0000-000000000522';
truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_analysis_jobs(1);
truncate action_result;
insert into action_result
select * from public.fail_analysis_job(
  '25000000-0000-0000-0000-000000000522',
  (select claim_token from claim_result), 'unsupported_language', false
);
reset role;
select ok(
  (select result.status = 'failed'
      and analysis.status = 'failed'
      and analysis.attempt_count = 1
      and analysis.last_error_code = 'unsupported_language'
   from action_result as result
   join public.call_analyses as analysis on analysis.call_id = result.call_id),
  'a permanent failure becomes failed without consuming extra attempts'
);

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at
) values (
  '25000000-0000-0000-0000-000000000523',
  '10000000-0000-0000-0000-000000000051',
  '00000000-0000-0000-0000-000000000051',
  'expired-max.mp3', 'call-audio',
  '10000000-0000-0000-0000-000000000051/25000000-0000-0000-0000-000000000523/source.mp3',
  'audio/mpeg', 2200, 'uploaded', now()
);
update public.call_transcriptions
set
  status = 'completed', transcript_text = 'Expired maximum transcript.', language_code = 'en',
  attempt_count = 1, claim_token = pg_catalog.gen_random_uuid(),
  started_at = now(), completed_at = now()
where call_id = '25000000-0000-0000-0000-000000000523';
update public.call_analyses
set
  status = 'processing',
  attempt_count = 3,
  claim_token = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
  lease_expires_at = now() - interval '1 minute',
  started_at = now() - interval '1 hour'
where call_id = '25000000-0000-0000-0000-000000000523';
truncate claim_result;
set local role service_role;
insert into claim_result select * from public.claim_analysis_jobs(1);
reset role;
select ok(
  (select status = 'failed'
      and last_error_code = 'worker_lease_expired'
      and failed_at is not null
      and lease_expires_at is null
   from public.call_analyses
   where call_id = '25000000-0000-0000-0000-000000000523')
  and (select count(*) from claim_result) = 0,
  'an expired maximum-attempt lease becomes failed instead of being reclaimed'
);

select * from finish();
rollback;
