-- ============================================================
-- Al-Wahat Farm
-- Add tree issue photo RPC
-- ============================================================

create or replace function public.add_tree_issue_photo(
  p_tree_issue_id uuid,
  p_storage_path text,
  p_caption text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_farm_id uuid;
  v_task_id uuid;
  v_reporter_id uuid;
  v_existing_photo_id uuid;
  v_photo_id uuid;
  v_activity_log_id uuid;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if nullif(trim(p_storage_path), '') is null then
    raise exception 'Photo path must follow {auth_user_uuid}/{farm_id}/{task_id}/filename'
      using errcode = '23514';
  end if;

  select
    ti.farm_id,
    ti.linked_task_id,
    ti.reported_by_profile_id
  into
    v_farm_id,
    v_task_id,
    v_reporter_id
  from public.tree_issues ti
  where ti.id = p_tree_issue_id;

  if not found then
    raise exception 'Tree issue not found'
      using errcode = 'P0002';
  end if;

  if v_task_id is null then
    raise exception 'Tree issue has no linked review task'
      using errcode = '23514';
  end if;

  if not exists (
    select 1
    from public.tasks t
    where t.id = v_task_id
      and t.farm_id = v_farm_id
      and t.related_tree_issue_id = p_tree_issue_id
  ) then
    raise exception 'Linked review task is not valid for this tree issue'
      using errcode = '23514';
  end if;

  if not private.is_operational_farm_member(v_farm_id) then
    raise exception 'You do not have access to this farm'
      using errcode = '42501';
  end if;

  if v_actor_id <> v_reporter_id
    and not private.is_operational_manager(v_farm_id) then
    raise exception 'Only the issue reporter or an operational farm manager can add issue photos'
      using errcode = '42501';
  end if;

  if not private.is_valid_task_photo_path(v_task_id, p_storage_path) then
    raise exception 'Photo path must follow {auth_user_uuid}/{farm_id}/{task_id}/filename'
      using errcode = '23514';
  end if;

  if not exists (
    select 1
    from storage.objects so
    where so.bucket_id = 'farm-evidence'
      and so.name = p_storage_path
  ) then
    raise exception 'Storage object not found in farm-evidence bucket'
      using errcode = 'P0002';
  end if;

  select tp.id
  into v_existing_photo_id
  from public.task_photos tp
  where tp.storage_bucket_id = 'farm-evidence'
    and tp.storage_path = p_storage_path
  for update;

  if found then
    if exists (
      select 1
      from public.task_photos tp
      where tp.id = v_existing_photo_id
        and tp.task_id = v_task_id
        and tp.uploaded_by_profile_id = v_actor_id
        and tp.photo_type = 'issue'
    ) then
      return v_existing_photo_id;
    end if;

    raise exception 'Storage path is already registered to different task evidence'
      using errcode = '23505';
  end if;

  insert into public.task_activity_log (
    task_id,
    actor_profile_id,
    action,
    new_status,
    metadata
  )
  values (
    v_task_id,
    v_actor_id,
    'photo_added',
    'needs_engineer_review',
    jsonb_build_object(
      'tree_issue_id',
      p_tree_issue_id,
      'photo_type',
      'issue',
      'storage_path',
      p_storage_path
    )
  )
  returning id into v_activity_log_id;

  insert into public.task_photos (
    task_id,
    task_activity_log_id,
    storage_path,
    photo_type,
    caption,
    uploaded_by_profile_id
  )
  values (
    v_task_id,
    v_activity_log_id,
    p_storage_path,
    'issue',
    p_caption,
    v_actor_id
  )
  returning id into v_photo_id;

  update public.task_activity_log
  set metadata = metadata || jsonb_build_object('task_photo_id', v_photo_id)
  where id = v_activity_log_id;

  return v_photo_id;
end;
$$;

revoke all on function public.add_tree_issue_photo(uuid, text, text)
from public, anon;

grant execute on function public.add_tree_issue_photo(uuid, text, text)
to authenticated;
