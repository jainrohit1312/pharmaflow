-- Migration: 20260918000020_phase4_ledger_payments | Purpose: close two defects
-- migration 00019 shipped with, post the purchase-return credit note the Phase 2
-- work left unposted, and put a manual payment and its ledger row behind one
-- transaction.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace function / drop trigger if exists /
--             insert ... where not exists / guarded grants.
--
-- Why 00019 is not edited in place
-- -------------------------------
-- 00019 is already applied to the hosted project, and `supabase db push` does not
-- re-run an applied version - so a correction made inside it would never reach
-- the database this project actually uses. Migration 00016 faced the same
-- situation with 00015 and settled the convention this file follows: the applied
-- migration stays as the historical record of what ran, and the correction is a
-- new migration. A fresh replay of 00019 then 00020 reaches the same state.

-- ---------------------------------------------------------------------------
-- 1. Correction to 00019: the EXECUTE grant anon was left with
--
--    Supabase grants EXECUTE on a new function in `public` to `anon`,
--    `authenticated` and `service_role` directly, not only through PUBLIC, so
--    `grant execute ... to authenticated` in 00019 narrowed nothing: anon could
--    still call checkout_sale(). D-017 records the same trap for
--    onboard_pharmacy() - revoking from PUBLIC is not enough while a role holds
--    its own grant.
--
--    Found by the SQL test, assertion 1: "anon cannot execute checkout_sale
--    (expected false, got true)".
-- ---------------------------------------------------------------------------
revoke execute on function public.checkout_sale(jsonb) from anon, public;
revoke execute on function public.next_sale_invoice_no() from anon, public;

-- ---------------------------------------------------------------------------
-- 2. Correction to 00019: tendering more than the bill
--
--    checkout_sale() computed `balance_due = grand_total - amount_paid`, so a
--    tender larger than the bill stored a NEGATIVE balance. Found by the SQL test,
--    assertion 8: "an overpayment leaves no negative balance (expected 0.00, got
--    -4783.00) - the change a cashier hands back is not a payment".
--
--    Fixed as a table-level check rather than inside the RPC, because the
--    document's own arithmetic should hold for every insert path, not only for
--    the one function that exists today. A constraint cannot express it (it would
--    compare two columns of the same row, which is allowed - but a CHECK is only
--    evaluated on write and cannot be added in place without a lock, and a
--    trigger keeps the error inside this file's reach and the message readable).
-- ---------------------------------------------------------------------------
create or replace function public.sales_payment_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- The change handed back to a customer is not revenue: a sale records what
  -- settled it, which is at most what it was for.
  if coalesce(new.amount_paid, 0) > coalesce(new.grand_total, 0) then
    raise exception 'a sale cannot be paid more than its total (% tendered for %)',
      new.amount_paid, new.grand_total
      using errcode = 'check_violation';
  end if;

  if coalesce(new.amount_paid, 0) < 0 then
    raise exception 'a sale cannot have a negative amount paid'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sales_payment_check on public.sales;
create trigger trg_sales_payment_check
  before insert or update on public.sales
  for each row execute function public.sales_payment_check();

-- ---------------------------------------------------------------------------
-- 3. The purchase-return credit note
--
--    `ledger_auto_entry_purchase()` has posted the supplier payable since
--    migration 00015, but nothing ever posted the *contra*: a purchase return
--    reduced stock (stock_update_on_purchase_return, also 00015) and left the
--    supplier looking owed the full invoice. `ledger_reference_type` has carried
--    'purchase_return' since migration 00002 in anticipation of exactly this.
--
--    Direction: a supplier's balance is credit - debit (what we owe). A return
--    reduces it, so the credit note is a DEBIT. The mirror of the sale side,
--    where a customer's return is a credit.
-- ---------------------------------------------------------------------------
create or replace function public.ledger_auto_entry_purchase_return()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- `purchase_returns.status` is text and defaults to 'completed'; the one way
  -- it is not final is a cancellation, which never happened.
  if coalesce(new.status, 'completed') = 'cancelled' then
    return new;
  end if;

  if exists (
    select 1 from public.ledger_entries
    where reference_type = 'purchase_return' and reference_id = new.id
  ) then
    return new;
  end if;

  insert into public.ledger_entries (
    pharmacy_id, entry_date, party_type, supplier_id,
    reference_type, reference_id, description, debit, credit, created_by
  ) values (
    new.pharmacy_id,
    coalesce(new.return_date, current_date),
    'supplier',
    new.supplier_id,
    'purchase_return',
    new.id,
    'Purchase return ' || new.id::text,
    coalesce(new.grand_total, 0),
    0,
    new.created_by
  );

  return new;
end;
$$;

drop trigger if exists trg_ledger_auto_entry_purchase_return on public.purchase_returns;
create trigger trg_ledger_auto_entry_purchase_return
  after insert or update of status on public.purchase_returns
  for each row execute function public.ledger_auto_entry_purchase_return();

-- Backfill: any return recorded before this trigger existed has no credit note.
-- Guarded by the same not-exists test the trigger uses, so re-running is a no-op.
insert into public.ledger_entries (
  pharmacy_id, entry_date, party_type, supplier_id,
  reference_type, reference_id, description, debit, credit, created_by
)
select
  pr.pharmacy_id,
  coalesce(pr.return_date, current_date),
  'supplier',
  pr.supplier_id,
  'purchase_return',
  pr.id,
  'Purchase return ' || pr.id::text || ' (backfilled)',
  coalesce(pr.grand_total, 0),
  0,
  pr.created_by
from public.purchase_returns pr
where coalesce(pr.status, 'completed') <> 'cancelled'
  and coalesce(pr.grand_total, 0) <> 0
  and not exists (
    select 1 from public.ledger_entries le
    where le.reference_type = 'purchase_return' and le.reference_id = pr.id
  );

-- ---------------------------------------------------------------------------
-- 4. record_payment()
--
--    A payment is two rows that have to agree - the cash/bank movement and the
--    ledger entry that settles the party - and PostgREST writes one statement at
--    a time, which is why this is a function: a payment that recorded the cash
--    and failed to post the ledger would leave a party looking in debt after they
--    had paid.
--
--    It is also the only write path that can set `payments` from the app: the
--    counter settlement inside `ledger_auto_entry_sale()` is written by the sale
--    trigger, because at that moment the sale *is* the event.
--
--    Direction, and why the two parties differ:
--      * supplier - the bill was a credit, so a payment DEBITS (we owe less);
--      * customer - the bill was a debit, so a payment CREDITS (they owe less).
-- ---------------------------------------------------------------------------
create or replace function public.record_payment(
  p_party_type public.party_type,
  p_party_id uuid,
  p_amount numeric,
  p_mode public.payment_mode,
  p_reference_no text default null,
  p_payment_date date default null,
  p_notes text default null
)
returns public.payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_date     date := coalesce(p_payment_date, current_date);
  v_payment  public.payments;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  if coalesce(p_amount, 0) <= 0 then
    raise exception 'a payment needs an amount greater than zero'
      using errcode = 'check_violation';
  end if;

  -- The party has to be the caller's own: the FK would accept another tenant's
  -- id, and RLS does not apply inside a definer function.
  if p_party_type = 'supplier' then
    if not exists (
      select 1 from public.suppliers s
       where s.id = p_party_id and s.pharmacy_id = v_pharmacy
    ) then
      raise exception 'that supplier is not in this pharmacy'
        using errcode = 'check_violation';
    end if;
  else
    if not exists (
      select 1 from public.customers c
       where c.id = p_party_id and c.pharmacy_id = v_pharmacy
    ) then
      raise exception 'that customer is not in this pharmacy'
        using errcode = 'check_violation';
    end if;
  end if;

  insert into public.payments (
    pharmacy_id, party_type, supplier_id, customer_id, amount, mode,
    reference_no, payment_date, notes
  ) values (
    v_pharmacy,
    p_party_type,
    case when p_party_type = 'supplier' then p_party_id end,
    case when p_party_type = 'customer' then p_party_id end,
    p_amount,
    p_mode,
    nullif(trim(coalesce(p_reference_no, '')), ''),
    v_date,
    nullif(trim(coalesce(p_notes, '')), '')
  )
  returning * into v_payment;

  insert into public.ledger_entries (
    pharmacy_id, entry_date, party_type, supplier_id, customer_id,
    reference_type, reference_id, description, debit, credit
  ) values (
    v_pharmacy,
    v_date,
    p_party_type,
    case when p_party_type = 'supplier' then p_party_id end,
    case when p_party_type = 'customer' then p_party_id end,
    'payment',
    v_payment.id,
    case when p_party_type = 'supplier'
         then 'Paid to supplier'
         else 'Received from customer'
    end,
    case when p_party_type = 'supplier' then p_amount else 0 end,
    case when p_party_type = 'customer' then p_amount else 0 end
  );

  return v_payment;
end;
$$;

comment on function public.record_payment(
  public.party_type, uuid, numeric, public.payment_mode, text, date, text
) is
  'Records a supplier or customer payment and its ledger entry in one transaction. Scoped to the caller''s pharmacy; refuses a party from another tenant.';

-- ---------------------------------------------------------------------------
-- 5. Grants
--    authenticated only, and anon revoked explicitly - see section 1 for why the
--    grant alone would not have been enough.
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.record_payment(public.party_type, uuid, numeric, public.payment_mode, text, date, text) to authenticated';
  execute 'revoke execute on function public.record_payment(public.party_type, uuid, numeric, public.payment_mode, text, date, text) from anon, public';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Not changed, on purpose
--
--    `expenses` posts nothing to the ledger, and cannot: `ledger_entries`
--    requires a `party_type` and exactly one matching party id, and an expense has
--    no party at all (rent, electricity, salaries). `ledger_reference_type` lists
--    'expense' for a future expense that *is* paid to a party, but with no party
--    column on `expenses` there is nothing to post today. Phase 4's reports read
--    expenses from their own table.
--
--    A walk-in counter sale cannot appear in `payments` either, because
--    `payments_party_check` requires a customer_id for party_type = 'customer'.
--    Its takings live on `sales.amount_paid`, which is why the cash report has to
--    read both tables rather than `payments` alone.
-- ---------------------------------------------------------------------------
