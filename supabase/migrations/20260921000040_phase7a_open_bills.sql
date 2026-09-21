-- Migration: 20260921000040_phase7a_open_bills | Purpose: one party's open bills, and what is
-- still owed on each - the list `allocate_payment()` needs its caller to present, and which no
-- reader returned.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create-or-replace function, guarded grants.
--
-- Why this exists (C3/4b)
-- ----------------------
-- Applying a deposit means `allocate_payment(p_payment_id, p_allocations)`: it writes allocation
-- rows against the **bills a party owes**, and refuses a slice larger than what is still owed on its
-- target, computed **under a row lock**. So a screen has to present the bills before it can apply
-- anything - and until this migration there was no way to read them. `patient_account()` and
-- `admission_account()` (00036) return five aggregate figures and a balance, not rows.
--
-- The alternative was reading `sales`, `sale_returns` and `payment_allocations` in Dart and
-- subtracting. That is the same arithmetic the server re-checks under its lock, and it is exactly what
-- this phase has refused to do anywhere else: a balance is the server's figure (D-025, D-075). Two
-- implementations of one subtraction is how a client comes to show a number the server will refuse,
-- so the subtraction lives here instead.
--
-- The arithmetic is deliberately the SAME EXPRESSIONS as `allocate_payment()`'s own per-target check
-- (00037), restricted to one bill, and the same three sums `patient_account()` aggregates over the
-- whole patient:
--
--     outstanding = grand_total − returned_total − allocated_total
--
-- where `returned_total` is the bill's **non-cancelled** returns and `allocated_total` is every
-- allocation row aimed at that bill. Reusing those expressions rather than re-deriving them is the
-- point: this reader and the lock that guards the write cannot drift, so the limit a refusal names is
-- the limit this list showed.
--
-- The party filter, and one honest gap
-- -----------------------------------
-- `p_party_type` is kept because `collect_payment()` / `allocate_payment()` take one, and a caller
-- assembling a collection has that value in hand. **Only `customer` has bills here.** A supplier's
-- open documents are *purchases*, not sales, and this reader deliberately does not pretend otherwise:
-- a `supplier` party answers an empty list with a zero total rather than a wrong one, which is also
-- what `allocate_payment()` can actually do with a supplier's receipt today (its only targets are
-- sales and admissions, and a supplier owns neither - so the money stays a deposit). Reading a
-- supplier's open purchases is a separate reader for whoever needs it.
--
-- Ordering: **oldest bill first**, which is the order a counter collects in.

-- ---------------------------------------------------------------------------
-- 1. open_bills() - one party's unpaid bills
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
        order by ob.sale_date, ob.id
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
  'One customer''s open bills, oldest first, each with the outstanding the server computes (grand_total less non-cancelled returns less allocations) and their total. The same expressions allocate_payment() checks under its lock, so a bill''s figure here is the limit a refusal would name. Tenant-scoped and security invoker, so RLS applies as well as the pharmacy guard. A supplier answers an empty list: a supplier''s open documents are purchases, which this reader does not return.';

-- ---------------------------------------------------------------------------
-- 2. Grants
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.open_bills(public.party_type, uuid) to authenticated';
  execute 'revoke execute on function public.open_bills(public.party_type, uuid) from anon, public';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
