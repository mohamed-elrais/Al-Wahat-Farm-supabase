-- ============================================================
-- Al-Wahat Farm — Core security, RLS, farm bootstrap and QR scan
-- ============================================================

create schema if not exists private;

-- ------------------------------------------------------------
-- Harden the trigger functions created in the first migration.
-- ------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (
    id,
    full_name,
    phone_number
  )
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'full_name',
      new.email,
      'New user'
    ),
    new.raw_user_meta_data ->> 'phone_number'
  );

  return new;
end;
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = current_timestamp;
  return new;
end;
$$;

-- ------------------------------------------------------------
-- Private permission helpers.
-- These are used inside RLS policies and are not exposed as API RPCs.
-- ------------------------------------------------------------

create or replace function private.is_active_farm_member(
  p_farm_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.farm_memberships fm
    where fm.farm_id = p_farm_id
      and fm.profile_id = (select auth.uid())
      and fm.is_active = true
  );
$$;

create or replace function private.has_farm_role(
  p_farm_id uuid,
  p_roles public.farm_role[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.farm_memberships fm
    where fm.farm_id = p_farm_id
      and fm.profile_id = (select auth.uid())
      and fm.is_active = true
      and fm.role = any (p_roles)
  );
$$;

create or replace function private.is_active_section_member(
  p_section_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.farm_sections s
    join public.farm_memberships fm
      on fm.farm_id = s.farm_id
    where s.id = p_section_id
      and fm.profile_id = (select auth.uid())
      and fm.is_active = true
  );
$$;

create or replace function private.has_section_role(
  p_section_id uuid,
  p_roles public.farm_role[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.farm_sections s
    join public.farm_memberships fm
      on fm.farm_id = s.farm_id
    where s.id = p_section_id
      and fm.profile_id = (select auth.uid())
      and fm.is_active = true
      and fm.role = any (p_roles)
  );
$$;

create or replace function private.has_palm_role(
  p_palm_tree_id uuid,
  p_roles public.farm_role[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.palm_trees p
    join public.farm_memberships fm
      on fm.farm_id = p.farm_id
    where p.id = p_palm_tree_id
      and fm.profile_id = (select auth.uid())
      and fm.is_active = true
      and fm.role = any (p_roles)
  );
$$;

create or replace function private.shares_active_farm_with(
  p_other_profile_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.farm_memberships mine
    join public.farm_memberships theirs
      on theirs.farm_id = mine.farm_id
    where mine.profile_id = (select auth.uid())
      and mine.is_active = true
      and theirs.profile_id = p_other_profile_id
      and theirs.is_active = true
  );
$$;

revoke all on schema private from public;

revoke all on function private.is_active_farm_member(uuid) from public;
revoke all on function private.has_farm_role(uuid, public.farm_role[]) from public;
revoke all on function private.is_active_section_member(uuid) from public;
revoke all on function private.has_section_role(uuid, public.farm_role[]) from public;
revoke all on function private.has_palm_role(uuid, public.farm_role[]) from public;
revoke all on function private.shares_active_farm_with(uuid) from public;

grant execute on function private.is_active_farm_member(uuid) to authenticated;
grant execute on function private.has_farm_role(uuid, public.farm_role[]) to authenticated;
grant execute on function private.is_active_section_member(uuid) to authenticated;
grant execute on function private.has_section_role(uuid, public.farm_role[]) to authenticated;
grant execute on function private.has_palm_role(uuid, public.farm_role[]) to authenticated;
grant execute on function private.shares_active_farm_with(uuid) to authenticated;

-- ------------------------------------------------------------
-- Prevent invalid farm / section / irrigation-zone relationships.
-- ------------------------------------------------------------

create or replace function public.validate_palm_tree_hierarchy()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.farm_sections s
    where s.id = new.section_id
      and s.farm_id = new.farm_id
  ) then
    raise exception 'The selected section does not belong to this farm'
      using errcode = '23514';
  end if;

  if new.irrigation_zone_id is not null
     and not exists (
       select 1
       from public.irrigation_zones iz
       where iz.id = new.irrigation_zone_id
         and iz.section_id = new.section_id
     ) then
    raise exception 'The selected irrigation zone does not belong to this section'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists palm_trees_validate_hierarchy on public.palm_trees;

create trigger palm_trees_validate_hierarchy
before insert or update of farm_id, section_id, irrigation_zone_id
on public.palm_trees
for each row
execute function public.validate_palm_tree_hierarchy();

-- ------------------------------------------------------------
-- Automatically give every newly registered palm one QR token.
-- The QR image is generated in Flutter/Angular from this token.
-- ------------------------------------------------------------

create or replace function public.create_palm_qr_code()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.palm_qr_codes (palm_tree_id)
  values (new.id)
  on conflict (palm_tree_id) do nothing;

  return new;
end;
$$;

drop trigger if exists palm_trees_create_qr_code on public.palm_trees;

create trigger palm_trees_create_qr_code
after insert on public.palm_trees
for each row
execute function public.create_palm_qr_code();

-- ------------------------------------------------------------
-- Secure RPC: creates one farm, its owner membership,
-- and the 12 default farm sections.
-- ------------------------------------------------------------

create or replace function public.create_farm_with_owner(
  p_name text,
  p_code text,
  p_total_area_m2 numeric default 252000,
  p_palm_variety text default 'Medjool',
  p_timezone text default 'Africa/Cairo',
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_farm_id uuid;
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication is required'
      using errcode = '42501';
  end if;

  if nullif(btrim(p_name), '') is null then
    raise exception 'Farm name is required';
  end if;

  if nullif(btrim(p_code), '') is null then
    raise exception 'Farm code is required';
  end if;

  insert into public.farms (
    name,
    code,
    total_area_m2,
    palm_variety,
    timezone,
    notes
  )
  values (
    btrim(p_name),
    upper(btrim(p_code)),
    p_total_area_m2,
    coalesce(nullif(btrim(p_palm_variety), ''), 'Medjool'),
    coalesce(nullif(btrim(p_timezone), ''), 'Africa/Cairo'),
    p_notes
  )
  returning id into v_farm_id;

  insert into public.farm_memberships (
    farm_id,
    profile_id,
    role
  )
  values (
    v_farm_id,
    v_user_id,
    'owner'::public.farm_role
  );

  insert into public.farm_sections (
    farm_id,
    code,
    name,
    sort_order
  )
  select
    v_farm_id,
    'S' || lpad(section_number::text, 2, '0'),
    'Section ' || section_number::text,
    section_number
  from generate_series(1, 12) as section_number;

  return v_farm_id;
end;
$$;

-- ------------------------------------------------------------
-- Secure RPC for worker / owner / engineer QR scans.
-- Workers never need direct access to all QR tokens.
-- ------------------------------------------------------------

create or replace function public.scan_palm_by_qr(
  p_qr_token uuid
)
returns table (
  palm_tree_id uuid,
  farm_id uuid,
  section_id uuid,
  section_code text,
  section_name text,
  irrigation_zone_id uuid,
  tree_code text,
  row_number integer,
  palm_number integer,
  health_status public.palm_health_status
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    p.id as palm_tree_id,
    p.farm_id,
    p.section_id,
    s.code as section_code,
    s.name as section_name,
    p.irrigation_zone_id,
    p.tree_code,
    p.row_number,
    p.palm_number,
    p.health_status
  from public.palm_qr_codes qr
  join public.palm_trees p
    on p.id = qr.palm_tree_id
  join public.farm_sections s
    on s.id = p.section_id
  where qr.qr_token = p_qr_token
    and qr.is_active = true
    and p.is_active = true
    and exists (
      select 1
      from public.farm_memberships fm
      where fm.farm_id = p.farm_id
        and fm.profile_id = (select auth.uid())
        and fm.is_active = true
    )
  limit 1;
$$;

revoke all on function public.create_farm_with_owner(
  text,
  text,
  numeric,
  text,
  text,
  text
) from public, anon;

grant execute on function public.create_farm_with_owner(
  text,
  text,
  numeric,
  text,
  text,
  text
) to authenticated, service_role;

revoke all on function public.scan_palm_by_qr(uuid) from public, anon;

grant execute on function public.scan_palm_by_qr(uuid)
to authenticated, service_role;

-- ------------------------------------------------------------
-- Explicit API grants.
-- RLS below decides which records can be touched.
-- ------------------------------------------------------------

revoke all on table
  public.profiles,
  public.farms,
  public.farm_memberships,
  public.farm_sections,
  public.irrigation_zones,
  public.palm_trees,
  public.palm_qr_codes
from anon;

revoke all on table
  public.profiles,
  public.farms,
  public.farm_memberships,
  public.farm_sections,
  public.irrigation_zones,
  public.palm_trees,
  public.palm_qr_codes
from authenticated;

grant select on public.profiles to authenticated;
grant update (full_name, phone_number, avatar_url)
on public.profiles to authenticated;

grant select on public.farms to authenticated;

grant select, insert, update, delete
on public.farm_memberships to authenticated;

grant select, insert, update, delete
on public.farm_sections to authenticated;

grant select, insert, update, delete
on public.irrigation_zones to authenticated;

grant select, insert, update, delete
on public.palm_trees to authenticated;

grant select, update
on public.palm_qr_codes to authenticated;

-- ------------------------------------------------------------
-- Enable Row Level Security.
-- ------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.farms enable row level security;
alter table public.farm_memberships enable row level security;
alter table public.farm_sections enable row level security;
alter table public.irrigation_zones enable row level security;
alter table public.palm_trees enable row level security;
alter table public.palm_qr_codes enable row level security;

-- ------------------------------------------------------------
-- Profiles
-- ------------------------------------------------------------

create policy "profiles_select_self_or_shared_farm"
on public.profiles
for select
to authenticated
using (
  id = (select auth.uid())
  or (select private.shares_active_farm_with(id))
);

create policy "profiles_update_self"
on public.profiles
for update
to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

-- ------------------------------------------------------------
-- Farms
-- ------------------------------------------------------------

create policy "farms_select_active_members"
on public.farms
for select
to authenticated
using (
  (select private.is_active_farm_member(id))
);

create policy "farms_update_owners"
on public.farms
for update
to authenticated
using (
  (select private.has_farm_role(
    id,
    array['owner']::public.farm_role[]
  ))
)
with check (
  (select private.has_farm_role(
    id,
    array['owner']::public.farm_role[]
  ))
);

create policy "farms_delete_owners"
on public.farms
for delete
to authenticated
using (
  (select private.has_farm_role(
    id,
    array['owner']::public.farm_role[]
  ))
);

-- ------------------------------------------------------------
-- Farm memberships
-- Owners manage users but cannot self-assign or create another owner.
-- ------------------------------------------------------------

create policy "farm_memberships_select_own_or_management"
on public.farm_memberships
for select
to authenticated
using (
  profile_id = (select auth.uid())
  or (
    select private.has_farm_role(
      farm_id,
      array['owner', 'agricultural_engineer']::public.farm_role[]
    )
  )
);

create policy "farm_memberships_insert_owners"
on public.farm_memberships
for insert
to authenticated
with check (
  (select private.has_farm_role(
    farm_id,
    array['owner']::public.farm_role[]
  ))
  and profile_id <> (select auth.uid())
  and role <> 'owner'::public.farm_role
);

create policy "farm_memberships_update_owners"
on public.farm_memberships
for update
to authenticated
using (
  (select private.has_farm_role(
    farm_id,
    array['owner']::public.farm_role[]
  ))
  and profile_id <> (select auth.uid())
  and role <> 'owner'::public.farm_role
)
with check (
  (select private.has_farm_role(
    farm_id,
    array['owner']::public.farm_role[]
  ))
  and profile_id <> (select auth.uid())
  and role <> 'owner'::public.farm_role
);

create policy "farm_memberships_delete_owners"
on public.farm_memberships
for delete
to authenticated
using (
  (select private.has_farm_role(
    farm_id,
    array['owner']::public.farm_role[]
  ))
  and profile_id <> (select auth.uid())
  and role <> 'owner'::public.farm_role
);

-- ------------------------------------------------------------
-- Farm sections
-- Owner + engineer manage them.
-- ------------------------------------------------------------

create policy "sections_select_farm_members"
on public.farm_sections
for select
to authenticated
using (
  (select private.is_active_farm_member(farm_id))
);

create policy "sections_insert_owner_or_engineer"
on public.farm_sections
for insert
to authenticated
with check (
  (select private.has_farm_role(
    farm_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
);

create policy "sections_update_owner_or_engineer"
on public.farm_sections
for update
to authenticated
using (
  (select private.has_farm_role(
    farm_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
)
with check (
  (select private.has_farm_role(
    farm_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
);

create policy "sections_delete_owners"
on public.farm_sections
for delete
to authenticated
using (
  (select private.has_farm_role(
    farm_id,
    array['owner']::public.farm_role[]
  ))
);

-- ------------------------------------------------------------
-- Irrigation zones
-- ------------------------------------------------------------

create policy "irrigation_zones_select_farm_members"
on public.irrigation_zones
for select
to authenticated
using (
  (select private.is_active_section_member(section_id))
);

create policy "irrigation_zones_insert_owner_or_engineer"
on public.irrigation_zones
for insert
to authenticated
with check (
  (select private.has_section_role(
    section_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
);

create policy "irrigation_zones_update_owner_or_engineer"
on public.irrigation_zones
for update
to authenticated
using (
  (select private.has_section_role(
    section_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
)
with check (
  (select private.has_section_role(
    section_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
);

create policy "irrigation_zones_delete_owners"
on public.irrigation_zones
for delete
to authenticated
using (
  (select private.has_section_role(
    section_id,
    array['owner']::public.farm_role[]
  ))
);

-- ------------------------------------------------------------
-- Palm trees
-- All active members can view; owner + engineer manage.
-- ------------------------------------------------------------

create policy "palm_trees_select_farm_members"
on public.palm_trees
for select
to authenticated
using (
  (select private.is_active_farm_member(farm_id))
);

create policy "palm_trees_insert_owner_or_engineer"
on public.palm_trees
for insert
to authenticated
with check (
  (select private.has_farm_role(
    farm_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
);

create policy "palm_trees_update_owner_or_engineer"
on public.palm_trees
for update
to authenticated
using (
  (select private.has_farm_role(
    farm_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
)
with check (
  (select private.has_farm_role(
    farm_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
);

create policy "palm_trees_delete_owners"
on public.palm_trees
for delete
to authenticated
using (
  (select private.has_farm_role(
    farm_id,
    array['owner']::public.farm_role[]
  ))
);

-- ------------------------------------------------------------
-- QR tokens
-- Workers scan through scan_palm_by_qr() rather than reading all QR codes.
-- ------------------------------------------------------------

create policy "palm_qr_codes_select_owner_or_engineer"
on public.palm_qr_codes
for select
to authenticated
using (
  (select private.has_palm_role(
    palm_tree_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
);

create policy "palm_qr_codes_update_owner_or_engineer"
on public.palm_qr_codes
for update
to authenticated
using (
  (select private.has_palm_role(
    palm_tree_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
)
with check (
  (select private.has_palm_role(
    palm_tree_id,
    array['owner', 'agricultural_engineer']::public.farm_role[]
  ))
);