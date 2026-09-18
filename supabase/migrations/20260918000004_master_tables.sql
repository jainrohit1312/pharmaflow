-- Migration: 20260918000004_master_tables | Purpose: Create master data tables (suppliers, customers, products, batches, aliases)

create table if not exists suppliers (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  name text not null,
  gstin text,
  drug_license_no text,
  contact_person text,
  phone text,
  email text,
  address text,
  city text,
  state text,
  pincode text,
  credit_days int not null default 0,
  opening_balance numeric(14,2) not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists customers (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  name text not null,
  phone text,
  email text,
  address text,
  gstin text,
  opening_balance numeric(14,2) not null default 0,
  loyalty_points int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists products (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  name text not null,
  generic_name text,
  brand text,
  manufacturer text,
  hsn_code text,
  category text,
  schedule_type schedule_type not null default 'OTC',
  pack_size text,
  unit text,
  min_stock_level int not null default 0,
  rack_location text,
  barcode text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table products is 'Catalogue master. Stock lives in product_batches, not here.';

create table if not exists product_batches (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  product_id uuid not null references products(id) on delete cascade,
  batch_no text not null,
  mfg_date date,
  expiry_date date not null,
  qty int not null default 0 check (qty >= 0),
  purchase_rate numeric(12,2) not null default 0,
  mrp numeric(12,2) not null default 0,
  selling_rate numeric(12,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_batches_pharmacy_product_batch_key unique (pharmacy_id, product_id, batch_no)
);

comment on table product_batches is 'Stock-on-hand per product+batch; qty is the running balance maintained by later triggers.';

create table if not exists product_aliases (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  raw_name text not null,
  normalized_name text not null,
  product_id uuid not null references products(id) on delete cascade,
  supplier_id uuid references suppliers(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table product_aliases is 'Learned mappings from supplier invoice text to catalogue products, used to auto-match on purchase import.';
