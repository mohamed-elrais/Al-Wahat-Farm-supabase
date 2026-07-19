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

select plan(16);

-- ------------------------------------------------------------
-- Seed: farm A (manager + worker, section, zone, 3 trees) and a
-- foreign farm B with one section for cross-farm rejection.
-- ------------------------------------------------------------

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
)
values
  ('40000000-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'mt-manager@example.test', '', now(), now(), now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"full_name":"MT Manager"}'::jsonb),
  ('40000000-0000-0000-0000-000000000002',
   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'mt-worker@example.test', '', now(), now(), now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"full_name":"MT Worker"}'::jsonb);

insert into public.farms (id, name, code)
values
  ('41000000-0000-0000-0000-000000000001', 'MT Farm', 'MTF'),
  ('41000000-0000-0000-0000-000000000009', 'Other Farm', 'OTH');

insert into public.farm_memberships (farm_id, profile_id, role)
values
  ('41000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000001', 'owner'),
  ('41000000-0000-0000-0000-000000000001',
   '40000000-0000-0000-0000-000000000002', 'worker');

insert into public.farm_sections (id, farm_id, code, name, sort_order)
values
  ('41000000-0000-0000-0000-000000000002',
   '41000000-0000-0000-0000-000000000001', 'MT', 'Section MT', 98),
  ('41000000-0000-0000-0000-000000000008',
   '41000000-0000-0000-0000-000000000009', 'OX', 'Foreign Section', 1);

insert into public.irrigation_zones (id, section_id, code, name)
values ('41000000-0000-0000-0000-000000000003',
        '41000000-0000-0000-0000-000000000002', 'ZCV-MT', 'MT Zone');

insert into public.trees (id, farm_id, section_id, irrigation_zone_id, tree_code)
values
  ('41000000-0000-0000-0000-000000000004',
   '41000000-0000-0000-0000-000000000001',
   '41000000-0000-0000-0000-000000000002',
   '41000000-0000-0000-0000-000000000003', 'TREE-MT-001'),
  ('41000000-0000-0000-0000-000000000005',
   '41000000-0000-0000-0000-000000000001',
   '41000000-0000-0000-0000-000000000002',
   '41000000-0000-0000-0000-000000000003', 'TREE-MT-002'),
  ('41000000-0000-0000-0000-000000000006',
   '41000000-0000-0000-0000-000000000001',
   '41000000-0000-0000-0000-000000000002',
   '41000000-0000-0000-0000-000000000003', 'TREE-MT-003');

select test.set_auth('40000000-0000-0000-0000-000000000001');

create temp table _d (key text primary key, id uuid) on commit drop;
grant select on _d to authenticated;

-- ------------------------------------------------------------
-- 1-4: multi-target create + idempotent replay
-- ------------------------------------------------------------

insert into _d
select 'multi', public.create_farm_task(
  p_farm_id => '41000000-0000-0000-0000-000000000001',
  p_task_type => 'tree_inspection',
  p_title => 'Prune three palms',
  p_op_id => '42000000-0000-0000-0000-000000000001',
  p_targets => '[
    {"tree_id": "41000000-0000-0000-0000-000000000004"},
    {"tree_id": "41000000-0000-0000-0000-000000000005"},
    {"tree_id": "41000000-0000-0000-0000-000000000006"}
  ]'::jsonb
);

select is(
  (select count(*) from public.task_targets
   where task_id = (select id from _d where key = 'multi')),
  3::bigint,
  'multi-target create stores one row per target'
);

select is(
  (select tree_id from public.tasks
   where id = (select id from _d where key = 'multi')),
  '41000000-0000-0000-0000-000000000004'::uuid,
  'first target is mirrored onto the legacy tree_id column'
);

select is(
  public.create_farm_task(
    p_farm_id => '41000000-0000-0000-0000-000000000001',
    p_task_type => 'tree_inspection',
    p_title => 'Prune three palms',
    p_op_id => '42000000-0000-0000-0000-000000000001',
    p_targets => '[
      {"tree_id": "41000000-0000-0000-0000-000000000004"},
      {"tree_id": "41000000-0000-0000-0000-000000000005"},
      {"tree_id": "41000000-0000-0000-0000-000000000006"}
    ]'::jsonb
  ),
  (select id from _d where key = 'multi'),
  'p_op_id replay returns the same task'
);

select is(
  (select count(*) from public.task_targets
   where task_id = (select id from _d where key = 'multi')),
  3::bigint,
  'replay does not duplicate targets'
);

-- ------------------------------------------------------------
-- 5-7: p_targets shape validation
-- ------------------------------------------------------------

select throws_ok(
  $$select public.create_farm_task(
      p_farm_id => '41000000-0000-0000-0000-000000000001',
      p_task_type => 'tree_inspection',
      p_title => 'Mixed kinds',
      p_targets => '[
        {"tree_id": "41000000-0000-0000-0000-000000000004"},
        {"section_id": "41000000-0000-0000-0000-000000000002"}
      ]'::jsonb
    )$$,
  '23514',
  null,
  'mixed target kinds are rejected'
);

select throws_ok(
  $$select public.create_farm_task(
      p_farm_id => '41000000-0000-0000-0000-000000000001',
      p_task_type => 'tree_inspection',
      p_title => 'Empty targets',
      p_targets => '[]'::jsonb
    )$$,
  '23514',
  null,
  'empty target arrays are rejected'
);

select throws_ok(
  $$select public.create_farm_task(
      p_farm_id => '41000000-0000-0000-0000-000000000001',
      p_task_type => 'tree_inspection',
      p_title => 'Two keys',
      p_targets => '[
        {"tree_id": "41000000-0000-0000-0000-000000000004",
         "section_id": "41000000-0000-0000-0000-000000000002"}
      ]'::jsonb
    )$$,
  '23514',
  null,
  'a target with two scope keys is rejected'
);

-- ------------------------------------------------------------
-- 8-9: legacy parameter path still works and is mirrored
-- ------------------------------------------------------------

insert into _d
select 'legacy', public.create_farm_task(
  p_farm_id => '41000000-0000-0000-0000-000000000001',
  p_task_type => 'irrigation',
  p_title => 'Legacy section task',
  p_section_id => '41000000-0000-0000-0000-000000000002'
);

select is(
  (select count(*) from public.task_targets
   where task_id = (select id from _d where key = 'legacy')
     and section_id = '41000000-0000-0000-0000-000000000002'),
  1::bigint,
  'legacy single-target params produce one mirrored target row'
);

insert into _d
select 'farmwide', public.create_farm_task(
  p_farm_id => '41000000-0000-0000-0000-000000000001',
  p_task_type => 'irrigation',
  p_title => 'Whole farm walkabout'
);

select is(
  (select count(*) from public.task_targets
   where task_id = (select id from _d where key = 'farmwide')),
  0::bigint,
  'farm-wide tasks have no target rows'
);

-- ------------------------------------------------------------
-- 10: cross-farm targets are rejected
-- ------------------------------------------------------------

select throws_ok(
  $$select public.create_farm_task(
      p_farm_id => '41000000-0000-0000-0000-000000000001',
      p_task_type => 'irrigation',
      p_title => 'Foreign section',
      p_targets => '[
        {"section_id": "41000000-0000-0000-0000-000000000008"}
      ]'::jsonb
    )$$,
  '23514',
  null,
  'targets from another farm are rejected'
);

-- ------------------------------------------------------------
-- 11-12: table-level guards (unique + same-kind trigger)
-- ------------------------------------------------------------

select throws_ok(
  $$insert into public.task_targets (task_id, tree_id)
    select id, '41000000-0000-0000-0000-000000000004'
    from _d where key = 'multi'$$,
  '23505',
  null,
  'duplicate targets violate the per-task unique index'
);

select throws_ok(
  $$insert into public.task_targets (task_id, section_id)
    select id, '41000000-0000-0000-0000-000000000002'
    from _d where key = 'multi'$$,
  '23514',
  null,
  'adding a different kind to an existing task is rejected'
);

-- ------------------------------------------------------------
-- 13-14: RLS follows task visibility
-- ------------------------------------------------------------

insert into _d
select 'assigned', public.create_farm_task(
  p_farm_id => '41000000-0000-0000-0000-000000000001',
  p_task_type => 'tree_inspection',
  p_title => 'Assigned to worker',
  p_assignee_profile_ids =>
    array['40000000-0000-0000-0000-000000000002']::uuid[],
  p_targets => '[
    {"irrigation_zone_id": "41000000-0000-0000-0000-000000000003"}
  ]'::jsonb
);

select test.set_auth('40000000-0000-0000-0000-000000000002');
set local role authenticated;

select is(
  (select count(*) from public.task_targets
   where task_id = (select id from _d where key = 'multi')),
  0::bigint,
  'worker cannot see targets of tasks not assigned to them'
);

select is(
  (select count(*) from public.task_targets
   where task_id = (select id from _d where key = 'assigned')),
  1::bigint,
  'assigned worker sees the targets of their task'
);

reset role;
select test.set_auth('40000000-0000-0000-0000-000000000001');

-- ------------------------------------------------------------
-- 15: direct inserts (plan generator path) are mirrored too
-- ------------------------------------------------------------

insert into public.tasks (
  id, farm_id, irrigation_zone_id, task_type, title, status,
  created_by_profile_id
)
values (
  '42000000-0000-0000-0000-000000000005',
  '41000000-0000-0000-0000-000000000001',
  '41000000-0000-0000-0000-000000000003',
  'irrigation', 'Generated zone task', 'draft',
  '40000000-0000-0000-0000-000000000001'
);

select is(
  (select count(*) from public.task_targets
   where task_id = '42000000-0000-0000-0000-000000000005'
     and irrigation_zone_id = '41000000-0000-0000-0000-000000000003'),
  1::bigint,
  'direct task inserts mirror their target row'
);

-- ------------------------------------------------------------
-- 16: targets are removed with their task
-- ------------------------------------------------------------

delete from public.tasks
where id = (select id from _d where key = 'multi');

select is(
  (select count(*) from public.task_targets
   where task_id = (select id from _d where key = 'multi')),
  0::bigint,
  'deleting a task cascades to its targets'
);

select * from finish();

rollback;
