-- Migration: 20260918000006_sales_tables | Purpose: Create sales and sale-return tables

create table if not exists sales (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  customer_id uuid references customers(id) on delete set null,
  invoice_no text not null,
  sale_date timestamptz not null default now(),
  status sale_status not null default 'completed',
  sub_total numeric(14,2) not null default 0,
  discount_total numeric(14,2) not null default 0,
  tax_total numeric(14,2) not null default 0,
  grand_total numeric(14,2) not null default 0,
  payment_mode payment_mode not null default 'cash',
  amount_paid numeric(14,2) not null default 0,
  balance_due numeric(14,2) not null default 0,
  place_of_supply text,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sales_pharmacy_invoice_key unique (pharmacy_id, invoice_no)
);

create table if not exists sale_items (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  sale_id uuid not null references sales(id) on delete cascade,
  product_id uuid references products(id) on delete set null,
  batch_id uuid not null references product_batches(id) on delete restrict,
  qty int not null check (qty > 0),
  rate numeric(12,2) not null,
  discount_percent numeric(5,2) not null default 0,
  discount_amount numeric(14,2) not null default 0,
  gst_percent numeric(5,2) not null default 0,
  cgst_amount numeric(14,2) not null default 0,
  sgst_amount numeric(14,2) not null default 0,
  igst_amount numeric(14,2) not null default 0,
  tax_amount numeric(14,2) not null default 0,
  total_amount numeric(14,2) not null default 0,
  schedule_type schedule_type not null default 'OTC',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column sale_items.schedule_type is 'Snapshot of the product schedule at time of sale; drives statutory register reporting.';

create table if not exists sale_returns (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  sale_id uuid not null references sales(id) on delete restrict,
  customer_id uuid references customers(id) on delete set null,
  return_date timestamptz not null default now(),
  reason text,
  refund_mode payment_mode not null default 'cash',
  sub_total numeric(14,2) not null default 0,
  tax_total numeric(14,2) not null default 0,
  grand_total numeric(14,2) not null default 0,
  restock boolean not null default true,
  status text not null default 'completed',
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column sale_returns.restock is 'False when goods are damaged/not resellable, so the later trigger skips stock restoration.';

create table if not exists sale_return_items (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  sale_return_id uuid not null references sale_returns(id) on delete cascade,
  sale_item_id uuid references sale_items(id) on delete set null,
  product_id uuid references products(id) on delete set null,
  batch_id uuid references product_batches(id) on delete restrict,
  qty int not null check (qty > 0),
  rate numeric(12,2) not null default 0,
  gst_percent numeric(5,2) not null default 0,
  tax_amount numeric(14,2) not null default 0,
  total_amount numeric(14,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
