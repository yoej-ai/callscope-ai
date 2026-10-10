begin;

create function public.list_workspace_calls(
  p_workspace_id uuid,
  p_search text default null,
  p_status text default 'all',
  p_sort text default 'newest',
  p_page integer default 1
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  normalized_search text := pg_catalog.btrim(coalesce(p_search, ''));
  normalized_status text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_status, 'all')));
  normalized_sort text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_sort, 'newest')));
  response jsonb;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null then
    raise exception 'Workspace is required' using errcode = '22023';
  end if;

  if pg_catalog.length(normalized_search) > 100
    or normalized_search ~ '[[:cntrl:]]'
  then
    raise exception 'Search must be at most 100 characters without control characters'
      using errcode = '22023';
  end if;

  if normalized_status not in ('all', 'in_progress', 'completed', 'failed', 'deleting') then
    raise exception 'Invalid call status filter' using errcode = '22023';
  end if;

  if normalized_sort not in ('newest', 'oldest') then
    raise exception 'Invalid call sort order' using errcode = '22023';
  end if;

  if p_page is null or p_page < 1 or p_page > 10000 then
    raise exception 'Page must be between 1 and 10000' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.workspace_members as member
    where member.workspace_id = p_workspace_id
      and member.user_id = current_user_id
  ) then
    raise exception 'Workspace access denied' using errcode = '42501';
  end if;

  with derived as (
    select
      call.id,
      call.display_name,
      call.original_filename,
      call.uploaded_by,
      call.content_type,
      call.size_bytes,
      call.created_at,
      call.upload_completed_at,
      case
        when call.status = 'deleting' then 'deleting'
        when call.status = 'pending_upload' then 'upload_pending'
        when call.status = 'failed' then 'failed'
        when transcription.id is null or transcription.status = 'queued'
          then 'waiting_transcription'
        when transcription.status = 'processing' then 'transcribing'
        when transcription.status = 'failed' then 'failed'
        when transcription.status = 'completed' and (
          analysis.id is null or analysis.status = 'queued'
        ) then 'waiting_analysis'
        when transcription.status = 'completed' and analysis.status = 'processing'
          then 'analyzing'
        when transcription.status = 'completed' and analysis.status = 'failed'
          then 'failed'
        when transcription.status = 'completed' and analysis.status = 'completed'
          then 'completed'
        else 'failed'
      end as processing_stage
    from public.calls as call
    left join public.call_transcriptions as transcription
      on transcription.call_id = call.id
    left join public.call_analyses as analysis
      on analysis.call_id = call.id
    where call.workspace_id = p_workspace_id
  ),
  filtered as (
    select derived.*
    from derived
    where (
        normalized_search = ''
        or pg_catalog.strpos(
          pg_catalog.lower(coalesce(derived.display_name, '')),
          pg_catalog.lower(normalized_search)
        ) > 0
        or pg_catalog.strpos(
          pg_catalog.lower(derived.original_filename),
          pg_catalog.lower(normalized_search)
        ) > 0
      )
      and (
        normalized_status = 'all'
        or (normalized_status = 'in_progress' and derived.processing_stage in (
          'upload_pending',
          'waiting_transcription',
          'transcribing',
          'waiting_analysis',
          'analyzing'
        ))
        or (normalized_status = 'completed' and derived.processing_stage = 'completed')
        or (normalized_status = 'failed' and derived.processing_stage = 'failed')
        or (normalized_status = 'deleting' and derived.processing_stage = 'deleting')
      )
  ),
  counts as (
    select
      (select pg_catalog.count(*) from derived) as workspace_total_count,
      (select pg_catalog.count(*) from filtered) as total_count
  ),
  pagination as (
    select
      counts.workspace_total_count,
      counts.total_count,
      pg_catalog.ceil(counts.total_count::numeric / 20)::integer as total_pages,
      least(
        p_page,
        greatest(
          1,
          pg_catalog.ceil(counts.total_count::numeric / 20)::integer
        )
      ) as effective_page
    from counts
  ),
  paged as (
    select
      filtered.*,
      pg_catalog.row_number() over (
        order by
          case when normalized_sort = 'oldest' then filtered.created_at end asc,
          case when normalized_sort = 'oldest' then filtered.id end asc,
          case when normalized_sort = 'newest' then filtered.created_at end desc,
          case when normalized_sort = 'newest' then filtered.id end desc
      ) as ordinal
    from filtered
    order by
      case when normalized_sort = 'oldest' then filtered.created_at end asc,
      case when normalized_sort = 'oldest' then filtered.id end asc,
      case when normalized_sort = 'newest' then filtered.created_at end desc,
      case when normalized_sort = 'newest' then filtered.id end desc
    limit 20
    offset ((select effective_page from pagination) - 1) * 20
  )
  select pg_catalog.jsonb_build_object(
    'items', coalesce(
      (
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'id', paged.id,
            'display_name', paged.display_name,
            'original_filename', paged.original_filename,
            'uploaded_by', paged.uploaded_by,
            'content_type', paged.content_type,
            'size_bytes', paged.size_bytes,
            'processing_stage', paged.processing_stage,
            'created_at', paged.created_at,
            'upload_completed_at', paged.upload_completed_at
          )
          order by paged.ordinal
        )
        from paged
      ),
      '[]'::jsonb
    ),
    'page', pagination.effective_page,
    'page_size', 20,
    'total_count', pagination.total_count,
    'total_pages', pagination.total_pages,
    'workspace_total_count', pagination.workspace_total_count
  )
  into response
  from pagination;

  return response;
end;
$$;

revoke all on function public.list_workspace_calls(uuid, text, text, text, integer)
from public, anon, authenticated, service_role;
grant execute on function public.list_workspace_calls(uuid, text, text, text, integer)
to authenticated;

comment on function public.list_workspace_calls(uuid, text, text, text, integer) is
  'Returns one tenant-authorized, literal-search, deterministic page of bounded call-history presentation fields.';

commit;
