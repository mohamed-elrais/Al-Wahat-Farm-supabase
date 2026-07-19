begin;

create extension if not exists pgtap with schema extensions;

set local search_path = public, extensions;

select plan(12);

-- ------------------------------------------------------------
-- New chemical operation kinds on both enums
-- ------------------------------------------------------------

select ok(
  'pest_control' = any (enum_range(null::public.task_type)::text[]),
  'task_type includes pest_control'
);

select ok(
  'disease_control' = any (enum_range(null::public.task_type)::text[]),
  'task_type includes disease_control'
);

select ok(
  'pest_control' = any (enum_range(null::public.operation_plan_type)::text[]),
  'operation_plan_type includes pest_control'
);

select ok(
  'disease_control' = any (enum_range(null::public.operation_plan_type)::text[]),
  'operation_plan_type includes disease_control'
);

-- ------------------------------------------------------------
-- Foundation types
-- ------------------------------------------------------------

select has_type('public', 'inventory_unit', 'inventory_unit type exists');

select is(
  enum_range(null::public.inventory_unit)::text[],
  array['gram', 'kilogram', 'liter', 'milliliter', 'piece', 'meter'],
  'inventory_unit has the six confirmed units'
);

select has_type(
  'public',
  'inventory_transaction_type',
  'inventory_transaction_type type exists'
);

select is(
  enum_range(null::public.inventory_transaction_type)::text[],
  array['addition', 'consumption', 'adjustment', 'reversal'],
  'inventory_transaction_type has the four ledger kinds'
);

select has_type(
  'public',
  'application_rate_basis',
  'application_rate_basis type exists'
);

select is(
  enum_range(null::public.application_rate_basis)::text[],
  array['per_feddan', 'per_tree', 'absolute'],
  'application_rate_basis uses feddan-based dosing'
);

-- ------------------------------------------------------------
-- farms.trees_per_feddan conversion rule
-- ------------------------------------------------------------

select has_column(
  'public',
  'farms',
  'trees_per_feddan',
  'farms carries the trees_per_feddan conversion column'
);

select col_default_is(
  'public',
  'farms',
  'trees_per_feddan',
  '60',
  'trees_per_feddan defaults to 60 trees per feddan'
);

select * from finish();

rollback;
