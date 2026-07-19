-- ============================================================
-- Al-Wahat Farm
-- Inventory module (plan M1)
--
-- Farm-scoped inventory with an append-only transaction ledger:
--   * inventory_categories  - configurable kinds, seeded per farm
--   * inventory_items       - stock, units, thresholds, attributes
--   * inventory_transactions- immutable ledger; every quantity
--                             change is a row with a resulting-
--                             quantity snapshot
--
-- Quantity rules:
--   * items.quantity only ever changes inside SECURITY DEFINER
--     functions, under `select ... for update`, in the same
--     transaction as the ledger row.
--   * Task consumption is net-zero guarded: a task can consume an
--     item again only after a reversal restored it, so replays and
--     retries can never double-deduct.
--   * Insufficient stock at completion deducts what is available
--     and records the shortfall (owner decision 3).
-- ============================================================

-- ------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------

create table public.inventory_categories (
  id uuid primary key default gen_random_uuid(),

  farm_id uuid not null
    references public.farms(id)
    on delete cascade,

  code text not null,
  name text not null,

  applies_to_operation public.operation_plan_type,
  is_consumable boolean not null default true,
  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint inventory_categories_code_not_blank_check
    check (nullif(trim(code), '') is not null),

  constraint inventory_categories_name_not_blank_check
    check (nullif(trim(name), '') is not null),

  unique (farm_id, code)
);

comment on table public.inventory_categories is
  'Configurable inventory kinds per farm. A default set is seeded when a '
  'farm is created; managers may add more.';

create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),

  farm_id uuid not null
    references public.farms(id)
    on delete cascade,

  category_id uuid not null
    references public.inventory_categories(id)
    on delete restrict,

  name text not null,
  description text,

  unit public.inventory_unit not null,
  quantity numeric(14, 3) not null default 0,
  minimum_stock numeric(14, 3),

  attributes jsonb not null default '{}'::jsonb,

  image_bucket_id text,
  image_path text,

  is_active boolean not null default true,

  created_by_profile_id uuid not null
    references public.profiles(id)
    on delete restrict,

  client_operation_id uuid,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint inventory_items_name_not_blank_check
    check (nullif(trim(name), '') is not null),

  constraint inventory_items_quantity_non_negative_check
    check (quantity >= 0),

  constraint inventory_items_minimum_stock_check
    check (minimum_stock is null or minimum_stock >= 0),

  constraint inventory_items_attributes_object_check
    check (jsonb_typeof(attributes) = 'object'),

  constraint inventory_items_image_pair_check
    check ((image_bucket_id is null) = (image_path is null)),

  unique (farm_id, name)
);

create unique index inventory_items_client_operation_id_key
  on public.inventory_items (client_operation_id)
  where client_operation_id is not null;

create index inventory_items_farm_active_idx
  on public.inventory_items (farm_id, is_active);

create index inventory_items_category_id_idx
  on public.inventory_items (category_id);

comment on table public.inventory_items is
  'Farm inventory. quantity is maintained exclusively by SECURITY DEFINER '
  'functions writing matching inventory_transactions rows.';

create table public.inventory_transactions (
  id uuid primary key default gen_random_uuid(),

  farm_id uuid not null
    references public.farms(id)
    on delete cascade,

  inventory_item_id uuid not null
    references public.inventory_items(id)
    on delete restrict,

  transaction_type public.inventory_transaction_type not null,

  quantity_delta numeric(14, 3) not null,
  resulting_quantity numeric(14, 3) not null,

  task_id uuid
    references public.tasks(id)
    on delete set null,

  actor_profile_id uuid not null
    references public.profiles(id)
    on delete restrict,

  note text,
  metadata jsonb not null default '{}'::jsonb,

  client_operation_id uuid,

  created_at timestamptz not null default now(),

  constraint inventory_transactions_delta_not_zero_check
    check (quantity_delta <> 0),

  constraint inventory_transactions_resulting_non_negative_check
    check (resulting_quantity >= 0),

  constraint inventory_transactions_sign_check
    check (
      (transaction_type in ('addition', 'reversal') and quantity_delta > 0)
      or (transaction_type = 'consumption' and quantity_delta < 0)
      or (transaction_type = 'adjustment')
    ),

  constraint inventory_transactions_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint inventory_transactions_task_link_check
    check (
      transaction_type not in ('consumption', 'reversal')
      or task_id is not null
    )
);

create unique index inventory_transactions_client_operation_id_key
  on public.inventory_transactions (client_operation_id)
  where client_operation_id is not null;

create index inventory_transactions_item_created_idx
  on public.inventory_transactions (inventory_item_id, created_at desc);

create index inventory_transactions_farm_created_idx
  on public.inventory_transactions (farm_id, created_at desc);

create index inventory_transactions_task_id_idx
  on public.inventory_transactions (task_id)
  where task_id is not null;

comment on table public.inventory_transactions is
  'Append-only inventory ledger. Rows are never updated or deleted; '
  'corrections are compensating adjustment/reversal rows.';

create trigger inventory_categories_set_updated_at
before update on public.inventory_categories
for each row
execute function public.set_updated_at();

create trigger inventory_items_set_updated_at
before update on public.inventory_items
for each row
execute function public.set_updated_at();

-- ------------------------------------------------------------
-- Cross-farm integrity triggers
-- ------------------------------------------------------------

create or replace function public.validate_inventory_item_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_category_farm uuid;
begin
  select farm_id into v_category_farm
  from public.inventory_categories
  where id = new.category_id;

  if v_category_farm is null or v_category_farm <> new.farm_id then
    raise exception 'Inventory category does not belong to the item farm'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger inventory_items_validate_scope
before insert or update of category_id, farm_id on public.inventory_items
for each row
execute function public.validate_inventory_item_scope();

create or replace function public.validate_inventory_transaction_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item_farm uuid;
  v_task_farm uuid;
begin
  select farm_id into v_item_farm
  from public.inventory_items
  where id = new.inventory_item_id;

  if v_item_farm is null or v_item_farm <> new.farm_id then
    raise exception 'Inventory item does not belong to the transaction farm'
      using errcode = '23514';
  end if;

  if new.task_id is not null then
    select farm_id into v_task_farm
    from public.tasks
    where id = new.task_id;

    if v_task_farm is null or v_task_farm <> new.farm_id then
      raise exception 'Task does not belong to the transaction farm'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

create trigger inventory_transactions_validate_scope
before insert on public.inventory_transactions
for each row
execute function public.validate_inventory_transaction_scope();

-- ------------------------------------------------------------
-- Default category seeding (new farms via trigger; existing backfilled)
-- ------------------------------------------------------------

create or replace function private.seed_default_inventory_categories(
  p_farm_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.inventory_categories
    (farm_id, code, name, applies_to_operation, is_consumable)
  values
    (p_farm_id, 'pipe',        'Pipes',        null,                   true),
    (p_farm_id, 'pipe_joint',  'Pipe joints',  null,                   true),
    (p_farm_id, 'fertilizer',  'Fertilizers',  'fertilization',        true),
    (p_farm_id, 'dripper',     'Drippers',     null,                   true),
    (p_farm_id, 'insecticide', 'Insecticides', 'pest_control',         true),
    (p_farm_id, 'herbicide',   'Herbicides',   'harmful_weed_control', true),
    (p_farm_id, 'fungicide',   'Fungicides',   'disease_control',      true),
    (p_farm_id, 'tool',        'Farm tools',   null,                   false),
    (p_farm_id, 'other',       'Other',        null,                   true)
  on conflict (farm_id, code) do nothing;
end;
$$;

revoke all on function private.seed_default_inventory_categories(uuid)
  from public, anon, authenticated;

create or replace function public.seed_inventory_categories_for_new_farm()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.seed_default_inventory_categories(new.id);
  return new;
end;
$$;

create trigger farms_seed_inventory_categories
after insert on public.farms
for each row
execute function public.seed_inventory_categories_for_new_farm();

-- Backfill every existing farm.
do $$
declare
  v_farm record;
begin
  for v_farm in select id from public.farms loop
    perform private.seed_default_inventory_categories(v_farm.id);
  end loop;
end;
$$;

-- ------------------------------------------------------------
-- RLS
-- ------------------------------------------------------------

alter table public.inventory_categories enable row level security;
alter table public.inventory_items enable row level security;
alter table public.inventory_transactions enable row level security;

revoke all on public.inventory_categories from public, anon;
revoke all on public.inventory_items from public, anon;
revoke all on public.inventory_transactions from public, anon;

grant select on public.inventory_categories to authenticated;
grant select on public.inventory_items to authenticated;
grant select on public.inventory_transactions to authenticated;

grant all on public.inventory_categories to service_role;
grant all on public.inventory_items to service_role;
grant all on public.inventory_transactions to service_role;

-- Items and categories: readable by every operational member (workers see
-- stock read-only, owner decision 4). Ledger: managers only.
create policy "inventory categories readable by operational members"
  on public.inventory_categories
  for select
  to authenticated
  using ((select private.is_operational_farm_member(farm_id)));

create policy "inventory items readable by operational members"
  on public.inventory_items
  for select
  to authenticated
  using ((select private.is_operational_farm_member(farm_id)));

create policy "inventory transactions readable by managers"
  on public.inventory_transactions
  for select
  to authenticated
  using ((select private.is_operational_manager(farm_id)));

-- ------------------------------------------------------------
-- Category RPCs (manager-only; low-frequency online actions)
-- ------------------------------------------------------------

create or replace function public.create_inventory_category(
  p_farm_id uuid,
  p_code text,
  p_name text,
  p_applies_to_operation public.operation_plan_type default null,
  p_is_consumable boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_category_id uuid;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if not private.is_operational_manager(p_farm_id) then
    raise exception 'Only the owner or agricultural engineer can manage inventory'
      using errcode = '42501';
  end if;

  insert into public.inventory_categories
    (farm_id, code, name, applies_to_operation, is_consumable)
  values
    (p_farm_id, trim(p_code), trim(p_name), p_applies_to_operation,
     coalesce(p_is_consumable, true))
  returning id into v_category_id;

  return v_category_id;
end;
$$;

create or replace function public.update_inventory_category(
  p_category_id uuid,
  p_name text default null,
  p_applies_to_operation public.operation_plan_type default null,
  p_clear_applies_to_operation boolean default false,
  p_is_consumable boolean default null,
  p_is_active boolean default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_farm_id uuid;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  select farm_id into v_farm_id
  from public.inventory_categories
  where id = p_category_id;

  if v_farm_id is null then
    raise exception 'Inventory category not found'
      using errcode = 'P0002';
  end if;

  if not private.is_operational_manager(v_farm_id) then
    raise exception 'Only the owner or agricultural engineer can manage inventory'
      using errcode = '42501';
  end if;

  update public.inventory_categories
  set
    name = coalesce(nullif(trim(coalesce(p_name, '')), ''), name),
    applies_to_operation = case
      when p_clear_applies_to_operation then null
      else coalesce(p_applies_to_operation, applies_to_operation)
    end,
    is_consumable = coalesce(p_is_consumable, is_consumable),
    is_active = coalesce(p_is_active, is_active)
  where id = p_category_id;
end;
$$;

-- ------------------------------------------------------------
-- Item RPCs
-- ------------------------------------------------------------

create or replace function public.create_inventory_item(
  p_farm_id uuid,
  p_category_id uuid,
  p_name text,
  p_unit public.inventory_unit,
  p_description text default null,
  p_minimum_stock numeric default null,
  p_attributes jsonb default '{}'::jsonb,
  p_initial_quantity numeric default 0,
  p_image_path text default null,
  p_op_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_item_id uuid;
  v_existing record;
  v_quantity numeric(14, 3) := coalesce(p_initial_quantity, 0);
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if not private.is_operational_manager(p_farm_id) then
    raise exception 'Only the owner or agricultural engineer can manage inventory'
      using errcode = '42501';
  end if;

  if v_quantity < 0 then
    raise exception 'Initial quantity cannot be negative'
      using errcode = '23514';
  end if;

  -- Idempotent replay: same client operation returns the existing item.
  if p_op_id is not null then
    select id, farm_id, created_by_profile_id
      into v_existing
    from public.inventory_items
    where client_operation_id = p_op_id;

    if found then
      if v_existing.farm_id <> p_farm_id
        or v_existing.created_by_profile_id <> v_actor_id then
        raise exception 'Operation id was already used in another context'
          using errcode = '42501';
      end if;
      return v_existing.id;
    end if;
  end if;

  insert into public.inventory_items (
    farm_id, category_id, name, description, unit, quantity, minimum_stock,
    attributes, image_bucket_id, image_path,
    created_by_profile_id, client_operation_id
  )
  values (
    p_farm_id, p_category_id, trim(p_name), p_description, p_unit,
    v_quantity, p_minimum_stock,
    coalesce(p_attributes, '{}'::jsonb),
    case when p_image_path is null then null else 'farm-evidence' end,
    p_image_path,
    v_actor_id, p_op_id
  )
  returning id into v_item_id;

  if v_quantity > 0 then
    insert into public.inventory_transactions (
      farm_id, inventory_item_id, transaction_type,
      quantity_delta, resulting_quantity, actor_profile_id, note
    )
    values (
      p_farm_id, v_item_id, 'addition',
      v_quantity, v_quantity, v_actor_id, 'Initial stock'
    );
  end if;

  return v_item_id;
end;
$$;

create or replace function public.update_inventory_item(
  p_item_id uuid,
  p_name text default null,
  p_category_id uuid default null,
  p_description text default null,
  p_clear_description boolean default false,
  p_minimum_stock numeric default null,
  p_clear_minimum_stock boolean default false,
  p_attributes jsonb default null,
  p_image_path text default null,
  p_clear_image boolean default false,
  p_is_active boolean default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_farm_id uuid;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  select farm_id into v_farm_id
  from public.inventory_items
  where id = p_item_id;

  if v_farm_id is null then
    raise exception 'Inventory item not found'
      using errcode = 'P0002';
  end if;

  if not private.is_operational_manager(v_farm_id) then
    raise exception 'Only the owner or agricultural engineer can manage inventory'
      using errcode = '42501';
  end if;

  update public.inventory_items
  set
    name = coalesce(nullif(trim(coalesce(p_name, '')), ''), name),
    category_id = coalesce(p_category_id, category_id),
    description = case
      when p_clear_description then null
      else coalesce(p_description, description)
    end,
    minimum_stock = case
      when p_clear_minimum_stock then null
      else coalesce(p_minimum_stock, minimum_stock)
    end,
    attributes = coalesce(p_attributes, attributes),
    image_bucket_id = case
      when p_clear_image then null
      when p_image_path is not null then 'farm-evidence'
      else image_bucket_id
    end,
    image_path = case
      when p_clear_image then null
      else coalesce(p_image_path, image_path)
    end,
    is_active = coalesce(p_is_active, is_active)
  where id = p_item_id;
end;
$$;

-- ------------------------------------------------------------
-- Stock movements (manager): additions and signed adjustments
-- ------------------------------------------------------------

create or replace function public.record_inventory_transaction(
  p_item_id uuid,
  p_transaction_type public.inventory_transaction_type,
  p_quantity numeric,
  p_note text default null,
  p_op_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_item record;
  v_existing record;
  v_new_quantity numeric(14, 3);
  v_transaction_id uuid;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if p_transaction_type not in ('addition', 'adjustment') then
    raise exception 'Only additions and adjustments can be recorded directly'
      using errcode = '23514';
  end if;

  if p_quantity is null or p_quantity = 0 then
    raise exception 'Quantity must be non-zero'
      using errcode = '23514';
  end if;

  if p_transaction_type = 'addition' and p_quantity < 0 then
    raise exception 'Additions must increase stock'
      using errcode = '23514';
  end if;

  -- Idempotent replay.
  if p_op_id is not null then
    select id, actor_profile_id into v_existing
    from public.inventory_transactions
    where client_operation_id = p_op_id;

    if found then
      if v_existing.actor_profile_id <> v_actor_id then
        raise exception 'Operation id was already used in another context'
          using errcode = '42501';
      end if;
      return v_existing.id;
    end if;
  end if;

  select * into v_item
  from public.inventory_items
  where id = p_item_id
  for update;

  if not found then
    raise exception 'Inventory item not found'
      using errcode = 'P0002';
  end if;

  if not private.is_operational_manager(v_item.farm_id) then
    raise exception 'Only the owner or agricultural engineer can manage inventory'
      using errcode = '42501';
  end if;

  v_new_quantity := v_item.quantity + p_quantity;

  if v_new_quantity < 0 then
    raise exception 'Adjustment would make stock negative (available %)',
      v_item.quantity
      using errcode = '23514';
  end if;

  insert into public.inventory_transactions (
    farm_id, inventory_item_id, transaction_type,
    quantity_delta, resulting_quantity,
    actor_profile_id, note, client_operation_id
  )
  values (
    v_item.farm_id, p_item_id, p_transaction_type,
    p_quantity, v_new_quantity,
    v_actor_id, p_note, p_op_id
  )
  returning id into v_transaction_id;

  update public.inventory_items
  set quantity = v_new_quantity
  where id = p_item_id;

  return v_transaction_id;
end;
$$;

-- ------------------------------------------------------------
-- Task consumption / reversal core (used by complete_task and
-- review_task in M3; the private functions land now so the whole
-- inventory contract is testable in one milestone)
-- ------------------------------------------------------------

create or replace function private.task_net_consumed(
  p_task_id uuid,
  p_item_id uuid
)
returns numeric
language sql
security definer
set search_path = ''
as $$
  select coalesce(-sum(quantity_delta), 0)
  from public.inventory_transactions
  where task_id = p_task_id
    and inventory_item_id = p_item_id
    and transaction_type in ('consumption', 'reversal');
$$;

revoke all on function private.task_net_consumed(uuid, uuid)
  from public, anon, authenticated;

create or replace function private.consume_inventory_for_task(
  p_task_id uuid,
  p_actor_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task record;
  v_item record;
  v_item_id uuid;
  v_required numeric(14, 3);
  v_available numeric(14, 3);
  v_deduct numeric(14, 3);
  v_shortfall numeric(14, 3);
begin
  select id, farm_id, instructions into v_task
  from public.tasks
  where id = p_task_id;

  if not found then
    return '{}'::jsonb;
  end if;

  -- Consumption spec is carried in task instructions (stamped by the plan
  -- generator in M3, or provided on manual tasks).
  v_item_id := nullif(v_task.instructions ->> 'inventory_item_id', '')::uuid;
  v_required := nullif(v_task.instructions ->> 'required_quantity', '')::numeric;

  if v_item_id is null or v_required is null or v_required <= 0 then
    return '{}'::jsonb;
  end if;

  -- Net-zero guard: only consume when nothing is currently consumed for
  -- this (task, item) - immune to replays, retries and races.
  select * into v_item
  from public.inventory_items
  where id = v_item_id
  for update;

  if not found or v_item.farm_id <> v_task.farm_id then
    return jsonb_build_object(
      'inventory_item_id', v_item_id,
      'consumed', 0,
      'error', 'item_missing'
    );
  end if;

  if private.task_net_consumed(p_task_id, v_item_id) > 0 then
    return jsonb_build_object(
      'inventory_item_id', v_item_id,
      'consumed', 0,
      'already_consumed', true
    );
  end if;

  v_available := v_item.quantity;
  v_deduct := least(v_required, v_available);
  v_shortfall := v_required - v_deduct;

  if v_deduct > 0 then
    insert into public.inventory_transactions (
      farm_id, inventory_item_id, transaction_type,
      quantity_delta, resulting_quantity,
      task_id, actor_profile_id, note, metadata
    )
    values (
      v_item.farm_id, v_item_id, 'consumption',
      -v_deduct, v_available - v_deduct,
      p_task_id, p_actor_id,
      case
        when v_shortfall > 0
          then 'Task completion (short by ' || v_shortfall || ')'
        else 'Task completion'
      end,
      jsonb_build_object(
        'required_quantity', v_required,
        'shortfall', v_shortfall
      )
    );

    update public.inventory_items
    set quantity = v_available - v_deduct
    where id = v_item_id;
  end if;

  return jsonb_build_object(
    'inventory_item_id', v_item_id,
    'required_quantity', v_required,
    'consumed', v_deduct,
    'shortfall', v_shortfall
  );
end;
$$;

revoke all on function private.consume_inventory_for_task(uuid, uuid)
  from public, anon, authenticated;

create or replace function private.reverse_inventory_for_task(
  p_task_id uuid,
  p_actor_id uuid,
  p_note text
)
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry record;
  v_item record;
  v_net numeric(14, 3);
  v_total numeric(14, 3) := 0;
begin
  for v_entry in
    select distinct inventory_item_id
    from public.inventory_transactions
    where task_id = p_task_id
      and transaction_type in ('consumption', 'reversal')
  loop
    select * into v_item
    from public.inventory_items
    where id = v_entry.inventory_item_id
    for update;

    v_net := private.task_net_consumed(p_task_id, v_entry.inventory_item_id);

    if v_net > 0 then
      insert into public.inventory_transactions (
        farm_id, inventory_item_id, transaction_type,
        quantity_delta, resulting_quantity,
        task_id, actor_profile_id, note
      )
      values (
        v_item.farm_id, v_entry.inventory_item_id, 'reversal',
        v_net, v_item.quantity + v_net,
        p_task_id, p_actor_id,
        coalesce(p_note, 'Task consumption reversed')
      );

      update public.inventory_items
      set quantity = v_item.quantity + v_net
      where id = v_entry.inventory_item_id;

      v_total := v_total + v_net;
    end if;
  end loop;

  return v_total;
end;
$$;

revoke all on function private.reverse_inventory_for_task(uuid, uuid, text)
  from public, anon, authenticated;

create or replace function public.reverse_task_inventory(
  p_task_id uuid,
  p_note text default null,
  p_op_id uuid default null
)
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_farm_id uuid;
begin
  if v_actor_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  select farm_id into v_farm_id
  from public.tasks
  where id = p_task_id;

  if v_farm_id is null then
    raise exception 'Task not found'
      using errcode = 'P0002';
  end if;

  if not private.is_operational_manager(v_farm_id) then
    raise exception 'Only the owner or agricultural engineer can adjust inventory'
      using errcode = '42501';
  end if;

  if p_op_id is not null then
    insert into private.applied_operations (op_id)
    values (p_op_id)
    on conflict (op_id) do nothing;

    if not found then
      return 0;  -- already applied
    end if;
  end if;

  return private.reverse_inventory_for_task(p_task_id, v_actor_id, p_note);
end;
$$;

-- ------------------------------------------------------------
-- Grants
-- ------------------------------------------------------------

do $$
declare
  v_fn text;
begin
  foreach v_fn in array array[
    'public.create_inventory_category(uuid, text, text, public.operation_plan_type, boolean)',
    'public.update_inventory_category(uuid, text, public.operation_plan_type, boolean, boolean, boolean)',
    'public.create_inventory_item(uuid, uuid, text, public.inventory_unit, text, numeric, jsonb, numeric, text, uuid)',
    'public.update_inventory_item(uuid, text, uuid, text, boolean, numeric, boolean, jsonb, text, boolean, boolean)',
    'public.record_inventory_transaction(uuid, public.inventory_transaction_type, numeric, text, uuid)',
    'public.reverse_task_inventory(uuid, text, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', v_fn);
    execute format(
      'grant execute on function %s to authenticated, service_role', v_fn
    );
  end loop;
end;
$$;
