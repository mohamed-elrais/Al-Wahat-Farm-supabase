-- ============================================================
-- Al-Wahat Farm
-- Multi-target tasks (plan M5)
--
-- One task may target multiple trees, multiple sections, or multiple
-- irrigation zones - never a mix of kinds (enforced HERE, not just in
-- the app). Mirrors the operation_plan_targets idiom.
--
-- Compatibility contract:
--   * tasks.section_id / irrigation_zone_id / tree_id remain the
--     PRIMARY target (the first one) - old clients, cached JSON,
--     offline outbox replays and existing indexes keep working.
--   * An AFTER INSERT trigger mirrors the primary target into
--     task_targets, so every creation path (create_farm_task,
--     report_tree_issue's auto task, the plan generator) is uniform.
--   * Existing tasks are backfilled below.
-- ============================================================

create table public.task_targets (
  id uuid primary key default gen_random_uuid(),

  task_id uuid not null
    references public.tasks(id)
    on delete cascade,

  section_id uuid
    references public.farm_sections(id)
    on delete cascade,

  irrigation_zone_id uuid
    references public.irrigation_zones(id)
    on delete cascade,

  tree_id uuid
    references public.trees(id)
    on delete cascade,

  created_at timestamptz not null default now(),

  constraint task_targets_one_scope_check
    check (num_nonnulls(section_id, irrigation_zone_id, tree_id) = 1)
);

create unique index task_targets_section_key
  on public.task_targets (task_id, section_id)
  where section_id is not null;

create unique index task_targets_zone_key
  on public.task_targets (task_id, irrigation_zone_id)
  where irrigation_zone_id is not null;

create unique index task_targets_tree_key
  on public.task_targets (task_id, tree_id)
  where tree_id is not null;

create index task_targets_task_id_idx
  on public.task_targets (task_id);

create index task_targets_section_id_idx
  on public.task_targets (section_id)
  where section_id is not null;

create index task_targets_zone_id_idx
  on public.task_targets (irrigation_zone_id)
  where irrigation_zone_id is not null;

create index task_targets_tree_id_idx
  on public.task_targets (tree_id)
  where tree_id is not null;

comment on table public.task_targets is
  'Targets of a task (one row per section/zone/tree). All rows of a task '
  'share one kind - the same-category rule is enforced by trigger. The '
  'first target is mirrored on the legacy tasks.* single-target columns.';

-- ------------------------------------------------------------
-- Same-kind + same-farm enforcement (a CHECK cannot span rows)
-- ------------------------------------------------------------

create or replace function public.validate_task_target_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_farm_id uuid;
  v_new_kind text;
  v_existing_kind text;
  v_target_farm uuid;
begin
  select farm_id into v_farm_id
  from public.tasks
  where id = new.task_id;

  if v_farm_id is null then
    raise exception 'Task not found for target'
      using errcode = '23514';
  end if;

  v_new_kind := case
    when new.section_id is not null then 'section'
    when new.irrigation_zone_id is not null then 'zone'
    else 'tree'
  end;

  select case
    when tt.section_id is not null then 'section'
    when tt.irrigation_zone_id is not null then 'zone'
    else 'tree'
  end into v_existing_kind
  from public.task_targets tt
  where tt.task_id = new.task_id
    and tt.id <> new.id
  limit 1;

  if v_existing_kind is not null and v_existing_kind <> v_new_kind then
    raise exception
      'All targets of a task must be of the same kind (existing: %, new: %)',
      v_existing_kind, v_new_kind
      using errcode = '23514';
  end if;

  if new.section_id is not null then
    select farm_id into v_target_farm
    from public.farm_sections
    where id = new.section_id;
  elsif new.irrigation_zone_id is not null then
    select fs.farm_id into v_target_farm
    from public.irrigation_zones iz
    join public.farm_sections fs on fs.id = iz.section_id
    where iz.id = new.irrigation_zone_id;
  else
    select farm_id into v_target_farm
    from public.trees
    where id = new.tree_id;
  end if;

  if v_target_farm is null or v_target_farm <> v_farm_id then
    raise exception 'Task target must belong to the task farm'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger task_targets_validate_row
before insert or update on public.task_targets
for each row
execute function public.validate_task_target_row();

-- ------------------------------------------------------------
-- Mirror the legacy single-target columns into task_targets on
-- every task insert (uniform across all creation paths).
-- ------------------------------------------------------------

create or replace function public.mirror_task_primary_target()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if num_nonnulls(new.section_id, new.irrigation_zone_id, new.tree_id) = 1 then
    insert into public.task_targets (
      task_id, section_id, irrigation_zone_id, tree_id
    )
    values (
      new.id, new.section_id, new.irrigation_zone_id, new.tree_id
    )
    on conflict do nothing;
  end if;
  return new;
end;
$$;

create trigger tasks_mirror_primary_target
after insert on public.tasks
for each row
execute function public.mirror_task_primary_target();

-- Backfill every existing targeted task.
insert into public.task_targets (task_id, section_id, irrigation_zone_id, tree_id)
select t.id, t.section_id, t.irrigation_zone_id, t.tree_id
from public.tasks t
where num_nonnulls(t.section_id, t.irrigation_zone_id, t.tree_id) = 1
on conflict do nothing;

-- ------------------------------------------------------------
-- RLS
-- ------------------------------------------------------------

alter table public.task_targets enable row level security;

revoke all on public.task_targets from public, anon;
grant select on public.task_targets to authenticated;
grant all on public.task_targets to service_role;

create policy "task targets visible with their task"
  on public.task_targets
  for select
  to authenticated
  using ((select private.can_view_task(task_id)));

-- ------------------------------------------------------------
-- create_farm_task gains p_targets (array of {section_id} |
-- {irrigation_zone_id} | {tree_id} objects, all the same kind)
-- ------------------------------------------------------------

drop function if exists public.create_farm_task(
  uuid, public.task_type, text, text, uuid, uuid, uuid, date, time,
  integer, timestamptz, public.task_priority, jsonb, boolean, uuid,
  uuid[], uuid
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
  p_op_id uuid default null,
  p_targets jsonb default null
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
  v_section_id uuid := p_section_id;
  v_zone_id uuid := p_irrigation_zone_id;
  v_tree_id uuid := p_tree_id;
  v_target jsonb;
  v_kind text;
  v_first_kind text;
  v_first boolean := true;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if not private.is_operational_manager(p_farm_id) then
    raise exception 'Only the owner or agricultural engineer can create tasks'
      using errcode = '42501';
  end if;

  -- Multi-target mode: validate the array shape up front and derive the
  -- primary (first) target for the legacy columns.
  if p_targets is not null then
    if jsonb_typeof(p_targets) <> 'array'
      or jsonb_array_length(p_targets) = 0 then
      raise exception 'Targets must be a non-empty array'
        using errcode = '23514';
    end if;

    for v_target in select * from jsonb_array_elements(p_targets) loop
      if (select count(*) from jsonb_object_keys(v_target)
          where jsonb_object_keys in
            ('section_id', 'irrigation_zone_id', 'tree_id')) <> 1 then
        raise exception
          'Each target needs exactly one of section_id, irrigation_zone_id, tree_id'
          using errcode = '23514';
      end if;

      v_kind := case
        when v_target ? 'section_id' then 'section'
        when v_target ? 'irrigation_zone_id' then 'zone'
        else 'tree'
      end;

      if v_first then
        v_first_kind := v_kind;
        v_section_id := nullif(v_target ->> 'section_id', '')::uuid;
        v_zone_id := nullif(v_target ->> 'irrigation_zone_id', '')::uuid;
        v_tree_id := nullif(v_target ->> 'tree_id', '')::uuid;
        v_first := false;
      elsif v_kind <> v_first_kind then
        raise exception
          'All targets of a task must be of the same kind (existing: %, new: %)',
          v_first_kind, v_kind
          using errcode = '23514';
      end if;
    end loop;
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
      v_section_id,
      v_zone_id,
      v_tree_id,
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

  -- Remaining targets (the first was mirrored by the tasks insert trigger).
  if p_targets is not null then
    insert into public.task_targets (
      task_id, section_id, irrigation_zone_id, tree_id
    )
    select
      v_task_id,
      nullif(target ->> 'section_id', '')::uuid,
      nullif(target ->> 'irrigation_zone_id', '')::uuid,
      nullif(target ->> 'tree_id', '')::uuid
    from jsonb_array_elements(p_targets) as target
    on conflict do nothing;
  end if;

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

revoke all on function public.create_farm_task(
  uuid, public.task_type, text, text, uuid, uuid, uuid, date, time,
  integer, timestamptz, public.task_priority, jsonb, boolean, uuid,
  uuid[], uuid, jsonb
) from public, anon;

grant execute on function public.create_farm_task(
  uuid, public.task_type, text, text, uuid, uuid, uuid, date, time,
  integer, timestamptz, public.task_priority, jsonb, boolean, uuid,
  uuid[], uuid, jsonb
) to authenticated, service_role;
