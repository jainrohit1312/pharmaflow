-- Migration: 20260918000019_phase3_sale_automation | Purpose: enable the sale-side
-- automation layer (sale stock posting, customer ledger, sale-return restock and
-- credit note, audit trail), add the per-day invoice counter a POS needs, and put
-- the multi-table checkout behind one atomic RPC.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create table if not exists / create or replace function /
--             drop trigger if exists / create index if not exists.
--
-- Why this file exists instead of uncommenting migration 20260918000010
-- -------------------------------------------------------------------
-- The automation functions were shipped commented out in
-- 20260918000010_triggers.sql with TODO(phase-2) markers. That migration is
-- already applied to the hosted project, and `supabase db push` only applies
-- versions missing from supabase_migrations.schema_migrations - editing an
-- applied file would leave the repository looking enabled while the database
-- stayed inert. D-013 records that reasoning for the Phase 2 purchase side, and
-- this is the same move one phase later. The commented originals stay in 00010
-- as the historical record; the bodies below are the live ones.
--
-- Mapping back to the commented originals:
--   ledger_auto_entry_sale()          -> activated here, with two deliberate
--                                        deviations (see below)
--   stock_update_on_sale()            -> activated, with a status gate the
--                                        original lacked
--   write_audit_log()                 -> activated verbatim; attached per table
--   (sale returns had no original)    -> stock_restore_on_sale_return() and
--                                        ledger_auto_entry_sale_return()
--
-- Two deviations from the shipped ledger_auto_entry_sale(), both forced by
-- constraints already in the schema
-- -------------------------------------------------------------------------
--  1. A sale with no customer posts NOTHING. `ledger_entries_party_check`
--     (00007) requires a non-null customer_id whenever party_type = 'customer',
--     and `sales.customer_id` is nullable (00006) because a walk-in cash sale
--     has no party. The shipped body inserted unconditionally, so the commonest
--     sale in a pharmacy - cash, no customer - would have failed the check
--     constraint and aborted the checkout. There is also nothing to track: a
--     walk-in pays at the counter and owes nothing.
--  2. The gate is "not cancelled", not "is completed". `sale_status` has three
--     values (completed, cancelled, credit), and a credit sale is the one case
--     where a receivable is the whole point - the shipped `is distinct from
--     'completed'` gate would have left every credit sale unposted until it was
--     settled, which is exactly backwards.
--
-- What a sale does to stock, and why it is per line rather than per document
-- -------------------------------------------------------------------------
-- The purchase side posts stock when a document reaches `received`, because a
-- purchase has a draft life. A sale does not: `sale_status` has no draft, so the
-- header is final when it is written and the lines are the only event. Stock
-- therefore moves as each sale line is inserted (`after insert on sale_items`),
-- gated on the parent sale not being cancelled, and the once-only guarantee is
-- structural rather than a marker column: the app inserts a sale's lines exactly
-- once, and it has no update path for them (a sale that posted is corrected with
-- a sale return, not by editing - D-013's philosophy, D-019's one level up).
--
-- Consequences, stated rather than hidden:
--   * Deleting a sale line does NOT put the units back. `write_audit_log()` now
--     records the deletion, and the correction path is a sale return (restock)
--     or a stock adjustment, both of which leave their own record.
--   * A cancelled sale never moves stock and never posts a ledger row, but
--     cancelling one that already moved stock does NOT reverse it - the same
--     one-way contract D-013 established for purchases.
--
-- The checkout is an RPC, and that is the point
-- --------------------------------------------
-- A sale is a header plus its lines, and PostgREST writes one statement at a
-- time: insert the header, then insert the lines, and a refused line leaves a
-- header behind that has already posted a receivable. Worse, the per-line stock
-- trigger means a partial line write would leave some units taken and others not.
-- `checkout_sale()` does the whole write in one transaction, so a sale either
-- exists in full or does not exist at all.
--
-- Tables/columns/views/functions created or changed
-- -------------------------------------------------
--   * new table: invoice_counters (per pharmacy, per day, the sales numbering)
--   * new function: next_sale_invoice_no()
--   * new function: checkout_sale(p_payload jsonb) -> public.sales
--   * enabled: ledger_auto_entry_sale(), stock_update_on_sale(),
--     write_audit_log()
--   * new functions: stock_restore_on_sale_return(),
--     ledger_auto_entry_sale_return()
--   * new trigger attachments (7 audit triggers + 4 automation triggers)
--   * new index: ledger_entries(reference_type, reference_id) - the idempotency
--     guards look rows up by both columns, and the existing index stops at
--     reference_type

-- ---------------------------------------------------------------------------
-- 1. The invoice counter
--
--    A POS has to number its own invoices: unlike a purchase, there is no
--    supplier document to copy a number from, and `sales` carries a unique key on
--    (pharmacy_id, invoice_no), so a duplicate is a failed checkout.
--
--    A per-pharmacy, per-day counter row is the atomic way to do it: the UPDATE
--    under `on conflict do update` takes a row lock, so two tills checking out at
--    the same instant get consecutive numbers instead of racing a `count(*)`.
--    A global sequence would have been simpler and would have leaked one tenant's
--    volume to another through the gaps.
-- ---------------------------------------------------------------------------
create table if not exists public.invoice_counters (
  pharmacy_id uuid not null references public.pharmacies(id) on delete cascade,
  counter_date date not null,
  next_no int not null default 1,
  updated_at timestamptz not null default now(),
  primary key (pharmacy_id, counter_date)
);

comment on table public.invoice_counters is
  'Per-pharmacy, per-day counter behind the POS invoice number. Read and written only through next_sale_invoice_no().';

comment on column public.invoice_counters.next_no is
  'The number the NEXT call will hand out: it is incremented before it is returned, so the value returned is the invoice number, not the count so far.';

-- RLS on, and no policies: the table is reachable only through the SECURITY
-- DEFINER function below, which scopes itself to the caller's pharmacy. Supabase
-- grants table privileges to `authenticated` wholesale, so RLS with no policy is
-- what actually keeps a client from reading another tenant's numbering - or its
-- own volume in aggregate.
alter table public.invoice_counters enable row level security;

-- ---------------------------------------------------------------------------
-- 2. next_sale_invoice_no()
--
--    Takes no arguments on purpose: a function that accepted a pharmacy id could
--    be handed someone else's and burn their numbers. It reads the caller's
--    pharmacy from get_my_pharmacy_id(), which resolves auth.uid() to the
--    INVOKING user even inside a definer function (see migration 00011).
-- ---------------------------------------------------------------------------
create or replace function public.next_sale_invoice_no()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_day      date := current_date;
  v_no       int;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  insert into public.invoice_counters (pharmacy_id, counter_date, next_no)
  values (v_pharmacy, v_day, 1)
  on conflict (pharmacy_id, counter_date)
    do update set next_no = public.invoice_counters.next_no + 1
  returning next_no into v_no;

  -- SL = sale. The date makes a number meaningful to a human reading an old
  -- bill, and the sequence restarts each day.
  return 'SL' || to_char(v_day, 'YYMMDD') || '-' || lpad(v_no::text, 4, '0');
end;
$$;

comment on function public.next_sale_invoice_no() is
  'The next POS invoice number for the caller''s pharmacy, e.g. SL260918-0007. Atomic under concurrent checkouts; scoped to the caller rather than to an argument.';

-- ---------------------------------------------------------------------------
-- 3. ledger_auto_entry_sale()
--
--    Posts three things for a sale that has a customer, each at most once:
--      * the receivable (debit grand_total) - what the customer now owes;
--      * a `payments` row for the counter settlement (the cash book);
--      * the matching ledger credit for that settlement, so a customer-attached
--        CASH sale does not leave a receivable standing forever. The shipped
--        body wrote the payments row without its ledger counterpart, which would
--        have made every such customer look permanently in debt.
--
--    `balance_due` stays the document's own figure: the app writes it, and a
--    partial payment later goes through the Phase 4 payment path rather than
--    through a status flip.
-- ---------------------------------------------------------------------------
create or replace function public.ledger_auto_entry_sale()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry_date date := coalesce(new.sale_date::date, current_date);
  v_payment_id uuid;
begin
  -- A cancelled sale never happened, so it posts nothing.
  if new.status = 'cancelled' then
    return new;
  end if;

  -- No party, nothing to post (see the header note). This is the walk-in cash
  -- sale, which is the commonest sale a pharmacy makes.
  if new.customer_id is null then
    return new;
  end if;

  -- Idempotency guard: the receivable row is keyed by reference_id = sale id.
  if not exists (
    select 1 from public.ledger_entries
    where reference_type = 'sale' and reference_id = new.id
  ) then
    insert into public.ledger_entries (
      pharmacy_id, entry_date, party_type, customer_id,
      reference_type, reference_id, description, debit, credit, created_by
    ) values (
      new.pharmacy_id,
      v_entry_date,
      'customer',
      new.customer_id,
      'sale',
      new.id,
      'Sale ' || coalesce(new.invoice_no, new.id::text),
      coalesce(new.grand_total, 0),
      0,
      new.created_by
    );
  end if;

  -- The counter settlement, once per sale. Guarded on the payments row rather
  -- than on the ledger row, because that is the row this block creates.
  if coalesce(new.amount_paid, 0) > 0
     and not exists (
       select 1 from public.payments
       where pharmacy_id = new.pharmacy_id
         and party_type = 'customer'
         and customer_id = new.customer_id
         and reference_no = new.invoice_no
     )
  then
    insert into public.payments (
      pharmacy_id, party_type, customer_id, amount, mode,
      reference_no, payment_date, notes, created_by
    ) values (
      new.pharmacy_id,
      'customer',
      new.customer_id,
      new.amount_paid,
      new.payment_mode,
      new.invoice_no,
      v_entry_date,
      'Auto-captured from sale ' || coalesce(new.invoice_no, new.id::text),
      new.created_by
    )
    returning id into v_payment_id;

    insert into public.ledger_entries (
      pharmacy_id, entry_date, party_type, customer_id,
      reference_type, reference_id, description, debit, credit, created_by
    ) values (
      new.pharmacy_id,
      v_entry_date,
      'customer',
      new.customer_id,
      'payment',
      v_payment_id,
      'Paid at the counter for ' || coalesce(new.invoice_no, new.id::text),
      0,
      new.amount_paid,
      new.created_by
    );
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. stock_update_on_sale()
--
--    Decrements the line's batch and refuses to oversell, exactly as shipped -
--    plus a status gate the shipped body lacked, so a sale written as cancelled
--    cannot take stock out of the shelf.
-- ---------------------------------------------------------------------------
create or replace function public.stock_update_on_sale()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status  public.sale_status;
  v_updated integer;
begin
  if new.batch_id is null then
    return new;
  end if;

  select s.status
    into v_status
    from public.sales s
   where s.id = new.sale_id
     and s.pharmacy_id = new.pharmacy_id;

  if v_status is null or v_status = 'cancelled' then
    return new;
  end if;

  -- The trailing OR makes a sale larger than the batch match no row at all,
  -- which the row_count check turns into a hard error - and because the whole
  -- checkout is one transaction, that error takes the sale with it.
  update public.product_batches b
     set qty = b.qty - coalesce(new.qty, 0),
         updated_at = now()
   where b.id = new.batch_id
     and b.pharmacy_id = new.pharmacy_id
     and b.qty >= coalesce(new.qty, 0);

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    raise exception 'insufficient stock in batch % for sale item %',
      new.batch_id, new.id
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. stock_restore_on_sale_return()
--
--    Puts returned units back into the batch the sale came from - but only when
--    the return says the goods are resellable. `sale_returns.restock` was added
--    in 00006 with exactly this contract and nothing has ever read it.
--
--    The units come back at the batch's current cost basis, unchanged: they were
--    already part of the average that the sale left behind, so the write-off
--    treatment of D-012 (change quantity, leave the basis) is also the right one
--    for a restock.
--
--    An increment cannot be refused, so there is no error path here. A batch that
--    does not belong to the pharmacy matches no row and restores nothing - which
--    is why the write path validates the batch before it gets here.
-- ---------------------------------------------------------------------------
create or replace function public.stock_restore_on_sale_return()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_restock boolean;
begin
  if new.batch_id is null then
    return new;
  end if;

  select r.restock
    into v_restock
    from public.sale_returns r
   where r.id = new.sale_return_id
     and r.pharmacy_id = new.pharmacy_id;

  -- Damaged or unsellable goods come back to the paperwork, not to the shelf.
  if coalesce(v_restock, false) is not true then
    return new;
  end if;

  update public.product_batches b
     set qty = b.qty + coalesce(new.qty, 0),
         updated_at = now()
   where b.id = new.batch_id
     and b.pharmacy_id = new.pharmacy_id;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. ledger_auto_entry_sale_return()
--
--    The customer's credit note: a refund reduces what they owe, so it is a
--    CREDIT for a customer party - the mirror of the purchase side, where a
--    return debits the supplier.
--
--    No `payments` row is written for a refund. `payments.amount` carries a
--    `check (amount > 0)` and the table has no direction column, so a refund
--    cannot be represented there without inventing a sign convention; the money
--    that went back out is on `sale_returns.refund_mode` and the ledger credit
--    below. Phase 4's reports should read refunds from here rather than from the
--    cash book.
-- ---------------------------------------------------------------------------
create or replace function public.ledger_auto_entry_sale_return()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.status, 'completed') = 'cancelled' then
    return new;
  end if;

  -- Same party constraint as a sale: a walk-in return has nobody to credit.
  if new.customer_id is null then
    return new;
  end if;

  if exists (
    select 1 from public.ledger_entries
    where reference_type = 'sale_return' and reference_id = new.id
  ) then
    return new;
  end if;

  insert into public.ledger_entries (
    pharmacy_id, entry_date, party_type, customer_id,
    reference_type, reference_id, description, debit, credit, created_by
  ) values (
    new.pharmacy_id,
    coalesce(new.return_date::date, current_date),
    'customer',
    new.customer_id,
    'sale_return',
    new.id,
    'Sales return ' || new.id::text,
    0,
    coalesce(new.grand_total, 0),
    new.created_by
  );

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. write_audit_log()
--
--    Enabled verbatim from 00010 line 347. It is a generic AFTER
--    INSERT/UPDATE/DELETE trigger, so it is attached per table rather than
--    globally.
--
--    Attached to the seven money-and-stock documents. Deliberately NOT attached
--    to product_batches (its qty churns on every movement, so the log would grow
--    faster than the data it describes) or to ledger_entries (append-only by
--    construction - an audit of an audit trail is volume without information), nor
--    to the masters, whose history is Phase 6's problem if it is ever wanted.
-- ---------------------------------------------------------------------------
create or replace function public.write_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row         jsonb;
  v_record_id   uuid;
  v_pharmacy_id uuid;
begin
  if tg_op = 'DELETE' then
    v_row := to_jsonb(old);
  else
    v_row := to_jsonb(new);
  end if;

  v_record_id := nullif(v_row ->> 'id', '')::uuid;
  v_pharmacy_id := nullif(v_row ->> 'pharmacy_id', '')::uuid;

  insert into public.audit_logs (
    pharmacy_id, table_name, action, record_id, user_id, old_data, new_data
  ) values (
    v_pharmacy_id,
    tg_table_name,
    tg_op,
    v_record_id,
    auth.uid(),
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end
  );

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. checkout_sale()
--
--    One transaction for the whole sale: the lease on the invoice number, the
--    header, and every line. PostgREST writes one statement at a time, so without
--    this the client would have to write the header first (posting a receivable
--    through the ledger trigger) and would leave that header behind whenever a
--    later line was refused.
--
--    What it does NOT do: compute the money. The line amounts arrive from the
--    client, which computed them with `SaleTotals` - the same pure helper the
--    screen that showed them uses, exactly as `PurchaseTotals` does on the
--    purchase side. What the function does is *sum* those lines for the header,
--    rather than trusting a client-computed document total, so a stored
--    grand_total always equals the sum of its stored lines.
--
--    Tenant safety: it is SECURITY DEFINER, so it runs with the function owner's
--    rights and RLS does not apply inside it. It therefore takes the pharmacy from
--    get_my_pharmacy_id() (never from the payload) and verifies that every batch,
--    product and customer it is handed belongs to that pharmacy before it writes
--    anything.
--
--    Payload:
--      {
--        "customer_id":     uuid | null,
--        "payment_mode":    "cash" | "card" | "upi" | "credit" | "bank" | "wallet" | "other",
--        "amount_paid":     numeric,
--        "place_of_supply": text | null,
--        "items": [
--          { "product_id": uuid, "batch_id": uuid, "qty": int, "rate": numeric,
--            "discount_percent": numeric, "discount_amount": numeric,
--            "gst_percent": numeric, "cgst_amount": numeric, "sgst_amount": numeric,
--            "igst_amount": numeric, "tax_amount": numeric, "total_amount": numeric,
--            "schedule_type": "OTC" | "H" | "H1" | "X" | "narcotic" }
--        ]
--      }
-- ---------------------------------------------------------------------------
create or replace function public.checkout_sale(p_payload jsonb)
returns public.sales
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy      uuid := public.get_my_pharmacy_id();
  v_items         jsonb := coalesce(p_payload -> 'items', '[]'::jsonb);
  v_customer_id   uuid := nullif(p_payload ->> 'customer_id', '')::uuid;
  v_amount_paid   numeric(14,2) := coalesce((p_payload ->> 'amount_paid')::numeric, 0);
  v_grand_total   numeric(14,2);
  v_sub_total     numeric(14,2);
  v_tax_total     numeric(14,2);
  v_balance_due   numeric(14,2);
  v_sale          public.sales;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  if jsonb_array_length(v_items) = 0 then
    raise exception 'a sale needs at least one line'
      using errcode = 'check_violation';
  end if;

  -- Every reference has to be the caller's own. The FKs would accept another
  -- tenant's ids, and RLS does not apply inside a definer function, so this is
  -- the only thing standing between a crafted payload and a cross-tenant row.
  if exists (
    select 1
      from jsonb_array_elements(v_items) as i
     where not exists (
             select 1 from public.product_batches b
              where b.id = (i ->> 'batch_id')::uuid
                and b.pharmacy_id = v_pharmacy
           )
        or not exists (
             select 1 from public.products p
              where p.id = (i ->> 'product_id')::uuid
                and p.pharmacy_id = v_pharmacy
           )
  ) then
    raise exception 'a sale line references a product or batch outside this pharmacy'
      using errcode = 'check_violation';
  end if;

  if v_customer_id is not null and not exists (
    select 1 from public.customers c
     where c.id = v_customer_id
       and c.pharmacy_id = v_pharmacy
  ) then
    raise exception 'that customer is not in this pharmacy'
      using errcode = 'check_violation';
  end if;

  -- The header's money is the sum of its lines, rounded once - never a figure
  -- the client sent.
  select coalesce(sum((i ->> 'total_amount')::numeric), 0),
         coalesce(sum((i ->> 'tax_amount')::numeric), 0)
    into v_grand_total, v_tax_total
    from jsonb_array_elements(v_items) as i;

  v_grand_total := round(v_grand_total, 2);
  v_tax_total   := round(v_tax_total, 2);
  v_sub_total   := round(v_grand_total - v_tax_total, 2);
  v_balance_due := round(v_grand_total - v_amount_paid, 2);

  if v_balance_due > 0 and v_customer_id is null then
    raise exception 'a sale with an unpaid balance needs a customer to owe it'
      using errcode = 'check_violation';
  end if;

  insert into public.sales (
    pharmacy_id, customer_id, invoice_no, sale_date, status,
    sub_total, discount_total, tax_total, grand_total,
    payment_mode, amount_paid, balance_due, place_of_supply
  ) values (
    v_pharmacy,
    v_customer_id,
    public.next_sale_invoice_no(),
    now(),
    -- Explicitly cast: `text` has no assignment cast to an enum, so a bare CASE
    -- of two string literals would not reach a `sale_status` column.
    (case when v_balance_due > 0 then 'credit' else 'completed' end)::public.sale_status,
    v_sub_total,
    round(coalesce((
      select sum((i ->> 'discount_amount')::numeric)
        from jsonb_array_elements(v_items) as i
    ), 0), 2),
    v_tax_total,
    v_grand_total,
    coalesce((p_payload ->> 'payment_mode')::public.payment_mode, 'cash'),
    v_amount_paid,
    v_balance_due,
    nullif(p_payload ->> 'place_of_supply', '')
  )
  returning * into v_sale;

  insert into public.sale_items (
    pharmacy_id, sale_id, product_id, batch_id, qty, rate,
    discount_percent, discount_amount, gst_percent,
    cgst_amount, sgst_amount, igst_amount, tax_amount, total_amount,
    schedule_type
  )
  select
    v_pharmacy,
    v_sale.id,
    (i ->> 'product_id')::uuid,
    (i ->> 'batch_id')::uuid,
    (i ->> 'qty')::int,
    coalesce((i ->> 'rate')::numeric, 0),
    coalesce((i ->> 'discount_percent')::numeric, 0),
    coalesce((i ->> 'discount_amount')::numeric, 0),
    coalesce((i ->> 'gst_percent')::numeric, 0),
    coalesce((i ->> 'cgst_amount')::numeric, 0),
    coalesce((i ->> 'sgst_amount')::numeric, 0),
    coalesce((i ->> 'igst_amount')::numeric, 0),
    coalesce((i ->> 'tax_amount')::numeric, 0),
    coalesce((i ->> 'total_amount')::numeric, 0),
    coalesce((i ->> 'schedule_type')::public.schedule_type, 'OTC')
  from jsonb_array_elements(v_items) as i;

  -- `returning *` above captured the header BEFORE the lines existed; the
  -- receivable the ledger trigger posted used the header's own grand_total from
  -- this same insert, so re-reading is only about handing the caller a row that
  -- is final - including anything a later trigger touched. Scoped by pharmacy
  -- because a definer function bypasses the RLS that would otherwise bound it.
  select * into v_sale
    from public.sales
   where id = v_sale.id
     and pharmacy_id = v_pharmacy;

  return v_sale;
end;
$$;

comment on function public.checkout_sale(jsonb) is
  'Writes a sale and its lines in one transaction, numbering the invoice from next_sale_invoice_no() and summing the lines for the header. The whole sale fails together if any line cannot take its stock.';

-- ---------------------------------------------------------------------------
-- 9. Attach the triggers
--    All idempotent via drop trigger if exists.
-- ---------------------------------------------------------------------------
drop trigger if exists trg_ledger_auto_entry_sale on public.sales;
create trigger trg_ledger_auto_entry_sale
  after insert or update of status on public.sales
  for each row execute function public.ledger_auto_entry_sale();

drop trigger if exists trg_stock_update_on_sale on public.sale_items;
create trigger trg_stock_update_on_sale
  after insert on public.sale_items
  for each row execute function public.stock_update_on_sale();

drop trigger if exists trg_stock_restore_on_sale_return on public.sale_return_items;
create trigger trg_stock_restore_on_sale_return
  after insert on public.sale_return_items
  for each row execute function public.stock_restore_on_sale_return();

drop trigger if exists trg_ledger_auto_entry_sale_return on public.sale_returns;
create trigger trg_ledger_auto_entry_sale_return
  after insert or update of status on public.sale_returns
  for each row execute function public.ledger_auto_entry_sale_return();

-- The audit trail: one trigger per money-and-stock document.
do $$
declare
  t text;
  v_tables text[] := array[
    'sales',
    'sale_returns',
    'purchases',
    'purchase_returns',
    'payments',
    'stock_adjustments',
    'expenses'
  ];
begin
  foreach t in array v_tables loop
    execute format('drop trigger if exists %I on public.%I', 'trg_audit_' || t, t);
    execute format(
      'create trigger %I after insert or update or delete on public.%I for each row execute function public.write_audit_log()',
      'trg_audit_' || t, t
    );
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Indexes
--     The two ledger triggers guard on (reference_type, reference_id); the
--     existing index stops at reference_type, so the guards would have scanned
--     every entry of that type for the tenant.
-- ---------------------------------------------------------------------------
create index if not exists ledger_entries_reference_type_reference_id_idx
  on public.ledger_entries (reference_type, reference_id);

-- ---------------------------------------------------------------------------
-- 11. Grants
--     authenticated only: anon has no tenant identity. `checkout_sale` and
--     `next_sale_invoice_no` are the only new callables.
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.next_sale_invoice_no() to authenticated';
  execute 'grant execute on function public.checkout_sale(jsonb) to authenticated';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
