-- Migration: 20260918000010_triggers | Purpose: updated_at bookkeeping trigger on every table plus auth.users -> profiles provisioning trigger
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: drop trigger if exists before every create trigger; functions use create or replace.

-- ---------------------------------------------------------------------------
-- 1. Generic updated_at maintainer
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Attach it to every table that owns an updated_at column
-- ---------------------------------------------------------------------------
drop trigger if exists set_updated_at on public.pharmacies;
create trigger set_updated_at before update on public.pharmacies
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.profiles;
create trigger set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.suppliers;
create trigger set_updated_at before update on public.suppliers
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.customers;
create trigger set_updated_at before update on public.customers
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.products;
create trigger set_updated_at before update on public.products
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.product_batches;
create trigger set_updated_at before update on public.product_batches
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.product_aliases;
create trigger set_updated_at before update on public.product_aliases
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.purchases;
create trigger set_updated_at before update on public.purchases
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.purchase_items;
create trigger set_updated_at before update on public.purchase_items
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.purchase_returns;
create trigger set_updated_at before update on public.purchase_returns
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.purchase_return_items;
create trigger set_updated_at before update on public.purchase_return_items
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.sales;
create trigger set_updated_at before update on public.sales
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.sale_items;
create trigger set_updated_at before update on public.sale_items
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.sale_returns;
create trigger set_updated_at before update on public.sale_returns
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.sale_return_items;
create trigger set_updated_at before update on public.sale_return_items
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.payments;
create trigger set_updated_at before update on public.payments
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.ledger_entries;
create trigger set_updated_at before update on public.ledger_entries
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.expenses;
create trigger set_updated_at before update on public.expenses
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.stock_adjustments;
create trigger set_updated_at before update on public.stock_adjustments
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.notifications;
create trigger set_updated_at before update on public.notifications
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.audit_logs;
create trigger set_updated_at before update on public.audit_logs
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. Auth -> profiles provisioning
--    New auth.users rows get a matching profiles row with the least-privileged
--    role ('viewer'). Role elevation and pharmacy linkage are done by an owner
--    (or service_role) after onboarding.
--    SECURITY DEFINER + pinned search_path so the insert is not blocked by
--    profiles' own RLS and cannot be hijacked via search_path.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, role)
  values (
    new.id,
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    new.phone,
    'viewer'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- 4. PHASE-2 AUTOMATION (deliberately disabled)
--
--    The five functions below are the second-phase automation layer:
--    ledger postings, stock mutation and auditing. They are shipped as
--    commented blocks so the current release stays explicit-write only, and
--    so a future migration can enable them without redesigning call sites.
--
--    Each block is valid SQL/plpgsql that would work if uncommented (modulo
--    the workflow assumptions noted inline). To enable, uncomment the function
--    AND its trigger block, then run the migration.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- TODO(phase-2): ledger_auto_entry_purchase()
-- Posts a supplier credit entry when a purchase becomes 'received'.
-- Depends on: purchases.status, ledger_entries(reference_type='purchase').
-- ---------------------------------------------------------------------------
-- create or replace function public.ledger_auto_entry_purchase()
-- returns trigger
-- language plpgsql
-- security definer
-- set search_path = public
-- as $$
-- begin
--   -- Only post once the document is finalised; drafts must stay out of the ledger.
--   if new.status is distinct from 'received' then
--     return new;
--   end if;
--
--   -- Idempotency guard: one ledger row per purchase document.
--   if exists (
--     select 1 from public.ledger_entries
--     where reference_type = 'purchase' and reference_id = new.id
--   ) then
--     return new;
--   end if;
--
--   insert into public.ledger_entries (
--     pharmacy_id, entry_date, party_type, supplier_id,
--     reference_type, reference_id, description, debit, credit, created_by
--   ) values (
--     new.pharmacy_id,
--     coalesce(new.invoice_date, current_date),
--     'supplier',
--     new.supplier_id,
--     'purchase',
--     new.id,
--     'Purchase ' || coalesce(new.invoice_no, new.id::text),
--     0,
--     coalesce(new.grand_total, 0),
--     new.created_by
--   );
--
--   return new;
-- end;
-- $$;
--
-- drop trigger if exists trg_ledger_auto_entry_purchase on public.purchases;
-- create trigger trg_ledger_auto_entry_purchase
--   after insert or update of status on public.purchases
--   for each row execute function public.ledger_auto_entry_purchase();

-- ---------------------------------------------------------------------------
-- TODO(phase-2): ledger_auto_entry_sale()
-- Posts the customer receivable for a completed sale (debit grand_total) and
-- the immediate cash/bank receipt (credit amount_paid).
-- Depends on: sales.status, sales.amount_paid, sales.payment_mode.
-- ---------------------------------------------------------------------------
-- create or replace function public.ledger_auto_entry_sale()
-- returns trigger
-- language plpgsql
-- security definer
-- set search_path = public
-- as $$
-- begin
--   if new.status is distinct from 'completed' then
--     return new;
--   end if;
--
--   -- Idempotency guard: the receivable row is keyed by reference_id = sale id.
--   if not exists (
--     select 1 from public.ledger_entries
--     where reference_type = 'sale' and reference_id = new.id
--   ) then
--     insert into public.ledger_entries (
--       pharmacy_id, entry_date, party_type, customer_id,
--       reference_type, reference_id, description, debit, credit, created_by
--     ) values (
--       new.pharmacy_id,
--       coalesce(new.sale_date, current_date),
--       'customer',
--       new.customer_id,
--       'sale',
--       new.id,
--       'Sale ' || coalesce(new.invoice_no, new.id::text),
--       coalesce(new.grand_total, 0),
--       0,
--       new.created_by
--     );
--   end if;
--
--   -- Cash/counter settlement captured on the document itself.
--   if coalesce(new.amount_paid, 0) > 0 then
--     insert into public.payments (
--       pharmacy_id, party_type, customer_id, amount, mode,
--       reference_no, payment_date, notes, created_by
--     ) values (
--       new.pharmacy_id,
--       'customer',
--       new.customer_id,
--       new.amount_paid,
--       new.payment_mode,
--       new.invoice_no,
--       coalesce(new.sale_date, current_date),
--       'Auto-captured from sale ' || coalesce(new.invoice_no, new.id::text),
--       new.created_by
--     );
--   end if;
--
--   return new;
-- end;
-- $$;
--
-- drop trigger if exists trg_ledger_auto_entry_sale on public.sales;
-- create trigger trg_ledger_auto_entry_sale
--   after insert or update of status on public.sales
--   for each row execute function public.ledger_auto_entry_sale();

-- ---------------------------------------------------------------------------
-- TODO(phase-2): stock_update_on_purchase()
-- Increments the batch quantity for every received purchase line.
-- Depends on: purchase_items(batch_id, qty) being populated by the intake UI
-- (batch rows are expected to exist before lines are written).
-- ---------------------------------------------------------------------------
-- create or replace function public.stock_update_on_purchase()
-- returns trigger
-- language plpgsql
-- security definer
-- set search_path = public
-- as $$
-- begin
--   if new.batch_id is null then
--     return new;
--   end if;
--
--   update public.product_batches b
--      set qty = b.qty + coalesce(new.qty, 0),
--          updated_at = now()
--    where b.id = new.batch_id
--      and b.pharmacy_id = new.pharmacy_id;
--
--   return new;
-- end;
-- $$;
--
-- drop trigger if exists trg_stock_update_on_purchase on public.purchase_items;
-- create trigger trg_stock_update_on_purchase
--   after insert on public.purchase_items
--   for each row execute function public.stock_update_on_purchase();

-- ---------------------------------------------------------------------------
-- TODO(phase-2): stock_update_on_sale()
-- Decrements batch quantity and refuses to oversell. Paired with a refund path
-- on sale_returns once returns are wired to batches.
-- Depends on: sale_items(batch_id, qty), product_batches.qty.
-- ---------------------------------------------------------------------------
-- create or replace function public.stock_update_on_sale()
-- returns trigger
-- language plpgsql
-- security definer
-- set search_path = public
-- as $$
-- declare
--   v_updated integer;
-- begin
--   if new.batch_id is null then
--     return new;
--   end if;
--
--   update public.product_batches b
--      set qty = b.qty - coalesce(new.qty, 0),
--          updated_at = now()
--    where b.id = new.batch_id
--      and b.pharmacy_id = new.pharmacy_id
--      and b.qty >= coalesce(new.qty, 0);
--
--   get diagnostics v_updated = row_count;
--
--   if v_updated = 0 then
--     raise exception 'insufficient stock in batch % for sale item %', new.batch_id, new.id
--       using errcode = 'check_violation';
--   end if;
--
--   return new;
-- end;
-- $$;
--
-- drop trigger if exists trg_stock_update_on_sale on public.sale_items;
-- create trigger trg_stock_update_on_sale
--   after insert on public.sale_items
--   for each row execute function public.stock_update_on_sale();

-- ---------------------------------------------------------------------------
-- TODO(phase-2): write_audit_log()
-- Generic AFTER INSERT/UPDATE/DELETE audit trigger writing to public.audit_logs.
-- Attach per table with:
--   create trigger audit_<table> after insert or update or delete on public.<table>
--     for each row execute function public.write_audit_log();
-- audit_logs itself must be excluded to avoid recursion.
-- ---------------------------------------------------------------------------
-- create or replace function public.write_audit_log()
-- returns trigger
-- language plpgsql
-- security definer
-- set search_path = public
-- as $$
-- declare
--   v_row jsonb;
--   v_record_id uuid;
--   v_pharmacy_id uuid;
-- begin
--   if tg_op = 'DELETE' then
--     v_row := to_jsonb(old);
--   else
--     v_row := to_jsonb(new);
--   end if;
--
--   v_record_id := nullif(v_row ->> 'id', '')::uuid;
--   v_pharmacy_id := nullif(v_row ->> 'pharmacy_id', '')::uuid;
--
--   insert into public.audit_logs (
--     pharmacy_id, table_name, action, record_id, user_id, old_data, new_data
--   ) values (
--     v_pharmacy_id,
--     tg_table_name,
--     tg_op,
--     v_record_id,
--     auth.uid(),
--     case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
--     case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end
--   );
--
--   if tg_op = 'DELETE' then
--     return old;
--   end if;
--   return new;
-- end;
-- $$;
