-- Migration: 20260918000005_purchase_tables | Purpose: Create purchase and purchase-return tables

create table if not exists purchases (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  supplier_id uuid not null references suppliers(id) on delete restrict,
  invoice_no text not null,
  invoice_date date not null default current_date,
  status purchase_status not null default 'draft',
  sub_total numeric(14,2) not null default 0,
  discount_total numeric(14,2) not null default 0,
  tax_total numeric(14,2) not null default 0,
  grand_total numeric(14,2) not null default 0,
  notes text,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint purchases_pharmacy_supplier_invoice_key unique (pharmacy_id, supplier_id, invoice_no)
);

create table if not exists purchase_items (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  purchase_id uuid not null references purchases(id) on delete cascade,
  product_id uuid references products(id) on delete set null,
  batch_id uuid references product_batches(id) on delete set null,
  product_name_raw text,
  batch_no text,
  expiry_date date,
  hsn_code text,
  qty int not null check (qty > 0),
  free_qty int not null default 0 check (free_qty >= 0),
  purchase_rate numeric(12,2) not null,
  mrp numeric(12,2) not null,
  selling_rate numeric(12,2) not null default 0,
  discount_percent numeric(5,2) not null default 0,
  gst_percent numeric(5,2) not null default 0,
  cgst_amount numeric(14,2) not null default 0,
  sgst_amount numeric(14,2) not null default 0,
  igst_amount numeric(14,2) not null default 0,
  tax_amount numeric(14,2) not null default 0,
  total_amount numeric(14,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column purchase_items.product_name_raw is 'As printed on the supplier invoice, kept for alias learning even after product_id is resolved.';

create table if not exists purchase_returns (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  purchase_id uuid not null references purchases(id) on delete restrict,
  supplier_id uuid not null references suppliers(id) on delete restrict,
  return_date date not null default current_date,
  reason text,
  sub_total numeric(14,2) not null default 0,
  tax_total numeric(14,2) not null default 0,
  grand_total numeric(14,2) not null default 0,
  status text not null default 'completed',
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists purchase_return_items (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  purchase_return_id uuid not null references purchase_returns(id) on delete cascade,
  purchase_item_id uuid references purchase_items(id) on delete set null,
  product_id uuid references products(id) on delete set null,
  batch_id uuid references product_batches(id) on delete set null,
  qty int not null check (qty > 0),
  purchase_rate numeric(12,2) not null default 0,
  mrp numeric(12,2) not null default 0,
  gst_percent numeric(5,2) not null default 0,
  tax_amount numeric(14,2) not null default 0,
  total_amount numeric(14,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
