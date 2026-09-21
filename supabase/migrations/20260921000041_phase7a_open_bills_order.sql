-- Migration: 20260921000041_phase7a_open_bills_order | Purpose: give `open_bills()` a
-- deterministic oldest-first order, which 00040 did not.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create-or-replace function.
--
-- Why 00040 was not enough, stated plainly
-- ----------------------------------------
-- 00040 ordered the bills `by sale_date, id`. That is not an order at all when two bills share a
-- timestamp, and **they routinely do**: `sales.sale_date` defaults to `now()`, which in PostgreSQL
-- is the **transaction start time**, so every sale written in one transaction - and a whole batch
-- of counter sales is not the only way that happens - carries an identical `sale_date`. The
-- remaining tiebreak was `id`, a `gen_random_uuid()`: arbitrary, and not even stable across two
-- reads of the same rows in principle.
--
-- It was found by running the suite against **hosted** rather than locally. Locally the two fixture
-- bills happened to come back in the expected order and the test passed; hosted returned them the
-- other way round, and the two assertions that depended on which bill was which failed. A test that
-- passes because a random order happened to be the expected one is worse than no test, so the
-- function is fixed rather than the test loosened.
--
-- The fix: tie-break on `invoice_no`, which is the document's own sequence
-- (`next_sale_invoice_no()` bumps a per-pharmacy counter, so a later bill has a higher number and
-- the strings compare in that order because the width is fixed). Two bills raised in the same
-- instant then come out in the order they were **numbered** - which is what "oldest first" means,
-- and what a counter collecting a queue is reading.
--
-- `id` stays as the final term so the order is total: two rows that somehow shared a timestamp *and*
-- an invoice number still come back in a fixed order rather than an arbitrary one.

-- ---------------------------------------------------------------------------
-- 1. open_bills() - replaced, with a real order
-- ---------------------------------------------------------------------------
create or replace function public.open_bills(
  p_party_type public.party_type,
  p_party_id uuid
) returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_bills    jsonb;
  v_total    numeric(14,2);
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  -- A supplier owes nothing on a sale, and this reader is about sales. Answered rather than
  -- refused, so a caller holding a supplier receipt gets a list it can read (none) instead of an
  -- error it cannot act on.
  if p_party_type is distinct from 'customer' then
    return jsonb_build_object('bills', '[]'::jsonb, 'total_outstanding', 0);
  end if;

  with bill as (
    select
      s.id,
      s.invoice_no,
      s.sale_date,
      s.sale_type::text as sale_type,
      s.grand_total,
      -- The same expression `patient_account()` aggregates and `allocate_payment()` re-computes
      -- under its lock, for one bill.
      coalesce((
        select sum(r.grand_total)
          from public.sale_returns r
         where r.sale_id = s.id
           and r.pharmacy_id = v_pharmacy
           and r.status <> 'cancelled'
      ), 0)::numeric(14,2) as returned_total,
      coalesce((
        select sum(pa.amount)
          from public.payment_allocations pa
         where pa.sale_id = s.id
           and pa.pharmacy_id = v_pharmacy
      ), 0)::numeric(14,2) as allocated_total
    from public.sales s
   where s.pharmacy_id = v_pharmacy
     and s.customer_id = p_party_id
     and s.status <> 'cancelled'
  ),
  open_bill as (
    select
      b.*,
      round(b.grand_total - b.returned_total - b.allocated_total, 2) as outstanding
    from bill b
  )
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'sale_id', ob.id,
          'invoice_no', ob.invoice_no,
          'sale_date', ob.sale_date,
          'sale_type', ob.sale_type,
          'grand_total', ob.grand_total,
          'returned_total', ob.returned_total,
          'allocated_total', ob.allocated_total,
          'outstanding', ob.outstanding
        )
        -- Oldest first, and **total**: the date alone is not enough, because one transaction
        -- stamps every sale it writes with the same `now()`.
        order by ob.sale_date, ob.invoice_no, ob.id
      ),
      '[]'::jsonb
    ),
    coalesce(sum(ob.outstanding), 0)::numeric(14,2)
  into v_bills, v_total
  from open_bill ob
  -- Only what is still owed: a settled bill is not something to apply money to, and a fully
  -- returned one is not a debt at all. An **over**-settled bill cannot occur (the lock prevents
  -- it), and if one ever did it would be excluded here rather than offered as a negative.
  where ob.outstanding > 0;

  return jsonb_build_object('bills', v_bills, 'total_outstanding', v_total);
end;
$$;

comment on function public.open_bills(public.party_type, uuid) is
  'One customer''s open bills, oldest first and deterministically ordered (sale_date, then invoice number, then id - the date alone ties when a transaction writes several sales), each with the outstanding the server computes (grand_total less non-cancelled returns less allocations) and their total. The same expressions allocate_payment() checks under its lock, so a bill''s figure here is the limit a refusal would name. Tenant-scoped and security invoker, so RLS applies as well as the pharmacy guard. A supplier answers an empty list: a supplier''s open documents are purchases, which this reader does not return.';
