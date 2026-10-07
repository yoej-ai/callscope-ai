begin;

create function public.reconcile_stale_call_uploads(
  p_workspace_id uuid,
  p_limit integer default 20
)
returns table (
  call_id uuid,
  outcome text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_call public.calls%rowtype;
  object_metadata jsonb;
  object_exists boolean;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '28000';
  end if;

  if p_workspace_id is null then
    raise exception 'Workspace is required' using errcode = '22023';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 20 then
    raise exception 'Reconciliation limit must be between 1 and 20'
      using errcode = '22023';
  end if;

  if not private.is_workspace_member(p_workspace_id) then
    return;
  end if;

  for target_call in
    select call.*
    from public.calls as call
    where call.workspace_id = p_workspace_id
      and call.uploaded_by = current_user_id
      and call.status = 'pending_upload'
      and call.created_at <= pg_catalog.now() - interval '4 hours'
    order by call.created_at, call.id
    for update of call skip locked
    limit p_limit
  loop
    select object.metadata
    into object_metadata
    from storage.objects as object
    where object.bucket_id = target_call.storage_bucket
      and object.name = target_call.storage_path
    limit 1;
    object_exists := found;

    if not object_exists then
      delete from public.calls as call
      where call.id = target_call.id
        and call.workspace_id = p_workspace_id
        and call.uploaded_by = current_user_id
        and call.status = 'pending_upload';

      if found then
        call_id := target_call.id;
        outcome := 'deleted';
        return next;
      end if;
    elsif object_metadata is not null
      and object_metadata ? 'size'
      and object_metadata ? 'mimetype'
      and object_metadata ->> 'size' is not null
      and object_metadata ->> 'mimetype' is not null
      and object_metadata ->> 'size' ~ '^[0-9]+$'
      and (object_metadata ->> 'size')::numeric = target_call.size_bytes
      and pg_catalog.lower(object_metadata ->> 'mimetype') = target_call.content_type
      and target_call.storage_bucket = 'call-audio'
    then
      update public.calls as call
      set
        status = 'uploaded',
        upload_completed_at = pg_catalog.now()
      where call.id = target_call.id
        and call.workspace_id = p_workspace_id
        and call.uploaded_by = current_user_id
        and call.status = 'pending_upload';

      if found then
        call_id := target_call.id;
        outcome := 'uploaded';
        return next;
      end if;
    else
      update public.calls as call
      set status = 'failed'
      where call.id = target_call.id
        and call.workspace_id = p_workspace_id
        and call.uploaded_by = current_user_id
        and call.status = 'pending_upload';

      if found then
        call_id := target_call.id;
        outcome := 'failed';
        return next;
      end if;
    end if;
  end loop;
end;
$$;

revoke all on function public.reconcile_stale_call_uploads(uuid, integer) from public;
revoke all on function public.reconcile_stale_call_uploads(uuid, integer) from anon;
grant execute on function public.reconcile_stale_call_uploads(uuid, integer) to authenticated;

comment on function public.reconcile_stale_call_uploads(uuid, integer) is
  'Reconciles a bounded batch of auth.uid() uploads older than four hours without deleting Storage objects.';

commit;
