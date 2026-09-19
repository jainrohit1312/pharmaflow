-- Migration: 20260919000027_phase5_alert_sources | Purpose: the two questions an
-- alert asks - what is running out, and what is about to expire - answered in one
-- round trip each, in SQL.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace function + guarded grants.
--
-- What this migration is
-- ----------------------
-- Two functions and their grants. No table, no column, no trigger, and nothing
-- that moves stock: an alert READS stock and never writes it (D-011/D-013).
--
--   low_stock_products(...)  what has fallen to or below its reorder level
--   expiring_batches(...)     what is about to go off, and what already has
--
-- Why these live in SQL rather than in Dart
-- -----------------------------------------
-- Two reasons, and the first one is a defect this closes:
--
--   * **I-1.** The inventory screen decides `total_qty < min_stock_level` in Dart,
--     over at most 500 candidate rows, because PostgREST cannot compare two
--     columns. A catalogue past that bound silently reports a *partial* answer -
--     a stock alert that stops seeing products is worse than a slow one. The
--     comparison belongs where both columns are, which is here.
--   * **D-026** already reserved these two names for the chatbot's aggregates and
--     said explicitly that they are "the aggregates the reports screens want too,
--     so they are not chatbot-only work". This is that work arriving from the
--     other direction: one implementation, and the alert, the inventory screen and
--     the chatbot all call it.
--
-- Why the alert is not a row
-- --------------------------
-- D-046 puts these alerts in the in-app list and dispatches nothing in Phase 5.
-- They are still **derived**, not stored: a low-stock alert is a fact about stock
-- *now*, and materialising it would mean a row that is wrong by the time it is
-- read (and, with nothing writing it on a schedule, a row nobody would write at
-- all). `notifications` stays what it is - events someone was told about - and the
-- list screen reads these functions for the live part.
--
-- The tenant is never an argument (D-004/D-026). It comes from
-- get_my_pharmacy_id(), and because a SECURITY DEFINER function is not subject to
-- RLS, both queries carry `pharmacy_id = v_pharmacy` explicitly. Note that the
-- views they read are `security_invoker = true`, which follows the *current* user -
-- inside a definer function that is the owner, so the explicit predicate is not
-- belt-and-braces here, it is the whole scope.
--
-- Verified by supabase/tests/phase5_alerts.sql (atomic, self-rolling-back:
-- the boundary at the reorder level, a zero-quantity product, the expiry buckets,
-- tenant isolation both ways, the contract of both functions, and that reading
-- them moves nothing).

-- ---------------------------------------------------------------------------
-- 1. What is running out
--
--    `total_qty < min_stock_level` is the rule the app already uses (I-1), and it
--    is deliberately `<` and not `<=`: a product *at* its reorder level is where
--    the pharmacy meant to act, and one *below* it is one where they did not.
--    `shortfall` is the number of units that closes the gap, so a screen can say
--    how much to order rather than only what is low.
--
--    A product with no batches at all is `total_qty = 0` (the view coalesces), so
--    it is reported - correctly, because a product with nothing in stock and a
--    reorder level above zero is exactly the alert.
-- ---------------------------------------------------------------------------
create or replace function public.low_stock_products(p_limit int default 50)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with candidates as (
    select
      s.product_id,
      s.name,
      s.generic_name,
      p.pack_size,
      s.total_qty,
      s.min_stock_level,
      greatest(s.min_stock_level - s.total_qty, 0) as shortfall
    from public.product_stock s
    join public.products p
      on p.id = s.product_id
     and p.pharmacy_id = s.pharmacy_id
    where s.pharmacy_id = public.get_my_pharmacy_id()
      and p.is_active
      and s.total_qty < s.min_stock_level
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'product_id', c.product_id,
        'name', c.name,
        'generic_name', c.generic_name,
        'pack_size', c.pack_size,
        'total_qty', c.total_qty,
        'min_stock_level', c.min_stock_level,
        'shortfall', c.shortfall
      )
      -- The most under-stocked first, then by name so the order is stable: an
      -- operator working down the list should see the worst one first.
      order by c.shortfall desc, c.name
    ),
    '[]'::jsonb
  )
  from (
    select * from candidates
    order by shortfall desc, name
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  ) c;
$$;

comment on function public.low_stock_products(int) is
  'Products at or below their reorder level, most under-stocked first, with the shortfall in units. One round trip for the whole catalogue (I-1: the comparison cannot be done by PostgREST, and doing it in Dart over one page silently omits rows). Reads stock, never writes it; the pharmacy comes from get_my_pharmacy_id(), never an argument.';

-- ---------------------------------------------------------------------------
-- 2. What is about to expire
--
--    `days_left` is negative for a batch that has already expired, which is the
--    number a screen wants to show ("expired 6 days ago") rather than a bucket
--    name. Batches with nothing left in them are excluded: an empty batch cannot
--    be sold and so cannot be wasted, and listing it would bury the ones that can.
-- ---------------------------------------------------------------------------
create or replace function public.expiring_batches(
  p_days int default 90,
  p_limit int default 50
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with horizon as (
    select least(greatest(coalesce(p_days, 90), 1), 3650) as days
  ),
  candidates as (
    select
      b.id as batch_id,
      b.product_id,
      p.name as product_name,
      p.pack_size,
      b.batch_no,
      b.expiry_date,
      b.qty,
      (b.expiry_date - current_date) as days_left
    from public.product_batches b
    join public.products p
      on p.id = b.product_id
     and p.pharmacy_id = b.pharmacy_id
    join horizon h on true
    where b.pharmacy_id = public.get_my_pharmacy_id()
      and p.is_active
      and b.qty > 0
      and b.expiry_date is not null
      and b.expiry_date <= current_date + h.days
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'batch_id', c.batch_id,
        'product_id', c.product_id,
        'product_name', c.product_name,
        'pack_size', c.pack_size,
        'batch_no', c.batch_no,
        'expiry_date', c.expiry_date,
        'days_left', c.days_left,
        'qty', c.qty
      )
      -- Soonest to expire first, and an already-expired batch is therefore first
      -- of all, which is right: it is the one that is already a loss.
      order by c.expiry_date, c.product_name, c.batch_no
    ),
    '[]'::jsonb
  )
  from (
    select * from candidates
    order by expiry_date, product_name, batch_no
    limit least(greatest(coalesce(p_limit, 50), 1), 500)
  ) c;
$$;

comment on function public.expiring_batches(int, int) is
  'Batches with stock left that expire within p_days, soonest first, with days_left negative for the ones that already have. Empty batches are excluded (nothing left to waste). Reads stock, never writes it; the pharmacy comes from get_my_pharmacy_id(), never an argument.';

-- ---------------------------------------------------------------------------
-- 3. Grants
--    authenticated only; anon has no tenant identity. `revoke ... from anon,
--    public` is not redundant with the absence of a grant - Supabase grants
--    EXECUTE to anon and authenticated directly, so removing the PUBLIC grant
--    leaves their own in place (D-017's lesson, migration 00018).
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.low_stock_products(int) to authenticated';
  execute 'revoke execute on function public.low_stock_products(int) from anon, public';

  execute 'grant execute on function public.expiring_batches(int, int) to authenticated';
  execute 'revoke execute on function public.expiring_batches(int, int) from anon, public';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
