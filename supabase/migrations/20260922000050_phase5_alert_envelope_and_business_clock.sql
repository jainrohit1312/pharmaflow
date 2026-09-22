-- Migration: 20260922000050_phase5_alert_envelope_and_business_clock | Purpose: the two
-- alert reports state their own rule and their own total, and every report that means
-- "today" reads one business clock (D-090).
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace function/view + guarded grants + comments.
--
-- What this migration is
-- ----------------------
-- No table, no column, no trigger, and nothing that moves stock: every function here READS
-- and never writes (D-011/D-013/D-047).
--
--   business_today()      the pharmacy's day, as a date - the one clock
--   low_stock_products()  now {meta, rows}, and its total is the whole set
--   expiring_batches()    now {meta, rows}, with the horizon it actually queried
--   dead_stock()          the total it never had
--   top_products()        the clock, and the timezone in its meta
--   report_summary()      the clock, and the boundary it used
--   batch_status (view)   the clock, in its bucket boundaries
--
-- Why the envelope, and why it ships with the alert screens
-- ---------------------------------------------------------
-- 00027's two functions returned a bare `jsonb` array, so a caller could see how many rows
-- it got and never how many there were. The chatbot read that number as a total - the
-- brief's own finding - and a screen reading 200 rows had no way to say whether that was
-- all of them. 00029 chose the other shape for the same reason: a list whose *rule* is part
-- of the answer has to carry the rule, or a surface cannot show the caveat (D-053's
-- invisible-semantics trap). "Below its reorder level" is not a window like top_products',
-- but it is a rule, and it was a rule the copy got wrong once (D-089 §2) precisely because
-- nothing carried it.
--
-- So both answer `{meta, rows}`: the rule (or the horizon), the business day it was
-- evaluated on, and **the whole set's count alongside the page's**. That last pair is what
-- makes "50 of 120" sayable instead of "at least 50" - and it is computed by `count(*) over
-- ()` over the same candidate set the page is cut from, never read back off the page.
--
-- **This is a live RPC's contract**, so it ships together with the screens that read it:
-- `alert_payloads.dart` (the decoders read `rows`), `notifications_repository.dart`,
-- `inventory_repository.dart`, the low-stock controllers and the two alert sections - and
-- with the chatbot's own sentences, which now state the exact total.
--
-- Why the business clock
-- ----------------------
-- The server runs in UTC. Between 00:00 and 05:30 IST `current_date` - and therefore every
-- "aaj" figure, every expiry horizon and every dead-stock cutoff - belongs to *yesterday*,
-- and the brief's first acceptance scenario is exactly that boundary. So "today" becomes one
-- function, `public.business_today()`, returning `(now() at time zone 'Asia/Kolkata')::date`,
-- and the zone literal lives there and nowhere else: a per-report `'Asia/Kolkata'` would be
-- the second mechanism this project forbids.
--
-- The view is included deliberately. `batch_status.expiry_status` decides which bucket a
-- batch is in - on the expiry dashboard *and* in `report_summary`'s expiring section - and
-- leaving it on the UTC day would mean a batch that expired in the pharmacy reading as
-- "critical" for five and a half hours a day, in a report whose own `as_of` said the day had
-- turned. A second clock for the same question is the defect, not a shortcut.
--
-- The tenant is never an argument (D-004/D-026): it comes from get_my_pharmacy_id(), and
-- because these are SECURITY DEFINER functions the explicit `pharmacy_id` predicate is the
-- whole scope (the views they read are security_invoker, which follows the *current* user -
-- inside a definer function, the owner).

-- ---------------------------------------------------------------------------
-- 1. The business clock
-- One function, and one place the timezone is written. `stable` rather than `immutable` on
-- purpose: an IMMUTABLE claim would let the planner fold the call into an index expression or
-- a generated column and freeze the day it was built.
--
-- Granted to `authenticated` because `batch_status` is `security_invoker = true`: the view
-- evaluates its own expression as the caller, so the caller needs EXECUTE on this function for
-- the view to be readable at all.
-- ---------------------------------------------------------------------------

create or replace function public.business_today()
returns date
language sql
stable
security definer
set search_path = public
as $$
  select (now() at time zone 'Asia/Kolkata')::date;
$$;

comment on function public.business_today() is
  'The pharmacy''s business day, as a date: (now() at time zone ''Asia/Kolkata'')::date. One clock, in SQL, because the server runs in UTC and between 00:00 and 05:30 IST every "today" figure - the expiry horizon, the dead-stock cutoff, a summary''s default period, and batch_status'' bucket boundary - would otherwise belong to yesterday. The timezone literal lives here and nowhere else (D-090). STABLE, not IMMUTABLE: it reads the clock, and an immutable claim would let the planner freeze the day it was built.';

do $$
begin
  execute 'grant execute on function public.business_today() to authenticated';
  execute 'revoke execute on function public.business_today() from anon, public';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;

-- ---------------------------------------------------------------------------
-- 2. low_stock_products() - replaced: {meta, rows}, and its rule in its own answer
-- The predicate is byte-for-byte 00027's (`p.is_active`, `total_qty < min_stock_level`,
-- `greatest(min_stock_level - total_qty, 0)`, the same order) - what is new is the envelope
-- around it and the fact that the count and the page come from one pass over one candidate
-- set. `total_qty < min_stock_level` is stated in `meta.rule` in the database's own words, so
-- the copy and the predicate can no longer drift apart silently - which is how this rule was
-- misquoted once already.
--
-- The cap is clamped here (1..200) and reported as `meta.limit`, so a caller can see what it
-- was given. `returned_count` is the page; `total_count` is the whole set; `has_more` is the
-- two compared, computed once rather than re-derived by every reader.
-- ---------------------------------------------------------------------------

create or replace function public.low_stock_products(p_limit int default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_today    date := public.business_today();
  v_limit    int  := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  -- One statement, one pass over the candidate set, so the rows and the count cannot be
  -- built from two different predicates: `count(*) over ()` is the whole set and the row
  -- number is what the page is cut on. A `total_count` read back off the page would be
  -- the same lie in a new place.
  return (
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
      where s.pharmacy_id = v_pharmacy
        and p.is_active
        and s.total_qty < s.min_stock_level
    ),
    ranked as (
      select
        c.*,
        row_number() over (order by c.shortfall desc, c.name) as rn,
        count(*) over () as total_count
      from candidates c
    )
    select jsonb_build_object(
      'meta', jsonb_build_object(
        'rule', 'total_qty < min_stock_level',
        'as_of', v_today,
        'timezone', 'Asia/Kolkata',
        'limit', v_limit,
        'total_count', coalesce(max(r.total_count), 0),
        'returned_count', count(*) filter (where r.rn <= v_limit),
        'has_more', coalesce(max(r.total_count), 0) > count(*) filter (where r.rn <= v_limit)
      ),
      'rows', coalesce(
        jsonb_agg(
          jsonb_build_object(
            'product_id', r.product_id,
            'name', r.name,
            'generic_name', r.generic_name,
            'pack_size', r.pack_size,
            'total_qty', r.total_qty,
            'min_stock_level', r.min_stock_level,
            'shortfall', r.shortfall
          )
          order by r.rn
        ) filter (where r.rn <= v_limit),
        '[]'::jsonb
      )
    )
    from ranked r
  );
end;
$$;

comment on function public.low_stock_products(int) is
  'Products BELOW their reorder level (total_qty < min_stock_level, stated in meta.rule), most under-stocked first, with the shortfall in units. Answers {meta, rows}: the rule, the business day it was evaluated on (meta.as_of, Asia/Kolkata), the clamped cap, and total_count over the whole set beside returned_count and has_more - so a caller that read 50 rows can say whether that was all of them. One round trip for the whole catalogue (I-1: the comparison cannot be done by PostgREST, and doing it in Dart over one page silently omits rows). Reads stock, never writes it; the pharmacy comes from get_my_pharmacy_id(), never an argument.';

-- ---------------------------------------------------------------------------
-- 3. expiring_batches() - replaced: {meta, rows}, with the horizon that actually ran
-- The predicate is 00027's again (`p.is_active`, `qty > 0`, `expiry_date is not null`, the
-- same order), and the horizon is the same clamp (1..3650) - but it is now **stated** in
-- `meta.horizon_days`, which is the number the query used rather than the number a caller
-- asked for. That is the head of the same defect D-089 §4 closed on the chatbot side: a
-- caller that asked for 5000 days was told 5000 while the report queried 3650.
--
-- `as_of` is the business day the horizon was measured from, and `days_left` is measured
-- against it too, so a batch's countdown and the envelope's own day agree.
-- ---------------------------------------------------------------------------

create or replace function public.expiring_batches(
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
  v_today    date := public.business_today();
  v_days     int  := least(greatest(coalesce(p_days, 90), 1), 3650);
  v_limit    int  := least(greatest(coalesce(p_limit, 50), 1), 500);
begin
  return (
    with candidates as (
      select
        b.id as batch_id,
        b.product_id,
        p.name as product_name,
        p.pack_size,
        b.batch_no,
        b.expiry_date,
        b.qty,
        (b.expiry_date - v_today) as days_left
      from public.product_batches b
      join public.products p
        on p.id = b.product_id
       and p.pharmacy_id = b.pharmacy_id
      where b.pharmacy_id = v_pharmacy
        and p.is_active
        and b.qty > 0
        and b.expiry_date is not null
        and b.expiry_date <= v_today + v_days
    ),
    ranked as (
      select
        c.*,
        row_number() over (order by c.expiry_date, c.product_name, c.batch_no) as rn,
        count(*) over () as total_count
      from candidates c
    )
    select jsonb_build_object(
      'meta', jsonb_build_object(
        'horizon_days', v_days,
        'as_of', v_today,
        'timezone', 'Asia/Kolkata',
        'limit', v_limit,
        'total_count', coalesce(max(r.total_count), 0),
        'returned_count', count(*) filter (where r.rn <= v_limit),
        'has_more', coalesce(max(r.total_count), 0) > count(*) filter (where r.rn <= v_limit)
      ),
      'rows', coalesce(
        jsonb_agg(
          jsonb_build_object(
            'batch_id', r.batch_id,
            'product_id', r.product_id,
            'product_name', r.product_name,
            'pack_size', r.pack_size,
            'batch_no', r.batch_no,
            'expiry_date', r.expiry_date,
            'days_left', r.days_left,
            'qty', r.qty
          )
          order by r.rn
        ) filter (where r.rn <= v_limit),
        '[]'::jsonb
      )
    )
    from ranked r
  );
end;
$$;

comment on function public.expiring_batches(int, int) is
  'Batches with stock left that expire within meta.horizon_days (the clamped value that actually ran), soonest first, with days_left negative for the ones that already have. Empty batches and inactive products are excluded. Answers {meta, rows} with the horizon, the business day it was measured from (meta.as_of, Asia/Kolkata), the clamped cap and the whole set''s total_count beside returned_count and has_more. Reads stock, never writes it; the pharmacy comes from get_my_pharmacy_id(), never an argument.';

-- ---------------------------------------------------------------------------
-- 4. dead_stock() - replaced: the total it never had
-- `dead_stock` already answered `{meta, rows}` (00029) but carried no count, so its sentence
-- could only ever say "at least N" - the same defect in the one report that shipped with the
-- envelope. It gains `total_count` / `returned_count` / `has_more` and the `timezone`, and its
-- quiet cutoff and its `as_of` now come from the business clock.
--
-- Its rule is untouched: `total_qty > 0`, a most-recent sale older than the cutoff, and a
-- product that never sold counting as the strongest case of the answer.
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
  v_today    date := public.business_today();
  v_days     int  := least(greatest(coalesce(p_days, 90), 1), 3650);
  v_limit    int  := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_cutoff   date := public.business_today() - least(greatest(coalesce(p_days, 90), 1), 3650);
begin
  return (
    with candidates as (
      select
        ps.product_id,
        ps.name,
        ps.generic_name,
        p.pack_size,
        ps.total_qty,
        ps.stock_value_at_cost,
        ls.last_sold_on,
        (v_today - ls.last_sold_on) as days_since_last_sale
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
    ),
    ranked as (
      select
        c.*,
        row_number() over (order by c.stock_value_at_cost desc, c.name) as rn,
        count(*) over () as total_count
      from candidates c
    )
    select jsonb_build_object(
      'meta', jsonb_build_object(
        'as_of', v_today,
        'timezone', 'Asia/Kolkata',
        'quiet_days', v_days,
        'limit', v_limit,
        'total_count', coalesce(max(r.total_count), 0),
        'returned_count', count(*) filter (where r.rn <= v_limit),
        'has_more', coalesce(max(r.total_count), 0) > count(*) filter (where r.rn <= v_limit)
      ),
      'rows', coalesce(
        jsonb_agg(
          jsonb_build_object(
            'product_id', r.product_id,
            'name', r.name,
            'generic_name', r.generic_name,
            'pack_size', r.pack_size,
            'total_qty', r.total_qty,
            'stock_value_at_cost', r.stock_value_at_cost,
            'last_sold_on', r.last_sold_on,
            'days_since_last_sale', r.days_since_last_sale
          )
          order by r.rn
        ) filter (where r.rn <= v_limit),
        '[]'::jsonb
      )
    )
    from ranked r
  );
end;
$$;

comment on function public.dead_stock(int, int) is
  'Products with stock on hand that have not sold in p_days (default 90), most cash tied up first, with last_sold_on and days_since_last_sale (null when never sold). A product with nothing on the shelf is omitted; one whose only batch has expired is included. Answers {meta, rows} with as_of (the business day, Asia/Kolkata), quiet_days, the clamped cap, and the whole set''s total_count beside returned_count and has_more. Reads stock and sales, never moves stock; the pharmacy comes from get_my_pharmacy_id(), never an argument.';

-- ---------------------------------------------------------------------------
-- 5. top_products() - replaced: the clock, and the zone in its meta
-- One line of behaviour: its rolling window ends on the business day, so "what is moving
-- lately" is measured over the pharmacy's days rather than over UTC's. The envelope gains the
-- timezone it was measured in. Its own shape, its not-netted returns and its ranking are
-- untouched.
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
  v_to       date  := coalesce(p_to, public.business_today());
  v_from     date  := coalesce(p_from, coalesce(p_to, public.business_today()) - 29);
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
      'timezone', 'Asia/Kolkata',
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
  'What actually sells, ranked, in one round trip. A 30-day rolling window ending on the BUSINESS day (Asia/Kolkata, stated in meta.timezone) and units sold by default; p_metric chooses the ranking (units or revenue) and both figures are returned on every row. A return does not subtract and the envelope says so (returns_not_netted). Cancelled sales and unattributable lines are excluded. Reads sales, never moves stock; the pharmacy comes from get_my_pharmacy_id(), never an argument.';

-- ---------------------------------------------------------------------------
-- 6. report_summary() - replaced: the clock, and the boundary it used
-- Two clauses change: the default period is the business day rather than the server's UTC
-- day, and the envelope states the daylight boundary it worked to (`as_of`, `timezone`) so a
-- period is never shown without its edge. Everything else - every section, every figure, every
-- filter - is 00021's text, unchanged.
-- ---------------------------------------------------------------------------

create or replace function public.report_summary(
  p_from date,
  p_to date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_from     date := coalesce(p_from, public.business_today());
  v_to       date := coalesce(p_to, public.business_today());
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  return jsonb_build_object(
    'from', v_from,
    'to', v_to,
    -- Which day "today" was taken to be, and in which zone: an answer that states a period
    -- has to state its boundary, because the default period depends on it (D-090).
    'as_of', public.business_today(),
    'timezone', 'Asia/Kolkata',

    'sales', (
      select jsonb_build_object(
        'count', count(*),
        'sub_total', coalesce(sum(s.sub_total), 0),
        'tax_total', coalesce(sum(s.tax_total), 0),
        'grand_total', coalesce(sum(s.grand_total), 0),
        'collected', coalesce(sum(s.amount_paid), 0),
        'outstanding', coalesce(sum(s.balance_due), 0)
      )
      from public.sales s
      where s.pharmacy_id = v_pharmacy
        and s.status <> 'cancelled'
        and s.sale_date::date between v_from and v_to
    ),

    'purchases', (
      select jsonb_build_object(
        'count', count(*),
        'tax_total', coalesce(sum(p.tax_total), 0),
        'grand_total', coalesce(sum(p.grand_total), 0)
      )
      from public.purchases p
      where p.pharmacy_id = v_pharmacy
        and p.status = 'received'
        and p.invoice_date between v_from and v_to
    ),

    'returns', (
      select jsonb_build_object(
        'sale_count', (
          select count(*) from public.sale_returns r
           where r.pharmacy_id = v_pharmacy
             and r.return_date::date between v_from and v_to
        ),
        'sale_total', (
          select coalesce(sum(r.grand_total), 0) from public.sale_returns r
           where r.pharmacy_id = v_pharmacy
             and r.return_date::date between v_from and v_to
        ),
        'purchase_count', (
          select count(*) from public.purchase_returns r
           where r.pharmacy_id = v_pharmacy
             and r.return_date between v_from and v_to
        ),
        'purchase_total', (
          select coalesce(sum(r.grand_total), 0) from public.purchase_returns r
           where r.pharmacy_id = v_pharmacy
             and r.return_date between v_from and v_to
        )
      )
    ),

    'expenses', (
      select jsonb_build_object(
        'count', count(*),
        'total', coalesce(sum(e.amount), 0)
      )
      from public.expenses e
      where e.pharmacy_id = v_pharmacy
        and e.expense_date between v_from and v_to
    ),

    'stock', (
      select jsonb_build_object(
        'products', count(*),
        'units', coalesce(sum(ps.total_qty), 0),
        'value_at_cost', coalesce(sum(ps.stock_value_at_cost), 0),
        'value_at_mrp', coalesce(sum(ps.stock_value_at_mrp), 0)
      )
      from public.product_stock ps
      where ps.pharmacy_id = v_pharmacy
    ),

    'expiring', (
      select jsonb_build_object(
        'expired_value_at_mrp', coalesce(sum(case when b.expiry_status = 'expired'
          then b.qty * b.mrp else 0 end), 0),
        'critical_value_at_mrp', coalesce(sum(case when b.expiry_status = 'critical'
          then b.qty * b.mrp else 0 end), 0),
        'warning_value_at_mrp', coalesce(sum(case when b.expiry_status = 'warning'
          then b.qty * b.mrp else 0 end), 0)
      )
      from public.batch_status b
      where b.pharmacy_id = v_pharmacy
        and b.qty > 0
    )
  );
end;
$$;

comment on function public.report_summary(date, date) is
  'Every total the reports screen shows, for the caller''s pharmacy and a date range, in one round trip. Sales and purchases by document date, returns and expenses likewise, stock from product_stock (landed cost, D-012) and expiry value from batch_status at MRP (D-021). The default range is the BUSINESS day (meta-less envelope, so as_of and timezone are stated beside the range) - migration 20260922000050 (D-090).';

-- ---------------------------------------------------------------------------
-- 7. batch_status (view) - replaced: the buckets are the pharmacy's days
-- The one non-function change, and it is a behaviour change worth naming: a batch expiring
-- *today*, where today is the pharmacy's day, is `critical` (not `expired`); one that expired
-- yesterday is `expired` - and for the five and a half hours after 18:30 UTC those answers were
-- previously a day out. The dashboard and the summary read the same buckets, so they can no
-- longer disagree with each other about which side of a day a batch is on.
-- ---------------------------------------------------------------------------

create or replace view public.batch_status
with (security_invoker = true) as
select
  b.id,
  b.pharmacy_id,
  b.product_id,
  b.batch_no,
  b.mfg_date,
  b.expiry_date,
  b.qty,
  b.purchase_rate,
  b.mrp,
  b.selling_rate,
  b.created_at,
  b.updated_at,
  -- Every bucket boundary is the BUSINESS day, not the server's UTC day: for five and a half
  -- hours a day `current_date` here was yesterday, so a batch that had already expired in the
  -- pharmacy was reported as merely critical - and the expiry dashboard disagreed with the
  -- expiry report for the same hours. One clock, in one place (D-090).
  case
    when b.expiry_date is null                              then 'unknown'
    when b.expiry_date < public.business_today()            then 'expired'
    when b.expiry_date <= public.business_today() + 30      then 'critical'
    when b.expiry_date <= public.business_today() + 90      then 'warning'
    else 'safe'
  end as expiry_status,
  b.is_unknown_batch
from public.product_batches b;

-- ---------------------------------------------------------------------------
-- 8. Grants
-- `authenticated` only; `anon` has no tenant identity. The two 00027 functions change
-- signature? No - their identity arguments are unchanged (`int` and `int, int`), so the grant
-- from 00027 still holds and is restated here rather than assumed. `dead_stock` and
-- `top_products` likewise. The view's SELECT grant is restated beside the view.
-- ---------------------------------------------------------------------------

do $$
begin
  execute 'grant execute on function public.low_stock_products(int) to authenticated';
  execute 'revoke execute on function public.low_stock_products(int) from anon, public';

  execute 'grant execute on function public.expiring_batches(int, int) to authenticated';
  execute 'revoke execute on function public.expiring_batches(int, int) from anon, public';

  execute 'grant execute on function public.dead_stock(int, int) to authenticated';
  execute 'revoke execute on function public.dead_stock(int, int) from anon, public';

  execute 'grant execute on function public.top_products(date, date, int, text) to authenticated';
  execute 'revoke execute on function public.top_products(date, date, int, text) from anon, public';

  execute 'grant execute on function public.report_summary(date, date) to authenticated';
  execute 'revoke execute on function public.report_summary(date, date) from anon, public';

  execute 'grant select on public.batch_status to authenticated';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
