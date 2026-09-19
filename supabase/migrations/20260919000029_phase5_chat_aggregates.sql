-- Migration: 20260919000029_phase5_chat_aggregates | Purpose: the last two of the
-- four aggregates D-026 reserved for the chatbot - what sells, and what is not
-- selling - answered in one round trip each, in SQL.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace function + guarded grants.
--
-- What this migration is
-- ----------------------
-- Two functions and their grants. No table, no column, no trigger, and nothing
-- that moves stock: both READ and never write (D-011/D-013).
--
--   top_products(...)  what actually sells, ranked, over a window
--   dead_stock(...)    what has stock and has not moved - cash that is stuck
--
-- D-026 promised the chatbot four aggregates and built the first two in migration
-- 00027 (`low_stock_products`, `expiring_batches`). These are the other two, and
-- they are **not chatbot-only work** - D-026's last consequence is that "the four
-- RPCs are the aggregates the reports screens want too". One implementation, and
-- the reports screen, the inventory screen and the chatbot all call it.
--
-- Why the envelope carries a `meta` block (D-053)
-- -----------------------------------------------
-- 00027's two functions return a bare `jsonb` array. These two return
-- `{"meta": {...}, "rows": [...]}` instead, because both answer a question whose
-- *window* and *metric* are part of the answer. "Dolo is top" is meaningless
-- without "over the last 30 days, by units, and returns are not netted off" - and
-- a surface that cannot see the rule cannot show the caveat. The alternative is
-- semantics that live only in whoever wrote the query, which is exactly the
-- invisible-semantics trap D-053 names. (`low_stock_products` and
-- `expiring_batches` are not retrofitted: they return a list whose rule - below
-- the reorder level, inside the horizon - is a single comparison rather than a
-- window plus a ranking choice.)
--
-- The tenant is never an argument (D-004/D-026). It comes from
-- get_my_pharmacy_id(), and because a SECURITY DEFINER function is not subject to
-- RLS, both queries carry `pharmacy_id = v_pharmacy` explicitly. Note that the
-- view they read is `security_invoker = true`, which follows the *current* user -
-- inside a definer function that is the owner, so the explicit predicate is the
-- whole scope, not belt-and-braces (00027's reasoning).
--
-- Neither function filters on `products.is_active`, on purpose, and for opposite
-- reasons that arrive at the same place:
--   * `top_products` reports what *sold*. A product discontinued yesterday that
--     moved 500 units this month still moved them, and hiding it would silently
--     omit real sales - the same class of error I-1 is (a partial answer that
--     looks complete).
--   * `dead_stock` reports cash that is *stuck*. A discontinued product with
--     stock left is the most stuck of all, so excluding it would hide exactly what
--     the question is for.
-- (`low_stock_products` excludes inactive products for the opposite and correct
-- reason: a discontinued product must never be suggested for *reordering*.)
--
-- Verified by supabase/tests/phase5_chat_aggregates.sql (atomic, self-rolling-back:
-- the window boundaries both ways, the ranking by each metric, the not-netted
-- return, the never-sold and expired-only dead-stock cases, tenant isolation both
-- ways, the contract of both functions, and that reading them moves nothing).

-- ---------------------------------------------------------------------------
-- 1. What actually sells
--
--    The window defaults to a **30-day rolling** range ending today, and the
--    metric defaults to **units**: "top" means different things to a counter and
--    to an owner, so both `units_sold` and `revenue` are returned on every row and
--    `p_metric` decides only the *ranking*. Rolling rather than calendar-month, so
--    a pharmacy's "what is moving lately" does not read as nothing on the 1st.
--
--    Cancelled sales are excluded (the same rule `report_summary` uses), and a
--    sale line with no `product_id` cannot be attributed to a product and is
--    excluded. **A return does not subtract** - this is the sales side only, and
--    netting would make the window ambiguous the moment a return's date and the
--    sale's date fall on opposite sides of the boundary. The choice is not hidden:
--    `returns_not_netted` says so in the envelope, so a screen can render the
--    caveat.
-- ---------------------------------------------------------------------------
create or replace function public.top_products(
  p_from date default null,
  p_to date default null,
  p_limit int default 20,
  p_metric text default 'units'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid  := public.get_my_pharmacy_id();
  v_to       date  := coalesce(p_to, current_date);
  v_from     date  := coalesce(p_from, coalesce(p_to, current_date) - 29);
  -- Anything that is not 'revenue' ranks by units, so a closed-set choice that
  -- arrives as a typo degrades to the documented default rather than to a refusal
  -- the model cannot fix (D-026: the model picks from an enum; this is the belt).
  v_metric   text  := case when p_metric = 'revenue' then 'revenue' else 'units' end;
  v_limit    int   := least(greatest(coalesce(p_limit, 20), 1), 200);
begin
  return jsonb_build_object(
    'meta', jsonb_build_object(
      'window_from', v_from,
      'window_to', v_to,
      'metric_used', v_metric,
      'returns_not_netted', true,
      'limit', v_limit
    ),
    'rows', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'rank', c.rn,
            'product_id', c.product_id,
            'name', c.name,
            'generic_name', c.generic_name,
            'pack_size', c.pack_size,
            'units_sold', c.units_sold,
            'revenue', c.revenue,
            'sales_count', c.sales_count
          )
          order by c.rn
        )
        from (
          select
            row_number() over (
              order by
                case when v_metric = 'revenue' then m.revenue
                     else m.units_sold::numeric end desc,
                m.name
            ) as rn,
            m.product_id,
            m.name,
            m.generic_name,
            m.pack_size,
            m.units_sold,
            m.revenue,
            m.sales_count
          from (
            select
              si.product_id,
              p.name,
              p.generic_name,
              p.pack_size,
              sum(si.qty)                as units_sold,
              sum(si.total_amount)       as revenue,
              count(distinct si.sale_id) as sales_count
            from public.sale_items si
            join public.sales s
              on s.id = si.sale_id
             and s.pharmacy_id = si.pharmacy_id
            join public.products p
              on p.id = si.product_id
             and p.pharmacy_id = si.pharmacy_id
            where si.pharmacy_id = v_pharmacy
              and si.product_id is not null
              and s.status <> 'cancelled'
              and s.sale_date::date between v_from and v_to
            group by si.product_id, p.name, p.generic_name, p.pack_size
          ) m
        ) c
        where c.rn <= v_limit
      ),
      '[]'::jsonb
    )
  );
end;
$$;

comment on function public.top_products(date, date, int, text) is
  'What actually sells, ranked, in one round trip. A 30-day rolling window and units sold by default; p_metric chooses the ranking (units or revenue) and both figures are returned on every row. A return does not subtract and the envelope says so (returns_not_netted). Cancelled sales and unattributable lines are excluded. Reads sales, never moves stock; the pharmacy comes from get_my_pharmacy_id(), never an argument.';

-- ---------------------------------------------------------------------------
-- 2. What has stock and has not moved
--
--    The mirror of `low_stock_products`, which knows only about *levels*. This is
--    the question a pharmacy actually asks when cash is tight: what have I paid
--    for that is not coming back? So it returns `stock_value_at_cost` (the cash
--    the shelf is holding) alongside the units, and `last_sold_on` /
--    `days_since_last_sale`, which is null for a product that has never sold at
--    all - the strongest case of the answer, not a missing value.
--
--    Quiet is measured against `p_days` (default 90): a product is dead when its
--    most recent sale is **older than** `p_days` days, i.e. `last_sold_on <
--    as_of - p_days`. A sale exactly `p_days` ago counts as still moving, because
--    the window is inclusive of the boundary day. A product with no batches at all
--    has `total_qty = 0` and is not dead stock - there is nothing on the shelf to
--    be stale. A product whose only stock has expired *is* returned: it is dead
--    stock and a waste risk at once, and those are different questions
--    (`expiring_batches` asks the second).
-- ---------------------------------------------------------------------------
create or replace function public.dead_stock(
  p_days int default 90,
  p_limit int default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_days     int  := least(greatest(coalesce(p_days, 90), 1), 3650);
  v_limit    int  := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_as_of    date := current_date;
  v_cutoff   date := current_date - least(greatest(coalesce(p_days, 90), 1), 3650);
begin
  return jsonb_build_object(
    'meta', jsonb_build_object(
      'as_of', v_as_of,
      'quiet_days', v_days,
      'limit', v_limit
    ),
    'rows', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'product_id', c.product_id,
            'name', c.name,
            'generic_name', c.generic_name,
            'pack_size', c.pack_size,
            'total_qty', c.total_qty,
            'stock_value_at_cost', c.stock_value_at_cost,
            'last_sold_on', c.last_sold_on,
            'days_since_last_sale', c.days_since_last_sale
          )
          -- The most cash tied up first: an operator working down the list should
          -- free the biggest amount first.
          order by c.stock_value_at_cost desc, c.name
        )
        from (
          select
            ps.product_id,
            ps.name,
            ps.generic_name,
            p.pack_size,
            ps.total_qty,
            ps.stock_value_at_cost,
            ls.last_sold_on,
            (v_as_of - ls.last_sold_on) as days_since_last_sale
          from public.product_stock ps
          join public.products p
            on p.id = ps.product_id
           and p.pharmacy_id = ps.pharmacy_id
          left join (
            select
              si.product_id,
              max(s.sale_date::date) as last_sold_on
            from public.sale_items si
            join public.sales s
              on s.id = si.sale_id
             and s.pharmacy_id = si.pharmacy_id
            where si.pharmacy_id = v_pharmacy
              and si.product_id is not null
              and s.status <> 'cancelled'
            group by si.product_id
          ) ls on ls.product_id = ps.product_id
          where ps.pharmacy_id = v_pharmacy
            and ps.total_qty > 0
            and (ls.last_sold_on is null or ls.last_sold_on < v_cutoff)
          order by ps.stock_value_at_cost desc, ps.name
          limit v_limit
        ) c
      ),
      '[]'::jsonb
    )
  );
end;
$$;

comment on function public.dead_stock(int, int) is
  'Products with stock on hand that have not sold in p_days (default 90), most cash tied up first, with last_sold_on and days_since_last_sale (null when never sold). A product with nothing on the shelf is omitted; one whose only batch has expired is included. Reads stock and sales, never moves stock; the pharmacy comes from get_my_pharmacy_id(), never an argument.';

-- ---------------------------------------------------------------------------
-- 3. Grants
--    authenticated only; anon has no tenant identity. `revoke ... from anon,
--    public` is not redundant with the absence of a grant - Supabase grants
--    EXECUTE to anon and authenticated directly, so removing the PUBLIC grant
--    leaves their own in place (D-017's lesson, migration 00018).
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.top_products(date, date, int, text) to authenticated';
  execute 'revoke execute on function public.top_products(date, date, int, text) from anon, public';

  execute 'grant execute on function public.dead_stock(int, int) to authenticated';
  execute 'revoke execute on function public.dead_stock(int, int) from anon, public';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
