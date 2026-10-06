begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(15);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner@example.com', '', now(), '{}', '{"full_name":"Owner"}', now(), now()),
  ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'member@example.com', '', now(), '{}', '{"full_name":"Member"}', now(), now()),
  ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'outsider@example.com', '', now(), '{}', '{"full_name":"Outsider"}', now(), now()),
  ('00000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'candidate@example.com', '', now(), '{}', '{"full_name":"Candidate"}', now(), now());

insert into public.workspaces (id, name, created_by)
values ('10000000-0000-0000-0000-000000000001', 'Owner workspace', '00000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'owner'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'member');

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_path, status
) values (
  '20000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  'discovery.mp3',
  '10000000-0000-0000-0000-000000000001/discovery.mp3',
  'completed'
);

insert into public.call_analyses (id, call_id, summary)
values (
  '30000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  'Fixture analysis'
);

insert into public.usage_events (
  id, workspace_id, user_id, event_type, quantity, metadata
) values (
  '40000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  'call.processed',
  1,
  '{"source":"fixture"}'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select is((select count(*) from public.workspaces), 1::bigint, 'owner can read own workspace');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select is((select count(*) from public.workspaces), 1::bigint, 'member can read workspace data');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
select is((select count(*) from public.workspaces), 0::bigint, 'non-member cannot read another workspace');
select is((select count(*) from public.calls), 0::bigint, 'non-member cannot read another workspace calls');
select is((select count(*) from public.call_analyses), 0::bigint, 'non-member cannot read another workspace analyses');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
update public.workspace_members
set role = 'admin'
where workspace_id = '10000000-0000-0000-0000-000000000001'
  and user_id = '00000000-0000-0000-0000-000000000002';
select is(
  (select role from public.workspace_members where user_id = '00000000-0000-0000-0000-000000000002'),
  'member',
  'member cannot promote themselves'
);

select throws_ok(
  $$insert into public.workspace_members (workspace_id, user_id, role)
    values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004', 'member')$$,
  '42501',
  'new row violates row-level security policy for table "workspace_members"',
  'member cannot add arbitrary users'
);

update public.workspaces
set name = 'Member tampering'
where id = '10000000-0000-0000-0000-000000000001';
select is(
  (select name from public.workspaces where id = '10000000-0000-0000-0000-000000000001'),
  'Owner workspace',
  'ordinary member cannot update workspace name'
);

select throws_ok(
  $$select * from public.usage_events$$,
  '42501',
  'permission denied for table usage_events',
  'workspace member cannot directly read raw usage events'
);

update public.profiles
set full_name = 'Tampered'
where id = '00000000-0000-0000-0000-000000000001';
reset role;
select is(
  (select full_name from public.profiles where id = '00000000-0000-0000-0000-000000000001'),
  'Owner',
  'user cannot update another profile'
);

set local role anon;
select throws_ok(
  $$select * from public.workspaces$$,
  '42501',
  'permission denied for table workspaces',
  'anonymous users cannot access private application data'
);

select throws_ok(
  $$select public.create_workspace('Anonymous workspace')$$,
  '42501',
  'permission denied for function create_workspace',
  'anonymous user cannot execute create_workspace'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
delete from public.workspaces
where id = '10000000-0000-0000-0000-000000000001';

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select is(
  (select count(*) from public.workspaces where id = '10000000-0000-0000-0000-000000000001'),
  1::bigint,
  'outsider cannot delete another workspace'
);

update public.workspaces
set name = 'Renamed by owner'
where id = '10000000-0000-0000-0000-000000000001';
select is(
  (select name from public.workspaces where id = '10000000-0000-0000-0000-000000000001'),
  'Renamed by owner',
  'owner can update workspace name'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
select public.create_workspace(' Created safely ');
select is(
  (
    select count(*)
    from public.workspaces as workspace
    join public.workspace_members as member on member.workspace_id = workspace.id
    where workspace.name = 'Created safely'
      and workspace.created_by = '00000000-0000-0000-0000-000000000003'
      and member.user_id = '00000000-0000-0000-0000-000000000003'
      and member.role = 'owner'
  ),
  1::bigint,
  'workspace creation atomically creates owner membership'
);

reset role;
select * from finish();
rollback;
