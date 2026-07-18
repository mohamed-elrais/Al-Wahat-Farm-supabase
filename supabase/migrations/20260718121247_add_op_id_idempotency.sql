-- ============================================================
-- Al-Wahat Farm
-- Client operation IDs for offline mutation idempotency
-- ============================================================

alter table public.tasks
add column if not exists client_operation_id uuid;

alter table public.tree_issues
add column if not exists client_operation_id uuid;

alter table public.engineer_reviews
add column if not exists client_operation_id uuid;

create unique index if not exists tasks_client_operation_id_key
  on public.tasks (client_operation_id)
  where client_operation_id is not null;

create unique index if not exists tree_issues_client_operation_id_key
  on public.tree_issues (client_operation_id)
  where client_operation_id is not null;

create unique index if not exists engineer_reviews_client_operation_id_key
  on public.engineer_reviews (client_operation_id)
  where client_operation_id is not null;

create table if not exists private.applied_operations (
  op_id uuid primary key,
  applied_at timestamptz not null default now()
);

alter table private.applied_operations enable row level security;

revoke all on table private.applied_operations
from public, anon, authenticated;

grant all on table private.applied_operations
to service_role;

create policy "applied_operations_service_role_all"
on private.applied_operations
for all
to service_role
using (true)
with check (true);

-- Adding a parameter changes function identity. Remove each old signature so
-- PostgREST sees one unambiguous RPC with the new trailing optional argument.
drop function if exists public.create_farm_task(
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
);

create function public.create_farm_task(
  p_farm_id uuid,
  p_task_type public.task_type,
  p_title text,
  p_description text default null,
  p_section_id uuid default null,
  p_irrigation_zone_id uuid default null,
  p_tree_id uuid default null,
  p_scheduled_for date default null,
  p_planned_start_time time default null,
  p_planned_duration_minutes integer default null,
  p_due_at timestamptz default null,
  p_priority public.task_priority default 'medium',
  p_instructions jsonb default '{}'::jsonb,
  p_requires_engineer_review boolean default false,
  p_related_tree_issue_id uuid default null,
  p_assignee_profile_ids uuid[] default '{}'::uuid[],
  p_op_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task_id uuid;
  v_existing_farm_id uuid;
  v_existing_actor_id uuid;
  v_actor_id uuid := auth.uid();
  v_initial_status public.task_status;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if not private.is_operational_manager(p_farm_id) then
    raise exception 'Only the owner or agricultural engineer can create tasks'
      using errcode = '42501';
  end if;

  if p_op_id is not null then
    select t.id, t.farm_id, t.created_by_profile_id
    into v_task_id, v_existing_farm_id, v_existing_actor_id
    from public.tasks t
    where t.client_operation_id = p_op_id;

    if found then
      if v_existing_farm_id is distinct from p_farm_id
        or v_existing_actor_id is distinct from v_actor_id then
        raise exception 'Operation ID is already associated with a different task operation'
          using errcode = '23514';
      end if;

      return v_task_id;
    end if;
  end if;

  if nullif(trim(p_title), '') is null then
    raise exception 'Task title is required'
      using errcode = '23514';
  end if;

  perform private.assert_assignable_profiles(
    p_farm_id,
    p_assignee_profile_ids
  );

  v_initial_status :=
    case
      when cardinality(p_assignee_profile_ids) > 0
        then 'assigned'::public.task_status
      else 'draft'::public.task_status
    end;

  begin
    insert into public.tasks (
      farm_id,
      section_id,
      irrigation_zone_id,
      tree_id,
      related_tree_issue_id,
      task_type,
      title,
      description,
      priority,
      status,
      scheduled_for,
      planned_start_time,
      planned_duration_minutes,
      due_at,
      instructions,
      requires_engineer_review,
      created_by_profile_id,
      client_operation_id
    )
    values (
      p_farm_id,
      p_section_id,
      p_irrigation_zone_id,
      p_tree_id,
      p_related_tree_issue_id,
      p_task_type,
      trim(p_title),
      p_description,
      p_priority,
      v_initial_status,
      p_scheduled_for,
      p_planned_start_time,
      p_planned_duration_minutes,
      p_due_at,
      coalesce(p_instructions, '{}'::jsonb),
      coalesce(p_requires_engineer_review, false),
      v_actor_id,
      p_op_id
    )
    returning id into v_task_id;
  exception
    when unique_violation then
      if p_op_id is null then
        raise;
      end if;

      select t.id, t.farm_id, t.created_by_profile_id
      into v_task_id, v_existing_farm_id, v_existing_actor_id
      from public.tasks t
      where t.client_operation_id = p_op_id;

      if not found
        or v_existing_farm_id is distinct from p_farm_id
        or v_existing_actor_id is distinct from v_actor_id then
        raise exception 'Operation ID is already associated with a different task operation'
          using errcode = '23514';
      end if;

      return v_task_id;
  end;

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
    v_initial_status,
    p_description,
    jsonb_build_object(
      'task_type',
      p_task_type::text,
      'priority',
      p_priority::text
    )
  );

  if cardinality(p_assignee_profile_ids) > 0 then
    insert into public.task_assignments (
      task_id,
      assignee_profile_id,
      assigned_by_profile_id
    )
    select
      v_task_id,
      assignee.profile_id,
      v_actor_id
    from (
      select distinct unnest(p_assignee_profile_ids) as profile_id
    ) assignee;

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
      'assigned',
      v_initial_status,
      jsonb_build_object(
        'assignee_profile_ids',
        p_assignee_profile_ids
      )
    );
  end if;

  return v_task_id;
end;
$$;

drop function if exists public.report_tree_issue(
  uuid,
  public.tree_issue_type,
  public.issue_severity,
  text,
  text
);

create function public.report_tree_issue(
  p_tree_id uuid,
  p_issue_type public.tree_issue_type,
  p_severity public.issue_severity,
  p_description text default null,
  p_photo_storage_path text default null,
  p_op_id uuid default null
)
returns table (
  tree_issue_id uuid,
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
  v_existing_tree_id uuid;
  v_existing_actor_id uuid;
  v_photo_activity_log_id uuid;
  v_priority public.task_priority;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  select farm_id
  into v_farm_id
  from public.trees
  where id = p_tree_id
    and is_active = true;

  if not found then
    raise exception 'Tree not found or inactive'
      using errcode = 'P0002';
  end if;

  if not private.is_operational_farm_member(v_farm_id) then
    raise exception 'You do not have access to this farm'
      using errcode = '42501';
  end if;

  if p_op_id is not null then
    select
      ti.id,
      ti.linked_task_id,
      ti.tree_id,
      ti.reported_by_profile_id
    into
      v_issue_id,
      v_task_id,
      v_existing_tree_id,
      v_existing_actor_id
    from public.tree_issues ti
    where ti.client_operation_id = p_op_id;

    if found then
      if v_existing_tree_id is distinct from p_tree_id
        or v_existing_actor_id is distinct from v_actor_id then
        raise exception 'Operation ID is already associated with a different tree issue operation'
          using errcode = '23514';
      end if;

      if v_task_id is null then
        raise exception 'Applied tree issue operation is missing its linked review task'
          using errcode = 'P0002';
      end if;

      return query select v_issue_id, v_task_id;
      return;
    end if;
  end if;

  v_priority :=
    case p_severity
      when 'urgent' then 'urgent'::public.task_priority
      when 'high' then 'high'::public.task_priority
      when 'medium' then 'medium'::public.task_priority
      else 'low'::public.task_priority
    end;

  begin
    insert into public.tree_issues (
      farm_id,
      tree_id,
      issue_type,
      severity,
      status,
      description,
      reported_by_profile_id,
      client_operation_id
    )
    values (
      v_farm_id,
      p_tree_id,
      p_issue_type,
      p_severity,
      'in_review',
      p_description,
      v_actor_id,
      p_op_id
    )
    returning id into v_issue_id;
  exception
    when unique_violation then
      if p_op_id is null then
        raise;
      end if;

      select
        ti.id,
        ti.linked_task_id,
        ti.tree_id,
        ti.reported_by_profile_id
      into
        v_issue_id,
        v_task_id,
        v_existing_tree_id,
        v_existing_actor_id
      from public.tree_issues ti
      where ti.client_operation_id = p_op_id;

      if not found
        or v_existing_tree_id is distinct from p_tree_id
        or v_existing_actor_id is distinct from v_actor_id then
        raise exception 'Operation ID is already associated with a different tree issue operation'
          using errcode = '23514';
      end if;

      if v_task_id is null then
        raise exception 'Applied tree issue operation is missing its linked review task'
          using errcode = 'P0002';
      end if;

      return query select v_issue_id, v_task_id;
      return;
  end;

  insert into public.tasks (
    farm_id,
    tree_id,
    related_tree_issue_id,
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
    p_tree_id,
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

  update public.tree_issues
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
      'tree_issue_id',
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

drop function if exists public.review_task(
  uuid,
  public.engineer_review_decision,
  text,
  text
);

create function public.review_task(
  p_task_id uuid,
  p_decision public.engineer_review_decision,
  p_notes text default null,
  p_photo_storage_path text default null,
  p_op_id uuid default null
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
  v_existing_task_id uuid;
  v_existing_actor_id uuid;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  select
    farm_id,
    status,
    related_tree_issue_id
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

  if p_op_id is not null then
    select er.id, er.task_id, er.reviewer_profile_id
    into v_review_id, v_existing_task_id, v_existing_actor_id
    from public.engineer_reviews er
    where er.client_operation_id = p_op_id;

    if found then
      if v_existing_task_id is distinct from p_task_id
        or v_existing_actor_id is distinct from v_actor_id then
        raise exception 'Operation ID is already associated with a different task review operation'
          using errcode = '23514';
      end if;

      return v_review_id;
    end if;
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

  begin
    insert into public.engineer_reviews (
      task_id,
      tree_issue_id,
      reviewer_profile_id,
      decision,
      notes,
      client_operation_id
    )
    values (
      p_task_id,
      v_issue_id,
      v_actor_id,
      p_decision,
      p_notes,
      p_op_id
    )
    returning id into v_review_id;
  exception
    when unique_violation then
      if p_op_id is null then
        raise;
      end if;

      select er.id, er.task_id, er.reviewer_profile_id
      into v_review_id, v_existing_task_id, v_existing_actor_id
      from public.engineer_reviews er
      where er.client_operation_id = p_op_id;

      if not found
        or v_existing_task_id is distinct from p_task_id
        or v_existing_actor_id is distinct from v_actor_id then
        raise exception 'Operation ID is already associated with a different task review operation'
          using errcode = '23514';
      end if;

      return v_review_id;
  end;

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
    update public.tree_issues
    set
      status = case
        when p_decision = 'approved'
          then 'resolved'::public.tree_issue_status
        else 'in_review'::public.tree_issue_status
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

drop function if exists public.set_task_assignments(uuid, uuid[]);

create function public.set_task_assignments(
  p_task_id uuid,
  p_assignee_profile_ids uuid[],
  p_op_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_farm_id uuid;
  v_old_status public.task_status;
  v_new_status public.task_status;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  select
    t.farm_id,
    t.status
  into
    v_farm_id,
    v_old_status
  from public.tasks t
  where t.id = p_task_id
  for update;

  if not found then
    raise exception 'Task not found'
      using errcode = 'P0002';
  end if;

  if not private.is_operational_manager(v_farm_id) then
    raise exception 'Only the owner or agricultural engineer can assign tasks'
      using errcode = '42501';
  end if;

  if p_op_id is not null then
    insert into private.applied_operations (op_id)
    values (p_op_id)
    on conflict (op_id) do nothing;

    if not found then
      return;
    end if;
  end if;

  if v_old_status = any (
    array[
      'completed',
      'approved',
      'cancelled'
    ]::public.task_status[]
  ) then
    raise exception 'Assignments cannot be changed after a task is closed'
      using errcode = '23514';
  end if;

  perform private.assert_assignable_profiles(
    v_farm_id,
    p_assignee_profile_ids
  );

  update public.task_assignments
  set
    is_active = false,
    unassigned_at = now()
  where task_id = p_task_id
    and is_active = true;

  if cardinality(p_assignee_profile_ids) > 0 then
    insert into public.task_assignments (
      task_id,
      assignee_profile_id,
      assigned_by_profile_id
    )
    select
      p_task_id,
      assignee.profile_id,
      v_actor_id
    from (
      select distinct unnest(p_assignee_profile_ids) as profile_id
    ) assignee;

    v_new_status :=
      case
        when v_old_status = 'needs_engineer_review'
          then 'needs_engineer_review'::public.task_status
        else 'assigned'::public.task_status
      end;
  else
    v_new_status := 'draft'::public.task_status;
  end if;

  update public.tasks
  set status = v_new_status
  where id = p_task_id;

  insert into public.task_activity_log (
    task_id,
    actor_profile_id,
    action,
    old_status,
    new_status,
    metadata
  )
  values (
    p_task_id,
    v_actor_id,
    case
      when cardinality(p_assignee_profile_ids) > 0
        then 'assigned'::public.task_activity_action
      else 'unassigned'::public.task_activity_action
    end,
    v_old_status,
    v_new_status,
    jsonb_build_object(
      'assignee_profile_ids',
      coalesce(p_assignee_profile_ids, '{}'::uuid[])
    )
  );
end;
$$;

drop function if exists public.start_assigned_task(uuid, text);

create function public.start_assigned_task(
  p_task_id uuid,
  p_note text default null,
  p_op_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_old_status public.task_status;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if not private.can_operate_task(p_task_id) then
    raise exception 'You are not assigned to this task'
      using errcode = '42501';
  end if;

  select status
  into v_old_status
  from public.tasks
  where id = p_task_id
  for update;

  if p_op_id is not null then
    insert into private.applied_operations (op_id)
    values (p_op_id)
    on conflict (op_id) do nothing;

    if not found then
      return;
    end if;
  end if;

  if v_old_status not in (
    'assigned',
    'returned'
  ) then
    raise exception 'Only assigned or returned tasks can be started'
      using errcode = '23514';
  end if;

  update public.tasks
  set status = 'in_progress'
  where id = p_task_id;

  insert into public.task_activity_log (
    task_id,
    actor_profile_id,
    action,
    old_status,
    new_status,
    note
  )
  values (
    p_task_id,
    v_actor_id,
    'started',
    v_old_status,
    'in_progress',
    p_note
  );
end;
$$;

drop function if exists public.complete_task(uuid, text, boolean);

create function public.complete_task(
  p_task_id uuid,
  p_note text default null,
  p_requires_engineer_review boolean default false,
  p_op_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_old_status public.task_status;
  v_task_requires_review boolean;
  v_new_status public.task_status;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if not private.can_operate_task(p_task_id) then
    raise exception 'You are not assigned to this task'
      using errcode = '42501';
  end if;

  select
    status,
    requires_engineer_review
  into
    v_old_status,
    v_task_requires_review
  from public.tasks
  where id = p_task_id
  for update;

  if p_op_id is not null then
    insert into private.applied_operations (op_id)
    values (p_op_id)
    on conflict (op_id) do nothing;

    if not found then
      return;
    end if;
  end if;

  if v_old_status not in (
    'assigned',
    'in_progress',
    'returned'
  ) then
    raise exception 'This task cannot be completed from its current status'
      using errcode = '23514';
  end if;

  v_new_status :=
    case
      when coalesce(p_requires_engineer_review, false)
        or v_task_requires_review
        then 'needs_engineer_review'::public.task_status
      else 'completed'::public.task_status
    end;

  update public.tasks
  set
    status = v_new_status,
    completed_by_profile_id = v_actor_id,
    completed_at = now()
  where id = p_task_id;

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
      when v_new_status = 'needs_engineer_review'
        then 'flagged_for_review'::public.task_activity_action
      else 'completed'::public.task_activity_action
    end,
    v_old_status,
    v_new_status,
    p_note,
    jsonb_build_object(
      'requires_engineer_review',
      v_new_status = 'needs_engineer_review'
    )
  );
end;
$$;

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
  uuid[],
  uuid
) from public, anon;

revoke all on function public.report_tree_issue(
  uuid,
  public.tree_issue_type,
  public.issue_severity,
  text,
  text,
  uuid
) from public, anon;

revoke all on function public.review_task(
  uuid,
  public.engineer_review_decision,
  text,
  text,
  uuid
) from public, anon;

revoke all on function public.set_task_assignments(uuid, uuid[], uuid)
from public, anon;

revoke all on function public.start_assigned_task(uuid, text, uuid)
from public, anon;

revoke all on function public.complete_task(uuid, text, boolean, uuid)
from public, anon;

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
  uuid[],
  uuid
) to authenticated, service_role;

grant execute on function public.report_tree_issue(
  uuid,
  public.tree_issue_type,
  public.issue_severity,
  text,
  text,
  uuid
) to authenticated, service_role;

grant execute on function public.review_task(
  uuid,
  public.engineer_review_decision,
  text,
  text,
  uuid
) to authenticated, service_role;

grant execute on function public.set_task_assignments(uuid, uuid[], uuid)
to authenticated, service_role;

grant execute on function public.start_assigned_task(uuid, text, uuid)
to authenticated, service_role;

grant execute on function public.complete_task(uuid, text, boolean, uuid)
to authenticated, service_role;
