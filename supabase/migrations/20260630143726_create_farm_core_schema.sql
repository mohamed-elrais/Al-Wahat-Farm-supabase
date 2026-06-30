-- ============================================================
-- Al-Wahat Farm — Core Farm Structure
-- First migration
-- ============================================================

-- -------------------------
-- Enums
-- -------------------------

create type public.farm_role as enum (
  'owner',
  'agricultural_engineer',
  'worker',
  'accountant'
);

create type public.palm_health_status as enum (
  'healthy',
  'needs_monitoring',
  'needs_engineer_review',
  'inactive'
);

-- -------------------------
-- User profiles
-- One profile per Supabase Auth user
-- -------------------------

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  phone_number text,
  avatar_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Automatically create a profile whenever a new Auth user is created.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
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

create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();

-- -------------------------
-- Farms
-- -------------------------

create table public.farms (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text not null unique,
  total_area_m2 numeric(12, 2),
  palm_variety text not null default 'Medjool',
  timezone text not null default 'Africa/Cairo',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- -------------------------
-- Users and roles inside a farm
-- A person can have more than one role if needed.
-- -------------------------

create table public.farm_memberships (
  id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references public.farms(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  role public.farm_role not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),

  unique (farm_id, profile_id, role)
);

create index farm_memberships_farm_id_idx
  on public.farm_memberships (farm_id);

create index farm_memberships_profile_id_idx
  on public.farm_memberships (profile_id);

-- -------------------------
-- Farm sections
-- Your farm starts with 12 sections.
-- -------------------------

create table public.farm_sections (
  id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references public.farms(id) on delete cascade,
  code text not null,
  name text not null,
  sort_order smallint not null,
  area_m2 numeric(12, 2),
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (farm_id, code),
  unique (farm_id, sort_order)
);

create index farm_sections_farm_id_idx
  on public.farm_sections (farm_id);

-- -------------------------
-- Irrigation zones / valve areas
-- A section may contain several irrigation zones.
-- -------------------------

create table public.irrigation_zones (
  id uuid primary key default gen_random_uuid(),
  section_id uuid not null references public.farm_sections(id) on delete cascade,
  code text not null,
  name text not null,
  valve_code text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (section_id, code)
);

create index irrigation_zones_section_id_idx
  on public.irrigation_zones (section_id);

-- -------------------------
-- Individual Medjool palms
-- latitude/longitude are enough for the first version.
-- We can add PostGIS geometry later for advanced map / 3D work.
-- -------------------------

create table public.palm_trees (
  id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references public.farms(id) on delete cascade,
  section_id uuid not null references public.farm_sections(id) on delete restrict,
  irrigation_zone_id uuid references public.irrigation_zones(id) on delete set null,

  tree_code text not null,
  row_number integer,
  palm_number integer,

  planted_on date,
  latitude numeric(9, 6),
  longitude numeric(9, 6),

  health_status public.palm_health_status not null default 'healthy',
  notes text,
  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (farm_id, tree_code),

  constraint palm_latitude_range_check
    check (latitude is null or latitude between -90 and 90),

  constraint palm_longitude_range_check
    check (longitude is null or longitude between -180 and 180)
);

create index palm_trees_farm_id_idx
  on public.palm_trees (farm_id);

create index palm_trees_section_id_idx
  on public.palm_trees (section_id);

create index palm_trees_irrigation_zone_id_idx
  on public.palm_trees (irrigation_zone_id);

create index palm_trees_tree_code_idx
  on public.palm_trees (tree_code);

-- -------------------------
-- QR tags
-- QR code should contain a secure token, not the palm UUID itself.
-- -------------------------

create table public.palm_qr_codes (
  id uuid primary key default gen_random_uuid(),
  palm_tree_id uuid not null unique
    references public.palm_trees(id) on delete cascade,

  qr_token uuid not null unique default gen_random_uuid(),

  printed_at timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index palm_qr_codes_qr_token_idx
  on public.palm_qr_codes (qr_token);

-- -------------------------
-- Shared updated_at trigger
-- -------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
before update on public.profiles
for each row
execute function public.set_updated_at();

create trigger farms_set_updated_at
before update on public.farms
for each row
execute function public.set_updated_at();

create trigger farm_sections_set_updated_at
before update on public.farm_sections
for each row
execute function public.set_updated_at();

create trigger irrigation_zones_set_updated_at
before update on public.irrigation_zones
for each row
execute function public.set_updated_at();

create trigger palm_trees_set_updated_at
before update on public.palm_trees
for each row
execute function public.set_updated_at();