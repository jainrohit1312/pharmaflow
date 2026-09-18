-- Migration: 20260918000003_core_tables | Purpose: Create pharmacies and profiles core tenant tables

create table if not exists pharmacies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  city text,
  state text,
  pincode text,
  phone text,
  email text,
  gstin text,
  drug_license_no text,
  logo_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table pharmacies is 'Tenant root: one row per pharmacy/outlet. Every other business table scopes to this.';
comment on column pharmacies.gstin is 'GSTIN; unique per pharmacy when present.';

create unique index if not exists pharmacies_gstin_key on pharmacies (gstin) where gstin is not null;

create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  pharmacy_id uuid references pharmacies(id) on delete set null,
  full_name text,
  phone text,
  avatar_url text,
  role app_role not null default 'viewer',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table profiles is 'Application user profile, 1:1 with auth.users; may predate pharmacy assignment.';
