-- ============================================================
-- Al-Wahat Farm
-- Rename palm-specific model to generic tree model
-- ============================================================

-- ------------------------------------------------------------
-- Enums and farm/tree core tables
-- ------------------------------------------------------------

alter type public.palm_health_status
rename to tree_health_status;

alter type public.palm_issue_type
rename to tree_issue_type;

alter type public.tree_issue_type
rename value 'palm_damage' to 'tree_damage';

alter type public.palm_issue_status
rename to tree_issue_status;

alter type public.task_type
rename value 'palm_inspection' to 'tree_inspection';

alter table public.farms
drop column palm_variety;

alter table public.palm_trees
rename to trees;

alter table public.palm_qr_codes
rename to tree_qr_codes;

alter table public.palm_issues
rename to tree_issues;

alter table public.trees
rename column palm_number to tree_number;

alter table public.tree_qr_codes
rename column palm_tree_id to tree_id;

alter table public.tree_issues
rename column palm_tree_id to tree_id;

alter table public.tasks
rename column palm_tree_id to tree_id;

alter table public.tasks
rename column related_palm_issue_id to related_tree_issue_id;

alter table public.engineer_reviews
rename column palm_issue_id to tree_issue_id;

alter table public.operation_plan_targets
rename column palm_tree_id to tree_id;

alter table public.trees
add column type text not null default 'medjool';

-- ------------------------------------------------------------
-- Rename supporting database object names for clarity.
-- OIDs, grants, FK dependencies, RLS, and triggers remain intact.
-- ------------------------------------------------------------

alter function private.has_palm_role(uuid, public.farm_role[])
rename to has_tree_role;

alter function private.can_view_palm_issue(uuid)
rename to can_view_tree_issue;

alter function public.validate_palm_tree_hierarchy()
rename to validate_tree_hierarchy;

alter function public.create_palm_qr_code()
rename to create_tree_qr_code;

alter trigger palm_trees_set_updated_at
on public.trees
rename to trees_set_updated_at;

alter trigger palm_trees_validate_hierarchy
on public.trees
rename to trees_validate_hierarchy;

alter trigger palm_trees_create_qr_code
on public.trees
rename to trees_create_qr_code;

alter trigger palm_issues_set_updated_at
on public.tree_issues
rename to tree_issues_set_updated_at;

alter index public.palm_trees_farm_id_idx
rename to trees_farm_id_idx;

alter index public.palm_trees_section_id_idx
rename to trees_section_id_idx;

alter index public.palm_trees_irrigation_zone_id_idx
rename to trees_irrigation_zone_id_idx;

alter index public.palm_trees_tree_code_idx
rename to trees_tree_code_idx;

alter index public.palm_qr_codes_qr_token_idx
rename to tree_qr_codes_qr_token_idx;

alter index public.palm_issues_farm_status_idx
rename to tree_issues_farm_status_idx;

alter index public.palm_issues_palm_tree_id_idx
rename to tree_issues_tree_id_idx;

alter index public.palm_issues_reported_by_idx
rename to tree_issues_reported_by_idx;

alter index public.palm_issues_palm_status_idx
rename to tree_issues_tree_status_idx;

alter index public.tasks_palm_tree_id_idx
rename to tasks_tree_id_idx;

alter index public.tasks_related_palm_issue_id_idx
rename to tasks_related_tree_issue_id_idx;

alter index public.engineer_reviews_palm_issue_id_idx
rename to engineer_reviews_tree_issue_id_idx;

alter index public.operation_plan_targets_one_active_palm_idx
rename to operation_plan_targets_one_active_tree_idx;

alter index public.operation_plan_targets_palm_tree_id_idx
rename to operation_plan_targets_tree_id_idx;

alter policy "palm_trees_select_farm_members"
on public.trees
rename to "trees_select_farm_members";

alter policy "palm_trees_insert_owner_or_engineer"
on public.trees
rename to "trees_insert_owner_or_engineer";

alter policy "palm_trees_update_owner_or_engineer"
on public.trees
rename to "trees_update_owner_or_engineer";

alter policy "palm_trees_delete_owners"
on public.trees
rename to "trees_delete_owners";

alter policy "palm_qr_codes_select_owner_or_engineer"
on public.tree_qr_codes
rename to "tree_qr_codes_select_owner_or_engineer";

alter policy "palm_qr_codes_update_owner_or_engineer"
on public.tree_qr_codes
rename to "tree_qr_codes_update_owner_or_engineer";

alter policy "palm_issues_select_authorized_users"
on public.tree_issues
rename to "tree_issues_select_authorized_users";

-- ------------------------------------------------------------
-- Rebuild functions whose SQL bodies must use tree terminology.
-- ------------------------------------------------------------

drop policy "tree_qr_codes_select_owner_or_engineer"
on public.tree_qr_codes;

drop policy "tree_qr_codes_update_owner_or_engineer"
on public.tree_qr_codes;

drop function private.has_tree_role(uuid, public.farm_role[]);

create or replace function private.has_tree_role(
  p_tree_id uuid,
  p_roles public.farm_role[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.trees t
    join public.farm_memberships fm
      on fm.farm_id = t.farm_id
    where t.id = p_tree_id
      and fm.profile_id = (select auth.uid())
      and fm.is_active = true
      and fm.role = any (p_roles)
  );
$$;

create policy "tree_qr_codes_select_owner_or_engineer"
on public.tree_qr_codes
for select
to authenticated
using (
  (select private.has_tree_role(
    tree_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
);

create policy "tree_qr_codes_update_owner_or_engineer"
on public.tree_qr_codes
for update
to authenticated
using (
  (select private.has_tree_role(
    tree_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
)
with check (
  (select private.has_tree_role(
    tree_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
);

drop policy "tree_issues_select_authorized_users"
on public.tree_issues;

drop function private.can_view_tree_issue(uuid);

create or replace function private.can_view_tree_issue(
  p_tree_issue_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.tree_issues ti
    where ti.id = p_tree_issue_id
      and (
        private.is_operational_manager(ti.farm_id)
        or ti.reported_by_profile_id = (select auth.uid())
        or exists (
          select 1
          from public.tasks t
          join public.task_assignments ta
            on ta.task_id = t.id
          where t.related_tree_issue_id = ti.id
            and ta.assignee_profile_id = (select auth.uid())
            and ta.is_active = true
        )
      )
  );
$$;

create policy "tree_issues_select_authorized_users"
on public.tree_issues
for select
to authenticated
using (
  private.can_view_tree_issue(id)
);

create or replace function public.validate_tree_hierarchy()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.farm_sections s
    where s.id = new.section_id
      and s.farm_id = new.farm_id
  ) then
    raise exception 'The selected section does not belong to this farm'
      using errcode = '23514';
  end if;

  if new.irrigation_zone_id is not null
     and not exists (
       select 1
       from public.irrigation_zones iz
       where iz.id = new.irrigation_zone_id
         and iz.section_id = new.section_id
     ) then
    raise exception 'The selected irrigation zone does not belong to this section'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create or replace function public.create_tree_qr_code()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.tree_qr_codes (tree_id)
  values (new.id)
  on conflict (tree_id) do nothing;

  return new;
end;
$$;

create or replace function public.validate_task_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_issue_tree_id uuid;
begin
  if new.section_id is not null
    and not exists (
      select 1
      from public.farm_sections s
      where s.id = new.section_id
        and s.farm_id = new.farm_id
    ) then
    raise exception 'The selected section does not belong to this farm'
      using errcode = '23514';
  end if;

  if new.irrigation_zone_id is not null
    and not exists (
      select 1
      from public.irrigation_zones iz
      join public.farm_sections s
        on s.id = iz.section_id
      where iz.id = new.irrigation_zone_id
        and s.farm_id = new.farm_id
    ) then
    raise exception 'The selected irrigation zone does not belong to this farm'
      using errcode = '23514';
  end if;

  if new.tree_id is not null
    and not exists (
      select 1
      from public.trees t
      where t.id = new.tree_id
        and t.farm_id = new.farm_id
    ) then
    raise exception 'The selected tree does not belong to this farm'
      using errcode = '23514';
  end if;

  if new.related_tree_issue_id is not null then
    select ti.tree_id
    into v_issue_tree_id
    from public.tree_issues ti
    where ti.id = new.related_tree_issue_id
      and ti.farm_id = new.farm_id;

    if not found then
      raise exception 'The related tree issue does not belong to this farm'
        using errcode = '23514';
    end if;

    if new.tree_id is not null
      and new.tree_id <> v_issue_tree_id then
      raise exception 'The task tree must match the tree on the related issue'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.validate_operation_plan_target_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_farm_id uuid;
begin
  select op.farm_id
  into v_farm_id
  from public.operation_plans op
  where op.id = new.operation_plan_id;

  if not found then
    raise exception 'Operation plan not found'
      using errcode = '23503';
  end if;

  if new.section_id is not null
    and not exists (
      select 1
      from public.farm_sections s
      where s.id = new.section_id
        and s.farm_id = v_farm_id
    ) then
    raise exception 'The selected section does not belong to this plan farm'
      using errcode = '23514';
  end if;

  if new.irrigation_zone_id is not null
    and not exists (
      select 1
      from public.irrigation_zones iz
      join public.farm_sections s
        on s.id = iz.section_id
      where iz.id = new.irrigation_zone_id
        and s.farm_id = v_farm_id
    ) then
    raise exception 'The selected irrigation zone does not belong to this plan farm'
      using errcode = '23514';
  end if;

  if new.tree_id is not null
    and not exists (
      select 1
      from public.trees t
      where t.id = new.tree_id
        and t.farm_id = v_farm_id
    ) then
    raise exception 'The selected tree does not belong to this plan farm'
      using errcode = '23514';
  end if;

  if new.is_active = false
    and new.deactivated_at is null then
    new.deactivated_at = now();
  end if;

  return new;
end;
$$;

-- Drop public RPCs whose names or parameter names are palm-specific.
drop function public.create_farm_with_owner(
  text,
  text,
  numeric,
  text,
  text,
  text
);

drop function public.scan_palm_by_qr(uuid);

drop function public.create_farm_task(
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

drop function public.report_palm_issue(
  uuid,
  public.tree_issue_type,
  public.issue_severity,
  text,
  text
);

create or replace function public.create_farm_with_owner(
  p_name text,
  p_code text,
  p_total_area_m2 numeric default 252000,
  p_timezone text default 'Africa/Cairo',
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_farm_id uuid;
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if nullif(btrim(p_name), '') is null then
    raise exception 'Farm name is required';
  end if;

  if nullif(btrim(p_code), '') is null then
    raise exception 'Farm code is required';
  end if;

  insert into public.farms (
    name,
    code,
    total_area_m2,
    timezone,
    notes
  )
  values (
    btrim(p_name),
    upper(btrim(p_code)),
    p_total_area_m2,
    coalesce(nullif(btrim(p_timezone), ''), 'Africa/Cairo'),
    p_notes
  )
  returning id into v_farm_id;

  insert into public.farm_memberships (
    farm_id,
    profile_id,
    role
  )
  values (
    v_farm_id,
    v_user_id,
    'owner'::public.farm_role
  );

  insert into public.farm_sections (
    farm_id,
    code,
    name,
    sort_order
  )
  select
    v_farm_id,
    section_data.code,
    'Section ' || section_data.code,
    section_data.sort_order
  from (
    values
      ('A', 1),
      ('B', 2),
      ('C', 3),
      ('D', 4),
      ('E', 5),
      ('F', 6),
      ('G', 7),
      ('L', 8),
      ('M', 9),
      ('N', 10),
      ('O', 11),
      ('Q', 12)
  ) as section_data(code, sort_order);

  return v_farm_id;
end;
$$;

create or replace function public.scan_tree_by_qr(
  p_qr_token uuid
)
returns table (
  tree_id uuid,
  farm_id uuid,
  section_id uuid,
  section_code text,
  section_name text,
  irrigation_zone_id uuid,
  tree_code text,
  row_number integer,
  tree_number integer,
  health_status public.tree_health_status,
  type text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    t.id as tree_id,
    t.farm_id,
    t.section_id,
    s.code as section_code,
    s.name as section_name,
    t.irrigation_zone_id,
    t.tree_code,
    t.row_number,
    t.tree_number,
    t.health_status,
    t.type
  from public.tree_qr_codes qr
  join public.trees t
    on t.id = qr.tree_id
  join public.farm_sections s
    on s.id = t.section_id
  where qr.qr_token = p_qr_token
    and qr.is_active = true
    and t.is_active = true
    and exists (
      select 1
      from public.farm_memberships fm
      where fm.farm_id = t.farm_id
        and fm.profile_id = (select auth.uid())
        and fm.is_active = true
    )
  limit 1;
$$;

create or replace function public.create_farm_task(
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
  p_assignee_profile_ids uuid[] default '{}'::uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task_id uuid;
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
    created_by_profile_id
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
    v_actor_id
  )
  returning id into v_task_id;

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

create or replace function public.report_tree_issue(
  p_tree_id uuid,
  p_issue_type public.tree_issue_type,
  p_severity public.issue_severity,
  p_description text default null,
  p_photo_storage_path text default null
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

  v_priority :=
    case p_severity
      when 'urgent' then 'urgent'::public.task_priority
      when 'high' then 'high'::public.task_priority
      when 'medium' then 'medium'::public.task_priority
      else 'low'::public.task_priority
    end;

  insert into public.tree_issues (
    farm_id,
    tree_id,
    issue_type,
    severity,
    status,
    description,
    reported_by_profile_id
  )
  values (
    v_farm_id,
    p_tree_id,
    p_issue_type,
    p_severity,
    'in_review',
    p_description,
    v_actor_id
  )
  returning id into v_issue_id;

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
    tree_issue_id,
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

create or replace function private.replace_operation_plan_targets(
  p_operation_plan_id uuid,
  p_targets jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_targets jsonb := coalesce(p_targets, '[{}]'::jsonb);
  v_target jsonb;
  v_index integer;
  v_non_null_target_count integer;
  v_uuid_pattern text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
begin
  if jsonb_typeof(v_targets) <> 'array' then
    raise exception 'Targets must be a JSON array'
      using errcode = '23514';
  end if;

  if jsonb_array_length(v_targets) = 0 then
    v_targets := '[{}]'::jsonb;
  end if;

  for v_target, v_index in
    select value, ordinality::integer
    from jsonb_array_elements(v_targets) with ordinality
  loop
    if jsonb_typeof(v_target) <> 'object' then
      raise exception 'Target item % must be a JSON object', v_index
        using errcode = '23514';
    end if;

    if exists (
      select 1
      from jsonb_object_keys(v_target) as target_key(key)
      where target_key.key not in (
        'section_id',
        'irrigation_zone_id',
        'tree_id'
      )
    ) then
      raise exception 'Target item % contains unknown keys', v_index
        using errcode = '23514';
    end if;

    if v_target = '{}'::jsonb then
      continue;
    end if;

    v_non_null_target_count :=
      case
        when v_target ? 'section_id'
          and v_target -> 'section_id' <> 'null'::jsonb
          then 1
        else 0
      end
      + case
        when v_target ? 'irrigation_zone_id'
          and v_target -> 'irrigation_zone_id' <> 'null'::jsonb
          then 1
        else 0
      end
      + case
        when v_target ? 'tree_id'
          and v_target -> 'tree_id' <> 'null'::jsonb
          then 1
        else 0
      end;

    if v_non_null_target_count <> 1 then
      raise exception 'Target item % must contain exactly one non-null target ID or be {}', v_index
        using errcode = '23514';
    end if;

    if v_target ? 'section_id'
      and v_target -> 'section_id' <> 'null'::jsonb
      and (
        jsonb_typeof(v_target -> 'section_id') <> 'string'
        or v_target ->> 'section_id' !~ v_uuid_pattern
      ) then
      raise exception 'Target item % has an invalid section_id', v_index
        using errcode = '23514';
    end if;

    if v_target ? 'irrigation_zone_id'
      and v_target -> 'irrigation_zone_id' <> 'null'::jsonb
      and (
        jsonb_typeof(v_target -> 'irrigation_zone_id') <> 'string'
        or v_target ->> 'irrigation_zone_id' !~ v_uuid_pattern
      ) then
      raise exception 'Target item % has an invalid irrigation_zone_id', v_index
        using errcode = '23514';
    end if;

    if v_target ? 'tree_id'
      and v_target -> 'tree_id' <> 'null'::jsonb
      and (
        jsonb_typeof(v_target -> 'tree_id') <> 'string'
        or v_target ->> 'tree_id' !~ v_uuid_pattern
      ) then
      raise exception 'Target item % has an invalid tree_id', v_index
        using errcode = '23514';
    end if;
  end loop;

  with desired_targets as (
    select distinct
      parsed.section_id,
      parsed.irrigation_zone_id,
      parsed.tree_id
    from jsonb_to_recordset(v_targets) as parsed(
      section_id uuid,
      irrigation_zone_id uuid,
      tree_id uuid
    )
  )
  update public.operation_plan_targets opt
  set
    is_active = false,
    deactivated_at = coalesce(opt.deactivated_at, now())
  where opt.operation_plan_id = p_operation_plan_id
    and opt.is_active = true
    and not exists (
      select 1
      from desired_targets desired
      where desired.section_id is not distinct from opt.section_id
        and desired.irrigation_zone_id is not distinct from opt.irrigation_zone_id
        and desired.tree_id is not distinct from opt.tree_id
    );

  with desired_targets as (
    select distinct
      parsed.section_id,
      parsed.irrigation_zone_id,
      parsed.tree_id
    from jsonb_to_recordset(v_targets) as parsed(
      section_id uuid,
      irrigation_zone_id uuid,
      tree_id uuid
    )
  ),
  inactive_matches as (
    select distinct on (
      desired.section_id,
      desired.irrigation_zone_id,
      desired.tree_id
    )
      opt.id
    from desired_targets desired
    join public.operation_plan_targets opt
      on opt.operation_plan_id = p_operation_plan_id
     and opt.is_active = false
     and desired.section_id is not distinct from opt.section_id
     and desired.irrigation_zone_id is not distinct from opt.irrigation_zone_id
     and desired.tree_id is not distinct from opt.tree_id
    where not exists (
      select 1
      from public.operation_plan_targets active_opt
      where active_opt.operation_plan_id = p_operation_plan_id
        and active_opt.is_active = true
        and desired.section_id is not distinct from active_opt.section_id
        and desired.irrigation_zone_id is not distinct from active_opt.irrigation_zone_id
        and desired.tree_id is not distinct from active_opt.tree_id
    )
    order by
      desired.section_id,
      desired.irrigation_zone_id,
      desired.tree_id,
      opt.created_at desc,
      opt.id
  )
  update public.operation_plan_targets opt
  set
    is_active = true,
    deactivated_at = null
  from inactive_matches
  where opt.id = inactive_matches.id;

  with desired_targets as (
    select distinct
      parsed.section_id,
      parsed.irrigation_zone_id,
      parsed.tree_id
    from jsonb_to_recordset(v_targets) as parsed(
      section_id uuid,
      irrigation_zone_id uuid,
      tree_id uuid
    )
  )
  insert into public.operation_plan_targets (
    operation_plan_id,
    section_id,
    irrigation_zone_id,
    tree_id
  )
  select distinct
    p_operation_plan_id,
    desired.section_id,
    desired.irrigation_zone_id,
    desired.tree_id
  from desired_targets desired
  where not exists (
    select 1
    from public.operation_plan_targets opt
    where opt.operation_plan_id = p_operation_plan_id
      and opt.is_active = true
      and desired.section_id is not distinct from opt.section_id
      and desired.irrigation_zone_id is not distinct from opt.irrigation_zone_id
      and desired.tree_id is not distinct from opt.tree_id
  )
  and not exists (
    select 1
    from public.operation_plan_targets opt
    where opt.operation_plan_id = p_operation_plan_id
      and opt.is_active = false
      and desired.section_id is not distinct from opt.section_id
      and desired.irrigation_zone_id is not distinct from opt.irrigation_zone_id
      and desired.tree_id is not distinct from opt.tree_id
  );

  if not exists (
    select 1
    from public.operation_plan_targets opt
    where opt.operation_plan_id = p_operation_plan_id
      and opt.is_active = true
  ) then
    insert into public.operation_plan_targets (operation_plan_id)
    values (p_operation_plan_id);
  end if;
end;
$$;

create or replace function public.generate_operation_tasks_for_date(
  p_farm_id uuid,
  p_operation_date date
)
returns table (
  operation_plan_run_id uuid,
  generated_task_id uuid
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_plan record;
  v_target record;
  v_run_id uuid;
  v_task_id uuid;
  v_priority public.task_priority;
begin
  if v_actor_id is not null
    and not private.is_operational_manager(p_farm_id) then
    raise exception 'Only the owner or agricultural engineer can generate operation tasks'
      using errcode = '42501';
  end if;

  for v_plan in
    select op.*
    from public.operation_plans op
    where op.farm_id = p_farm_id
      and op.status = 'active'
      and op.starts_on <= p_operation_date
      and (op.ends_on is null or op.ends_on >= p_operation_date)
      and (
        (op.schedule_type = 'once' and op.starts_on = p_operation_date)
        or op.schedule_type = 'daily'
        or (
          op.schedule_type = 'weekly'
          and extract(isodow from p_operation_date)::smallint = any (op.days_of_week)
        )
      )
  loop
    for v_target in
      select opt.*
      from public.operation_plan_targets opt
      where opt.operation_plan_id = v_plan.id
        and opt.is_active = true
    loop
      v_run_id := null;
      v_task_id := null;

      insert into public.operation_plan_runs (
        operation_plan_id,
        operation_plan_target_id,
        operation_date
      )
      values (
        v_plan.id,
        v_target.id,
        p_operation_date
      )
      on conflict (
        operation_plan_id,
        operation_plan_target_id,
        operation_date
      )
      do update
      set generated_at = public.operation_plan_runs.generated_at
      where public.operation_plan_runs.generated_task_id is null
      returning
        public.operation_plan_runs.id,
        public.operation_plan_runs.generated_task_id
      into
        v_run_id,
        v_task_id;

      if v_run_id is not null and v_task_id is null then
        v_priority :=
          case v_plan.instructions ->> 'priority'
            when 'low' then 'low'::public.task_priority
            when 'high' then 'high'::public.task_priority
            when 'urgent' then 'urgent'::public.task_priority
            else 'medium'::public.task_priority
          end;

        insert into public.tasks (
          farm_id,
          section_id,
          irrigation_zone_id,
          tree_id,
          task_type,
          title,
          description,
          priority,
          status,
          scheduled_for,
          planned_start_time,
          planned_duration_minutes,
          instructions,
          created_by_profile_id
        )
        values (
          v_plan.farm_id,
          v_target.section_id,
          v_target.irrigation_zone_id,
          v_target.tree_id,
          v_plan.operation_type::text::public.task_type,
          v_plan.title,
          v_plan.description,
          v_priority,
          'draft',
          p_operation_date,
          v_plan.scheduled_start_time,
          v_plan.planned_duration_minutes,
          v_plan.instructions || jsonb_build_object(
            'operation_plan_id',
            v_plan.id,
            'operation_plan_target_id',
            v_target.id,
            'operation_plan_run_id',
            v_run_id
          ),
          v_plan.created_by_profile_id
        )
        returning id into v_task_id;

        update public.operation_plan_runs
        set
          generated_task_id = v_task_id,
          generated_at = now()
        where id = v_run_id;

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
          v_plan.created_by_profile_id,
          'created',
          'draft',
          'Generated from agricultural operation plan',
          jsonb_build_object(
            'operation_plan_id',
            v_plan.id,
            'operation_plan_target_id',
            v_target.id,
            'operation_plan_run_id',
            v_run_id,
            'operation_date',
            p_operation_date
          )
        );

        operation_plan_run_id := v_run_id;
        generated_task_id := v_task_id;
        return next;
      end if;
    end loop;
  end loop;
end;
$$;

create or replace function public.get_operation_plan_calendar(
  p_farm_id uuid,
  p_start_date date,
  p_end_date date
)
returns table (
  operation_plan_id uuid,
  operation_plan_target_id uuid,
  operation_date date,
  generated_task_id uuid,
  generated_task_status public.task_status,
  operation_type public.operation_plan_type,
  title text,
  status public.operation_plan_status,
  schedule_type public.operation_schedule_type,
  target jsonb
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    op.id as operation_plan_id,
    opt.id as operation_plan_target_id,
    calendar.operation_date::date,
    opr.generated_task_id,
    t.status as generated_task_status,
    op.operation_type,
    op.title,
    op.status,
    op.schedule_type,
    jsonb_build_object(
      'section_id',
      opt.section_id,
      'irrigation_zone_id',
      opt.irrigation_zone_id,
      'tree_id',
      opt.tree_id,
      'is_farm_wide',
      opt.section_id is null
        and opt.irrigation_zone_id is null
        and opt.tree_id is null
    ) as target
  from public.operation_plans op
  join public.operation_plan_targets opt
    on opt.operation_plan_id = op.id
   and opt.is_active = true
  cross join lateral generate_series(
    p_start_date,
    p_end_date,
    interval '1 day'
  ) as calendar(operation_date)
  left join public.operation_plan_runs opr
    on opr.operation_plan_id = op.id
   and opr.operation_plan_target_id = opt.id
   and opr.operation_date = calendar.operation_date::date
  left join public.tasks t
    on t.id = opr.generated_task_id
  where op.farm_id = p_farm_id
    and private.is_operational_manager(op.farm_id)
    and op.status <> 'archived'
    and p_end_date >= p_start_date
    and op.starts_on <= calendar.operation_date::date
    and (op.ends_on is null or op.ends_on >= calendar.operation_date::date)
    and (
      (op.schedule_type = 'once' and op.starts_on = calendar.operation_date::date)
      or op.schedule_type = 'daily'
      or (
        op.schedule_type = 'weekly'
        and extract(isodow from calendar.operation_date)::smallint = any (op.days_of_week)
      )
    );
$$;

-- ------------------------------------------------------------
-- Grants and table privileges using new names.
-- ------------------------------------------------------------

revoke all on function private.has_tree_role(uuid, public.farm_role[])
from public, anon;

revoke all on function private.can_view_tree_issue(uuid)
from public, anon;

grant execute on function private.has_tree_role(uuid, public.farm_role[])
to authenticated;

grant execute on function private.can_view_tree_issue(uuid)
to authenticated;

revoke all on table
  public.trees,
  public.tree_qr_codes
from anon;

revoke all on table
  public.trees,
  public.tree_qr_codes
from authenticated;

grant select, insert, update, delete
on public.trees to authenticated;

grant select, update
on public.tree_qr_codes to authenticated;

grant all on table
  public.trees,
  public.tree_qr_codes,
  public.tree_issues
to service_role;

revoke all on function public.create_farm_with_owner(
  text,
  text,
  numeric,
  text,
  text
) from public, anon;

revoke all on function public.scan_tree_by_qr(uuid)
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

revoke all on function public.report_tree_issue(
  uuid,
  public.tree_issue_type,
  public.issue_severity,
  text,
  text
) from public, anon;

grant execute on function public.create_farm_with_owner(
  text,
  text,
  numeric,
  text,
  text
) to authenticated, service_role;

grant execute on function public.scan_tree_by_qr(uuid)
to authenticated, service_role;

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

grant execute on function public.report_tree_issue(
  uuid,
  public.tree_issue_type,
  public.issue_severity,
  text,
  text
) to authenticated, service_role;
