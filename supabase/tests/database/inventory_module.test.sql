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

select plan(29);

-- ------------------------------------------------------------
-- Seed users, farm (trigger seeds categories), memberships
-- ------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
)
values
  ('20000000-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'inv-manager@example.test', '', now(), now(), now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"full_name":"Inv Manager"}'::jsonb),
  ('20000000-0000-0000-0000-000000000002',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'inv-worker@example.test', '', now(), now(), now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"full_name":"Inv Worker"}'::jsonb);

insert into public.farms (id, name, code)
values ('21000000-0000-0000-0000-000000000001', 'Inventory Farm', 'INVF');

insert into public.farm_memberships (farm_id, profile_id, role)
values
  ('21000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'owner'),
  ('21000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000002', 'worker');

-- ------------------------------------------------------------
-- Default category seeding
-- ------------------------------------------------------------

select is(
  (select count(*)::int from public.inventory_categories
   where farm_id = '21000000-0000-0000-0000-000000000001'),
  9,
  'creating a farm seeds the nine default inventory categories'
);

select is(
  (select applies_to_operation::text from public.inventory_categories
   where farm_id = '21000000-0000-0000-0000-000000000001'
     and code = 'fungicide'),
  'disease_control',
  'fungicide category maps to disease_control plans'
);

-- ------------------------------------------------------------
-- Role gating
-- ------------------------------------------------------------

select test.set_auth('20000000-0000-0000-0000-000000000002');

select throws_ok(
  $sql$
    select public.create_inventory_item(
      '21000000-0000-0000-0000-000000000001',
      (select id from public.inventory_categories
       where farm_id = '21000000-0000-0000-0000-000000000001'
         and code = 'fertilizer'),
      'Worker Calcium', 'gram'
    )
  $sql$,
  '42501',
  'Only the owner or agricultural engineer can manage inventory',
  'workers cannot create inventory items'
);

-- ------------------------------------------------------------
-- Item creation + initial stock + idempotent replay
-- ------------------------------------------------------------

select test.set_auth('20000000-0000-0000-0000-000000000001');

create temp table _ids (key text primary key, id uuid) on commit drop;

insert into _ids
select 'item', public.create_inventory_item(
  '21000000-0000-0000-0000-000000000001',
  (select id from public.inventory_categories
   where farm_id = '21000000-0000-0000-0000-000000000001'
     and code = 'fertilizer'),
  'Calcium nitrate', 'gram',
  p_description => 'Test fertilizer',
  p_minimum_stock => 20,
  p_initial_quantity => 100,
  p_op_id => '22000000-0000-0000-0000-000000000001'
);

select is(
  (select quantity from public.inventory_items
   where id = (select id from _ids where key = 'item')),
  100.000,
  'initial quantity recorded on the item'
);

select is(
  (select count(*)::int from public.inventory_transactions
   where inventory_item_id = (select id from _ids where key = 'item')),
  1,
  'initial stock wrote one addition ledger row'
);

select is(
  (select resulting_quantity from public.inventory_transactions
   where inventory_item_id = (select id from _ids where key = 'item')),
  100.000,
  'addition ledger row snapshots the resulting quantity'
);

select is(
  public.create_inventory_item(
    '21000000-0000-0000-0000-000000000001',
    (select id from public.inventory_categories
     where farm_id = '21000000-0000-0000-0000-000000000001'
       and code = 'fertilizer'),
    'Calcium nitrate', 'gram',
    p_initial_quantity => 100,
    p_op_id => '22000000-0000-0000-0000-000000000001'
  ),
  (select id from _ids where key = 'item'),
  'item creation replay with the same op id returns the original item'
);

select is(
  (select count(*)::int from public.inventory_items
   where farm_id = '21000000-0000-0000-0000-000000000001'),
  1,
  'replay did not create a duplicate item'
);

-- ------------------------------------------------------------
-- Stock movements
-- ------------------------------------------------------------

insert into _ids
select 'txn', public.record_inventory_transaction(
  (select id from _ids where key = 'item'),
  'addition', 50, 'Purchase',
  p_op_id => '22000000-0000-0000-0000-000000000002'
);

select is(
  (select quantity from public.inventory_items
   where id = (select id from _ids where key = 'item')),
  150.000,
  'addition raises stock'
);

select is(
  public.record_inventory_transaction(
    (select id from _ids where key = 'item'),
    'addition', 50, 'Purchase',
    p_op_id => '22000000-0000-0000-0000-000000000002'
  ),
  (select id from _ids where key = 'txn'),
  'transaction replay with the same op id is a no-op returning the original row'
);

select is(
  (select quantity from public.inventory_items
   where id = (select id from _ids where key = 'item')),
  150.000,
  'replayed addition did not double-apply'
);

select lives_ok(
  $sql$
    select public.record_inventory_transaction(
      (select id from _ids where key = 'item'), 'adjustment', -30, 'Damaged bags'
    )
  $sql$,
  'negative adjustment within stock succeeds'
);

select is(
  (select quantity from public.inventory_items
   where id = (select id from _ids where key = 'item')),
  120.000,
  'adjustment lowers stock'
);

select throws_ok(
  $sql$
    select public.record_inventory_transaction(
      (select id from _ids where key = 'item'), 'adjustment', -500, 'Too much'
    )
  $sql$,
  '23514',
  null,
  'adjustments cannot make stock negative'
);

select throws_ok(
  $sql$
    select public.record_inventory_transaction(
      (select id from _ids where key = 'item'), 'consumption', -5, 'Direct'
    )
  $sql$,
  '23514',
  'Only additions and adjustments can be recorded directly',
  'consumption cannot be recorded directly'
);

-- ------------------------------------------------------------
-- Worker read-only visibility (RLS)
-- ------------------------------------------------------------

select test.set_auth('20000000-0000-0000-0000-000000000002');
set local role authenticated;

select is(
  (select count(*)::int from public.inventory_items
   where farm_id = '21000000-0000-0000-0000-000000000001'),
  1,
  'workers can read inventory items'
);

select is(
  (select count(*)::int from public.inventory_categories
   where farm_id = '21000000-0000-0000-0000-000000000001'),
  9,
  'workers can read inventory categories'
);

select is(
  (select count(*)::int from public.inventory_transactions
   where farm_id = '21000000-0000-0000-0000-000000000001'),
  0,
  'workers cannot read the transaction ledger'
);

reset role;
select test.set_auth('20000000-0000-0000-0000-000000000001');
set local role authenticated;

select ok(
  (select count(*)::int from public.inventory_transactions
   where farm_id = '21000000-0000-0000-0000-000000000001') >= 3,
  'managers can read the transaction ledger'
);

reset role;
select test.set_auth('20000000-0000-0000-0000-000000000001');

-- ------------------------------------------------------------
-- Task consumption: net-zero guard, shortfall, reversal
-- ------------------------------------------------------------

insert into _ids
select 'task', public.create_farm_task(
  '21000000-0000-0000-0000-000000000001',
  'fertilization',
  'Apply calcium',
  p_instructions => jsonb_build_object(
    'inventory_item_id', (select id from _ids where key = 'item'),
    'required_quantity', 30
  ),
  p_assignee_profile_ids =>
    array['20000000-0000-0000-0000-000000000002']::uuid[]
);

select test.set_auth(null);

select is(
  (private.consume_inventory_for_task(
    (select id from _ids where key = 'task'),
    '20000000-0000-0000-0000-000000000002'
  ) ->> 'consumed')::numeric,
  30::numeric,
  'task completion consumes the required quantity'
);

select is(
  (select quantity from public.inventory_items
   where id = (select id from _ids where key = 'item')),
  90.000,
  'consumption lowered the stock'
);

select ok(
  (private.consume_inventory_for_task(
    (select id from _ids where key = 'task'),
    '20000000-0000-0000-0000-000000000002'
  ) ->> 'already_consumed')::boolean,
  'a second consumption for the same task is a no-op (net-zero guard)'
);

select is(
  (select quantity from public.inventory_items
   where id = (select id from _ids where key = 'item')),
  90.000,
  'stock unchanged after the replayed consumption'
);

-- Shortfall: another task requires more than the remaining stock.
select test.set_auth('20000000-0000-0000-0000-000000000001');

insert into _ids
select 'bigtask', public.create_farm_task(
  '21000000-0000-0000-0000-000000000001',
  'fertilization',
  'Apply too much calcium',
  p_instructions => jsonb_build_object(
    'inventory_item_id', (select id from _ids where key = 'item'),
    'required_quantity', 1000
  )
);

select test.set_auth(null);

select is(
  private.consume_inventory_for_task(
    (select id from _ids where key = 'bigtask'),
    '20000000-0000-0000-0000-000000000001'
  ) - 'inventory_item_id',
  jsonb_build_object(
    'required_quantity', 1000,
    'consumed', 90,
    'shortfall', 910
  ),
  'insufficient stock deducts what is available and records the shortfall'
);

select is(
  (select quantity from public.inventory_items
   where id = (select id from _ids where key = 'item')),
  0.000,
  'clamped consumption drained the stock to zero'
);

-- Reversal restores, and the task may consume again afterwards.
select test.set_auth('20000000-0000-0000-0000-000000000001');

select is(
  public.reverse_task_inventory(
    (select id from _ids where key = 'task'),
    'Task reopened',
    p_op_id => '22000000-0000-0000-0000-000000000003'
  ),
  30::numeric,
  'reversal restores the net consumed quantity'
);

select is(
  (select quantity from public.inventory_items
   where id = (select id from _ids where key = 'item')),
  30.000,
  'reversal returned stock to the item'
);

select is(
  public.reverse_task_inventory(
    (select id from _ids where key = 'task'),
    'Task reopened',
    p_op_id => '22000000-0000-0000-0000-000000000003'
  ),
  0::numeric,
  'reversal replay with the same op id is a no-op'
);

select test.set_auth(null);

select is(
  (private.consume_inventory_for_task(
    (select id from _ids where key = 'task'),
    '20000000-0000-0000-0000-000000000002'
  ) ->> 'consumed')::numeric,
  30::numeric,
  're-completion after a reversal consumes again (net returned to zero)'
);

select * from finish();

rollback;
