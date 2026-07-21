-- ============================================================
-- Al-Wahat Farm
-- Schedule date rules + combined-task grouping
--
-- 1. Date rules for operation plans, enforced in the RPCs (the only
--    write path — the table has no insert/update grant for
--    authenticated):
--      * an end date is required,
--      * the start date cannot be in the past (creation, or when the
--        start date is being changed),
--      * the end date cannot be before the start date,
--      * the end date cannot be more than one month after the start.
--    Existing rows (which may predate these rules) stay valid and can
--    still be paused/archived — the date rules only fire when a date
--    is being set.
--
-- 2. operation_plans.task_grouping ('per_target' | 'combined'):
--    'combined' makes the generator create ONE multi-target task per
--    matching date instead of one task per target. Dedup and the
--    insufficient-stock auto-recovery keep working through one
--    operation_plan_runs row per (plan, target, date); for a combined
--    plan every run row of the date points at the same task.
-- ============================================================

alter table public.operation_plans
  add column task_grouping text not null default 'per_target'
    constraint operation_plans_task_grouping_check
      check (task_grouping in ('per_target', 'combined'));

-- A combined plan links several run rows to ONE generated task, so the
-- one-task-per-run uniqueness no longer holds; keep a plain lookup index.
drop index if exists public.operation_plan_runs_generated_task_id_idx;
create index operation_plan_runs_generated_task_id_idx
  on public.operation_plan_runs (generated_task_id)
  where generated_task_id is not null;

comment on column public.operation_plans.task_grouping is
  'per_target: one generated task per target and date (default). '
  'combined: one task per date carrying every plan target (all targets '
  'must be concrete and of one kind).';

-- ------------------------------------------------------------
-- Shared date validation
-- ------------------------------------------------------------

create or replace function private.assert_plan_schedule_dates(
  p_starts_on date,
  p_ends_on date,
  p_require_future boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_ends_on is null then
    raise exception 'Schedules need an end date'
      using errcode = '23514';
  end if;

  if p_require_future and p_starts_on < current_date then
    raise exception 'The start date cannot be in the past'
      using errcode = '23514';
  end if;

  if p_ends_on < p_starts_on then
    raise exception 'The end date cannot be before the start date'
      using errcode = '23514';
  end if;

  if p_ends_on > p_starts_on + interval '1 month' then
    raise exception 'The end date cannot be more than one month after the start date'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function private.assert_plan_schedule_dates(date, date, boolean)
from public, anon;

-- Combined plans need every target concrete (not farm-wide) and of one
-- kind, because the generated task's targets share the task_targets
-- same-kind rule.
create or replace function private.assert_combined_plan_targets(
  p_operation_plan_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kinds integer;
  v_farm_wide integer;
begin
  select
    count(distinct case
      when opt.section_id is not null then 'section'
      when opt.irrigation_zone_id is not null then 'zone'
      when opt.tree_id is not null then 'tree'
    end),
    count(*) filter (
      where opt.section_id is null
        and opt.irrigation_zone_id is null
        and opt.tree_id is null
    )
  into v_kinds, v_farm_wide
  from public.operation_plan_targets opt
  where opt.operation_plan_id = p_operation_plan_id
    and opt.is_active = true;

  if v_farm_wide > 0 then
    raise exception 'A combined-task schedule needs specific targets, not the whole farm'
      using errcode = '23514';
  end if;

  if v_kinds > 1 then
    raise exception 'A combined task can only group targets of the same kind'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function private.assert_combined_plan_targets(uuid)
from public, anon;

-- ------------------------------------------------------------
-- create_operation_plan: date rules + p_task_grouping
-- ------------------------------------------------------------

drop function if exists public.create_operation_plan(
  uuid, public.operation_plan_type, text, public.operation_schedule_type,
  date, text, public.operation_plan_status, date, time, integer,
  smallint[], jsonb, jsonb, uuid, public.fertilizer_application_method,
  numeric, public.application_rate_basis, public.inventory_unit, uuid[]
);

create function public.create_operation_plan(
  p_farm_id uuid,
  p_operation_type public.operation_plan_type,
  p_title text,
  p_schedule_type public.operation_schedule_type,
  p_starts_on date,
  p_description text default null,
  p_status public.operation_plan_status default 'draft',
  p_ends_on date default null,
  p_scheduled_start_time time default null,
  p_planned_duration_minutes integer default null,
  p_days_of_week smallint[] default null,
  p_instructions jsonb default '{}'::jsonb,
  p_targets jsonb default '[{}]'::jsonb,
  p_inventory_item_id uuid default null,
  p_application_method public.fertilizer_application_method default null,
  p_application_rate numeric default null,
  p_rate_basis public.application_rate_basis default null,
  p_rate_unit public.inventory_unit default null,
  p_default_assignee_profile_ids uuid[] default '{}',
  p_task_grouping text default 'per_target'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_plan_id uuid;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if not private.is_operational_manager(p_farm_id) then
    raise exception 'Only the owner or agricultural engineer can create operation plans'
      using errcode = '42501';
  end if;

  perform private.assert_plan_schedule_dates(p_starts_on, p_ends_on, true);

  if coalesce(p_task_grouping, 'per_target')
    not in ('per_target', 'combined') then
    raise exception 'Unknown task grouping'
      using errcode = '23514';
  end if;

  perform private.assert_plan_product(
    p_farm_id, p_operation_type, p_inventory_item_id,
    p_application_rate, p_rate_basis, p_rate_unit
  );

  if p_operation_type <> 'irrigation'
    and p_inventory_item_id is null
    and (p_application_rate is not null
      or p_rate_basis is not null
      or p_rate_unit is not null) then
    raise exception 'An application rate needs a product from the inventory'
      using errcode = '23514';
  end if;

  if coalesce(cardinality(p_default_assignee_profile_ids), 0) > 0 then
    perform private.assert_assignable_profiles(
      p_farm_id, p_default_assignee_profile_ids
    );
  end if;

  insert into public.operation_plans (
    farm_id, operation_type, title, description, status, schedule_type,
    starts_on, ends_on, scheduled_start_time, planned_duration_minutes,
    days_of_week, instructions, created_by_profile_id,
    inventory_item_id, application_method, application_rate,
    rate_basis, rate_unit, default_assignee_profile_ids, task_grouping
  )
  values (
    p_farm_id, p_operation_type, trim(p_title), p_description,
    coalesce(p_status, 'draft'::public.operation_plan_status),
    p_schedule_type, p_starts_on, p_ends_on, p_scheduled_start_time,
    p_planned_duration_minutes,
    case when p_schedule_type = 'weekly' then p_days_of_week else null end,
    coalesce(p_instructions, '{}'::jsonb),
    v_actor_id,
    p_inventory_item_id, p_application_method, p_application_rate,
    p_rate_basis, p_rate_unit,
    coalesce(p_default_assignee_profile_ids, '{}'),
    coalesce(p_task_grouping, 'per_target')
  )
  returning id into v_plan_id;

  perform private.replace_operation_plan_targets(v_plan_id, p_targets);

  if coalesce(p_task_grouping, 'per_target') = 'combined' then
    perform private.assert_combined_plan_targets(v_plan_id);
  end if;

  return v_plan_id;
end;
$$;

-- ------------------------------------------------------------
-- update_operation_plan: date rules when dates change + grouping
-- ------------------------------------------------------------

drop function if exists public.update_operation_plan(
  uuid, text, text, public.operation_plan_status,
  public.operation_schedule_type, date, date, time, integer, smallint[],
  jsonb, boolean, jsonb, boolean, boolean, boolean, boolean, boolean,
  uuid, public.fertilizer_application_method, numeric,
  public.application_rate_basis, public.inventory_unit, boolean, uuid[]
);

create function public.update_operation_plan(
  p_operation_plan_id uuid,
  p_title text default null,
  p_description text default null,
  p_status public.operation_plan_status default null,
  p_schedule_type public.operation_schedule_type default null,
  p_starts_on date default null,
  p_ends_on date default null,
  p_scheduled_start_time time default null,
  p_planned_duration_minutes integer default null,
  p_days_of_week smallint[] default null,
  p_instructions jsonb default null,
  p_replace_targets boolean default false,
  p_targets jsonb default null,
  p_clear_description boolean default false,
  p_clear_ends_on boolean default false,
  p_clear_scheduled_start_time boolean default false,
  p_clear_planned_duration_minutes boolean default false,
  p_clear_days_of_week boolean default false,
  p_inventory_item_id uuid default null,
  p_application_method public.fertilizer_application_method default null,
  p_application_rate numeric default null,
  p_rate_basis public.application_rate_basis default null,
  p_rate_unit public.inventory_unit default null,
  p_clear_product boolean default false,
  p_default_assignee_profile_ids uuid[] default null,
  p_task_grouping text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_plan record;
  v_schedule public.operation_schedule_type;
  v_days smallint[];
  v_item uuid;
  v_rate numeric;
  v_basis public.application_rate_basis;
  v_unit public.inventory_unit;
  v_method public.fertilizer_application_method;
  v_assignees uuid[];
  v_grouping text;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  select * into v_plan
  from public.operation_plans
  where id = p_operation_plan_id
  for update;

  if not found then
    raise exception 'Operation plan not found'
      using errcode = 'P0002';
  end if;

  if not private.is_operational_manager(v_plan.farm_id) then
    raise exception 'Only the owner or agricultural engineer can update operation plans'
      using errcode = '42501';
  end if;

  if p_clear_ends_on then
    raise exception 'Schedules need an end date'
      using errcode = '23514';
  end if;

  -- Date rules apply only when a date is actually being changed, so
  -- legacy plans (from before the rules) can still be paused/archived.
  if p_starts_on is not null or p_ends_on is not null then
    perform private.assert_plan_schedule_dates(
      coalesce(p_starts_on, v_plan.starts_on),
      coalesce(p_ends_on, v_plan.ends_on),
      p_starts_on is not null
    );
  end if;

  v_grouping := coalesce(p_task_grouping, v_plan.task_grouping);
  if v_grouping not in ('per_target', 'combined') then
    raise exception 'Unknown task grouping'
      using errcode = '23514';
  end if;

  v_schedule := coalesce(p_schedule_type, v_plan.schedule_type);
  v_days := case
    when p_clear_days_of_week then null
    when p_days_of_week is not null then p_days_of_week
    else v_plan.days_of_week
  end;

  if v_schedule = 'weekly' then
    if v_days is null
      or cardinality(v_days) = 0
      or not (v_days <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]) then
      raise exception 'Weekly plans need valid days of the week'
        using errcode = '23514';
    end if;
  else
    v_days := null;
  end if;

  if p_clear_product then
    v_item := null;
    v_rate := null;
    v_basis := null;
    v_unit := null;
    v_method := null;
  else
    v_item := coalesce(p_inventory_item_id, v_plan.inventory_item_id);
    v_rate := coalesce(p_application_rate, v_plan.application_rate);
    v_basis := coalesce(p_rate_basis, v_plan.rate_basis);
    v_unit := coalesce(p_rate_unit, v_plan.rate_unit);
    v_method := coalesce(p_application_method, v_plan.application_method);
  end if;

  perform private.assert_plan_product(
    v_plan.farm_id, v_plan.operation_type, v_item, v_rate, v_basis, v_unit
  );

  if v_item is null and (v_rate is not null or v_basis is not null
    or v_unit is not null) then
    raise exception 'An application rate needs a product from the inventory'
      using errcode = '23514';
  end if;

  v_assignees := coalesce(
    p_default_assignee_profile_ids, v_plan.default_assignee_profile_ids
  );
  if p_default_assignee_profile_ids is not null
    and cardinality(p_default_assignee_profile_ids) > 0 then
    perform private.assert_assignable_profiles(
      v_plan.farm_id, p_default_assignee_profile_ids
    );
  end if;

  update public.operation_plans
  set
    title = coalesce(nullif(trim(coalesce(p_title, '')), ''), title),
    description = case
      when p_clear_description then null
      else coalesce(p_description, description)
    end,
    status = coalesce(p_status, status),
    schedule_type = v_schedule,
    starts_on = coalesce(p_starts_on, starts_on),
    ends_on = coalesce(p_ends_on, ends_on),
    scheduled_start_time = case
      when p_clear_scheduled_start_time then null
      else coalesce(p_scheduled_start_time, scheduled_start_time)
    end,
    planned_duration_minutes = case
      when p_clear_planned_duration_minutes then null
      else coalesce(p_planned_duration_minutes, planned_duration_minutes)
    end,
    days_of_week = v_days,
    instructions = coalesce(p_instructions, instructions),
    inventory_item_id = v_item,
    application_method = v_method,
    application_rate = v_rate,
    rate_basis = v_basis,
    rate_unit = v_unit,
    default_assignee_profile_ids = v_assignees,
    task_grouping = v_grouping
  where id = p_operation_plan_id;

  if p_replace_targets then
    perform private.replace_operation_plan_targets(
      p_operation_plan_id, coalesce(p_targets, '[{}]'::jsonb)
    );
  end if;

  if v_grouping = 'combined'
    and (p_task_grouping is not null or p_replace_targets) then
    perform private.assert_combined_plan_targets(p_operation_plan_id);
  end if;
end;
$$;

-- ------------------------------------------------------------
-- Group generation: one run row per (plan, target, date) always;
-- one task per GROUP (per target by default, all targets combined
-- for task_grouping = 'combined').
-- ------------------------------------------------------------

create or replace function private.generate_plan_run_group(
  p_operation_plan_id uuid,
  p_target_ids uuid[],
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
  v_plan record;
  v_target_id uuid;
  v_run_id uuid;
  v_task_id uuid;
  v_pending_runs uuid[] := '{}';
  v_pending_targets uuid[] := '{}';
  v_first record;
  v_required numeric := 0;
  v_available numeric;
  v_priority public.task_priority;
  v_instructions jsonb;
  v_assignees uuid[];
  v_assignee uuid;
  v_status public.task_status;
begin
  select * into v_plan
  from public.operation_plans
  where id = p_operation_plan_id;

  if not found then
    return;
  end if;

  -- One run row per target keeps the (plan, target, date) dedup and the
  -- task-less blocked-run recovery identical for both grouping modes.
  foreach v_target_id in array p_target_ids loop
    v_run_id := null;

    insert into public.operation_plan_runs (
      operation_plan_id,
      operation_plan_target_id,
      operation_date
    )
    values (
      v_plan.id,
      v_target_id,
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
    returning public.operation_plan_runs.id into v_run_id;

    if v_run_id is not null then
      v_pending_runs := v_pending_runs || v_run_id;
      v_pending_targets := v_pending_targets || v_target_id;
    end if;
  end loop;

  if cardinality(v_pending_runs) = 0 then
    return;
  end if;

  select coalesce(
    sum(private.operation_target_required_quantity(v_plan.id, t.id)), 0
  ) into v_required
  from unnest(v_pending_targets) as t(id);

  -- Availability gate (owner decision 2): block the whole group, keep
  -- the runs task-less, and let a later pass create the task(s) after
  -- restock.
  if v_plan.inventory_item_id is not null and v_required > 0 then
    select quantity into v_available
    from public.inventory_items
    where id = v_plan.inventory_item_id
    for update;

    if coalesce(v_available, 0) < v_required then
      update public.operation_plan_runs
      set blocked_reason = 'insufficient_stock'
      where id = any (v_pending_runs);
      return;
    end if;
  end if;

  select opt.* into v_first
  from public.operation_plan_targets opt
  where opt.id = v_pending_targets[1];

  v_priority :=
    case v_plan.instructions ->> 'priority'
      when 'low' then 'low'::public.task_priority
      when 'high' then 'high'::public.task_priority
      when 'urgent' then 'urgent'::public.task_priority
      else 'medium'::public.task_priority
    end;

  v_instructions := v_plan.instructions || jsonb_build_object(
    'operation_plan_id', v_plan.id
  );

  if cardinality(v_pending_targets) = 1 then
    -- Backward-compatible singular keys for per-target tasks.
    v_instructions := v_instructions || jsonb_build_object(
      'operation_plan_target_id', v_pending_targets[1],
      'operation_plan_run_id', v_pending_runs[1]
    );
  else
    v_instructions := v_instructions || jsonb_build_object(
      'operation_plan_target_ids', to_jsonb(v_pending_targets),
      'operation_plan_run_ids', to_jsonb(v_pending_runs)
    );
  end if;

  if v_plan.inventory_item_id is not null and v_required > 0 then
    v_instructions := v_instructions || jsonb_build_object(
      'inventory_item_id', v_plan.inventory_item_id,
      'required_quantity', v_required,
      'required_unit', v_plan.rate_unit::text,
      'application_method', v_plan.application_method::text
    );
  end if;

  -- Default assignees, filtered to currently-active operational members
  -- so a deactivated member never fails generation.
  select coalesce(array_agg(fm.profile_id), '{}') into v_assignees
  from public.farm_memberships fm
  where fm.farm_id = v_plan.farm_id
    and fm.is_active = true
    and fm.role in ('owner', 'agricultural_engineer', 'worker')
    and fm.profile_id = any (v_plan.default_assignee_profile_ids);

  v_status := case
    when cardinality(v_assignees) > 0
      then 'assigned'::public.task_status
    else 'draft'::public.task_status
  end;

  insert into public.tasks (
    farm_id, section_id, irrigation_zone_id, tree_id,
    task_type, title, description, priority, status,
    scheduled_for, planned_start_time, planned_duration_minutes,
    instructions, created_by_profile_id
  )
  values (
    v_plan.farm_id, v_first.section_id, v_first.irrigation_zone_id,
    v_first.tree_id,
    v_plan.operation_type::text::public.task_type,
    v_plan.title, v_plan.description, v_priority, v_status,
    p_operation_date, v_plan.scheduled_start_time,
    v_plan.planned_duration_minutes,
    v_instructions, v_plan.created_by_profile_id
  )
  returning id into v_task_id;

  -- Every concrete target becomes a task target (the first was already
  -- mirrored by the tasks insert trigger; duplicates are skipped).
  insert into public.task_targets (
    task_id, section_id, irrigation_zone_id, tree_id
  )
  select v_task_id, opt.section_id, opt.irrigation_zone_id, opt.tree_id
  from public.operation_plan_targets opt
  where opt.id = any (v_pending_targets)
    and num_nonnulls(
      opt.section_id, opt.irrigation_zone_id, opt.tree_id
    ) = 1
  on conflict do nothing;

  update public.operation_plan_runs
  set
    generated_task_id = v_task_id,
    generated_at = now(),
    blocked_reason = null
  where id = any (v_pending_runs);

  insert into public.task_activity_log (
    task_id, actor_profile_id, action, new_status, note, metadata
  )
  values (
    v_task_id, v_plan.created_by_profile_id, 'created', 'draft',
    'Generated from agricultural operation plan',
    jsonb_build_object(
      'operation_plan_id', v_plan.id,
      'operation_plan_target_ids', to_jsonb(v_pending_targets),
      'operation_plan_run_ids', to_jsonb(v_pending_runs),
      'operation_date', p_operation_date
    )
  );

  if cardinality(v_assignees) > 0 then
    foreach v_assignee in array v_assignees loop
      insert into public.task_assignments (
        task_id, assignee_profile_id, assigned_by_profile_id
      )
      values (v_task_id, v_assignee, v_plan.created_by_profile_id);
    end loop;

    insert into public.task_activity_log (
      task_id, actor_profile_id, action, old_status, new_status, metadata
    )
    values (
      v_task_id, v_plan.created_by_profile_id, 'assigned',
      'draft', 'assigned',
      jsonb_build_object('assignee_profile_ids', v_assignees)
    );
  end if;

  foreach v_run_id in array v_pending_runs loop
    operation_plan_run_id := v_run_id;
    generated_task_id := v_task_id;
    return next;
  end loop;
end;
$$;

revoke all on function private.generate_plan_run_group(uuid, uuid[], date)
from public, anon;

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
  v_target_ids uuid[];
  v_combinable boolean;
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
          and extract(isodow from p_operation_date)::smallint
            = any (op.days_of_week)
        )
      )
  loop
    select coalesce(array_agg(opt.id order by opt.created_at, opt.id), '{}')
    into v_target_ids
    from public.operation_plan_targets opt
    where opt.operation_plan_id = v_plan.id
      and opt.is_active = true;

    if cardinality(v_target_ids) = 0 then
      continue;
    end if;

    -- Combined grouping needs concrete same-kind targets; anything else
    -- (legacy data) falls back to per-target generation instead of
    -- failing the whole pass.
    v_combinable := v_plan.task_grouping = 'combined'
      and not exists (
        select 1
        from public.operation_plan_targets opt
        where opt.operation_plan_id = v_plan.id
          and opt.is_active = true
          and num_nonnulls(
            opt.section_id, opt.irrigation_zone_id, opt.tree_id
          ) <> 1
      )
      and (
        select count(distinct case
          when opt.section_id is not null then 'section'
          when opt.irrigation_zone_id is not null then 'zone'
          else 'tree'
        end)
        from public.operation_plan_targets opt
        where opt.operation_plan_id = v_plan.id
          and opt.is_active = true
      ) = 1;

    if v_combinable then
      return query
      select g.operation_plan_run_id, g.generated_task_id
      from private.generate_plan_run_group(
        v_plan.id, v_target_ids, p_operation_date
      ) g;
    else
      return query
      select g.operation_plan_run_id, g.generated_task_id
      from unnest(v_target_ids) as t(id),
        lateral private.generate_plan_run_group(
          v_plan.id, array[t.id], p_operation_date
        ) g;
    end if;
  end loop;
end;
$$;

-- ------------------------------------------------------------
-- Grants (new signatures)
-- ------------------------------------------------------------

do $$
declare
  v_fn text;
begin
  foreach v_fn in array array[
    'public.create_operation_plan(uuid, public.operation_plan_type, text, public.operation_schedule_type, date, text, public.operation_plan_status, date, time, integer, smallint[], jsonb, jsonb, uuid, public.fertilizer_application_method, numeric, public.application_rate_basis, public.inventory_unit, uuid[], text)',
    'public.update_operation_plan(uuid, text, text, public.operation_plan_status, public.operation_schedule_type, date, date, time, integer, smallint[], jsonb, boolean, jsonb, boolean, boolean, boolean, boolean, boolean, uuid, public.fertilizer_application_method, numeric, public.application_rate_basis, public.inventory_unit, boolean, uuid[], text)'
  ] loop
    execute format('revoke all on function %s from public, anon', v_fn);
    execute format(
      'grant execute on function %s to authenticated, service_role', v_fn
    );
  end loop;
end;
$$;
