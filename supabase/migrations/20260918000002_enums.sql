-- Migration: 20260918000002_enums | Purpose: Create PharmaFlow enum types

-- Application roles for pharmacy staff.
do $$ begin
  create type app_role as enum ('owner', 'pharmacist', 'cashier', 'viewer');
exception when duplicate_object then null;
end $$;

-- Drug schedule classification. 'OTC', 'H' and 'X' mirror the statutory labels; 'H1' is uppercase.
do $$ begin
  create type schedule_type as enum ('OTC', 'H', 'H1', 'X', 'narcotic');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type payment_mode as enum ('cash', 'card', 'upi', 'credit', 'bank', 'wallet', 'other');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type purchase_status as enum ('draft', 'ordered', 'received', 'cancelled');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type sale_status as enum ('completed', 'cancelled', 'credit');
exception when duplicate_object then null;
end $$;

-- Used by payments and ledger_entries to identify which party column is populated.
do $$ begin
  create type party_type as enum ('supplier', 'customer');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type ledger_reference_type as enum
    ('opening', 'purchase', 'purchase_return', 'sale', 'sale_return', 'payment', 'expense', 'adjustment');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type notification_channel as enum ('push', 'whatsapp', 'email', 'in_app');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type adjustment_type as enum ('increase', 'decrease');
exception when duplicate_object then null;
end $$;
