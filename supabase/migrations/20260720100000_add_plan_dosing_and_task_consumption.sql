-- ============================================================
-- Al-Wahat Farm
-- Plan dosing, generator upgrades, task consumption (plan M3)
--
--   * operation_plans gain a product (inventory item), application
--     rate/basis/unit/method, and default assignees.
--   * Dosing math (owner decisions 1, 8): per-feddan rates derive
--     area from ACTIVE TREE COUNTS - feddans = trees /
--     farms.trees_per_feddan (zones count the trees their ZCV feeds;
--     unplanted scopes therefore dose zero).
--   * Generation blocks on insufficient stock (owner decision 2):
--     the run row is kept task-less with blocked_reason, so the
--     hourly cron auto-creates the task once stock is added -
--     bounded by the existing today/tomorrow window.
--   * complete_task consumes inventory (net-zero guarded, clamps to
--     available and records shortfall - owner decision 3);
--     review_task(returned_for_correction) restores it.
-- ============================================================

-- ------------------------------------------------------------
-- Plan columns
-- ------------------------------------------------------------

alter table public.operation_plans
  add column inventory_item_id uuid
    references public.inventory_items(id) on delete restrict,
  add column application_method public.fertilizer_application_method,
  add column application_rate numeric(12, 4),
  add column rate_basis public.application_rate_basis,
  add column rate_unit public.inventory_unit,
  add column default_assignee_profile_ids uuid[] not null default '{}';

alter table public.operation_plans
  add constraint operation_plans_rate_positive_check
    check (application_rate is null or application_rate > 0),
  add constraint operation_plans_product_coherence_check
    check (
      (
        operation_type = 'irrigation'
        and inventory_item_id is null
        and application_rate is null
      )
      or (
        operation_type <> 'irrigation'
        and (inventory_item_id is null) = (application_rate is null)
        and (inventory_item_id is null) = (rate_basis is null)
        and (inventory_item_id is null) = (rate_unit is null)
      )
    );

create index operation_plans_inventory_item_id_idx
  on public.operation_plans (inventory_item_id)
  where inventory_item_id is not null;

-- Blocked-generation marker (kept on the run so the retry path is the
-- ordinary generator pass over task-less runs).
alter table public.operation_plan_runs
  add column blocked_reason text;

-- ------------------------------------------------------------
-- Shared validation + dosing helpers
-- ------------------------------------------------------------

create or replace function private.assert_plan_product(
  p_farm_id uuid,
  p_operation_type public.operation_plan_type,
  p_inventory_item_id uuid,
  p_application_rate numeric,
  p_rate_basis public.application_rate_basis,
  p_rate_unit public.inventory_unit
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item record;
  v_applies public.operation_plan_type;
begin
  if p_inventory_item_id is null then
    return;
  end if;

  if p_operation_type = 'irrigation' then
    raise exception 'Irrigation plans cannot carry a product'
      using errcode = '23514';
  end if;

  if p_application_rate is null or p_application_rate <= 0
    or p_rate_basis is null or p_rate_unit is null then
    raise exception 'Product plans need a positive rate, a basis, and a unit'
      using errcode = '23514';
  end if;

  select i.farm_id, i.unit, c.applies_to_operation
    into v_item
  from public.inventory_items i
  join public.inventory_categories c on c.id = i.category_id
  where i.id = p_inventory_item_id;

  if not found or v_item.farm_id <> p_farm_id then
    raise exception 'Inventory item does not belong to this farm'
      using errcode = '23514';
  end if;

  if v_item.unit <> p_rate_unit then
    raise exception 'Rate unit must match the inventory item unit'
      using errcode = '23514';
  end if;

  v_applies := v_item.applies_to_operation;
  if v_applies is null or v_applies <> p_operation_type then
    raise exception 'Inventory item category does not match the operation type'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function private.assert_plan_product(
  uuid, public.operation_plan_type, uuid, numeric,
  public.application_rate_basis, public.inventory_unit
) from public, anon, authenticated;

create or replace function private.operation_target_required_quantity(
  p_operation_plan_id uuid,
  p_operation_plan_target_id uuid
)
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan record;
  v_target record;
  v_trees_per_feddan numeric;
  v_tree_count numeric;
begin
  select op.farm_id, op.inventory_item_id, op.application_rate, op.rate_basis
    into v_plan
  from public.operation_plans op
  where op.id = p_operation_plan_id;

  if not found or v_plan.inventory_item_id is null then
    return 0;
  end if;

  if v_plan.rate_basis = 'absolute' then
    return round(v_plan.application_rate, 3);
  end if;

  select opt.section_id, opt.irrigation_zone_id, opt.tree_id
    into v_target
  from public.operation_plan_targets opt
  where opt.id = p_operation_plan_target_id;

  if not found then
    return 0;
  end if;

  select count(*)::numeric into v_tree_count
  from public.trees t
  where t.farm_id = v_plan.farm_id
    and t.is_active = true
    and (
      (v_target.tree_id is not null and t.id = v_target.tree_id)
      or (v_target.irrigation_zone_id is not null
          and t.irrigation_zone_id = v_target.irrigation_zone_id)
      or (v_target.section_id is not null
          and t.section_id = v_target.section_id)
      or (v_target.tree_id is null
          and v_target.irrigation_zone_id is null
          and v_target.section_id is null)
    );

  if v_plan.rate_basis = 'per_tree' then
    return round(v_plan.application_rate * v_tree_count, 3);
  end if;

  -- per_feddan: feddans = active tree count / farms.trees_per_feddan.
  select trees_per_feddan into v_trees_per_feddan
  from public.farms
  where id = v_plan.farm_id;

  return round(
    v_plan.application_rate * v_tree_count
      / coalesce(nullif(v_trees_per_feddan, 0), 60),
    3
  );
end;
$$;

revoke all on function private.operation_target_required_quantity(uuid, uuid)
  from public, anon, authenticated;

-- ------------------------------------------------------------
-- create_operation_plan / update_operation_plan (new signatures)
-- ------------------------------------------------------------

drop function if exists public.create_operation_plan(
  uuid, public.operation_plan_type, text, public.operation_schedule_type,
  date, text, public.operation_plan_status, date, time, integer,
  smallint[], jsonb, jsonb
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
  p_default_assignee_profile_ids uuid[] default '{}'
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
    rate_basis, rate_unit, default_assignee_profile_ids
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
    coalesce(p_default_assignee_profile_ids, '{}')
  )
  returning id into v_plan_id;

  perform private.replace_operation_plan_targets(v_plan_id, p_targets);

  return v_plan_id;
end;
$$;

drop function if exists public.update_operation_plan(
  uuid, text, text, public.operation_plan_status,
  public.operation_schedule_type, date, date, time, integer, smallint[],
  jsonb, boolean, jsonb, boolean, boolean, boolean, boolean, boolean
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
  p_default_assignee_profile_ids uuid[] default null
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
    ends_on = case
      when p_clear_ends_on then null
      else coalesce(p_ends_on, ends_on)
    end,
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
    default_assignee_profile_ids = v_assignees
  where id = p_operation_plan_id;

  if p_replace_targets then
    perform private.replace_operation_plan_targets(
      p_operation_plan_id, coalesce(p_targets, '[{}]'::jsonb)
    );
  end if;
end;
$$;

-- ------------------------------------------------------------
-- Generator: dosing, shortage blocking, default assignees
-- ------------------------------------------------------------

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
  v_required numeric;
  v_available numeric;
  v_instructions jsonb;
  v_assignees uuid[];
  v_assignee uuid;
  v_status public.task_status;
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
        v_required :=
          private.operation_target_required_quantity(v_plan.id, v_target.id);

        -- Availability gate (owner decision 2): block, keep the run
        -- task-less, and let a later pass create the task after restock.
        if v_plan.inventory_item_id is not null and v_required > 0 then
          select quantity into v_available
          from public.inventory_items
          where id = v_plan.inventory_item_id
          for update;

          if coalesce(v_available, 0) < v_required then
            update public.operation_plan_runs
            set blocked_reason = 'insufficient_stock'
            where id = v_run_id;
            continue;
          end if;
        end if;

        v_priority :=
          case v_plan.instructions ->> 'priority'
            when 'low' then 'low'::public.task_priority
            when 'high' then 'high'::public.task_priority
            when 'urgent' then 'urgent'::public.task_priority
            else 'medium'::public.task_priority
          end;

        v_instructions := v_plan.instructions || jsonb_build_object(
          'operation_plan_id', v_plan.id,
          'operation_plan_target_id', v_target.id,
          'operation_plan_run_id', v_run_id
        );

        if v_plan.inventory_item_id is not null and v_required > 0 then
          v_instructions := v_instructions || jsonb_build_object(
            'inventory_item_id', v_plan.inventory_item_id,
            'required_quantity', v_required,
            'required_unit', v_plan.rate_unit::text,
            'application_method', v_plan.application_method::text
          );
        end if;

        -- Default assignees, filtered to currently-active operational
        -- members so a deactivated member never fails generation.
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
          v_plan.farm_id, v_target.section_id, v_target.irrigation_zone_id,
          v_target.tree_id,
          v_plan.operation_type::text::public.task_type,
          v_plan.title, v_plan.description, v_priority, v_status,
          p_operation_date, v_plan.scheduled_start_time,
          v_plan.planned_duration_minutes,
          v_instructions, v_plan.created_by_profile_id
        )
        returning id into v_task_id;

        update public.operation_plan_runs
        set
          generated_task_id = v_task_id,
          generated_at = now(),
          blocked_reason = null
        where id = v_run_id;

        insert into public.task_activity_log (
          task_id, actor_profile_id, action, new_status, note, metadata
        )
        values (
          v_task_id, v_plan.created_by_profile_id, 'created', 'draft',
          'Generated from agricultural operation plan',
          jsonb_build_object(
            'operation_plan_id', v_plan.id,
            'operation_plan_target_id', v_target.id,
            'operation_plan_run_id', v_run_id,
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
            task_id, actor_profile_id, action, old_status, new_status,
            metadata
          )
          values (
            v_task_id, v_plan.created_by_profile_id, 'assigned',
            'draft', 'assigned',
            jsonb_build_object('assignee_profile_ids', v_assignees)
          );
        end if;

        operation_plan_run_id := v_run_id;
        generated_task_id := v_task_id;
        return next;
      end if;
    end loop;
  end loop;
end;
$$;

-- Manager wrapper for on-demand generation (cron stays primary).
create or replace function public.generate_farm_tasks_now(
  p_farm_id uuid,
  p_operation_date date default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_date date;
  v_count integer;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if not private.is_operational_manager(p_farm_id) then
    raise exception 'Only the owner or agricultural engineer can generate operation tasks'
      using errcode = '42501';
  end if;

  select coalesce(
    p_operation_date,
    (now() at time zone coalesce(f.timezone, 'Africa/Cairo'))::date
  ) into v_date
  from public.farms f
  where f.id = p_farm_id;

  select count(*) into v_count
  from public.generate_operation_tasks_for_date(p_farm_id, v_date);

  return coalesce(v_count, 0);
end;
$$;

-- ------------------------------------------------------------
-- Inventory sufficiency check for the schedules UI
-- ------------------------------------------------------------

create or replace function public.check_operation_plan_inventory(
  p_operation_plan_id uuid,
  p_horizon_days integer default 30
)
returns table (
  operation_date date,
  required_total numeric,
  available numeric,
  sufficient boolean,
  applications_covered integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_plan record;
  v_available numeric;
  v_per_occurrence numeric;
  v_from date;
  v_to date;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  select op.*, f.timezone into v_plan
  from public.operation_plans op
  join public.farms f on f.id = op.farm_id
  where op.id = p_operation_plan_id;

  if not found then
    raise exception 'Operation plan not found'
      using errcode = 'P0002';
  end if;

  if not private.is_operational_manager(v_plan.farm_id) then
    raise exception 'Only the owner or agricultural engineer can view plan inventory'
      using errcode = '42501';
  end if;

  if v_plan.inventory_item_id is null then
    return;
  end if;

  select quantity into v_available
  from public.inventory_items
  where id = v_plan.inventory_item_id;

  select coalesce(sum(
    private.operation_target_required_quantity(v_plan.id, opt.id)
  ), 0) into v_per_occurrence
  from public.operation_plan_targets opt
  where opt.operation_plan_id = v_plan.id
    and opt.is_active = true;

  v_from := greatest(
    v_plan.starts_on,
    (now() at time zone coalesce(v_plan.timezone, 'Africa/Cairo'))::date
  );
  v_to := least(
    coalesce(v_plan.ends_on, v_from + greatest(p_horizon_days, 1)),
    v_from + greatest(p_horizon_days, 1)
  );

  return query
  select
    d::date,
    v_per_occurrence,
    coalesce(v_available, 0),
    coalesce(v_available, 0) >= v_per_occurrence,
    case
      when v_per_occurrence > 0
        then floor(coalesce(v_available, 0) / v_per_occurrence)::integer
      else null
    end
  from generate_series(v_from, v_to, interval '1 day') as d
  where (
    (v_plan.schedule_type = 'once' and d::date = v_plan.starts_on)
    or v_plan.schedule_type = 'daily'
    or (
      v_plan.schedule_type = 'weekly'
      and extract(isodow from d)::smallint = any (v_plan.days_of_week)
    )
  )
  order by d;
end;
$$;

-- ------------------------------------------------------------
-- complete_task: consume inventory on completion (same signature)
-- ------------------------------------------------------------

create or replace function public.complete_task(
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
  v_consumption jsonb;
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

  -- Deduct the task's product (net-zero guarded; clamps to available and
  -- records the shortfall - owner decision 3). No-op for tasks without a
  -- consumption spec in their instructions.
  v_consumption := private.consume_inventory_for_task(p_task_id, v_actor_id);

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
    ) || case
      when v_consumption = '{}'::jsonb then '{}'::jsonb
      else jsonb_build_object('inventory', v_consumption)
    end
  );
end;
$$;

-- ------------------------------------------------------------
-- review_task: restore inventory when work is returned (same signature)
-- ------------------------------------------------------------

create or replace function public.review_task(
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
  v_restored numeric := 0;
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

  -- Work sent back for correction restores the consumed product so the
  -- redo can consume again (owner decision 10).
  if p_decision = 'returned_for_correction' then
    v_restored := private.reverse_inventory_for_task(
      p_task_id, v_actor_id, 'Returned for correction'
    );
  end if;

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
    ) || case
      when v_restored > 0
        then jsonb_build_object('inventory_restored', v_restored)
      else '{}'::jsonb
    end
  );

  return v_review_id;
end;
$$;

-- ------------------------------------------------------------
-- Inventory item images: readable by operational farm members
-- (path family {uid}/{farm_id}/inventory/{item_id}/{file})
-- ------------------------------------------------------------

create or replace function private.can_view_inventory_image_path(
  p_name text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_parts text[] := storage.foldername(p_name);
  v_farm uuid;
begin
  if array_length(v_parts, 1) < 3 or v_parts[3] <> 'inventory' then
    return false;
  end if;

  begin
    v_farm := v_parts[2]::uuid;
  exception
    when invalid_text_representation then
      return false;
  end;

  return private.is_operational_farm_member(v_farm);
end;
$$;

revoke all on function private.can_view_inventory_image_path(text)
  from public, anon;
grant execute on function private.can_view_inventory_image_path(text)
  to authenticated;

create policy "inventory images readable by farm members"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'farm-evidence'
    and private.can_view_inventory_image_path(name)
  );

-- ------------------------------------------------------------
-- Grants
-- ------------------------------------------------------------

do $$
declare
  v_fn text;
begin
  foreach v_fn in array array[
    'public.create_operation_plan(uuid, public.operation_plan_type, text, public.operation_schedule_type, date, text, public.operation_plan_status, date, time, integer, smallint[], jsonb, jsonb, uuid, public.fertilizer_application_method, numeric, public.application_rate_basis, public.inventory_unit, uuid[])',
    'public.update_operation_plan(uuid, text, text, public.operation_plan_status, public.operation_schedule_type, date, date, time, integer, smallint[], jsonb, boolean, jsonb, boolean, boolean, boolean, boolean, boolean, uuid, public.fertilizer_application_method, numeric, public.application_rate_basis, public.inventory_unit, boolean, uuid[])',
    'public.check_operation_plan_inventory(uuid, integer)',
    'public.generate_farm_tasks_now(uuid, date)'
  ] loop
    execute format('revoke all on function %s from public, anon', v_fn);
    execute format(
      'grant execute on function %s to authenticated, service_role', v_fn
    );
  end loop;
end;
$$;
