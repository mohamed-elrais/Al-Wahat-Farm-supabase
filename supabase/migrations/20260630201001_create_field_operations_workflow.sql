-- ============================================================
-- Al-Wahat Farm
-- Field operations workflow:
-- tasks, assignments, activity, photos, palm issues, reviews
-- ============================================================

-- ------------------------------------------------------------
-- 1. Enums
-- ------------------------------------------------------------

create type public.task_type as enum (
  'irrigation',
  'fertilization',
  'harmful_weed_control',
  'dripper_maintenance',
  'palm_inspection',
  'engineer_review',
  'general'
);

create type public.task_status as enum (
  'draft',
  'assigned',
  'in_progress',
  'completed',
  'needs_engineer_review',
  'approved',
  'returned',
  'cancelled'
);

create type public.task_priority as enum (
  'low',
  'medium',
  'high',
  'urgent'
);

create type public.task_activity_action as enum (
  'created',
  'assigned',
  'unassigned',
  'started',
  'completed',
  'flagged_for_review',
  'reviewed_approved',
  'reviewed_returned',
  'commented',
  'cancelled',
  'photo_added'
);

create type public.palm_issue_type as enum (
  'insufficient_irrigation',
  'clogged_dripper',
  'leak_or_dripper_damage',
  'harmful_weed',
  'pest_or_disease',
  'palm_damage',
  'other'
);

create type public.issue_severity as enum (
  'low',
  'medium',
  'high',
  'urgent'
);

create type public.palm_issue_status as enum (
  'open',
  'in_review',
  'resolved',
  'dismissed'
);

create type public.engineer_review_decision as enum (
  'approved',
  'returned_for_correction',
  'follow_up_required'
);

create type public.task_photo_type as enum (
  'before',
  'after',
  'evidence',
  'issue',
  'review'
);

-- ------------------------------------------------------------
-- 2. Palm issues
-- A worker can report a tree-level issue after QR scanning.
-- ------------------------------------------------------------

create table public.palm_issues (
  id uuid primary key default gen_random_uuid(),

  farm_id uuid not null
    references public.farms(id)
    on delete cascade,

  palm_tree_id uuid not null
    references public.palm_trees(id)
    on delete restrict,

  issue_type public.palm_issue_type not null,
  severity public.issue_severity not null default 'medium',

  status public.palm_issue_status not null default 'open',

  description text,

  reported_by_profile_id uuid not null
    references public.profiles(id)
    on delete restrict,

  reported_at timestamptz not null default now(),

  reviewed_by_profile_id uuid
    references public.profiles(id)
    on delete set null,

  reviewed_at timestamptz,

  resolved_by_profile_id uuid
    references public.profiles(id)
    on delete set null,

  resolved_at timestamptz,

  resolution_notes text,

  linked_task_id uuid,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index palm_issues_farm_status_idx
  on public.palm_issues (farm_id, status);

create index palm_issues_palm_tree_id_idx
  on public.palm_issues (palm_tree_id);

create index palm_issues_reported_by_idx
  on public.palm_issues (reported_by_profile_id);

-- ------------------------------------------------------------
-- 3. Tasks
-- A task can target a whole farm, one section, one irrigation
-- zone, or one individual palm.
-- ------------------------------------------------------------

create table public.tasks (
  id uuid primary key default gen_random_uuid(),

  farm_id uuid not null
    references public.farms(id)
    on delete cascade,

  section_id uuid
    references public.farm_sections(id)
    on delete restrict,

  irrigation_zone_id uuid
    references public.irrigation_zones(id)
    on delete restrict,

  palm_tree_id uuid
    references public.palm_trees(id)
    on delete restrict,

  related_palm_issue_id uuid
    references public.palm_issues(id)
    on delete set null,

  task_type public.task_type not null,

  title text not null,
  description text,

  priority public.task_priority not null default 'medium',
  status public.task_status not null default 'draft',

  scheduled_for date,

  planned_start_time time,

  planned_duration_minutes integer,

  due_at timestamptz,

  instructions jsonb not null default '{}'::jsonb,

  requires_engineer_review boolean not null default false,

  created_by_profile_id uuid not null
    references public.profiles(id)
    on delete restrict,

  completed_by_profile_id uuid
    references public.profiles(id)
    on delete set null,

  completed_at timestamptz,

  approved_by_profile_id uuid
    references public.profiles(id)
    on delete set null,

  approved_at timestamptz,

  cancelled_by_profile_id uuid
    references public.profiles(id)
    on delete set null,

  cancelled_at timestamptz,

  cancellation_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint tasks_title_not_blank_check
    check (nullif(trim(title), '') is not null),

  constraint tasks_duration_positive_check
    check (
      planned_duration_minutes is null
      or planned_duration_minutes > 0
    ),

  constraint tasks_instructions_object_check
    check (jsonb_typeof(instructions) = 'object'),

  constraint tasks_only_one_specific_target_check
    check (
      num_nonnulls(
        section_id,
        irrigation_zone_id,
        palm_tree_id
      ) <= 1
    )
);

alter table public.palm_issues
add constraint palm_issues_linked_task_id_fkey
foreign key (linked_task_id)
references public.tasks(id)
on delete set null;

create index tasks_farm_status_date_idx
  on public.tasks (farm_id, status, scheduled_for);

create index tasks_section_id_idx
  on public.tasks (section_id);

create index tasks_irrigation_zone_id_idx
  on public.tasks (irrigation_zone_id);

create index tasks_palm_tree_id_idx
  on public.tasks (palm_tree_id);

create index tasks_related_palm_issue_id_idx
  on public.tasks (related_palm_issue_id);

-- ------------------------------------------------------------
-- 4. Task assignments
-- More than one person can be assigned if needed.
-- Old assignments remain as history with is_active = false.
-- ------------------------------------------------------------

create table public.task_assignments (
  id uuid primary key default gen_random_uuid(),

  task_id uuid not null
    references public.tasks(id)
    on delete cascade,

  assignee_profile_id uuid not null
    references public.profiles(id)
    on delete restrict,

  assigned_by_profile_id uuid not null
    references public.profiles(id)
    on delete restrict,

  assigned_at timestamptz not null default now(),

  is_active boolean not null default true,

  unassigned_at timestamptz,

  created_at timestamptz not null default now()
);

create unique index task_assignments_one_active_assignee_idx
  on public.task_assignments (task_id, assignee_profile_id)
  where is_active = true;

create index task_assignments_active_assignee_idx
  on public.task_assignments (assignee_profile_id, is_active);

create index task_assignments_task_id_idx
  on public.task_assignments (task_id);

-- ------------------------------------------------------------
-- 5. Immutable operational history
-- ------------------------------------------------------------

create table public.task_activity_log (
  id uuid primary key default gen_random_uuid(),

  task_id uuid not null
    references public.tasks(id)
    on delete cascade,

  actor_profile_id uuid not null
    references public.profiles(id)
    on delete restrict,

  action public.task_activity_action not null,

  old_status public.task_status,
  new_status public.task_status,

  note text,

  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),

  constraint task_activity_log_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

create index task_activity_log_task_created_at_idx
  on public.task_activity_log (task_id, created_at desc);

-- ------------------------------------------------------------
-- 6. Engineer reviews
-- A task can receive multiple reviews over time.
-- ------------------------------------------------------------

create table public.engineer_reviews (
  id uuid primary key default gen_random_uuid(),

  task_id uuid not null
    references public.tasks(id)
    on delete cascade,

  palm_issue_id uuid
    references public.palm_issues(id)
    on delete set null,

  reviewer_profile_id uuid not null
    references public.profiles(id)
    on delete restrict,

  decision public.engineer_review_decision not null,

  notes text,

  reviewed_at timestamptz not null default now(),

  created_at timestamptz not null default now()
);

create index engineer_reviews_task_id_idx
  on public.engineer_reviews (task_id, reviewed_at desc);

create index engineer_reviews_palm_issue_id_idx
  on public.engineer_reviews (palm_issue_id);

-- ------------------------------------------------------------
-- 7. Task photo metadata
-- Real files are stored in private Supabase Storage.
-- ------------------------------------------------------------

create table public.task_photos (
  id uuid primary key default gen_random_uuid(),

  task_id uuid not null
    references public.tasks(id)
    on delete cascade,

  task_activity_log_id uuid
    references public.task_activity_log(id)
    on delete set null,

  engineer_review_id uuid
    references public.engineer_reviews(id)
    on delete set null,

  storage_bucket_id text not null default 'farm-evidence',
  storage_path text not null,

  photo_type public.task_photo_type not null default 'evidence',

  caption text,

  uploaded_by_profile_id uuid not null
    references public.profiles(id)
    on delete restrict,

  taken_at timestamptz,

  created_at timestamptz not null default now(),

  constraint task_photos_storage_path_not_blank_check
    check (nullif(trim(storage_path), '') is not null),

  unique (storage_bucket_id, storage_path)
);

create index task_photos_task_id_idx
  on public.task_photos (task_id);

create index task_photos_activity_log_id_idx
  on public.task_photos (task_activity_log_id);

create index task_photos_engineer_review_id_idx
  on public.task_photos (engineer_review_id);

-- ------------------------------------------------------------
-- 8. Updated-at triggers
-- ------------------------------------------------------------

create trigger palm_issues_set_updated_at
before update on public.palm_issues
for each row
execute function public.set_updated_at();

create trigger tasks_set_updated_at
before update on public.tasks
for each row
execute function public.set_updated_at();

-- ------------------------------------------------------------
-- 9. Data-integrity trigger:
-- Confirm task targets belong to the selected farm.
-- ------------------------------------------------------------

create or replace function public.validate_task_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_issue_palm_tree_id uuid;
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

  if new.palm_tree_id is not null
    and not exists (
      select 1
      from public.palm_trees p
      where p.id = new.palm_tree_id
        and p.farm_id = new.farm_id
    ) then
    raise exception 'The selected palm does not belong to this farm'
      using errcode = '23514';
  end if;

  if new.related_palm_issue_id is not null then
    select pi.palm_tree_id
    into v_issue_palm_tree_id
    from public.palm_issues pi
    where pi.id = new.related_palm_issue_id
      and pi.farm_id = new.farm_id;

    if not found then
      raise exception 'The related palm issue does not belong to this farm'
        using errcode = '23514';
    end if;

    if new.palm_tree_id is not null
      and new.palm_tree_id <> v_issue_palm_tree_id then
      raise exception 'The task palm must match the palm on the related issue'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.validate_task_scope()
from public, anon, authenticated;

create trigger tasks_validate_scope
before insert or update of
  farm_id,
  section_id,
  irrigation_zone_id,
  palm_tree_id,
  related_palm_issue_id
on public.tasks
for each row
execute function public.validate_task_scope();

-- ------------------------------------------------------------
-- 10. Photo consistency:
-- Activity/review IDs must belong to the same task.
-- ------------------------------------------------------------

create or replace function public.validate_task_photo_links()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.task_activity_log_id is not null
    and not exists (
      select 1
      from public.task_activity_log tal
      where tal.id = new.task_activity_log_id
        and tal.task_id = new.task_id
    ) then
    raise exception 'The activity log does not belong to this task'
      using errcode = '23514';
  end if;

  if new.engineer_review_id is not null
    and not exists (
      select 1
      from public.engineer_reviews er
      where er.id = new.engineer_review_id
        and er.task_id = new.task_id
    ) then
    raise exception 'The engineer review does not belong to this task'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function public.validate_task_photo_links()
from public, anon, authenticated;

create trigger task_photos_validate_links
before insert or update of
  task_id,
  task_activity_log_id,
  engineer_review_id
on public.task_photos
for each row
execute function public.validate_task_photo_links();

-- ------------------------------------------------------------
-- 11. Private access helpers
-- Used by RLS and workflow functions.
-- ------------------------------------------------------------

create or replace function private.is_operational_farm_member(
  p_farm_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.farm_memberships fm
    where fm.farm_id = p_farm_id
      and fm.profile_id = (select auth.uid())
      and fm.is_active = true
      and fm.role = any (
        array[
          'owner',
          'agricultural_engineer',
          'worker'
        ]::public.farm_role[]
      )
  );
$$;

create or replace function private.is_operational_manager(
  p_farm_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.farm_memberships fm
    where fm.farm_id = p_farm_id
      and fm.profile_id = (select auth.uid())
      and fm.is_active = true
      and fm.role = any (
        array[
          'owner',
          'agricultural_engineer'
        ]::public.farm_role[]
      )
  );
$$;

create or replace function private.is_active_task_assignee(
  p_task_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.task_assignments ta
    where ta.task_id = p_task_id
      and ta.assignee_profile_id = (select auth.uid())
      and ta.is_active = true
  );
$$;

create or replace function private.can_view_task(
  p_task_id uuid
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
      and (
        private.is_operational_manager(t.farm_id)
        or private.is_active_task_assignee(t.id)
      )
  );
$$;

create or replace function private.can_operate_task(
  p_task_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.can_view_task(p_task_id);
$$;

create or replace function private.can_view_palm_issue(
  p_palm_issue_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.palm_issues pi
    where pi.id = p_palm_issue_id
      and (
        private.is_operational_manager(pi.farm_id)
        or pi.reported_by_profile_id = (select auth.uid())
        or exists (
          select 1
          from public.tasks t
          join public.task_assignments ta
            on ta.task_id = t.id
          where t.related_palm_issue_id = pi.id
            and ta.assignee_profile_id = (select auth.uid())
            and ta.is_active = true
        )
      )
  );
$$;

create or replace function private.can_view_task_photo_path(
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
    from public.task_photos tp
    where tp.storage_bucket_id = 'farm-evidence'
      and tp.storage_path = p_storage_path
      and private.can_view_task(tp.task_id)
  );
$$;

create or replace function private.assert_assignable_profiles(
  p_farm_id uuid,
  p_profile_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_profile_ids is null
    or cardinality(p_profile_ids) = 0 then
    return;
  end if;

  if exists (
    select 1
    from unnest(p_profile_ids) as candidate(profile_id)
    where not exists (
      select 1
      from public.farm_memberships fm
      where fm.farm_id = p_farm_id
        and fm.profile_id = candidate.profile_id
        and fm.is_active = true
        and fm.role = any (
          array[
            'owner',
            'agricultural_engineer',
            'worker'
          ]::public.farm_role[]
        )
    )
  ) then
    raise exception 'Every assigned user must be an active operational member of this farm'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function private.is_operational_farm_member(uuid)
from public, anon;

revoke all on function private.is_operational_manager(uuid)
from public, anon;

revoke all on function private.is_active_task_assignee(uuid)
from public, anon;

revoke all on function private.can_view_task(uuid)
from public, anon;

revoke all on function private.can_operate_task(uuid)
from public, anon;

revoke all on function private.can_view_palm_issue(uuid)
from public, anon;

revoke all on function private.can_view_task_photo_path(text)
from public, anon;

revoke all on function private.assert_assignable_profiles(uuid, uuid[])
from public, anon;

grant execute on function private.is_operational_farm_member(uuid)
to authenticated;

grant execute on function private.is_operational_manager(uuid)
to authenticated;

grant execute on function private.is_active_task_assignee(uuid)
to authenticated;

grant execute on function private.can_view_task(uuid)
to authenticated;

grant execute on function private.can_operate_task(uuid)
to authenticated;

grant execute on function private.can_view_palm_issue(uuid)
to authenticated;

grant execute on function private.can_view_task_photo_path(text)
to authenticated;

grant execute on function private.assert_assignable_profiles(uuid, uuid[])
to authenticated;

-- ------------------------------------------------------------
-- 12. Workflow RPC:
-- Create a task and optionally assign workers/engineers.
-- ------------------------------------------------------------

create or replace function public.create_farm_task(
  p_farm_id uuid,
  p_task_type public.task_type,
  p_title text,
  p_description text default null,
  p_section_id uuid default null,
  p_irrigation_zone_id uuid default null,
  p_palm_tree_id uuid default null,
  p_scheduled_for date default null,
  p_planned_start_time time default null,
  p_planned_duration_minutes integer default null,
  p_due_at timestamptz default null,
  p_priority public.task_priority default 'medium',
  p_instructions jsonb default '{}'::jsonb,
  p_requires_engineer_review boolean default false,
  p_related_palm_issue_id uuid default null,
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
    palm_tree_id,
    related_palm_issue_id,
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
    p_palm_tree_id,
    p_related_palm_issue_id,
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

-- ------------------------------------------------------------
-- 13. Workflow RPC:
-- Replace the active assignment list for a task.
-- ------------------------------------------------------------

create or replace function public.set_task_assignments(
  p_task_id uuid,
  p_assignee_profile_ids uuid[]
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

-- ------------------------------------------------------------
-- 14. Workflow RPC:
-- Worker/manager starts an assigned task.
-- ------------------------------------------------------------

create or replace function public.start_assigned_task(
  p_task_id uuid,
  p_note text default null
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

-- ------------------------------------------------------------
-- 15. Workflow RPC:
-- Worker/manager completes a task.
-- ------------------------------------------------------------

create or replace function public.complete_task(
  p_task_id uuid,
  p_note text default null,
  p_requires_engineer_review boolean default false
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

-- ------------------------------------------------------------
-- 16. Workflow RPC:
-- Worker scans a palm and reports an issue.
-- It also creates an engineer-review task automatically.
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

  if p_photo_storage_path is not null
    and p_photo_storage_path not like v_actor_id::text || '/%' then
    raise exception 'Photo path must start with the uploader user ID'
      using errcode = '23514';
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
    'flagged_for_review',
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
    insert into public.task_photos (
      task_id,
      storage_path,
      photo_type,
      uploaded_by_profile_id
    )
    values (
      v_task_id,
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
-- 17. Workflow RPC:
-- Engineer/owner reviews a completed or review-needed task.
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
    and p_photo_storage_path not like v_actor_id::text || '/%' then
    raise exception 'Photo path must start with the uploader user ID'
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
-- 18. Workflow RPC:
-- Attach evidence to an assigned/managed task.
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
    or p_storage_path not like v_actor_id::text || '/%' then
    raise exception 'Photo path must start with the uploader user ID'
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
-- 19. Database grants
-- Clients read through RLS.
-- They write only through the controlled RPC functions above.
-- ------------------------------------------------------------

revoke all on table
  public.tasks,
  public.task_assignments,
  public.task_activity_log,
  public.task_photos,
  public.palm_issues,
  public.engineer_reviews
from anon;

revoke all on table
  public.tasks,
  public.task_assignments,
  public.task_activity_log,
  public.task_photos,
  public.palm_issues,
  public.engineer_reviews
from authenticated;

grant select on table
  public.tasks,
  public.task_assignments,
  public.task_activity_log,
  public.task_photos,
  public.palm_issues,
  public.engineer_reviews
to authenticated;

grant all on table
  public.tasks,
  public.task_assignments,
  public.task_activity_log,
  public.task_photos,
  public.palm_issues,
  public.engineer_reviews
to service_role;

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
) to authenticated;

grant execute on function public.set_task_assignments(uuid, uuid[])
to authenticated;

grant execute on function public.start_assigned_task(uuid, text)
to authenticated;

grant execute on function public.complete_task(uuid, text, boolean)
to authenticated;

grant execute on function public.report_palm_issue(
  uuid,
  public.palm_issue_type,
  public.issue_severity,
  text,
  text
) to authenticated;

grant execute on function public.review_task(
  uuid,
  public.engineer_review_decision,
  text,
  text
) to authenticated;

grant execute on function public.add_task_photo(
  uuid,
  text,
  public.task_photo_type,
  text
) to authenticated;

-- ------------------------------------------------------------
-- 20. Row Level Security
-- ------------------------------------------------------------

alter table public.tasks enable row level security;
alter table public.task_assignments enable row level security;
alter table public.task_activity_log enable row level security;
alter table public.task_photos enable row level security;
alter table public.palm_issues enable row level security;
alter table public.engineer_reviews enable row level security;

create policy "tasks_select_visible_tasks"
on public.tasks
for select
to authenticated
using (
  private.can_view_task(id)
);

create policy "task_assignments_select_visible_task_assignments"
on public.task_assignments
for select
to authenticated
using (
  private.can_view_task(task_id)
);

create policy "task_activity_log_select_visible_task_activity"
on public.task_activity_log
for select
to authenticated
using (
  private.can_view_task(task_id)
);

create policy "task_photos_select_visible_task_photos"
on public.task_photos
for select
to authenticated
using (
  private.can_view_task(task_id)
);

create policy "palm_issues_select_authorized_users"
on public.palm_issues
for select
to authenticated
using (
  private.can_view_palm_issue(id)
);

create policy "engineer_reviews_select_visible_task_reviews"
on public.engineer_reviews
for select
to authenticated
using (
  private.can_view_task(task_id)
);

-- ------------------------------------------------------------
-- 21. Private Supabase Storage bucket for evidence photos
--
-- Required upload path:
-- {auth_user_uuid}/{farm_id}/{task_id}/{filename}.jpg
-- ------------------------------------------------------------

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'farm-evidence',
  'farm-evidence',
  false,
  10485760,
  array[
    'image/jpeg',
    'image/png',
    'image/webp'
  ]::text[]
)
on conflict (id)
do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "farm_evidence_upload_to_own_folder"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'farm-evidence'
  and (storage.foldername(name))[1] = auth.uid()::text
);

create policy "farm_evidence_select_authorized_objects"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'farm-evidence'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or private.can_view_task_photo_path(name)
  )
);

create policy "farm_evidence_delete_own_uploads"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'farm-evidence'
  and (storage.foldername(name))[1] = auth.uid()::text
);