begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(26);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'reconcile-owner@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'reconcile-member@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000023', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'reconcile-outsider@example.com', '', now(), '{}', '{}', now(), now());

insert into public.workspaces (id, name, created_by) values
  ('10000000-0000-0000-0000-000000000021', 'Reconciliation workspace', '00000000-0000-0000-0000-000000000021'),
  ('10000000-0000-0000-0000-000000000022', 'Hidden reconciliation workspace', '00000000-0000-0000-0000-000000000023');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000021', 'owner'),
  ('10000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000022', 'member'),
  ('10000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000023', 'owner');

insert into storage.buckets (id, name, public)
values ('other-private', 'other-private', false);

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, upload_completed_at, created_at
) values
  ('20000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000021', 'fresh.mp3', 'call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000021/source.mp3', 'audio/mpeg', 1000, 'pending_upload', null, now() - interval '3 hours'),
  ('20000000-0000-0000-0000-000000000022', '10000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000022', 'member.mp3', 'call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000022/source.mp3', 'audio/mpeg', 1000, 'pending_upload', null, now() - interval '5 hours'),
  ('20000000-0000-0000-0000-000000000023', '10000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000023', 'cross-tenant.mp3', 'call-audio', '10000000-0000-0000-0000-000000000022/20000000-0000-0000-0000-000000000023/source.mp3', 'audio/mpeg', 1000, 'pending_upload', null, now() - interval '5 hours'),
  ('20000000-0000-0000-0000-000000000024', '10000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000021', 'missing.mp3', 'call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000024/source.mp3', 'audio/mpeg', 1000, 'pending_upload', null, now() - interval '5 hours'),
  ('20000000-0000-0000-0000-000000000025', '10000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000021', 'valid.mp3', 'call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000025/source.mp3', 'audio/mpeg', 1000, 'pending_upload', null, now() - interval '5 hours'),
  ('20000000-0000-0000-0000-000000000026', '10000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000021', 'mime.mp3', 'call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000026/source.mp3', 'audio/mpeg', 1000, 'pending_upload', null, now() - interval '5 hours'),
  ('20000000-0000-0000-0000-000000000027', '10000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000021', 'size.mp3', 'call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000027/source.mp3', 'audio/mpeg', 1000, 'pending_upload', null, now() - interval '5 hours'),
  ('20000000-0000-0000-0000-000000000028', '10000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000021', 'wrong-location.mp3', 'call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000028/source.mp3', 'audio/mpeg', 1000, 'pending_upload', null, now() - interval '5 hours'),
  ('20000000-0000-0000-0000-000000000029', '10000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000021', 'already-uploaded.mp3', 'call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000029/source.mp3', 'audio/mpeg', 1000, 'uploaded', now() - interval '5 hours', now() - interval '5 hours'),
  ('20000000-0000-0000-0000-000000000030', '10000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000021', 'abort-empty.mp3', 'call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000030/source.mp3', 'audio/mpeg', 1000, 'pending_upload', null, now()),
  ('20000000-0000-0000-0000-000000000031', '10000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000021', 'abort-stored.mp3', 'call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000031/source.mp3', 'audio/mpeg', 1000, 'pending_upload', null, now());

insert into storage.objects (bucket_id, name, metadata) values
  ('call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000025/source.mp3', '{"size":1000,"mimetype":"audio/mpeg"}'),
  ('call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000026/source.mp3', '{"size":1000,"mimetype":"audio/wav"}'),
  ('call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000027/source.mp3', '{"size":999,"mimetype":"audio/mpeg"}'),
  ('other-private', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000028/source.mp3', '{"size":1000,"mimetype":"audio/mpeg"}'),
  ('call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000028/wrong.mp3', '{"size":1000,"mimetype":"audio/mpeg"}'),
  ('call-audio', '10000000-0000-0000-0000-000000000021/20000000-0000-0000-0000-000000000031/source.mp3', '{"size":1000,"mimetype":"audio/mpeg"}');

create temporary table reconciliation_result (
  call_id uuid,
  outcome text
) on commit drop;

grant insert, select on table pg_temp.reconciliation_result to authenticated;

set local role anon;
select throws_ok(
  $$select * from public.reconcile_stale_call_uploads(
    '10000000-0000-0000-0000-000000000021', 20
  )$$,
  '42501',
  'permission denied for function reconcile_stale_call_uploads',
  'anonymous users cannot reconcile uploads'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);
select is_empty(
  $$select * from public.reconcile_stale_call_uploads(
    '10000000-0000-0000-0000-000000000022', 20
  )$$,
  'a non-member cannot reconcile another workspace'
);

reset role;
select ok(
  (select procedure.prosecdef
      and pg_catalog.array_to_string(procedure.proconfig, ',') = 'search_path=""'
      and pg_catalog.lower(procedure.prosrc) like '%for update of call skip locked%'
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace
     on namespace.oid = procedure.pronamespace
   where namespace.nspname = 'public'
     and procedure.proname = 'reconcile_stale_call_uploads'),
  'reconciliation uses a hardened empty search path and skip-locked row locks'
);

select ok(
  not has_function_privilege('anon', 'public.reconcile_stale_call_uploads(uuid,integer)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.reconcile_stale_call_uploads(uuid,integer)', 'EXECUTE'),
  'only authenticated callers receive reconciliation execute permission'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);
select is(
  public.abort_call_upload(
    '10000000-0000-0000-0000-000000000021',
    '20000000-0000-0000-0000-000000000030'
  ),
  true,
  'abort removes the callers pending row when no exact Storage object exists'
);

reset role;
select is(
  (select count(*) from public.calls
   where id = '20000000-0000-0000-0000-000000000030'),
  0::bigint,
  'a successful abort removes the pending call row'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);
select is(
  public.abort_call_upload(
    '10000000-0000-0000-0000-000000000021',
    '20000000-0000-0000-0000-000000000030'
  ),
  false,
  'repeating an already completed abort is safe and idempotent'
);

select is(
  public.abort_call_upload(
    '10000000-0000-0000-0000-000000000021',
    '20000000-0000-0000-0000-000000000031'
  ),
  false,
  'abort refuses deletion when the exact expected Storage object exists'
);

reset role;
select is(
  (select status from public.calls
   where id = '20000000-0000-0000-0000-000000000031'),
  'pending_upload',
  'a pending row with an exact Storage object remains available for finalization'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);
select is(
  public.abort_call_upload(
    '10000000-0000-0000-0000-000000000021',
    '20000000-0000-0000-0000-000000000022'
  ),
  false,
  'a workspace member cannot abort another users pending upload'
);

select is(
  public.abort_call_upload(
    '10000000-0000-0000-0000-000000000022',
    '20000000-0000-0000-0000-000000000023'
  ),
  false,
  'a caller cannot abort a pending upload in another workspace'
);

insert into reconciliation_result
select * from public.reconcile_stale_call_uploads(
  '10000000-0000-0000-0000-000000000021', 20
);

reset role;
select results_eq(
  $$select call_id, outcome from reconciliation_result order by call_id$$,
  $$values
    ('20000000-0000-0000-0000-000000000024'::uuid, 'deleted'::text),
    ('20000000-0000-0000-0000-000000000025'::uuid, 'uploaded'::text),
    ('20000000-0000-0000-0000-000000000026'::uuid, 'failed'::text),
    ('20000000-0000-0000-0000-000000000027'::uuid, 'failed'::text),
    ('20000000-0000-0000-0000-000000000028'::uuid, 'deleted'::text)$$,
  'stale uploads receive deterministic outcomes from exact object metadata'
);

select is(
  (select status from public.calls where id = '20000000-0000-0000-0000-000000000023'),
  'pending_upload',
  'a cross-workspace call cannot be reconciled'
);

select is(
  (select status from public.calls where id = '20000000-0000-0000-0000-000000000022'),
  'pending_upload',
  'the caller cannot reconcile another users pending upload'
);

select is(
  (select status from public.calls where id = '20000000-0000-0000-0000-000000000021'),
  'pending_upload',
  'a pending upload younger than four hours is not reconciled'
);

select is(
  (select count(*) from public.calls where id = '20000000-0000-0000-0000-000000000024'),
  0::bigint,
  'a stale pending upload with no exact object is removed'
);

select ok(
  (select status = 'uploaded' and upload_completed_at is not null
   from public.calls where id = '20000000-0000-0000-0000-000000000025'),
  'an exact valid object becomes uploaded with a completion timestamp'
);

select is(
  (select status from public.calls where id = '20000000-0000-0000-0000-000000000026'),
  'failed',
  'a MIME mismatch is never marked uploaded'
);

select is(
  (select status from public.calls where id = '20000000-0000-0000-0000-000000000027'),
  'failed',
  'a size mismatch is never marked uploaded'
);

select is(
  (select count(*) from public.calls where id = '20000000-0000-0000-0000-000000000028'),
  0::bigint,
  'objects in the wrong bucket or path never make a call uploaded'
);

select is(
  (select status from public.calls where id = '20000000-0000-0000-0000-000000000029'),
  'uploaded',
  'an already uploaded call remains uploaded'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000021', true);
select is_empty(
  $$select * from public.reconcile_stale_call_uploads(
    '10000000-0000-0000-0000-000000000021', 20
  )$$,
  'repeated reconciliation is safe and idempotent'
);

select throws_ok(
  $$select * from public.reconcile_stale_call_uploads(
    '10000000-0000-0000-0000-000000000021', 0
  )$$,
  '22023',
  'Reconciliation limit must be between 1 and 20',
  'callers cannot request an invalid reconciliation batch size'
);

select throws_ok(
  $$select * from public.reconcile_stale_call_uploads(
    '10000000-0000-0000-0000-000000000021', 21
  )$$,
  '22023',
  'Reconciliation limit must be between 1 and 20',
  'callers cannot expand reconciliation beyond the fixed maximum batch size'
);

reset role;
select is(
  (select count(*) from storage.objects
   where bucket_id = 'other-private'
      or name like '%/20000000-0000-0000-0000-000000000028/%'),
  2::bigint,
  'reconciliation does not delete orphaned Storage objects'
);

select ok(
  not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname like 'call_audio_%' and cmd = 'UPDATE'
  )
  and (select count(*) from pg_policies
       where schemaname = 'storage' and tablename = 'objects'
         and policyname like 'call_audio_%' and cmd = 'SELECT') = 1
  and (select count(*) from pg_policies
       where schemaname = 'storage' and tablename = 'objects'
         and policyname = 'call_audio_select_managed_deleting_for_delete'
         and cmd = 'SELECT'
         and pg_catalog.lower(qual) like '%storage.allow_delete_query%') = 1
  and (select count(*) from pg_policies
       where schemaname = 'storage' and tablename = 'objects'
         and policyname like 'call_audio_%' and cmd = 'DELETE') = 1
  and (select count(*) from pg_policies
       where schemaname = 'storage' and tablename = 'objects'
         and policyname = 'call_audio_delete_managed_deleting'
         and cmd = 'DELETE') = 1,
  'reconciliation keeps Storage reads delete-transaction-only and deletion exact-object scoped'
);

select * from finish();
rollback;
