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

select plan(25);

-- ------------------------------------------------------------
-- Seed: farm, manager, worker, section, zone, 30 trees, product
-- ------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
)
values
  ('30000000-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'dose-manager@example.test', '', now(), now(), now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"full_name":"Dose Manager"}'::jsonb),
  ('30000000-0000-0000-0000-000000000002',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'dose-worker@example.test', '', now(), now(), now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"full_name":"Dose Worker"}'::jsonb);

insert into public.farms (id, name, code)
values ('31000000-0000-0000-0000-000000000001', 'Dosing Farm', 'DOSE');

insert into public.farm_memberships (farm_id, profile_id, role)
values
  ('31000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000001', 'owner'),
  ('31000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000002', 'worker');

insert into public.farm_sections (id, farm_id, code, name, sort_order)
values ('31000000-0000-0000-0000-000000000002',
        '31000000-0000-0000-0000-000000000001', 'Z', 'Section Z', 99);

insert into public.irrigation_zones (id, section_id, code, name)
values ('31000000-0000-0000-0000-000000000003',
        '31000000-0000-0000-0000-000000000002', 'ZCV-01', 'Zone 1');

do $$
begin
  for i in 1..30 loop
    insert into public.trees (farm_id, section_id, irrigation_zone_id, tree_code)
    values (
      '31000000-0000-0000-0000-000000000001',
      '31000000-0000-0000-0000-000000000002',
      '31000000-0000-0000-0000-000000000003',
      'TREE-Z-' || lpad(i::text, 3, '0')
    );
  end loop;
end;
$$;

select test.set_auth('30000000-0000-0000-0000-000000000001');

create temp table _d (key text primary key, id uuid) on commit drop;

-- Relative dates so the suite stays valid as time passes AND satisfies
-- the schedule date rules (start >= today, end within one month).
create temp table _dates (key text primary key, d date) on commit drop;
insert into _dates values
  ('starts', current_date),
  ('ends', current_date + 27),
  ('friday',
   current_date + 3 + ((5 - extract(isodow from current_date + 3)::int + 7) % 7));
insert into _dates
select 'saturday', d + 1 from _dates where key = 'friday';
insert into _dates
select 'once', d + 3 from _dates where key = 'friday';

insert into _d
select 'calcium', public.create_inventory_item(
  '31000000-0000-0000-0000-000000000001',
  (select id from public.inventory_categories
   where farm_id = '31000000-0000-0000-0000-000000000001'
     and code = 'fertilizer'),
  'Calcium', 'gram',
  p_initial_quantity => 100
);

insert into _d
select 'shovel', public.create_inventory_item(
  '31000000-0000-0000-0000-000000000001',
  (select id from public.inventory_categories
   where farm_id = '31000000-0000-0000-0000-000000000001'
     and code = 'tool'),
  'Shovel', 'piece',
  p_initial_quantity => 5
);

-- ------------------------------------------------------------
-- Plan validation
-- ------------------------------------------------------------

select throws_ok(
  $sql$
    select public.create_operation_plan(
      '31000000-0000-0000-0000-000000000001', 'fertilization',
      'Bad category', 'daily', current_date,
      p_ends_on => current_date + 7,
      p_inventory_item_id => (select id from _d where key = 'shovel'),
      p_application_rate => 10,
      p_rate_basis => 'per_feddan',
      p_rate_unit => 'piece'
    )
  $sql$,
  '23514',
  'Inventory item category does not match the operation type',
  'plan product must belong to a matching category'
);

select throws_ok(
  $sql$
    select public.create_operation_plan(
      '31000000-0000-0000-0000-000000000001', 'fertilization',
      'Rate without product', 'daily', current_date,
      p_ends_on => current_date + 7,
      p_application_rate => 10
    )
  $sql$,
  '23514',
  'An application rate needs a product from the inventory',
  'a rate without a product is rejected'
);

select throws_ok(
  $sql$
    select public.create_operation_plan(
      '31000000-0000-0000-0000-000000000001', 'irrigation',
      'Watered fertilizer', 'daily', current_date,
      p_ends_on => current_date + 7,
      p_inventory_item_id => (select id from _d where key = 'calcium'),
      p_application_rate => 10,
      p_rate_basis => 'per_feddan',
      p_rate_unit => 'gram'
    )
  $sql$,
  '23514',
  'Irrigation plans cannot carry a product',
  'irrigation plans cannot carry a product'
);

-- ------------------------------------------------------------
-- Weekly fertilization plan: 100 g per feddan on a 30-tree zone
-- (30 trees / 60 trees-per-feddan = 0.5 feddan -> 50 g per run)
-- ------------------------------------------------------------

insert into _d
select 'plan', public.create_operation_plan(
  '31000000-0000-0000-0000-000000000001', 'fertilization',
  'Friday calcium', 'weekly', (select d from _dates where key = 'starts'),
  p_status => 'active',
  p_ends_on => (select d from _dates where key = 'ends'),
  p_scheduled_start_time => time '08:00',
  p_days_of_week => array[5::smallint], -- Friday
  p_targets => jsonb_build_array(jsonb_build_object(
    'irrigation_zone_id', '31000000-0000-0000-0000-000000000003'
  )),
  p_inventory_item_id => (select id from _d where key = 'calcium'),
  p_application_method => 'fertigation',
  p_application_rate => 100,
  p_rate_basis => 'per_feddan',
  p_rate_unit => 'gram',
  p_default_assignee_profile_ids =>
    array['30000000-0000-0000-0000-000000000002']::uuid[]
);

select is(
  (select count(*)::int
   from public.generate_operation_tasks_for_date(
     '31000000-0000-0000-0000-000000000001',
     (select d from _dates where key = 'friday'))),
  1,
  'a matching weekly date generates one task per target'
);

insert into _d
select 'task', r.generated_task_id
from public.operation_plan_runs r
where r.operation_plan_id = (select id from _d where key = 'plan')
  and r.operation_date = (select d from _dates where key = 'friday');

select is(
  (select (instructions ->> 'required_quantity')::numeric
   from public.tasks where id = (select id from _d where key = 'task')),
  50::numeric,
  'per-feddan dosing computed from the zone tree count (30/60 x 100 g)'
);

select is(
  (select status::text from public.tasks
   where id = (select id from _d where key = 'task')),
  'assigned',
  'default assignees make the generated task assigned'
);

select is(
  (select count(*)::int from public.task_assignments
   where task_id = (select id from _d where key = 'task')
     and assignee_profile_id = '30000000-0000-0000-0000-000000000002'
     and is_active),
  1,
  'the default worker is assigned'
);

select is(
  (select count(*)::int
   from public.generate_operation_tasks_for_date(
     '31000000-0000-0000-0000-000000000001',
     (select d from _dates where key = 'friday'))),
  0,
  'regeneration for the same date is a no-op (dedup)'
);

select is(
  (select count(*)::int
   from public.generate_operation_tasks_for_date(
     '31000000-0000-0000-0000-000000000001',
     (select d from _dates where key = 'saturday'))),
  0,
  'non-matching weekday generates nothing'
);

-- ------------------------------------------------------------
-- check_operation_plan_inventory
-- ------------------------------------------------------------

select is(
  (select applications_covered
   from public.check_operation_plan_inventory(
     (select id from _d where key = 'plan'), 30)
   limit 1),
  2,
  'stock of 100 g covers two 50 g applications'
);

-- ------------------------------------------------------------
-- Insufficient stock BLOCKS generation; restock recovers
-- ------------------------------------------------------------

insert into _d
select 'bigplan', public.create_operation_plan(
  '31000000-0000-0000-0000-000000000001', 'fertilization',
  'Huge dose', 'once', (select d from _dates where key = 'once'),
  p_ends_on => (select d from _dates where key = 'once'),
  p_status => 'active',
  p_targets => jsonb_build_array(jsonb_build_object(
    'irrigation_zone_id', '31000000-0000-0000-0000-000000000003'
  )),
  p_inventory_item_id => (select id from _d where key = 'calcium'),
  p_application_rate => 1000,
  p_rate_basis => 'per_feddan',
  p_rate_unit => 'gram'
);

select is(
  (select count(*)::int
   from public.generate_operation_tasks_for_date(
     '31000000-0000-0000-0000-000000000001',
     (select d from _dates where key = 'once'))),
  0,
  'insufficient stock blocks task generation'
);

select is(
  (select blocked_reason from public.operation_plan_runs
   where operation_plan_id = (select id from _d where key = 'bigplan')),
  'insufficient_stock',
  'the blocked run records why'
);

select is(
  (select generated_task_id from public.operation_plan_runs
   where operation_plan_id = (select id from _d where key = 'bigplan')),
  null,
  'no task exists for the blocked run'
);

-- Restock (need 500 g total) and regenerate the same date.
select lives_ok(
  $sql$
    select public.record_inventory_transaction(
      (select id from _d where key = 'calcium'), 'addition', 900, 'Restock')
  $sql$,
  'restock succeeds'
);

select is(
  (select count(*)::int
   from public.generate_operation_tasks_for_date(
     '31000000-0000-0000-0000-000000000001',
     (select d from _dates where key = 'once'))),
  1,
  'the blocked run generates its task after restock'
);

select is(
  (select blocked_reason from public.operation_plan_runs
   where operation_plan_id = (select id from _d where key = 'bigplan')),
  null,
  'the blocked reason clears once the task is generated'
);

-- ------------------------------------------------------------
-- Completion consumes; replay cannot double-deduct
-- ------------------------------------------------------------

select test.set_auth('30000000-0000-0000-0000-000000000002');

select lives_ok(
  $sql$
    select public.complete_task(
      (select id from _d where key = 'task'),
      p_op_id => '32000000-0000-0000-0000-000000000001')
  $sql$,
  'worker completes the generated task'
);

select is(
  (select quantity from public.inventory_items
   where id = (select id from _d where key = 'calcium')),
  950.000,
  'completion consumed the computed 50 g (1000 - 50)'
);

select is(
  (select (metadata -> 'inventory' ->> 'consumed')::numeric
   from public.task_activity_log
   where task_id = (select id from _d where key = 'task')
     and action = 'completed'),
  50::numeric,
  'completion activity records the consumption'
);

select lives_ok(
  $sql$
    select public.complete_task(
      (select id from _d where key = 'task'),
      p_op_id => '32000000-0000-0000-0000-000000000001')
  $sql$,
  'completion replay with the same op id is accepted'
);

select is(
  (select quantity from public.inventory_items
   where id = (select id from _d where key = 'calcium')),
  950.000,
  'replay did not deduct twice'
);

-- ------------------------------------------------------------
-- Returned-for-correction restores; redo consumes again
-- ------------------------------------------------------------

select test.set_auth('30000000-0000-0000-0000-000000000001');

select lives_ok(
  $sql$
    select public.review_task(
      (select id from _d where key = 'task'),
      'returned_for_correction', 'Redo the dosing')
  $sql$,
  'manager returns the task for correction'
);

select is(
  (select quantity from public.inventory_items
   where id = (select id from _d where key = 'calcium')),
  1000.000,
  'returned-for-correction restored the consumed stock'
);

select test.set_auth('30000000-0000-0000-0000-000000000002');

select lives_ok(
  $sql$
    select public.complete_task((select id from _d where key = 'task'))
  $sql$,
  'the returned task can be completed again'
);

select is(
  (select quantity from public.inventory_items
   where id = (select id from _d where key = 'calcium')),
  950.000,
  're-completion consumed again after the reversal'
);

select * from finish();

rollback;
