-- Migration: 20260918000007_ledger_tables | Purpose: Create payments, ledger_entries and expenses tables

-- Exactly one party column is populated, and it must agree with party_type.
create table if not exists payments (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  party_type party_type not null,
  supplier_id uuid references suppliers(id) on delete restrict,
  customer_id uuid references customers(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  mode payment_mode not null,
  reference_no text,
  payment_date date not null default current_date,
  notes text,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payments_party_check check (
    (party_type = 'supplier' and supplier_id is not null and customer_id is null)
    or (party_type = 'customer' and customer_id is not null and supplier_id is null)
  )
);

comment on table payments is 'Cash/bank movements against a single supplier or customer party.';

create table if not exists ledger_entries (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  entry_date date not null default current_date,
  party_type party_type not null,
  supplier_id uuid references suppliers(id) on delete restrict,
  customer_id uuid references customers(id) on delete restrict,
  reference_type ledger_reference_type not null,
  reference_id uuid,
  description text,
  debit numeric(14,2) not null default 0 check (debit >= 0),
  credit numeric(14,2) not null default 0 check (credit >= 0),
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ledger_entries_party_check check (
    (party_type = 'supplier' and supplier_id is not null and customer_id is null)
    or (party_type = 'customer' and customer_id is not null and supplier_id is null)
  )
);

comment on table ledger_entries is 'Append-only party ledger; reference_id points at the source document but is not FK-enforced (polymorphic).';

create table if not exists expenses (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  category text not null,
  amount numeric(14,2) not null check (amount > 0),
  expense_date date not null default current_date,
  payment_mode payment_mode not null default 'cash',
  notes text,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
