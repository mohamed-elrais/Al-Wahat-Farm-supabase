-- ============================================================
-- Al-Wahat Farm
-- Field operations workflow hardening
--
-- This migration intentionally leaves earlier migrations intact.
-- It tightens the workflow created by the existing local migration
-- and aligns RPC/photo permissions with the operational workflow.
-- ============================================================

create index if not exists palm_issues_palm_status_idx
  on public.palm_issues (palm_tree_id, status);

create index if not exists tasks_scheduled_status_idx
  on public.tasks (scheduled_for, status);

create index if not exists task_assignments_assignee_active_task_idx
  on public.task_assignments (assignee_profile_id, is_active, task_id);

-- ------------------------------------------------------------
-- Private helper: RPC photo paths must match
-- {auth_user_uuid}/{farm_id}/{task_id}/{filename}
-- ------------------------------------------------------------

create or replace function private.is_valid_task_photo_path(
  p_task_id uuid,
  p_storage_path text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.tasks t
    where t.id = p_task_id
      and p_storage_path like
        (select auth.uid())::text || '/' || t.farm_id::text || '/' || t.id::text || '/%'
  );
$$;

revoke all on function private.is_valid_task_photo_path(uuid, text)
from public, anon;

grant execute on function private.is_valid_task_photo_path(uuid, text)
to authenticated;

-- ------------------------------------------------------------
-- Replace report_palm_issue to:
-- - create a created activity entry for the generated review task;
-- - validate optional photo paths against user/farm/task;
-- - record optional issue photos with a photo_added activity row.
-- ------------------------------------------------------------

create or replace function public.report_palm_issue(
  p_palm_tree_id uuid,
  p_issue_type public.palm_issue_type,
  p_severity public.issue_severity,
  p_description text default null,
  p_photo_storage_path text default null
)
returns table (
  palm_issue_id uuid,
  task_id uuid
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_farm_id uuid;
  v_issue_id uuid;
  v_task_id uuid;
  v_photo_activity_log_id uuid;
  v_priority public.task_priority;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  select farm_id
  into v_farm_id
  from public.palm_trees
  where id = p_palm_tree_id
    and is_active = true;

  if not found then
    raise exception 'Palm tree not found or inactive'
      using errcode = 'P0002';
  end if;

  if not private.is_operational_farm_member(v_farm_id) then
    raise exception 'You do not have access to this farm'
      using errcode = '42501';
  end if;

  v_priority :=
    case p_severity
      when 'urgent' then 'urgent'::public.task_priority
      when 'high' then 'high'::public.task_priority
      when 'medium' then 'medium'::public.task_priority
      else 'low'::public.task_priority
    end;

  insert into public.palm_issues (
    farm_id,
    palm_tree_id,
    issue_type,
    severity,
    status,
    description,
    reported_by_profile_id
  )
  values (
    v_farm_id,
    p_palm_tree_id,
    p_issue_type,
    p_severity,
    'in_review',
    p_description,
    v_actor_id
  )
  returning id into v_issue_id;

  insert into public.tasks (
    farm_id,
    palm_tree_id,
    related_palm_issue_id,
    task_type,
    title,
    description,
    priority,
    status,
    requires_engineer_review,
    created_by_profile_id
  )
  values (
    v_farm_id,
    p_palm_tree_id,
    v_issue_id,
    'engineer_review',
    'Engineer review: ' || initcap(replace(p_issue_type::text, '_', ' ')),
    p_description,
    v_priority,
    'needs_engineer_review',
    true,
    v_actor_id
  )
  returning id into v_task_id;

  update public.palm_issues
  set linked_task_id = v_task_id
  where id = v_issue_id;

  insert into public.task_activity_log (
    task_id,
    actor_profile_id,
    action,
    new_status,
    note,
    metadata
  )
  values (
    v_task_id,
    v_actor_id,
    'created',
    'needs_engineer_review',
    p_description,
    jsonb_build_object(
      'palm_issue_id',
      v_issue_id,
      'issue_type',
      p_issue_type::text,
      'severity',
      p_severity::text
    )
  );

  if p_photo_storage_path is not null then
    if not private.is_valid_task_photo_path(v_task_id, p_photo_storage_path) then
      raise exception 'Photo path must follow {auth_user_uuid}/{farm_id}/{task_id}/filename'
        using errcode = '23514';
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
        'photo_type',
        'issue',
        'storage_path',
        p_photo_storage_path
      )
    )
    returning id into v_photo_activity_log_id;

    insert into public.task_photos (
      task_id,
      task_activity_log_id,
      storage_path,
      photo_type,
      uploaded_by_profile_id
    )
    values (
      v_task_id,
      v_photo_activity_log_id,
      p_photo_storage_path,
      'issue',
      v_actor_id
    );
  end if;

  return query
  select v_issue_id, v_task_id;
end;
$$;

-- ------------------------------------------------------------
-- Replace review_task to enforce scoped review-photo paths and
-- log follow-up reviews distinctly.
-- ------------------------------------------------------------

create or replace function public.review_task(
  p_task_id uuid,
  p_decision public.engineer_review_decision,
  p_notes text default null,
  p_photo_storage_path text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_farm_id uuid;
  v_old_status public.task_status;
  v_new_status public.task_status;
  v_issue_id uuid;
  v_review_id uuid;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  select
    farm_id,
    status,
    related_palm_issue_id
  into
    v_farm_id,
    v_old_status,
    v_issue_id
  from public.tasks
  where id = p_task_id
  for update;

  if not found then
    raise exception 'Task not found'
      using errcode = 'P0002';
  end if;

  if not private.is_operational_manager(v_farm_id) then
    raise exception 'Only the owner or agricultural engineer can review tasks'
      using errcode = '42501';
  end if;

  if v_old_status not in (
    'completed',
    'needs_engineer_review'
  ) then
    raise exception 'Only completed or review-needed tasks can be reviewed'
      using errcode = '23514';
  end if;

  if p_photo_storage_path is not null
    and not private.is_valid_task_photo_path(p_task_id, p_photo_storage_path) then
    raise exception 'Photo path must follow {auth_user_uuid}/{farm_id}/{task_id}/filename'
      using errcode = '23514';
  end if;

  v_new_status :=
    case p_decision
      when 'approved' then 'approved'::public.task_status
      when 'returned_for_correction' then 'returned'::public.task_status
      else 'needs_engineer_review'::public.task_status
    end;

  insert into public.engineer_reviews (
    task_id,
    palm_issue_id,
    reviewer_profile_id,
    decision,
    notes
  )
  values (
    p_task_id,
    v_issue_id,
    v_actor_id,
    p_decision,
    p_notes
  )
  returning id into v_review_id;

  update public.tasks
  set
    status = v_new_status,
    approved_by_profile_id = case
      when p_decision = 'approved'
        then v_actor_id
      else null
    end,
    approved_at = case
      when p_decision = 'approved'
        then now()
      else null
    end
  where id = p_task_id;

  if v_issue_id is not null then
    update public.palm_issues
    set
      status = case
        when p_decision = 'approved'
          then 'resolved'::public.palm_issue_status
        else 'in_review'::public.palm_issue_status
      end,
      reviewed_by_profile_id = v_actor_id,
      reviewed_at = now(),
      resolved_by_profile_id = case
        when p_decision = 'approved'
          then v_actor_id
        else null
      end,
      resolved_at = case
        when p_decision = 'approved'
          then now()
        else null
      end,
      resolution_notes = case
        when p_decision = 'approved'
          then p_notes
        else resolution_notes
      end
    where id = v_issue_id;
  end if;

  if p_photo_storage_path is not null then
    insert into public.task_photos (
      task_id,
      engineer_review_id,
      storage_path,
      photo_type,
      uploaded_by_profile_id
    )
    values (
      p_task_id,
      v_review_id,
      p_photo_storage_path,
      'review',
      v_actor_id
    );
  end if;

  insert into public.task_activity_log (
    task_id,
    actor_profile_id,
    action,
    old_status,
    new_status,
    note,
    metadata
  )
  values (
    p_task_id,
    v_actor_id,
    case
      when p_decision = 'approved'
        then 'reviewed_approved'::public.task_activity_action
      else 'reviewed_returned'::public.task_activity_action
    end,
    v_old_status,
    v_new_status,
    p_notes,
    jsonb_build_object(
      'engineer_review_id',
      v_review_id,
      'decision',
      p_decision::text
    )
  );

  return v_review_id;
end;
$$;

-- ------------------------------------------------------------
-- Replace add_task_photo to enforce full scoped storage paths.
-- ------------------------------------------------------------

create or replace function public.add_task_photo(
  p_task_id uuid,
  p_storage_path text,
  p_photo_type public.task_photo_type default 'evidence',
  p_caption text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_photo_id uuid;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if not private.can_operate_task(p_task_id) then
    raise exception 'You are not assigned to this task'
      using errcode = '42501';
  end if;

  if nullif(trim(p_storage_path), '') is null
    or not private.is_valid_task_photo_path(p_task_id, p_storage_path) then
    raise exception 'Photo path must follow {auth_user_uuid}/{farm_id}/{task_id}/filename'
      using errcode = '23514';
  end if;

  insert into public.task_photos (
    task_id,
    storage_path,
    photo_type,
    caption,
    uploaded_by_profile_id
  )
  values (
    p_task_id,
    p_storage_path,
    p_photo_type,
    p_caption,
    v_actor_id
  )
  returning id into v_photo_id;

  insert into public.task_activity_log (
    task_id,
    actor_profile_id,
    action,
    metadata
  )
  values (
    p_task_id,
    v_actor_id,
    'photo_added',
    jsonb_build_object(
      'task_photo_id',
      v_photo_id,
      'photo_type',
      p_photo_type::text
    )
  );

  return v_photo_id;
end;
$$;

-- ------------------------------------------------------------
-- Explicit RPC execute grants.
-- Never grant these workflow RPCs to anon.
-- ------------------------------------------------------------

revoke all on function private.is_valid_task_photo_path(uuid, text)
from public, anon;

revoke all on function public.create_farm_task(
  uuid,
  public.task_type,
  text,
  text,
  uuid,
  uuid,
  uuid,
  date,
  time,
  integer,
  timestamptz,
  public.task_priority,
  jsonb,
  boolean,
  uuid,
  uuid[]
) from public, anon;

revoke all on function public.set_task_assignments(uuid, uuid[])
from public, anon;

revoke all on function public.start_assigned_task(uuid, text)
from public, anon;

revoke all on function public.complete_task(uuid, text, boolean)
from public, anon;

revoke all on function public.report_palm_issue(
  uuid,
  public.palm_issue_type,
  public.issue_severity,
  text,
  text
) from public, anon;

revoke all on function public.review_task(
  uuid,
  public.engineer_review_decision,
  text,
  text
) from public, anon;

revoke all on function public.add_task_photo(
  uuid,
  text,
  public.task_photo_type,
  text
) from public, anon;

grant execute on function private.is_valid_task_photo_path(uuid, text)
to authenticated;

grant execute on function public.create_farm_task(
  uuid,
  public.task_type,
  text,
  text,
  uuid,
  uuid,
  uuid,
  date,
  time,
  integer,
  timestamptz,
  public.task_priority,
  jsonb,
  boolean,
  uuid,
  uuid[]
) to authenticated, service_role;

grant execute on function public.set_task_assignments(uuid, uuid[])
to authenticated, service_role;

grant execute on function public.start_assigned_task(uuid, text)
to authenticated, service_role;

grant execute on function public.complete_task(uuid, text, boolean)
to authenticated, service_role;

grant execute on function public.report_palm_issue(
  uuid,
  public.palm_issue_type,
  public.issue_severity,
  text,
  text
) to authenticated, service_role;

grant execute on function public.review_task(
  uuid,
  public.engineer_review_decision,
  text,
  text
) to authenticated, service_role;

grant execute on function public.add_task_photo(
  uuid,
  text,
  public.task_photo_type,
  text
) to authenticated, service_role;
