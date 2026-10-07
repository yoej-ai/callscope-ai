begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(23);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'upload-owner@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'upload-member@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'upload-outsider@example.com', '', now(), '{}', '{}', now(), now());

insert into public.workspaces (id, name, created_by) values
  ('10000000-0000-0000-0000-000000000011', 'Upload workspace', '00000000-0000-0000-0000-000000000011'),
  ('10000000-0000-0000-0000-000000000012', 'Other workspace', '00000000-0000-0000-0000-000000000013');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000011', 'owner'),
  ('10000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000012', 'member'),
  ('10000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000013', 'owner');

create temporary table upload_result (
  call_id uuid,
  workspace_id uuid,
  storage_bucket text,
  storage_path text,
  content_type text,
  size_bytes bigint
) on commit drop;

grant insert, select on table pg_temp.upload_result to authenticated;

select results_eq(
  $$select public, file_size_limit, allowed_mime_types
    from storage.buckets where id = 'call-audio'$$,
  $$values (
    false,
    26214400::bigint,
    array['audio/mpeg', 'audio/mp4', 'audio/x-m4a', 'audio/wav', 'audio/webm', 'audio/ogg']::text[]
  )$$,
  'call-audio bucket is private and enforces the declared limits'
);

set local role anon;
select throws_ok(
  $$select * from public.create_call_upload(
    '10000000-0000-0000-0000-000000000011', 'call.mp3', 'audio/mpeg', 1024
  )$$,
  '42501',
  'permission denied for function create_call_upload',
  'anonymous users cannot create upload records'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);

insert into upload_result
select * from public.create_call_upload(
  '10000000-0000-0000-0000-000000000011',
  'Customer Discovery.mp3',
  'audio/mpeg',
  1048576
);

select results_eq(
  $$select call.workspace_id, call.uploaded_by, call.original_filename,
           call.storage_bucket, call.content_type, call.size_bytes, call.status
    from public.calls as call
    join upload_result as result on result.call_id = call.id$$,
  $$values (
    '10000000-0000-0000-0000-000000000011'::uuid,
    '00000000-0000-0000-0000-000000000011'::uuid,
    'Customer Discovery.mp3'::text,
    'call-audio'::text,
    'audio/mpeg'::text,
    1048576::bigint,
    'pending_upload'::text
  )$$,
  'create_call_upload stores a tenant-bound pending upload'
);

select ok(
  (select storage_path ~ '^10000000-0000-0000-0000-000000000011/[0-9a-f-]{36}/source\.mp3$' from upload_result),
  'the database generates the trusted workspace and call object path'
);

select ok(
  (select strpos(storage_path, 'Customer Discovery') = 0 from upload_result),
  'the original filename is not used in the object path'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000013', true);
select is_empty(
  $$select * from public.create_call_upload(
    '10000000-0000-0000-0000-000000000011', 'hidden.mp3', 'audio/mpeg', 1024
  )$$,
  'a non-member cannot create an upload in another workspace'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
select throws_ok(
  $$select * from public.create_call_upload(
    '10000000-0000-0000-0000-000000000011', 'call.exe', 'audio/mpeg', 1024
  )$$,
  '22023', 'Unsupported filename extension',
  'unsupported extensions are rejected'
);
select throws_ok(
  $$select * from public.create_call_upload(
    '10000000-0000-0000-0000-000000000011', 'call.mp3', 'application/octet-stream', 1024
  )$$,
  '22023', 'Unsupported content type',
  'unsupported MIME types are rejected'
);
select throws_ok(
  $$select * from public.create_call_upload(
    '10000000-0000-0000-0000-000000000011', 'call.wav', 'audio/mpeg', 1024
  )$$,
  '22023', 'Filename extension and content type do not match',
  'extension and MIME type must agree'
);
select throws_ok(
  $$select * from public.create_call_upload(
    '10000000-0000-0000-0000-000000000011', 'call.mp3', 'audio/mpeg', 0
  )$$,
  '22023', 'Invalid upload size',
  'empty uploads are rejected'
);
select throws_ok(
  $$select * from public.create_call_upload(
    '10000000-0000-0000-0000-000000000011', 'call.mp3', 'audio/mpeg', 26214401
  )$$,
  '22023', 'Invalid upload size',
  'uploads larger than 25 MiB are rejected'
);

select throws_ok(
  $$insert into storage.objects (bucket_id, name, metadata)
    values ('call-audio', 'arbitrary/path.mp3', '{"size":1048576,"mimetype":"audio/mpeg"}')$$,
  '42501',
  'new row violates row-level security policy for table "objects"',
  'storage RLS rejects arbitrary object paths'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000012', true);
select throws_ok(
  $$insert into storage.objects (bucket_id, name, metadata)
    select 'call-audio', storage_path, '{"size":1048576,"mimetype":"audio/mpeg"}'::jsonb
    from upload_result$$,
  '42501',
  'new row violates row-level security policy for table "objects"',
  'another workspace member cannot upload to the creator-bound pending path'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
select throws_ok(
  $$insert into storage.objects (bucket_id, name, metadata)
    values (
      'call-audio',
      '10000000-0000-0000-0000-000000000012/60000000-0000-0000-0000-000000000001/source.mp3',
      '{"size":1048576,"mimetype":"audio/mpeg"}'
    )$$,
  '42501',
  'new row violates row-level security policy for table "objects"',
  'a path under another workspace is denied without its trusted pending call'
);

reset role;
select is(
  (select count(*) from pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and policyname like 'call_audio_%' and cmd in ('UPDATE', 'DELETE')),
  0::bigint,
  'call audio has no browser update or delete policy'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
select is_empty(
  $$select * from public.finalize_call_upload(
    '10000000-0000-0000-0000-000000000011', (select call_id from upload_result)
  )$$,
  'a call cannot be finalized before its exact object exists'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000013', true);
select is_empty(
  $$select * from public.finalize_call_upload(
    '10000000-0000-0000-0000-000000000011', (select call_id from upload_result)
  )$$,
  'cross-tenant finalization reveals no call'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
insert into storage.objects (bucket_id, name, metadata)
select 'call-audio', storage_path, '{"size":1,"mimetype":"audio/mpeg"}'::jsonb
from upload_result;

select is_empty(
  $$select * from public.finalize_call_upload(
    '10000000-0000-0000-0000-000000000011', (select call_id from upload_result)
  )$$,
  'mismatched object metadata cannot finalize a call'
);

select is(
  (select status from public.calls where id = (select call_id from upload_result)),
  'pending_upload',
  'a failed finalization leaves the call pending'
);

reset role;
update storage.objects
set metadata = '{"size":1048576,"mimetype":"audio/mpeg"}'::jsonb
where bucket_id = 'call-audio'
  and name = (select storage_path from upload_result);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
select results_eq(
  $$select * from public.finalize_call_upload(
    '10000000-0000-0000-0000-000000000011', (select call_id from upload_result)
  )$$,
  $$select call_id, 'uploaded'::text from upload_result$$,
  'matching stored object metadata finalizes the call'
);

select ok(
  (select status = 'uploaded' and upload_completed_at is not null
   from public.calls where id = (select call_id from upload_result)),
  'successful finalization records uploaded state and completion time'
);

select results_eq(
  $$select * from public.finalize_call_upload(
    '10000000-0000-0000-0000-000000000011', (select call_id from upload_result)
  )$$,
  $$select call_id, 'uploaded'::text from upload_result$$,
  'finalization is idempotent after success'
);

reset role;
update public.calls set status = 'processing'
where id = (select call_id from upload_result);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000011', true);
select is_empty(
  $$select * from public.finalize_call_upload(
    '10000000-0000-0000-0000-000000000011', (select call_id from upload_result)
  )$$,
  'finalization never resets a later processing state'
);

reset role;
select * from finish();
rollback;
