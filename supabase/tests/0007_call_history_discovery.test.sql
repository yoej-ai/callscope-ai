begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-4000-8000-000000000071', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'history-member@example.com', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-4000-8000-000000000072', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'history-outsider@example.com', '', now(), '{}', '{}', now(), now());

insert into public.workspaces (id, name, created_by) values
  ('10000000-0000-4000-8000-000000000071', 'History workspace', '00000000-0000-4000-8000-000000000071'),
  ('10000000-0000-4000-8000-000000000072', 'Other history workspace', '00000000-0000-4000-8000-000000000072');

insert into public.workspace_members (workspace_id, user_id, role) values
  ('10000000-0000-4000-8000-000000000071', '00000000-0000-4000-8000-000000000071', 'member'),
  ('10000000-0000-4000-8000-000000000072', '00000000-0000-4000-8000-000000000072', 'owner');

insert into public.calls (
  id,
  workspace_id,
  uploaded_by,
  display_name,
  original_filename,
  storage_bucket,
  storage_path,
  content_type,
  size_bytes,
  status,
  created_at,
  upload_completed_at
)
select
  ('26000000-0000-4000-8000-' || pg_catalog.lpad(series.value::text, 12, '0'))::uuid,
  '10000000-0000-4000-8000-000000000071'::uuid,
  '00000000-0000-4000-8000-000000000071'::uuid,
  case series.value
    when 1 then 'Enterprise Discovery'
    when 3 then E'Literal %_,() \\ path'
    else null
  end,
  case series.value
    when 2 then 'Filename Needle.MP3'
    else 'history-' || pg_catalog.lpad(series.value::text, 2, '0') || '.mp3'
  end,
  'call-audio',
  '10000000-0000-4000-8000-000000000071/26000000-0000-4000-8000-' ||
    pg_catalog.lpad(series.value::text, 12, '0') || '/source.mp3',
  'audio/mpeg',
  1000,
  'uploaded',
  timestamptz '2026-01-01 00:00:00+00' +
    case when series.value in (24, 25) then interval '25 minutes'
      else series.value * interval '1 minute'
    end,
  timestamptz '2026-01-01 00:00:30+00' + series.value * interval '1 minute'
from pg_catalog.generate_series(1, 25) as series(value);

insert into public.calls (
  id, workspace_id, uploaded_by, original_filename, storage_bucket,
  storage_path, content_type, size_bytes, status, created_at, upload_completed_at
) values (
  '26000000-0000-4000-8000-000000000999',
  '10000000-0000-4000-8000-000000000072',
  '00000000-0000-4000-8000-000000000072',
  'other-tenant.mp3',
  'call-audio',
  '10000000-0000-4000-8000-000000000072/26000000-0000-4000-8000-000000000999/source.mp3',
  'audio/mpeg',
  1000,
  'uploaded',
  timestamptz '2026-01-01 01:00:00+00',
  timestamptz '2026-01-01 01:00:30+00'
);

update public.calls
set status = 'deleting'
where id = '26000000-0000-4000-8000-000000000004';

update public.calls
set status = 'failed'
where id = '26000000-0000-4000-8000-000000000005';

update public.calls
set status = 'pending_upload', upload_completed_at = null
where id = '26000000-0000-4000-8000-000000000012';

update public.call_transcriptions
set
  status = 'processing',
  attempt_count = 1,
  claim_token = '56000000-0000-4000-8000-000000000006',
  lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes',
  started_at = now()
where call_id = '26000000-0000-4000-8000-000000000006';

update public.call_transcriptions
set
  status = 'failed',
  attempt_count = 2,
  claim_token = '56000000-0000-4000-8000-000000000007',
  last_error_code = 'fixture_failure',
  started_at = now() - interval '1 minute',
  failed_at = now()
where call_id = '26000000-0000-4000-8000-000000000007';

update public.call_transcriptions
set
  status = 'completed',
  transcript_text = 'Completed transcript fixture.',
  language_code = 'en',
  attempt_count = 1,
  claim_token = '56000000-0000-4000-8000-000000000008',
  started_at = now() - interval '2 minutes',
  completed_at = now()
where call_id in (
  '26000000-0000-4000-8000-000000000008',
  '26000000-0000-4000-8000-000000000009',
  '26000000-0000-4000-8000-000000000010',
  '26000000-0000-4000-8000-000000000011'
);

update public.call_analyses
set
  status = 'processing',
  attempt_count = 1,
  claim_token = '57000000-0000-4000-8000-000000000009',
  lease_expires_at = pg_catalog.clock_timestamp() + interval '15 minutes',
  started_at = now()
where call_id = '26000000-0000-4000-8000-000000000009';

update public.call_analyses
set
  status = 'failed',
  attempt_count = 3,
  claim_token = '57000000-0000-4000-8000-000000000010',
  last_error_code = 'fixture_failure',
  started_at = now() - interval '1 minute',
  failed_at = now()
where call_id = '26000000-0000-4000-8000-000000000010';

update public.call_analyses
set
  status = 'completed',
  summary = 'Completed summary fixture.',
  sentiment = 'positive',
  primary_intent = 'evaluation',
  attempt_count = 1,
  claim_token = '57000000-0000-4000-8000-000000000011',
  started_at = now() - interval '1 minute',
  completed_at = now()
where call_id = '26000000-0000-4000-8000-000000000011';

select ok(
  has_function_privilege(
    'authenticated',
    'public.list_workspace_calls(uuid,text,text,text,integer)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.list_workspace_calls(uuid,text,text,text,integer)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'service_role',
    'public.list_workspace_calls(uuid,text,text,text,integer)',
    'EXECUTE'
  ),
  'only authenticated users can execute call-history listing'
);

select ok(
  (select procedure.prosecdef
      and pg_catalog.array_to_string(procedure.proconfig, ',') = 'search_path=""'
   from pg_catalog.pg_proc as procedure
   join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
   where namespace.nspname = 'public'
     and procedure.proname = 'list_workspace_calls'),
  'the listing RPC is security definer with an empty search path'
);

set local role anon;
select throws_ok(
  $$select public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 1
  )$$,
  '42501',
  'permission denied for function list_workspace_calls',
  'anonymous callers cannot execute the listing RPC'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000071', true);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 1
  )->>'workspace_total_count')::integer,
  25,
  'an authenticated member can list their workspace calls'
);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', 'discovery', 'all', 'newest', 1
  )->>'total_count')::integer,
  1,
  'display name search is case-insensitive and substring based'
);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', 'needle.mp3', 'all', 'newest', 1
  )->>'total_count')::integer,
  1,
  'original filename search is case-insensitive and substring based'
);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', 'ENTERPRISE', 'all', 'newest', 1
  )->>'total_count')::integer,
  1,
  'uppercase search safely matches normalized content'
);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', '   ', 'all', 'newest', 1
  )->>'total_count')::integer,
  25,
  'blank search behaves as no search'
);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', '%_,()', 'all', 'newest', 1
  )->>'total_count')::integer,
  1,
  'wildcard and filter-like search characters are matched literally'
);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', E'\\', 'all', 'newest', 1
  )->>'total_count')::integer,
  1,
  'backslash search input is matched literally'
);

select throws_ok(
  $$select public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', E'bad\nquery', 'all', 'newest', 1
  )$$,
  '22023',
  'Search must be at most 100 characters without control characters',
  'control characters are rejected from search'
);

select throws_ok(
  $$select public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', repeat('x', 101), 'all', 'newest', 1
  )$$,
  '22023',
  'Search must be at most 100 characters without control characters',
  'overlong search is rejected'
);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 1
  )->>'total_count')::integer,
  25,
  'the All filter includes every workspace call'
);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'in_progress', 'newest', 1
  )->>'total_count')::integer,
  20,
  'the In progress filter includes only active and waiting lifecycle stages'
);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'completed', 'newest', 1
  )->>'total_count')::integer,
  1,
  'the Completed filter includes completed analysis'
);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'failed', 'newest', 1
  )->>'total_count')::integer,
  3,
  'the Failed filter includes call, transcription, and analysis failures'
);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'deleting', 'newest', 1
  )->>'total_count')::integer,
  1,
  'the Deleting filter is distinct from processing'
);

select throws_ok(
  $$select public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'completed,failed', 'newest', 1
  )$$,
  '22023',
  'Invalid call status filter',
  'invalid filter syntax is rejected safely'
);

select throws_ok(
  $$select public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'created_at desc', 1
  )$$,
  '22023',
  'Invalid call sort order',
  'arbitrary sort expressions are rejected'
);

select is(
  public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 1
  )->'items'->0->>'id',
  '26000000-0000-4000-8000-000000000025',
  'newest sorting uses descending created_at and id deterministically'
);

select is(
  public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'oldest', 1
  )->'items'->0->>'id',
  '26000000-0000-4000-8000-000000000001',
  'oldest sorting uses ascending created_at and id deterministically'
);

select is(
  pg_catalog.jsonb_array_length(public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 1
  )->'items'),
  20,
  'the first page is bounded to twenty calls'
);

select is(
  pg_catalog.jsonb_array_length(public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 2
  )->'items'),
  5,
  'the second page contains only the remaining calls'
);

select is(
  (
    with first_page as (
      select item->>'id' as id
      from pg_catalog.jsonb_array_elements(public.list_workspace_calls(
        '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 1
      )->'items') as item
    ),
    second_page as (
      select item->>'id' as id
      from pg_catalog.jsonb_array_elements(public.list_workspace_calls(
        '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 2
      )->'items') as item
    )
    select pg_catalog.count(*) from first_page join second_page using (id)
  ),
  0::bigint,
  'deterministic adjacent pages contain no duplicate calls'
);

select is(
  (public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 100
  )->>'page')::integer,
  2,
  'a page beyond the result range safely clamps to the final page'
);

select throws_ok(
  $$select public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 0
  )$$,
  '22023',
  'Page must be between 1 and 10000',
  'zero page input is rejected'
);

select throws_ok(
  $$select public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 10001
  )$$,
  '22023',
  'Page must be between 1 and 10000',
  'excessive page input is rejected'
);

select results_eq(
  $$select key
    from pg_catalog.jsonb_object_keys(public.list_workspace_calls(
      '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 1
    )) as key
    order by key$$,
  $$values
    ('items'::text),
    ('page'::text),
    ('page_size'::text),
    ('total_count'::text),
    ('total_pages'::text),
    ('workspace_total_count'::text)$$,
  'the response envelope exposes only bounded pagination metadata and items'
);

select results_eq(
  $$select key
    from pg_catalog.jsonb_object_keys(
      public.list_workspace_calls(
        '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 1
      )->'items'->0
    ) as key
    order by key$$,
  $$values
    ('content_type'::text),
    ('created_at'::text),
    ('display_name'::text),
    ('id'::text),
    ('original_filename'::text),
    ('processing_stage'::text),
    ('size_bytes'::text),
    ('upload_completed_at'::text),
    ('uploaded_by'::text)$$,
  'call items expose only safe dashboard presentation fields'
);

select ok(
  public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 1
  )::text !~ '(claim_token|lease_expires_at|attempt_count|last_error_code|transcript_text|summary|segments|topics|objections|action_items)',
  'worker-private, transcript, and AI fields are absent from the response'
);

select results_eq(
  $$select item->>'id', item->>'processing_stage'
    from pg_catalog.jsonb_array_elements(public.list_workspace_calls(
      '10000000-0000-4000-8000-000000000071', null, 'all', 'oldest', 1
    )->'items') as item
    where item->>'id' in (
      '26000000-0000-4000-8000-000000000004',
      '26000000-0000-4000-8000-000000000005',
      '26000000-0000-4000-8000-000000000006',
      '26000000-0000-4000-8000-000000000007',
      '26000000-0000-4000-8000-000000000008',
      '26000000-0000-4000-8000-000000000009',
      '26000000-0000-4000-8000-000000000010',
      '26000000-0000-4000-8000-000000000011',
      '26000000-0000-4000-8000-000000000012'
    )
    order by item->>'id'$$,
  $$values
    ('26000000-0000-4000-8000-000000000004'::text, 'deleting'::text),
    ('26000000-0000-4000-8000-000000000005'::text, 'failed'::text),
    ('26000000-0000-4000-8000-000000000006'::text, 'transcribing'::text),
    ('26000000-0000-4000-8000-000000000007'::text, 'failed'::text),
    ('26000000-0000-4000-8000-000000000008'::text, 'waiting_analysis'::text),
    ('26000000-0000-4000-8000-000000000009'::text, 'analyzing'::text),
    ('26000000-0000-4000-8000-000000000010'::text, 'failed'::text),
    ('26000000-0000-4000-8000-000000000011'::text, 'completed'::text),
    ('26000000-0000-4000-8000-000000000012'::text, 'upload_pending'::text)$$,
  'lifecycle derivation follows safe stage precedence'
);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000072', true);
select throws_ok(
  $$select public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000071', null, 'all', 'newest', 1
  )$$,
  '42501',
  'Workspace access denied',
  'an unrelated workspace member cannot query another tenant'
);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000071', true);
select throws_ok(
  $$select public.list_workspace_calls(
    '10000000-0000-4000-8000-000000000072', null, 'all', 'newest', 1
  )$$,
  '42501',
  'Workspace access denied',
  'tenant isolation is enforced in both directions'
);

reset role;
select ok(
  not has_table_privilege('authenticated', 'public.calls', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.calls', 'DELETE')
  and not has_table_privilege('authenticated', 'public.call_transcriptions', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.call_analyses', 'UPDATE'),
  'listing adds no authenticated mutation privileges'
);

select ok(
  has_function_privilege('authenticated', 'public.rename_call(uuid,uuid,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.prepare_call_deletion(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.finalize_call_deletion(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.retry_failed_call_processing(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.claim_transcription_jobs(integer)', 'EXECUTE')
  and has_function_privilege('service_role', 'public.claim_analysis_jobs(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.claim_transcription_jobs(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.claim_analysis_jobs(integer)', 'EXECUTE'),
  'Phase 6A management and worker RPC permission boundaries remain unchanged'
);

select * from finish();
rollback;
