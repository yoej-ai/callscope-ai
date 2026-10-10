begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-4000-8000-000000000081', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'playbook-owner@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000082', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'playbook-admin@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000083', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'playbook-member@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000084', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'playbook-outsider@example.com', '', now(), '{}', '{}', now(), now());

insert into public.workspaces (id, name, created_by) values
  ('10000000-0000-4000-8000-000000000081', 'Playbook workspace A', '00000000-0000-4000-8000-000000000081'),
  ('10000000-0000-4000-8000-000000000082', 'Playbook workspace B', '00000000-0000-4000-8000-000000000084');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-4000-8000-000000000081', '00000000-0000-4000-8000-000000000081', 'owner'),
  ('10000000-0000-4000-8000-000000000081', '00000000-0000-4000-8000-000000000082', 'admin'),
  ('10000000-0000-4000-8000-000000000081', '00000000-0000-4000-8000-000000000083', 'member'),
  ('10000000-0000-4000-8000-000000000082', '00000000-0000-4000-8000-000000000084', 'owner');

create temporary table playbook_test_ids (
  label text primary key,
  playbook_id uuid not null,
  version_id uuid not null
) on commit drop;

grant select, insert on table playbook_test_ids to authenticated;

create temporary table playbook_criterion_test_ids (
  label text primary key,
  criterion_id uuid not null
) on commit drop;

grant select, insert on table playbook_criterion_test_ids to authenticated;

select ok(
  has_table_privilege('authenticated', 'public.playbooks', 'SELECT')
  and has_table_privilege('authenticated', 'public.playbook_versions', 'SELECT')
  and has_table_privilege('authenticated', 'public.playbook_criteria', 'SELECT')
  and not has_table_privilege('authenticated', 'public.playbooks', 'INSERT')
  and not has_table_privilege('authenticated', 'public.playbooks', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.playbooks', 'DELETE')
  and not has_table_privilege('authenticated', 'public.playbook_versions', 'INSERT')
  and not has_table_privilege('authenticated', 'public.playbook_versions', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.playbook_versions', 'DELETE')
  and not has_table_privilege('authenticated', 'public.playbook_criteria', 'INSERT')
  and not has_table_privilege('authenticated', 'public.playbook_criteria', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.playbook_criteria', 'DELETE'),
  'authenticated clients receive read-only table grants'
);

select ok(
  not has_table_privilege('anon', 'public.playbooks', 'SELECT')
  and not has_table_privilege('anon', 'public.playbook_versions', 'SELECT')
  and not has_table_privilege('anon', 'public.playbook_criteria', 'SELECT'),
  'anonymous clients receive no playbook table access'
);

select ok(
  has_function_privilege('authenticated', 'public.create_playbook(uuid,text,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.update_playbook_draft(uuid,uuid,text,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.add_playbook_criterion(uuid,uuid,text,text,integer,text,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.update_playbook_criterion(uuid,uuid,text,text,integer,text,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.remove_playbook_criterion(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.move_playbook_criterion(uuid,uuid,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.publish_playbook_version(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.create_next_playbook_version(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.create_playbook(uuid,text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.update_playbook_draft(uuid,uuid,text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.add_playbook_criterion(uuid,uuid,text,text,integer,text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.update_playbook_criterion(uuid,uuid,text,text,integer,text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.remove_playbook_criterion(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.move_playbook_criterion(uuid,uuid,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.publish_playbook_version(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.create_next_playbook_version(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.create_playbook(uuid,text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.update_playbook_draft(uuid,uuid,text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.add_playbook_criterion(uuid,uuid,text,text,integer,text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.update_playbook_criterion(uuid,uuid,text,text,integer,text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.remove_playbook_criterion(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.move_playbook_criterion(uuid,uuid,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.publish_playbook_version(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.create_next_playbook_version(uuid,uuid)', 'EXECUTE'),
  'playbook RPC execution is restricted to authenticated users'
);

select is(
  (
    select pg_catalog.count(*)
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_namespace as namespace
      on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.proname in (
        'create_playbook',
        'update_playbook_draft',
        'add_playbook_criterion',
        'update_playbook_criterion',
        'remove_playbook_criterion',
        'move_playbook_criterion',
        'publish_playbook_version',
        'create_next_playbook_version'
      )
      and procedure.prosecdef
      and pg_catalog.array_to_string(procedure.proconfig, ',') = 'search_path=""'
  ),
  8::bigint,
  'every public playbook RPC is SECURITY DEFINER with an empty search path'
);

set local role anon;
select throws_ok(
  $$select pg_catalog.count(*) from public.playbooks$$,
  '42501',
  'permission denied for table playbooks',
  'anonymous direct reads are denied'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000081', true);
select lives_ok(
  $$insert into playbook_test_ids (label, playbook_id, version_id)
    select 'owner-a', created.playbook_id, created.version_id
    from public.create_playbook(
      '10000000-0000-4000-8000-000000000081',
      'Owner Sales Playbook',
      'sales'
    ) as created$$,
  'an owner can create Version 1 as a draft'
);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000082', true);
select lives_ok(
  $$insert into playbook_test_ids (label, playbook_id, version_id)
    select 'admin-a', created.playbook_id, created.version_id
    from public.create_playbook(
      '10000000-0000-4000-8000-000000000081',
      'Admin Sales Playbook',
      'sales'
    ) as created$$,
  'an admin can create Version 1 as a draft'
);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000084', true);
select lives_ok(
  $$insert into playbook_test_ids (label, playbook_id, version_id)
    select 'owner-b', created.playbook_id, created.version_id
    from public.create_playbook(
      '10000000-0000-4000-8000-000000000082',
      'Other Tenant Playbook',
      'sales'
    ) as created$$,
  'another tenant owner can create only in their own workspace'
);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000083', true);
select throws_ok(
  $$select public.create_playbook(
    '10000000-0000-4000-8000-000000000081', 'Member Attempt', 'sales'
  )$$,
  '42501',
  'Playbook operation is not permitted',
  'a member cannot create a playbook'
);

select is(
  (select pg_catalog.count(*) from public.playbooks),
  0::bigint,
  'a member receives no unpublished playbook roots'
);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000084', true);
select throws_ok(
  $$select public.update_playbook_draft(
    '10000000-0000-4000-8000-000000000081',
    (select version_id from playbook_test_ids where label = 'owner-a'),
    'Cross tenant edit',
    'sales'
  )$$,
  '42501',
  'Playbook operation is not permitted',
  'a guessed cross-tenant draft UUID cannot be edited'
);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000081', true);
select is(
  public.update_playbook_draft(
    '10000000-0000-4000-8000-000000000081',
    (select version_id from playbook_test_ids where label = 'owner-a'),
    'Owner Sales Standard',
    'sales'
  ),
  'updated'::text,
  'an owner can edit normalized draft metadata'
);

select throws_ok(
  $$select public.publish_playbook_version(
    '10000000-0000-4000-8000-000000000081',
    (select version_id from playbook_test_ids where label = 'owner-a')
  )$$,
  '22023',
  'A playbook must contain between 1 and 20 criteria',
  'a draft with no criteria cannot be published'
);

select ok(
  public.add_playbook_criterion(
    '10000000-0000-4000-8000-000000000081',
    (select version_id from playbook_test_ids where label = 'owner-a'),
    'Discovery',
    'Understand the buyer context.',
    60,
    'Uses open questions.',
    'Relies on assumptions.'
  ) is not null,
  'a manager can add a bounded draft criterion'
);

select throws_ok(
  $$select public.add_playbook_criterion(
    '10000000-0000-4000-8000-000000000081',
    (select version_id from playbook_test_ids where label = 'owner-a'),
    'discovery', '', 40, '', ''
  )$$,
  '22023',
  'Criterion name must be unique within the version',
  'case-insensitive duplicate criterion names are rejected'
);

select throws_ok(
  $$select public.publish_playbook_version(
    '10000000-0000-4000-8000-000000000081',
    (select version_id from playbook_test_ids where label = 'owner-a')
  )$$,
  '22023',
  'Criterion weights must total exactly 100',
  'a draft whose weights do not total 100 cannot be published'
);

select ok(
  public.add_playbook_criterion(
    '10000000-0000-4000-8000-000000000081',
    (select version_id from playbook_test_ids where label = 'owner-a'),
    'Clear Next Step',
    'Secure a concrete next action.',
    40,
    'Owner and date are explicit.',
    'No next action is agreed.'
  ) is not null,
  'a second criterion can complete the draft weight'
);

select is(
  public.publish_playbook_version(
    '10000000-0000-4000-8000-000000000081',
    (select version_id from playbook_test_ids where label = 'owner-a')
  ),
  'published'::text,
  'a valid 100-weight draft publishes atomically'
);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000083', true);
select is(
  (
    select pg_catalog.count(*)
    from public.playbook_versions as version
    where version.id = (select version_id from playbook_test_ids where label = 'owner-a')
      and version.status = 'published'
  ),
  1::bigint,
  'a member can read an appropriate published playbook version'
);

select is(
  (
    select pg_catalog.count(*)
    from public.playbook_versions as version
    where version.id = (select version_id from playbook_test_ids where label = 'admin-a')
  ),
  0::bigint,
  'a member does not receive another unpublished draft'
);

select throws_ok(
  $$select public.add_playbook_criterion(
    '10000000-0000-4000-8000-000000000081',
    (select version_id from playbook_test_ids where label = 'admin-a'),
    'Member mutation', '', 100, '', ''
  )$$,
  '42501',
  'Playbook operation is not permitted',
  'a member cannot manage a draft even with its exact UUID'
);

reset role;
select throws_ok(
  $$update public.playbook_versions
    set name = 'Changed published name'
    where id = (select version_id from playbook_test_ids where label = 'owner-a')$$,
  '55000',
  'Published playbook versions are immutable',
  'published version metadata cannot be updated even by a direct table write'
);

select throws_ok(
  $$delete from public.playbook_versions
    where id = (select version_id from playbook_test_ids where label = 'owner-a')$$,
  '55000',
  'Published playbook versions are immutable',
  'published versions cannot be deleted'
);

select throws_ok(
  $$insert into public.playbook_criteria (
      playbook_version_id, name, description, weight,
      pass_guidance, fail_guidance, position
    ) values (
      (select version_id from playbook_test_ids where label = 'owner-a'),
      'Late criterion', '', 1, '', '', 3
    )$$,
  '55000',
  'Published playbook criteria are immutable',
  'criteria cannot be inserted into a published version'
);

select throws_ok(
  $$update public.playbook_criteria
    set weight = 50
    where playbook_version_id = (
      select version_id from playbook_test_ids where label = 'owner-a'
    ) and position = 1$$,
  '55000',
  'Published playbook criteria are immutable',
  'published criteria cannot be updated'
);

select throws_ok(
  $$delete from public.playbook_criteria
    where playbook_version_id = (
      select version_id from playbook_test_ids where label = 'owner-a'
    ) and position = 1$$,
  '55000',
  'Published playbook criteria are immutable',
  'published criteria cannot be deleted'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000081', true);
select lives_ok(
  $$insert into playbook_test_ids (label, playbook_id, version_id)
    select
      'owner-a-v2',
      (select playbook_id from playbook_test_ids where label = 'owner-a'),
      created.version_id
    from public.create_next_playbook_version(
      '10000000-0000-4000-8000-000000000081',
      (select playbook_id from playbook_test_ids where label = 'owner-a')
    ) as created$$,
  'a manager can atomically create the next draft from a published version'
);

select is(
  (
    select version.version_number
    from public.playbook_versions as version
    where version.id = (select version_id from playbook_test_ids where label = 'owner-a-v2')
  ),
  2,
  'the copied draft receives the deterministic next version number'
);

select results_eq(
  $$select criterion.name, criterion.weight, criterion.position
    from public.playbook_criteria as criterion
    where criterion.playbook_version_id = (
      select version_id from playbook_test_ids where label = 'owner-a-v2'
    )
    order by criterion.position$$,
  $$values
    ('Discovery'::text, 60, 1),
    ('Clear Next Step'::text, 40, 2)$$,
  'the new draft copies the published criteria and order'
);

select is(
  public.update_playbook_criterion(
    '10000000-0000-4000-8000-000000000081',
    (
      select criterion.id
      from public.playbook_criteria as criterion
      where criterion.playbook_version_id = (
        select version_id from playbook_test_ids where label = 'owner-a-v2'
      ) and criterion.position = 1
    ),
    'Discovery and Qualification',
    'Expanded in Version 2.',
    60,
    'Uses open questions.',
    'Relies on assumptions.'
  ),
  'updated'::text,
  'the copied draft remains editable'
);

select results_eq(
  $$select criterion.name, criterion.weight
    from public.playbook_criteria as criterion
    where criterion.playbook_version_id = (
      select version_id from playbook_test_ids where label = 'owner-a'
    )
    order by criterion.position$$,
  $$values
    ('Discovery'::text, 60),
    ('Clear Next Step'::text, 40)$$,
  'editing the new version leaves the published source unchanged'
);

select is(
  public.move_playbook_criterion(
    '10000000-0000-4000-8000-000000000081',
    (
      select criterion.id
      from public.playbook_criteria as criterion
      where criterion.playbook_version_id = (
        select version_id from playbook_test_ids where label = 'owner-a-v2'
      ) and criterion.position = 2
    ),
    'up'
  ),
  'moved'::text,
  'a manager can move a draft criterion up'
);

select results_eq(
  $$select criterion.name, criterion.position
    from public.playbook_criteria as criterion
    where criterion.playbook_version_id = (
      select version_id from playbook_test_ids where label = 'owner-a-v2'
    )
    order by criterion.position$$,
  $$values
    ('Clear Next Step'::text, 1),
    ('Discovery and Qualification'::text, 2)$$,
  'criterion movement swaps deterministic adjacent positions'
);

select lives_ok(
  $$insert into playbook_criterion_test_ids (label, criterion_id)
    select 'temporary-draft-criterion', public.add_playbook_criterion(
      '10000000-0000-4000-8000-000000000081',
      (select version_id from playbook_test_ids where label = 'owner-a-v2'),
      'Temporary criterion', '', 1, '', ''
    )$$,
  'a manager can append another draft criterion'
);

select is(
  public.remove_playbook_criterion(
    '10000000-0000-4000-8000-000000000081',
    (
      select criterion_id
      from playbook_criterion_test_ids
      where label = 'temporary-draft-criterion'
    )
  ),
  'removed'::text,
  'a manager can remove a draft criterion'
);

select results_eq(
  $$select criterion.position
    from public.playbook_criteria as criterion
    where criterion.playbook_version_id = (
      select version_id from playbook_test_ids where label = 'owner-a-v2'
    )
    order by criterion.position$$,
  $$values (1), (2)$$,
  'criterion removal leaves a complete ordered sequence'
);

select throws_ok(
  $$select public.create_next_playbook_version(
    '10000000-0000-4000-8000-000000000081',
    (select playbook_id from playbook_test_ids where label = 'owner-a')
  )$$,
  '23505',
  'A draft version already exists',
  'only one draft version can exist per playbook'
);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000082', true);
select throws_ok(
  $$select public.publish_playbook_version(
    '10000000-0000-4000-8000-000000000081',
    (select version_id from playbook_test_ids where label = 'admin-a')
  )$$,
  '22023',
  'A playbook must contain between 1 and 20 criteria',
  'the admin draft also requires criteria before publishing'
);

select lives_ok(
  $$select public.add_playbook_criterion(
      '10000000-0000-4000-8000-000000000081',
      (select version_id from playbook_test_ids where label = 'admin-a'),
      'Admin criterion ' || series.value,
      '',
      5,
      '',
      ''
    )
    from pg_catalog.generate_series(1, 20) as series(value)$$,
  'an admin can add the maximum twenty criteria'
);

select throws_ok(
  $$select public.add_playbook_criterion(
    '10000000-0000-4000-8000-000000000081',
    (select version_id from playbook_test_ids where label = 'admin-a'),
    'Twenty first criterion', '', 1, '', ''
  )$$,
  '22023',
  'A playbook cannot contain more than 20 criteria',
  'a twenty-first criterion is rejected under the version lock'
);

select is(
  public.publish_playbook_version(
    '10000000-0000-4000-8000-000000000081',
    (select version_id from playbook_test_ids where label = 'admin-a')
  ),
  'published'::text,
  'an admin can publish a valid maximum-size draft'
);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000084', true);
select lives_ok(
  $$insert into playbook_criterion_test_ids (label, criterion_id)
    select 'owner-b-criterion', public.add_playbook_criterion(
      '10000000-0000-4000-8000-000000000082',
      (select version_id from playbook_test_ids where label = 'owner-b'),
      'Tenant B criterion',
      '',
      100,
      '',
      ''
    )$$,
  'tenant B can configure its own draft'
);
select is(
  public.publish_playbook_version(
    '10000000-0000-4000-8000-000000000082',
    (select version_id from playbook_test_ids where label = 'owner-b')
  ),
  'published'::text,
  'tenant B can publish its own valid version'
);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000081', true);
select is(
  (
    select pg_catalog.count(*)
    from public.playbooks as playbook
    where playbook.workspace_id = '10000000-0000-4000-8000-000000000082'
  ),
  0::bigint,
  'tenant A cannot read tenant B published playbooks'
);

select throws_ok(
  $$select public.update_playbook_criterion(
    '10000000-0000-4000-8000-000000000081',
    (select criterion_id from playbook_criterion_test_ids where label = 'owner-b-criterion'),
    'Cross tenant', '', 100, '', ''
  )$$,
  '42501',
  'Playbook operation is not permitted',
  'tenant A cannot mutate tenant B through a guessed criterion UUID'
);

reset role;
select ok(
  has_function_privilege('authenticated', 'public.rename_call(uuid,uuid,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.list_workspace_calls(uuid,text,text,text,integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.claim_transcription_jobs(integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.claim_analysis_jobs(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.claim_transcription_jobs(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.claim_analysis_jobs(integer)', 'EXECUTE'),
  'Phase 6A and 6B security boundaries remain intact'
);

select * from finish();
rollback;
