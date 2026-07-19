-- ============================================================
-- Al-Wahat Farm
-- Inventory & scheduling foundations (plan M0)
--
-- Additive groundwork only — no tables or behavior changes yet:
--   * task_type / operation_plan_type gain the two chemical
--     operations that were missing (insecticides -> pest_control,
--     fungicides -> disease_control; herbicides remain
--     harmful_weed_control).
--   * Types the inventory module (M1) and plan dosing (M3) build on.
--   * farms.trees_per_feddan: the farm's dosing conversion rule —
--     per-feddan application rates derive area from tree counts
--     (60 trees = 1 feddan by default, owner-configurable).
--
-- Enum values added here must not be used by any function in this
-- same migration (PostgreSQL restriction); first use arrives in M1/M3.
-- ============================================================

-- ------------------------------------------------------------
-- New chemical operation kinds
-- ------------------------------------------------------------

alter type public.task_type add value if not exists 'pest_control';
alter type public.task_type add value if not exists 'disease_control';

alter type public.operation_plan_type add value if not exists 'pest_control';
alter type public.operation_plan_type add value if not exists 'disease_control';

-- ------------------------------------------------------------
-- Inventory foundations
-- ------------------------------------------------------------

create type public.inventory_unit as enum (
  'gram',
  'kilogram',
  'liter',
  'milliliter',
  'piece',
  'meter'
);

comment on type public.inventory_unit is
  'Unit of measurement for inventory items and application rates.';

create type public.inventory_transaction_type as enum (
  'addition',
  'consumption',
  'adjustment',
  'reversal'
);

comment on type public.inventory_transaction_type is
  'Kind of inventory ledger entry: addition (stock in), consumption '
  '(deducted by a completed task), adjustment (manual correction, either '
  'sign), reversal (compensating restore of a task consumption).';

create type public.application_rate_basis as enum (
  'per_feddan',
  'per_tree',
  'absolute'
);

comment on type public.application_rate_basis is
  'How an operation plan''s application rate scales to a target: '
  'per_feddan (feddans = active tree count / farms.trees_per_feddan), '
  'per_tree (rate x active tree count), or absolute (rate per occurrence).';

-- ------------------------------------------------------------
-- Farm-level dosing conversion rule
-- ------------------------------------------------------------

alter table public.farms
  add column trees_per_feddan numeric(6, 2) not null default 60
    constraint farms_trees_per_feddan_positive_check
      check (trees_per_feddan > 0);

comment on column public.farms.trees_per_feddan is
  'Planting-density conversion used for per-feddan dosing: '
  'feddans(target) = active tree count / trees_per_feddan.';
