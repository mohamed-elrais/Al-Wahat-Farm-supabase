begin;

create extension if not exists pgtap with schema extensions;

set local search_path = public, extensions;

create schema if not exists test;

create or replace function test.set_auth(p_user_id uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_user_id::text, ''), true);
  perform set_config(
    'request.jwt.claim.role',
    case when p_user_id is null then '' else 'authenticated' end,
    true
  );
end;
$$;

select plan(22);

-- ------------------------------------------------------------
-- Seed: farm, manager, section, two zones (30 + 60 trees), product
-- ------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
)
values
  ('50000000-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'rules-manager@example.test', '', now(), now(), now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"full_name":"Rules Manager"}'::jsonb);

insert into public.farms (id, name, code)
values ('51000000-0000-0000-0000-000000000001', 'Rules Farm', 'RULE');

insert into public.farm_memberships (farm_id, profile_id, role)
values ('51000000-0000-0000-0000-000000000001',
        '50000000-0000-0000-0000-000000000001', 'owner');

insert into public.farm_sections (id, farm_id, code, name, sort_order)
values ('51000000-0000-0000-0000-000000000002',
        '51000000-0000-0000-0000-000000000001', 'R', 'Section R', 97);

insert into public.irrigation_zones (id, section_id, code, name)
values
  ('51000000-0000-0000-0000-000000000003',
   '51000000-0000-0000-0000-000000000002', 'ZCV-R1', 'Zone R1'),
  ('51000000-0000-0000-0000-000000000004',
   '51000000-0000-0000-0000-000000000002', 'ZCV-R2', 'Zone R2');

do $$
begin
  for i in 1..30 loop
    insert into public.trees (farm_id, section_id, irrigation_zone_id, tree_code)
    values ('51000000-0000-0000-0000-000000000001',
            '51000000-0000-0000-0000-000000000002',
            '51000000-0000-0000-0000-000000000003',
            'TREE-R1-' || lpad(i::text, 3, '0'));
  end loop;
  for i in 1..60 loop
    insert into public.trees (farm_id, section_id, irrigation_zone_id, tree_code)
    values ('51000000-0000-0000-0000-000000000001',
            '51000000-0000-0000-0000-000000000002',
            '51000000-0000-0000-0000-000000000004',
            'TREE-R2-' || lpad(i::text, 3, '0'));
  end loop;
end;
$$;

select test.set_auth('50000000-0000-0000-0000-000000000001');

create temp table _d (key text primary key, id uuid) on commit drop;

insert into _d
select 'calcium', public.create_inventory_item(
  '51000000-0000-0000-0000-000000000001',
  (select id from public.inventory_categories
   where farm_id = '51000000-0000-0000-0000-000000000001'
     and code = 'fertilizer'),
  'Calcium', 'gram',
  p_initial_quantity => 1000
);

-- ------------------------------------------------------------
-- 1-4: creation date rules
-- ------------------------------------------------------------

select throws_ok(
  $sql$
    select public.create_operation_plan(
      '51000000-0000-0000-0000-000000000001', 'irrigation',
      'No end', 'daily', current_date)
  $sql$,
  '23514', 'Schedules need an end date',
  'an end date is required'
);

select throws_ok(
  $sql$
    select public.create_operation_plan(
      '51000000-0000-0000-0000-000000000001', 'irrigation',
      'Past start', 'daily', current_date - 1,
      p_ends_on => current_date + 5)
  $sql$,
  '23514', 'The start date cannot be in the past',
  'the start date cannot be in the past'
);

select throws_ok(
  $sql$
    select public.create_operation_plan(
      '51000000-0000-0000-0000-000000000001', 'irrigation',
      'Backwards', 'daily', current_date + 5,
      p_ends_on => current_date + 2)
  $sql$,
  '23514', 'The end date cannot be before the start date',
  'the end date cannot be before the start date'
);

select throws_ok(
  $sql$
    select public.create_operation_plan(
      '51000000-0000-0000-0000-000000000001', 'irrigation',
      'Too long', 'daily', current_date,
      p_ends_on => current_date + 45)
  $sql$,
  '23514',
  'The end date cannot be more than one month after the start date',
  'the end date is capped at one month after the start'
);

-- ------------------------------------------------------------
-- 5-7: grouping validation
-- ------------------------------------------------------------

select throws_ok(
  $sql$
    select public.create_operation_plan(
      '51000000-0000-0000-0000-000000000001', 'irrigation',
      'Mixed combined', 'daily', current_date,
      p_ends_on => current_date + 7,
      p_task_grouping => 'combined',
      p_targets => jsonb_build_array(
        jsonb_build_object('section_id', '51000000-0000-0000-0000-000000000002'),
        jsonb_build_object('irrigation_zone_id', '51000000-0000-0000-0000-000000000003')
      ))
  $sql$,
  '23514', 'A combined task can only group targets of the same kind',
  'combined plans cannot mix target kinds'
);

select throws_ok(
  $sql$
    select public.create_operation_plan(
      '51000000-0000-0000-0000-000000000001', 'irrigation',
      'Farm-wide combined', 'daily', current_date,
      p_ends_on => current_date + 7,
      p_task_grouping => 'combined')
  $sql$,
  '23514',
  'A combined-task schedule needs specific targets, not the whole farm',
  'combined plans need concrete targets'
);

select throws_ok(
  $sql$
    select public.create_operation_plan(
      '51000000-0000-0000-0000-000000000001', 'irrigation',
      'Bad grouping', 'daily', current_date,
      p_ends_on => current_date + 7,
      p_task_grouping => 'sideways')
  $sql$,
  '23514', 'Unknown task grouping',
  'unknown grouping values are rejected'
);

-- ------------------------------------------------------------
-- 8-13: combined generation (100 g/feddan over 30 + 60 trees
--        = 50 + 100 = 150 g total per date)
-- ------------------------------------------------------------

insert into _d
select 'combined', public.create_operation_plan(
  '51000000-0000-0000-0000-000000000001', 'fertilization',
  'Feed both zones', 'daily', current_date,
  p_status => 'active',
  p_ends_on => current_date + 7,
  p_task_grouping => 'combined',
  p_targets => jsonb_build_array(
    jsonb_build_object('irrigation_zone_id', '51000000-0000-0000-0000-000000000003'),
    jsonb_build_object('irrigation_zone_id', '51000000-0000-0000-0000-000000000004')
  ),
  p_inventory_item_id => (select id from _d where key = 'calcium'),
  p_application_method => 'fertigation',
  p_application_rate => 100,
  p_rate_basis => 'per_feddan',
  p_rate_unit => 'gram'
);

select is(
  (select task_grouping from public.operation_plans
   where id = (select id from _d where key = 'combined')),
  'combined',
  'the plan stores its task grouping'
);

select is(
  (select count(*)::int
   from public.generate_operation_tasks_for_date(
     '51000000-0000-0000-0000-000000000001', current_date + 1)),
  2,
  'a combined plan still reports one run per target'
);

select is(
  (select count(distinct generated_task_id)::int
   from public.operation_plan_runs
   where operation_plan_id = (select id from _d where key = 'combined')
     and operation_date = current_date + 1),
  1,
  'both runs point at one combined task'
);

insert into _d
select 'combitask', r.generated_task_id
from public.operation_plan_runs r
where r.operation_plan_id = (select id from _d where key = 'combined')
  and r.operation_date = current_date + 1
limit 1;

select is(
  (select count(*)::int from public.task_targets
   where task_id = (select id from _d where key = 'combitask')),
  2,
  'the combined task carries both zone targets'
);

select is(
  (select (instructions ->> 'required_quantity')::numeric
   from public.tasks where id = (select id from _d where key = 'combitask')),
  150::numeric,
  'the combined dose is the sum over all targets (50 + 100 g)'
);

select is(
  (select count(*)::int
   from public.generate_operation_tasks_for_date(
     '51000000-0000-0000-0000-000000000001', current_date + 1)),
  0,
  'regeneration for the same date is a no-op'
);

-- ------------------------------------------------------------
-- 14-16: combined shortage blocks the whole group; restock recovers
-- ------------------------------------------------------------

insert into _d
select 'bigcombined', public.create_operation_plan(
  '51000000-0000-0000-0000-000000000001', 'fertilization',
  'Huge combined dose', 'once', current_date + 2,
  p_status => 'active',
  p_ends_on => current_date + 2,
  p_task_grouping => 'combined',
  p_targets => jsonb_build_array(
    jsonb_build_object('irrigation_zone_id', '51000000-0000-0000-0000-000000000003'),
    jsonb_build_object('irrigation_zone_id', '51000000-0000-0000-0000-000000000004')
  ),
  p_inventory_item_id => (select id from _d where key = 'calcium'),
  p_application_rate => 1000,
  p_rate_basis => 'per_feddan',
  p_rate_unit => 'gram'
);

select is(
  (select count(*)::int
   from public.generate_operation_tasks_for_date(
     '51000000-0000-0000-0000-000000000001', current_date + 2)),
  2,
  'the daily combined plan still generates on the once plan''s date'
);

select is(
  (select count(*)::int from public.operation_plan_runs
   where operation_plan_id = (select id from _d where key = 'bigcombined')
     and blocked_reason = 'insufficient_stock'),
  2,
  'a shortage for the group total blocks every run of the group'
);

select lives_ok(
  $sql$
    select public.record_inventory_transaction(
      (select id from _d where key = 'calcium'), 'addition', 2000, 'Restock')
  $sql$,
  'restock succeeds'
);

-- Materialize the recovery pass first: reading operation_plan_runs in
-- the same statement would see the pre-update snapshot.
select is(
  (select count(*)::int
   from public.generate_operation_tasks_for_date(
     '51000000-0000-0000-0000-000000000001', current_date + 2)),
  2,
  'after restock the blocked group generates (one run per target)'
);

select is(
  (select count(distinct generated_task_id)::int
   from public.operation_plan_runs
   where operation_plan_id = (select id from _d where key = 'bigcombined')
     and generated_task_id is not null),
  1,
  'the recovered group shares one combined task'
);

-- ------------------------------------------------------------
-- 17-19: per-target default unchanged + update-side date rules
-- ------------------------------------------------------------

insert into _d
select 'separate', public.create_operation_plan(
  '51000000-0000-0000-0000-000000000001', 'irrigation',
  'Water both zones', 'once', current_date + 3,
  p_status => 'active',
  p_ends_on => current_date + 3,
  p_targets => jsonb_build_array(
    jsonb_build_object('irrigation_zone_id', '51000000-0000-0000-0000-000000000003'),
    jsonb_build_object('irrigation_zone_id', '51000000-0000-0000-0000-000000000004')
  )
);

select lives_ok(
  $sql$
    select count(*)
    from public.generate_operation_tasks_for_date(
      '51000000-0000-0000-0000-000000000001', current_date + 3)
  $sql$,
  'generation for the per-target date succeeds'
);

select is(
  (select count(distinct generated_task_id)::int
   from public.operation_plan_runs
   where operation_plan_id = (select id from _d where key = 'separate')
     and generated_task_id is not null),
  2,
  'per-target plans keep creating one task per target'
);

select throws_ok(
  $sql$
    select public.update_operation_plan(
      (select id from _d where key = 'separate'),
      p_clear_ends_on => true)
  $sql$,
  '23514', 'Schedules need an end date',
  'the end date cannot be cleared'
);

select throws_ok(
  $sql$
    select public.update_operation_plan(
      (select id from _d where key = 'separate'),
      p_ends_on => current_date + 60)
  $sql$,
  '23514',
  'The end date cannot be more than one month after the start date',
  'updates also enforce the one-month cap'
);

select * from finish();

rollback;
