-- ============================================================
-- Al-Wahat Farm
-- Agricultural operation plans
-- ============================================================

create type public.operation_plan_type as enum (
  'irrigation',
  'fertilization',
  'harmful_weed_control'
);

create type public.operation_plan_status as enum (
  'draft',
  'active',
  'paused',
  'completed',
  'archived'
);

create type public.operation_schedule_type as enum (
  'once',
  'daily',
  'weekly'
);

create type public.fertilizer_application_method as enum (
  'fertigation',
  'soil_application',
  'foliar_spray',
  'manual_application'
);

create table public.operation_plans (
  id uuid primary key default gen_random_uuid(),

  farm_id uuid not null
    references public.farms(id)
    on delete cascade,

  operation_type public.operation_plan_type not null,
  title text not null,
  description text,

  status public.operation_plan_status not null default 'draft',
  schedule_type public.operation_schedule_type not null,

  starts_on date not null,
  ends_on date,
  scheduled_start_time time,
  planned_duration_minutes integer,
  days_of_week smallint[],

  instructions jsonb not null default '{}'::jsonb,

  created_by_profile_id uuid not null
    references public.profiles(id)
    on delete restrict,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint operation_plans_title_not_blank_check
    check (nullif(trim(title), '') is not null),

  constraint operation_plans_ends_on_check
    check (ends_on is null or ends_on >= starts_on),

  constraint operation_plans_duration_positive_check
    check (
      planned_duration_minutes is null
      or planned_duration_minutes > 0
    ),

  constraint operation_plans_instructions_object_check
    check (jsonb_typeof(instructions) = 'object'),

  constraint operation_plans_weekly_days_check
    check (
      (
        schedule_type <> 'weekly'
        and days_of_week is null
      )
      or (
        schedule_type = 'weekly'
        and cardinality(days_of_week) > 0
        and days_of_week <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]
      )
    )
);

create table public.operation_plan_targets (
  id uuid primary key default gen_random_uuid(),

  operation_plan_id uuid not null
    references public.operation_plans(id)
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

  is_active boolean not null default true,
  deactivated_at timestamptz,

  created_at timestamptz not null default now(),

  constraint operation_plan_targets_one_scope_check
    check (num_nonnulls(section_id, irrigation_zone_id, palm_tree_id) <= 1),

  constraint operation_plan_targets_deactivated_at_check
    check (
      (is_active = true and deactivated_at is null)
      or is_active = false
    )
);

create table public.operation_plan_runs (
  id uuid primary key default gen_random_uuid(),

  operation_plan_id uuid not null
    references public.operation_plans(id)
    on delete cascade,

  operation_plan_target_id uuid not null
    references public.operation_plan_targets(id)
    on delete restrict,

  operation_date date not null,

  generated_task_id uuid
    references public.tasks(id)
    on delete set null,

  generated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  unique (
    operation_plan_id,
    operation_plan_target_id,
    operation_date
  )
);

create unique index operation_plan_runs_generated_task_id_idx
  on public.operation_plan_runs (generated_task_id)
  where generated_task_id is not null;

create unique index operation_plan_targets_one_active_farm_wide_idx
  on public.operation_plan_targets (operation_plan_id)
  where is_active = true
    and section_id is null
    and irrigation_zone_id is null
    and palm_tree_id is null;

create unique index operation_plan_targets_one_active_section_idx
  on public.operation_plan_targets (operation_plan_id, section_id)
  where is_active = true
    and section_id is not null;

create unique index operation_plan_targets_one_active_zone_idx
  on public.operation_plan_targets (operation_plan_id, irrigation_zone_id)
  where is_active = true
    and irrigation_zone_id is not null;

create unique index operation_plan_targets_one_active_palm_idx
  on public.operation_plan_targets (operation_plan_id, palm_tree_id)
  where is_active = true
    and palm_tree_id is not null;

create index operation_plans_farm_status_schedule_idx
  on public.operation_plans (farm_id, status, schedule_type, starts_on, ends_on);

create index operation_plan_targets_plan_active_idx
  on public.operation_plan_targets (operation_plan_id, is_active);

create index operation_plan_targets_section_id_idx
  on public.operation_plan_targets (section_id);

create index operation_plan_targets_irrigation_zone_id_idx
  on public.operation_plan_targets (irrigation_zone_id);

create index operation_plan_targets_palm_tree_id_idx
  on public.operation_plan_targets (palm_tree_id);

create index operation_plan_runs_plan_date_idx
  on public.operation_plan_runs (operation_plan_id, operation_date);

create index operation_plan_runs_target_date_idx
  on public.operation_plan_runs (operation_plan_target_id, operation_date);

create trigger operation_plans_set_updated_at
before update on public.operation_plans
for each row
execute function public.set_updated_at();

-- ------------------------------------------------------------
-- Validation helpers
-- ------------------------------------------------------------

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

  if new.palm_tree_id is not null
    and not exists (
      select 1
      from public.palm_trees p
      where p.id = new.palm_tree_id
        and p.farm_id = v_farm_id
    ) then
    raise exception 'The selected palm does not belong to this plan farm'
      using errcode = '23514';
  end if;

  if new.is_active = false
    and new.deactivated_at is null then
    new.deactivated_at = now();
  end if;

  return new;
end;
$$;

revoke all on function public.validate_operation_plan_target_scope()
from public, anon, authenticated;

create trigger operation_plan_targets_validate_scope
before insert or update of
  operation_plan_id,
  section_id,
  irrigation_zone_id,
  palm_tree_id,
  is_active,
  deactivated_at
on public.operation_plan_targets
for each row
execute function public.validate_operation_plan_target_scope();

create or replace function private.can_view_operation_plan(
  p_operation_plan_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.operation_plans op
    where op.id = p_operation_plan_id
      and private.is_operational_manager(op.farm_id)
  );
$$;

create or replace function private.can_view_operation_plan_run(
  p_operation_plan_run_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.operation_plan_runs opr
    join public.operation_plans op
      on op.id = opr.operation_plan_id
    where opr.id = p_operation_plan_run_id
      and private.is_operational_manager(op.farm_id)
  );
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
        'palm_tree_id'
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
        when v_target ? 'palm_tree_id'
          and v_target -> 'palm_tree_id' <> 'null'::jsonb
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

    if v_target ? 'palm_tree_id'
      and v_target -> 'palm_tree_id' <> 'null'::jsonb
      and (
        jsonb_typeof(v_target -> 'palm_tree_id') <> 'string'
        or v_target ->> 'palm_tree_id' !~ v_uuid_pattern
      ) then
      raise exception 'Target item % has an invalid palm_tree_id', v_index
        using errcode = '23514';
    end if;
  end loop;

  with desired_targets as (
    select distinct
      parsed.section_id,
      parsed.irrigation_zone_id,
      parsed.palm_tree_id
    from jsonb_to_recordset(v_targets) as parsed(
      section_id uuid,
      irrigation_zone_id uuid,
      palm_tree_id uuid
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
        and desired.palm_tree_id is not distinct from opt.palm_tree_id
    );

  with desired_targets as (
    select distinct
      parsed.section_id,
      parsed.irrigation_zone_id,
      parsed.palm_tree_id
    from jsonb_to_recordset(v_targets) as parsed(
      section_id uuid,
      irrigation_zone_id uuid,
      palm_tree_id uuid
    )
  ),
  inactive_matches as (
    select distinct on (
      desired.section_id,
      desired.irrigation_zone_id,
      desired.palm_tree_id
    )
      opt.id
    from desired_targets desired
    join public.operation_plan_targets opt
      on opt.operation_plan_id = p_operation_plan_id
     and opt.is_active = false
     and desired.section_id is not distinct from opt.section_id
     and desired.irrigation_zone_id is not distinct from opt.irrigation_zone_id
     and desired.palm_tree_id is not distinct from opt.palm_tree_id
    where not exists (
      select 1
      from public.operation_plan_targets active_opt
      where active_opt.operation_plan_id = p_operation_plan_id
        and active_opt.is_active = true
        and desired.section_id is not distinct from active_opt.section_id
        and desired.irrigation_zone_id is not distinct from active_opt.irrigation_zone_id
        and desired.palm_tree_id is not distinct from active_opt.palm_tree_id
    )
    order by
      desired.section_id,
      desired.irrigation_zone_id,
      desired.palm_tree_id,
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
      parsed.palm_tree_id
    from jsonb_to_recordset(v_targets) as parsed(
      section_id uuid,
      irrigation_zone_id uuid,
      palm_tree_id uuid
    )
  )
  insert into public.operation_plan_targets (
    operation_plan_id,
    section_id,
    irrigation_zone_id,
    palm_tree_id
  )
  select distinct
    p_operation_plan_id,
    desired.section_id,
    desired.irrigation_zone_id,
    desired.palm_tree_id
  from desired_targets desired
  where not exists (
    select 1
    from public.operation_plan_targets opt
    where opt.operation_plan_id = p_operation_plan_id
      and opt.is_active = true
      and desired.section_id is not distinct from opt.section_id
      and desired.irrigation_zone_id is not distinct from opt.irrigation_zone_id
      and desired.palm_tree_id is not distinct from opt.palm_tree_id
  )
  and not exists (
    select 1
    from public.operation_plan_targets opt
    where opt.operation_plan_id = p_operation_plan_id
      and opt.is_active = false
      and desired.section_id is not distinct from opt.section_id
      and desired.irrigation_zone_id is not distinct from opt.irrigation_zone_id
      and desired.palm_tree_id is not distinct from opt.palm_tree_id
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

revoke all on function private.can_view_operation_plan(uuid)
from public, anon;

revoke all on function private.can_view_operation_plan_run(uuid)
from public, anon;

revoke all on function private.replace_operation_plan_targets(uuid, jsonb)
from public, anon;

grant execute on function private.can_view_operation_plan(uuid)
to authenticated;

grant execute on function private.can_view_operation_plan_run(uuid)
to authenticated;

-- ------------------------------------------------------------
-- Controlled RPCs
-- ------------------------------------------------------------

create or replace function public.create_operation_plan(
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
  p_targets jsonb default '[{}]'::jsonb
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

  insert into public.operation_plans (
    farm_id,
    operation_type,
    title,
    description,
    status,
    schedule_type,
    starts_on,
    ends_on,
    scheduled_start_time,
    planned_duration_minutes,
    days_of_week,
    instructions,
    created_by_profile_id
  )
  values (
    p_farm_id,
    p_operation_type,
    trim(p_title),
    p_description,
    coalesce(p_status, 'draft'::public.operation_plan_status),
    p_schedule_type,
    p_starts_on,
    p_ends_on,
    p_scheduled_start_time,
    p_planned_duration_minutes,
    case
      when p_schedule_type = 'weekly' then p_days_of_week
      else null
    end,
    coalesce(p_instructions, '{}'::jsonb),
    v_actor_id
  )
  returning id into v_plan_id;

  perform private.replace_operation_plan_targets(v_plan_id, p_targets);

  return v_plan_id;
end;
$$;

create or replace function public.update_operation_plan(
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
  p_clear_days_of_week boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_farm_id uuid;
  v_schedule_type public.operation_schedule_type;
  v_days_of_week smallint[];
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  select op.farm_id
  into v_farm_id
  from public.operation_plans op
  where op.id = p_operation_plan_id
  for update;

  if not found then
    raise exception 'Operation plan not found'
      using errcode = 'P0002';
  end if;

  if not private.is_operational_manager(v_farm_id) then
    raise exception 'Only the owner or agricultural engineer can update operation plans'
      using errcode = '42501';
  end if;

  v_schedule_type := coalesce(
    p_schedule_type,
    (
      select op.schedule_type
      from public.operation_plans op
      where op.id = p_operation_plan_id
    )
  );

  v_days_of_week :=
    case
      when v_schedule_type = 'weekly' then
        coalesce(
          p_days_of_week,
          (
            select op.days_of_week
            from public.operation_plans op
            where op.id = p_operation_plan_id
          )
        )
      else null
    end;

  if coalesce(p_clear_days_of_week, false)
    and v_schedule_type = 'weekly' then
    raise exception 'days_of_week cannot be cleared for a weekly plan'
      using errcode = '23514';
  end if;

  if v_schedule_type = 'weekly'
    and (
      v_days_of_week is null
      or cardinality(v_days_of_week) = 0
      or not v_days_of_week <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]
    ) then
    raise exception 'Weekly plans require one or more ISO weekdays from 1 through 7'
      using errcode = '23514';
  end if;

  update public.operation_plans
  set
    title = coalesce(nullif(trim(p_title), ''), title),
    description = case
      when coalesce(p_clear_description, false) then null
      else coalesce(p_description, description)
    end,
    status = coalesce(p_status, status),
    schedule_type = v_schedule_type,
    starts_on = coalesce(p_starts_on, starts_on),
    ends_on = case
      when coalesce(p_clear_ends_on, false) then null
      else coalesce(p_ends_on, ends_on)
    end,
    scheduled_start_time = case
      when coalesce(p_clear_scheduled_start_time, false) then null
      else coalesce(p_scheduled_start_time, scheduled_start_time)
    end,
    planned_duration_minutes = case
      when coalesce(p_clear_planned_duration_minutes, false) then null
      else coalesce(p_planned_duration_minutes, planned_duration_minutes)
    end,
    days_of_week = case
      when coalesce(p_clear_days_of_week, false) then null
      when v_schedule_type = 'weekly' then v_days_of_week
      else null
    end,
    instructions = coalesce(p_instructions, instructions)
  where id = p_operation_plan_id;

  if coalesce(p_replace_targets, false) then
    perform private.replace_operation_plan_targets(
      p_operation_plan_id,
      p_targets
    );
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
          palm_tree_id,
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
          v_target.palm_tree_id,
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
      'palm_tree_id',
      opt.palm_tree_id,
      'is_farm_wide',
      opt.section_id is null
        and opt.irrigation_zone_id is null
        and opt.palm_tree_id is null
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
-- Grants and RLS
-- ------------------------------------------------------------

revoke all on table
  public.operation_plans,
  public.operation_plan_targets,
  public.operation_plan_runs
from anon;

revoke all on table
  public.operation_plans,
  public.operation_plan_targets,
  public.operation_plan_runs
from authenticated;

grant select on table
  public.operation_plans,
  public.operation_plan_targets,
  public.operation_plan_runs
to authenticated;

grant all on table
  public.operation_plans,
  public.operation_plan_targets,
  public.operation_plan_runs
to service_role;

alter table public.operation_plans enable row level security;
alter table public.operation_plan_targets enable row level security;
alter table public.operation_plan_runs enable row level security;

create policy "operation_plans_select_managers"
on public.operation_plans
for select
to authenticated
using (
  private.is_operational_manager(farm_id)
);

create policy "operation_plan_targets_select_managers"
on public.operation_plan_targets
for select
to authenticated
using (
  private.can_view_operation_plan(operation_plan_id)
);

create policy "operation_plan_runs_select_managers"
on public.operation_plan_runs
for select
to authenticated
using (
  private.can_view_operation_plan_run(id)
);

revoke all on function public.create_operation_plan(
  uuid,
  public.operation_plan_type,
  text,
  public.operation_schedule_type,
  date,
  text,
  public.operation_plan_status,
  date,
  time,
  integer,
  smallint[],
  jsonb,
  jsonb
) from public, anon;

revoke all on function public.update_operation_plan(
  uuid,
  text,
  text,
  public.operation_plan_status,
  public.operation_schedule_type,
  date,
  date,
  time,
  integer,
  smallint[],
  jsonb,
  boolean,
  jsonb,
  boolean,
  boolean,
  boolean,
  boolean,
  boolean
) from public, anon;

revoke all on function public.generate_operation_tasks_for_date(uuid, date)
from public, anon, authenticated;

revoke all on function public.get_operation_plan_calendar(uuid, date, date)
from public, anon;

grant execute on function public.create_operation_plan(
  uuid,
  public.operation_plan_type,
  text,
  public.operation_schedule_type,
  date,
  text,
  public.operation_plan_status,
  date,
  time,
  integer,
  smallint[],
  jsonb,
  jsonb
) to authenticated, service_role;

grant execute on function public.update_operation_plan(
  uuid,
  text,
  text,
  public.operation_plan_status,
  public.operation_schedule_type,
  date,
  date,
  time,
  integer,
  smallint[],
  jsonb,
  boolean,
  jsonb,
  boolean,
  boolean,
  boolean,
  boolean,
  boolean
) to authenticated, service_role;

grant execute on function public.generate_operation_tasks_for_date(uuid, date)
to service_role;

grant execute on function public.get_operation_plan_calendar(uuid, date, date)
to authenticated, service_role;
