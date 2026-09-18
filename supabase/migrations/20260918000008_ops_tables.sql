-- Migration: 20260918000008_ops_tables | Purpose: Create stock adjustment, notification and audit log tables

create table if not exists stock_adjustments (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  product_id uuid not null references products(id) on delete cascade,
  batch_id uuid references product_batches(id) on delete restrict,
  adjustment_type adjustment_type not null,
  qty int not null check (qty > 0),
  reason text,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table stock_adjustments is 'Manual stock corrections; qty is always positive, adjustment_type gives the direction.';

create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  pharmacy_id uuid references pharmacies(id) on delete cascade,
  type text not null,
  title text,
  message text not null,
  channel notification_channel not null default 'in_app',
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column notifications.data is 'Arbitrary payload for deep-linking / channel rendering.';

create table if not exists audit_logs (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid references pharmacies(id) on delete cascade,
  table_name text not null,
  action text not null,
  record_id uuid,
  user_id uuid references profiles(id) on delete set null,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table audit_logs is 'Written by later audit triggers; pharmacy_id nullable so pre-tenant actions are still captured.';
