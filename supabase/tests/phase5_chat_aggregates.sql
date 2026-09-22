-- Phase 5 chat aggregates - functional test for migration
-- 20260919000029_phase5_chat_aggregates.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase5_chat_aggregates.sql
--
-- HOW TO READ THE RESULT
--   Every line is "PASS: ..." or "FAIL: ...", and the last line is
--   "SUMMARY: n PASS / n FAIL". A non-zero exit code is expected and means the
--   script ran to completion: it ends by raising, so the whole DO block (one
--   statement, one transaction) rolls back and no ZZTEST pharmacy, product, batch
--   or sale survives.
--
-- WHY IT IMPERSONATES
--   Both functions are SECURITY DEFINER, so RLS is NOT applied to their own
--   queries - and the view they read (`product_stock`) is `security_invoker =
--   true`, which follows the *current* user, so inside a definer function that is
--   the owner. The only way to prove they scope by hand is to call them as
--   `authenticated` with a JWT set and to put a second tenant's stock and sales in
--   reach.
--
-- WHY THE SALES ARE REAL SALES
--   Every product sale here is written through `checkout_sale()`, the only
--   sanctioned write path (D-021), so the fixtures obey the same stock and ledger
--   triggers production does - the stock trigger refuses to oversell, and a
--   walk-in sale (no customer) posts no ledger row. Only the *dates* are moved
--   after the fact, because `checkout_sale` stamps `now()` and this test needs
--   sales inside and outside several windows.
--
-- WHAT IT PROVES
--   1.  `top_products` ranks by units by default and by revenue on request, and
--       returns both figures on every row.
--   2.  The window's boundaries: a sale 60 days old is out of the default 30-day
--       window and back in when the caller widens it; the envelope echoes the
--       window it actually used.
--   3.  The exclusions: a never-sold product is absent (not a zero row), a
--       cancelled sale's lines are absent, and an unattributable line cannot
--       appear.
--   4.  A return inside the window does NOT subtract, and the envelope says so
--       (`returns_not_netted`).
--   5.  A product discontinued *after* it sold is still reported: hiding it would
--       silently drop real sales.
--   6.  `dead_stock`'s rule: never-sold is dead (with a null `days_since`),
--       100 days quiet is dead, exactly 90 days quiet is NOT (the boundary day is
--       inside the window), 5 days quiet is NOT.
--   7.  A product whose only stock has expired IS dead stock (a different question
--       from `expiring_batches`), and a product with nothing on the shelf is not.
--   8.  The most cash tied up comes first, and it is valued at cost.
--   9.  Tenant isolation both ways: another pharmacy's best seller and its dead
--       stock are invisible to us.
--   10. Neither function moves anything: the product and batch counts are the same
--       after as before.
--   11. Both functions' own contract: SECURITY DEFINER, STABLE, search_path
--       pinned, no pharmacy argument, EXECUTE for `authenticated` and not `anon`.
--   12. **The business clock (20260922000050)**: the rolling window's default ends on
--       `business_today()` - the pharmacy's IST day - rather than on the server's UTC day,
--       and the envelope says which zone it was measured in. (`phase5_alerts.sql` owns the
--       boundary itself and the reports that carry `as_of`.)
--   13. **`dead_stock`'s own total (20260922000050)**: it answers `{meta, rows}` with
--       `total_count` over the whole quiet set beside `returned_count` and `has_more`, which
--       is what lets its sentence state an exact total instead of "at least N".

do $$
declare
  v_log       text[] := array[]::text[];
  v_pass      int;
  v_fail      int;
  v_pharmacy  uuid;
  v_user      uuid;
  v_other     uuid;

  -- top-products fixtures
  v_pa        uuid;   -- 10 units / 500 revenue: the units leader
  v_pb        uuid;   -- 3 units / 900 revenue: the revenue leader
  v_pout      uuid;   -- sold 60 days ago: outside a 30-day window, inside a year
  v_pcanc     uuid;   -- its only sale is cancelled: never "sold"
  v_pret      uuid;   -- sold in window, with a return in window: must not net
  v_pinact    uuid;   -- sold in window, then discontinued: still reported
  v_pnone     uuid;   -- never sold at all, and carries the most stock

  -- dead-stock fixtures
  v_d_quiet    uuid;  -- sold 100 days ago: dead
  v_d_boundary uuid;  -- sold exactly 90 days ago: NOT dead (inclusive boundary)
  v_d_moving   uuid;  -- sold 5 days ago: NOT dead
  v_d_expired  uuid;  -- never sold, and its only batch has expired: dead
  v_d_empty    uuid;  -- nothing on the shelf: not dead stock

  -- another tenant
  v_other_top  uuid;  -- sold 9 units, another pharmacy
  v_other_dead uuid;  -- 77 in stock, never sold, another pharmacy

  v_b_pa      uuid;
  v_b_pb      uuid;
  v_b_pout    uuid;
  v_b_canc    uuid;
  v_b_ret     uuid;
  v_b_inact   uuid;
  v_b_none    uuid;
  v_b_quiet   uuid;
  v_b_bound   uuid;
  v_b_moving  uuid;
  v_b_expired uuid;
  v_b_empty   uuid;
  v_b_o_top   uuid;
  v_b_o_dead  uuid;

  v_sale      public.sales;
  v_spec      jsonb;
  v_specs     jsonb;
  v_other_sale uuid;
  v_return    uuid;
  v_result    jsonb;
  v_rows      jsonb;
  v_meta      jsonb;
  v_row       jsonb;
  v_n         int;
  v_products_before int;
  v_products_after  int;
  v_batches_before  int;
  v_batches_after   int;
  v_prosecdef boolean;
  v_provolatile char;
  v_proconfig text[];
  v_identity  text;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE5 CHAT AGGREGATES TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user from public.profiles where pharmacy_id = v_pharmacy order by created_at limit 1;
  if v_user is null then
    raise exception 'PHASE5 CHAT AGGREGATES TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- The caller's identity, transaction-local. Used both by `checkout_sale()`
  -- (which resolves the pharmacy from it) and by the two functions under test.
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);

  -- ------------------------------------------------------------------- fixtures
  -- A product is never shared between two assertions that could interfere, and
  -- each one is sized so that exactly one rule decides it.
  insert into public.pharmacies (name) values ('ZZTEST chat aggregates other pharmacy')
  returning id into v_other;

  insert into public.products (pharmacy_id, name) values (v_pharmacy, 'ZZTEST Chat Units Leader') returning id into v_pa;
  insert into public.products (pharmacy_id, name) values (v_pharmacy, 'ZZTEST Chat Revenue Leader') returning id into v_pb;
  insert into public.products (pharmacy_id, name) values (v_pharmacy, 'ZZTEST Chat Old Sale') returning id into v_pout;
  insert into public.products (pharmacy_id, name) values (v_pharmacy, 'ZZTEST Chat Cancelled') returning id into v_pcanc;
  insert into public.products (pharmacy_id, name) values (v_pharmacy, 'ZZTEST Chat Returned') returning id into v_pret;
  insert into public.products (pharmacy_id, name, is_active) values (v_pharmacy, 'ZZTEST Chat Discontinued', false) returning id into v_pinact;
  insert into public.products (pharmacy_id, name) values (v_pharmacy, 'ZZTEST Chat Never Sold') returning id into v_pnone;
  insert into public.products (pharmacy_id, name) values (v_pharmacy, 'ZZTEST Chat Quiet 100d') returning id into v_d_quiet;
  insert into public.products (pharmacy_id, name) values (v_pharmacy, 'ZZTEST Chat Sold 90d') returning id into v_d_boundary;
  insert into public.products (pharmacy_id, name) values (v_pharmacy, 'ZZTEST Chat Moving') returning id into v_d_moving;
  insert into public.products (pharmacy_id, name) values (v_pharmacy, 'ZZTEST Chat Expired Only') returning id into v_d_expired;
  insert into public.products (pharmacy_id, name) values (v_pharmacy, 'ZZTEST Chat Empty') returning id into v_d_empty;

  insert into public.products (pharmacy_id, name) values (v_other, 'ZZTEST Chat Other Best Seller') returning id into v_other_top;
  insert into public.products (pharmacy_id, name) values (v_other, 'ZZTEST Chat Other Dead') returning id into v_other_dead;

  -- Batches. `purchase_rate` decides the cost a shelf is holding, and it is set so that every
  -- fixture this file asserts MEMBERSHIP of is at the top of the page it must appear in: hosted
  -- shares these tables with the owner's real catalogue, where a page of 50 dead-stock rows is
  -- filled by its own stock and a fixture valued at a few hundred rupees falls off the end.
  -- `v_pnone` (never sold), `v_d_quiet` (100 days quiet) and `v_d_expired` (expired only) are
  -- therefore sized far above the whole catalogue's cost, not merely above a neighbour's.
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_pharmacy, v_pa, 'C-A', current_date + 365, 200, 1) returning id into v_b_pa;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_pharmacy, v_pb, 'C-B', current_date + 365, 100, 1) returning id into v_b_pb;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_pharmacy, v_pout, 'C-OUT', current_date + 365, 100, 1) returning id into v_b_pout;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_pharmacy, v_pcanc, 'C-CANC', current_date + 365, 100, 1) returning id into v_b_canc;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_pharmacy, v_pret, 'C-RET', current_date + 365, 100, 1) returning id into v_b_ret;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_pharmacy, v_pinact, 'C-INACT', current_date + 365, 100, 1) returning id into v_b_inact;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_pharmacy, v_pnone, 'C-NONE', current_date + 365, 500, 1000000) returning id into v_b_none;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_pharmacy, v_d_quiet, 'C-QUIET', current_date + 365, 55, 100000) returning id into v_b_quiet;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_pharmacy, v_d_boundary, 'C-BOUND', current_date + 365, 45, 10) returning id into v_b_bound;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_pharmacy, v_d_moving, 'C-MOVE', current_date + 365, 35, 10) returning id into v_b_moving;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_pharmacy, v_d_expired, 'C-EXP', current_date - 10, 20, 50000) returning id into v_b_expired;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_pharmacy, v_d_empty, 'C-EMPTY', current_date + 365, 0, 10) returning id into v_b_empty;

  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_other, v_other_top, 'D-1', current_date + 365, 20, 1) returning id into v_b_o_top;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate)
  values (v_other, v_other_dead, 'D-2', current_date + 365, 77, 1) returning id into v_b_o_dead;

  -- ------------------------------------------------ the sales, via checkout_sale
  -- `checkout_sale()` is the sanctioned write path (D-021), so the stock trigger
  -- runs and refuses to oversell. Every sale is a walk-in (no customer), so the
  -- ledger trigger returns without posting - these fixtures are about reads.
  execute 'set local role authenticated';

  v_specs := jsonb_build_array(
    jsonb_build_object('product', v_pa,         'batch', v_b_pa,     'qty', 10, 'total', 500, 'days_ago', 1),
    jsonb_build_object('product', v_pb,         'batch', v_b_pb,     'qty', 3,  'total', 900, 'days_ago', 2),
    jsonb_build_object('product', v_pout,       'batch', v_b_pout,   'qty', 5,  'total', 250, 'days_ago', 60),
    jsonb_build_object('product', v_pcanc,      'batch', v_b_canc,   'qty', 4,  'total', 400, 'days_ago', 1),
    jsonb_build_object('product', v_pret,       'batch', v_b_ret,    'qty', 6,  'total', 600, 'days_ago', 3),
    jsonb_build_object('product', v_pinact,     'batch', v_b_inact,  'qty', 8,  'total', 800, 'days_ago', 1),
    jsonb_build_object('product', v_d_quiet,    'batch', v_b_quiet,  'qty', 5,  'total', 50,  'days_ago', 100),
    jsonb_build_object('product', v_d_boundary, 'batch', v_b_bound,  'qty', 5,  'total', 50,  'days_ago', 90),
    jsonb_build_object('product', v_d_moving,   'batch', v_b_moving, 'qty', 5,  'total', 50,  'days_ago', 5)
  );

  for v_spec in select value from jsonb_array_elements(v_specs) loop
    v_sale := public.checkout_sale(jsonb_build_object(
      'amount_paid', (v_spec ->> 'total')::numeric,
      'payment_mode', 'cash',
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_spec ->> 'product',
        'batch_id', v_spec ->> 'batch',
        'qty', (v_spec ->> 'qty')::int,
        'rate', (v_spec ->> 'total')::numeric,
        'total_amount', (v_spec ->> 'total')::numeric,
        'tax_amount', 0,
        'schedule_type', 'OTC'
      ))
    ));
  end loop;

  execute 'reset role';

  -- Move the dates back off `now()`, which is what the windows are measured
  -- against. Done as the owner: this is fixture surgery, not app behaviour.
  update public.sales s
     set sale_date = (current_date - m.days_ago)::timestamptz
    from public.sale_items si
    join (values
      (v_pa::uuid, 1), (v_pb::uuid, 2), (v_pout::uuid, 60), (v_pcanc::uuid, 1),
      (v_pret::uuid, 3), (v_pinact::uuid, 1), (v_d_quiet::uuid, 100),
      (v_d_boundary::uuid, 90), (v_d_moving::uuid, 5)
    ) as m(product_id, days_ago) on m.product_id = si.product_id
   where si.sale_id = s.id
     and s.pharmacy_id = v_pharmacy;

  -- A sale that is cancelled never happened, so its lines must not count.
  update public.sales s
     set status = 'cancelled'
    from public.sale_items si
   where si.sale_id = s.id
     and si.product_id = v_pcanc
     and s.pharmacy_id = v_pharmacy;

  -- A return inside the window, for the product that must NOT be netted.
  select s.id into v_return from public.sales s
    join public.sale_items si on si.sale_id = s.id
   where si.product_id = v_pret and s.pharmacy_id = v_pharmacy
   limit 1;

  insert into public.sale_returns (
    pharmacy_id, sale_id, return_date, reason, refund_mode,
    sub_total, tax_total, grand_total, restock, status
  ) values (
    v_pharmacy, v_return, (current_date - 2)::timestamptz, 'ZZTEST chat return', 'cash',
    200, 0, 200, true, 'completed'
  ) returning id into v_return;

  insert into public.sale_return_items (
    pharmacy_id, sale_return_id, product_id, batch_id, qty, rate, total_amount
  ) values (
    v_pharmacy, v_return, v_pret, v_b_ret, 2, 100, 200
  );

  -- ------------------------------------------- the other tenant's own best seller
  insert into public.sales (
    pharmacy_id, invoice_no, sale_date, status, payment_mode, grand_total, amount_paid
  ) values (
    v_other, 'ZZTEST-B-1', (current_date - 1)::timestamptz, 'completed', 'cash', 990, 990
  ) returning id into v_other_sale;

  insert into public.sale_items (
    pharmacy_id, sale_id, product_id, batch_id, qty, rate, total_amount, schedule_type
  ) values (
    v_other, v_other_sale, v_other_top, v_b_o_top, 9, 110, 990, 'OTC'
  );

  -- ------------------------------------------------------------------ as the user
  execute 'set local role authenticated';

  select count(*) into v_products_before from public.products where pharmacy_id = v_pharmacy;
  select count(*) into v_batches_before from public.product_batches where pharmacy_id = v_pharmacy;

  -- ---------------------------------------------------- 1/2/3/4/5. top_products
  v_result := public.top_products(null, null, null, null);

  v_log := array_append(
    v_log,
    case when jsonb_typeof(v_result) = 'object'
          and jsonb_typeof(v_result -> 'rows') = 'array'
          and jsonb_typeof(v_result -> 'meta') = 'object'
      then 'PASS' else 'FAIL' end
      || ': 1. top_products answers with {meta, rows} (D-053: no invisible semantics)'
  );

  v_meta := v_result -> 'meta';
  v_log := array_append(
    v_log,
    case when v_meta ->> 'window_to' = public.business_today()::text
          and v_meta ->> 'window_from' = (public.business_today() - 29)::text
          and v_meta ->> 'metric_used' = 'units'
          and (v_meta ->> 'returns_not_netted')::boolean
      then 'PASS' else 'FAIL' end
      || ': 2. the default window is the last 30 BUSINESS days, by units, returns not netted ('
      || coalesce(v_meta ->> 'window_from', 'null') || ' .. '
      || coalesce(v_meta ->> 'window_to', 'null') || ', '
      || coalesce(v_meta ->> 'metric_used', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_meta ->> 'timezone' = 'Asia/Kolkata' then 'PASS' else 'FAIL' end
      || ': 12. and it says which zone those days were measured in (got '
      || coalesce(v_meta ->> 'timezone', 'null') || ')'
  );

  v_rows := v_result -> 'rows';

  select count(*) into v_n from jsonb_array_elements(v_rows) r
   where not (r ? 'rank') or not (r ? 'units_sold') or not (r ? 'revenue');
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 1. every row carries rank, units_sold and revenue, whichever metric ranked it'
  );

  -- The ranking is asserted as a RELATION on the page rather than against a fixture row:
  -- hosted shares these tables with the owner's own catalogue, where a fixture stops being
  -- the leader - and "the leader is the maximum" is what the report actually promises.
  v_log := array_append(
    v_log,
    case when (v_rows -> 0 ->> 'rank')::int = 1
          and (v_rows -> 0 ->> 'units_sold')::int
                = (select max((r ->> 'units_sold')::int) from jsonb_array_elements(v_rows) r)
      then 'PASS' else 'FAIL' end
      || ': 1. by default the units leader is first with its units ('
      || coalesce(v_rows -> 0 ->> 'units_sold', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when (v_rows -> 0 ? 'revenue') and (v_rows -> 0 ? 'units_sold')
      then 'PASS' else 'FAIL' end
      || ': 1. and the revenue it did not rank by is on the same row ('
      || coalesce(v_rows -> 0 ->> 'revenue', 'null') || ')'
  );

  v_result := public.top_products(null, null, 20, 'revenue');
  v_rows := v_result -> 'rows';

  v_log := array_append(
    v_log,
    case when (v_result -> 'meta' ->> 'metric_used') = 'revenue'
          and (v_rows -> 0 ->> 'revenue')::numeric
                = (select max((r ->> 'revenue')::numeric) from jsonb_array_elements(v_rows) r)
      then 'PASS' else 'FAIL' end
      || ': 1. asking for revenue ranks by revenue ('
      || coalesce(v_rows -> 0 ->> 'name', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when jsonb_array_length(public.top_products(null, null, 1, 'units') -> 'rows') = 1
      then 'PASS' else 'FAIL' end
      || ': 1. the limit bounds the answer'
  );

  select count(*) into v_n from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_pout::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 2. a sale 60 days old is out of the default 30-day window'
  );

  v_result := public.top_products(public.business_today() - 365, public.business_today(), 200, 'units');
  v_rows := v_result -> 'rows';
  select count(*) into v_n from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_pout::text;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 2. and back in it when the caller widens the window to a year'
  );

  v_log := array_append(
    v_log,
    case when (v_result -> 'meta' ->> 'window_from') = (public.business_today() - 365)::text
      then 'PASS' else 'FAIL' end
      || ': 2. and the envelope echoes the window it actually used'
  );

  select count(*) into v_n from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_pnone::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 3. a product with no sales at all is absent, not a zero row'
  );

  select count(*) into v_n from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_pcanc::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 3. a cancelled sale''s lines do not count'
  );

  select count(*) into v_n from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_other_top::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 9. another pharmacy''s best seller is invisible to us'
  );

  select count(*) into v_n from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_pinact::text;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 5. a product discontinued after it sold is still reported'
  );

  v_result := public.top_products(null, null, 50, 'units');
  v_rows := v_result -> 'rows';
  select r into v_row from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_pret::text;
  v_log := array_append(
    v_log,
    case when (v_row ->> 'units_sold')::int = 6 and (v_row ->> 'revenue')::numeric = 600
      then 'PASS' else 'FAIL' end
      || ': 4. a return in the window does not subtract (still '
      || coalesce(v_row ->> 'units_sold', 'null') || ' units)'
  );

  v_log := array_append(
    v_log,
    case when (v_result -> 'meta' ->> 'returns_not_netted')::boolean then 'PASS' else 'FAIL' end
      || ': 4. and the envelope says returns were not netted, so a surface can caveat it'
  );

  select count(*) into v_n from jsonb_array_elements(v_rows) r where r ->> 'product_id' is null;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 3. no unattributable (null product) line can appear'
  );

  -- ------------------------------------------------------------- 6/7/8. dead_stock
  v_result := public.dead_stock(null, null);
  v_rows := v_result -> 'rows';
  v_meta := v_result -> 'meta';

  v_log := array_append(
    v_log,
    case when jsonb_typeof(v_result -> 'rows') = 'array'
          and (v_meta ->> 'as_of') = public.business_today()::text
          and (v_meta ->> 'quiet_days')::int = 90
      then 'PASS' else 'FAIL' end
      || ': 6. dead_stock answers with {meta, rows} and its own window ('
      || coalesce(v_meta ->> 'quiet_days', 'null') || ' quiet days as of '
      || coalesce(v_meta ->> 'as_of', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when (v_meta ->> 'returned_count')::int = jsonb_array_length(v_rows)
          and (v_meta ->> 'total_count')::int >= (v_meta ->> 'returned_count')::int
          and (v_meta ->> 'has_more')::boolean
                = ((v_meta ->> 'total_count')::int > (v_meta ->> 'returned_count')::int)
      then 'PASS' else 'FAIL' end
      || ': 13. and it states its own total - the whole quiet set, not the page ('
      || coalesce(v_meta ->> 'returned_count', 'null') || ' of '
      || coalesce(v_meta ->> 'total_count', 'null') || ')'
  );

  select r into v_row from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_pnone::text;
  v_log := array_append(
    v_log,
    case when v_row is not null and (v_row -> 'days_since_last_sale') = 'null'::jsonb
      then 'PASS' else 'FAIL' end
      || ': 6. a product that never sold is dead stock, and days_since_last_sale is null (an answer, not a hole)'
  );

  select r into v_row from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_d_quiet::text;
  v_log := array_append(
    v_log,
    case when v_row is not null and (v_row ->> 'days_since_last_sale')::int = 100
      then 'PASS' else 'FAIL' end
      || ': 6. 100 days quiet is dead, with the days reported ('
      || coalesce(v_row ->> 'days_since_last_sale', 'null') || ')'
  );

  select count(*) into v_n from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_d_boundary::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 6. exactly 90 days quiet is NOT dead - the boundary day is inside the window'
  );

  select count(*) into v_n from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_d_moving::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 6. and 5 days quiet is not either'
  );

  select count(*) into v_n from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_d_expired::text;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 7. a product whose only stock has expired is dead stock too (a different question from expiring_batches)'
  );

  select count(*) into v_n from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_d_empty::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 7. a product with nothing on the shelf is not dead stock - there is nothing to be stale'
  );

  select count(*) into v_n from jsonb_array_elements(v_rows) r where r ->> 'product_id' = v_other_dead::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 9. another pharmacy''s dead stock is invisible to us'
  );

  -- Relational, for the same hosted-data reason as the ranking above: the claim is "most cash
  -- first", not "the fixture is first".
  v_log := array_append(
    v_log,
    case when jsonb_array_length(v_rows) >= 2
          and (v_rows -> 0 ->> 'stock_value_at_cost')::numeric
                = (select max((r ->> 'stock_value_at_cost')::numeric)
                     from jsonb_array_elements(v_rows) r)
      then 'PASS' else 'FAIL' end
      || ': 8. the most cash tied up comes first ('
      || coalesce(v_rows -> 0 ->> 'name', 'null') || ')'
  );

  select count(*) into v_n from jsonb_array_elements(v_rows) r
   where not (r ? 'stock_value_at_cost');
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 8. and every row is valued at cost, which is what is actually stuck'
  );

  v_result := public.dead_stock(90, 1);
  v_log := array_append(
    v_log,
    case when jsonb_array_length(v_result -> 'rows') = 1
          and (v_result -> 'meta' ->> 'returned_count')::int = 1
          and (v_result -> 'meta' ->> 'total_count')::int
                >= (v_result -> 'meta' ->> 'returned_count')::int
          and (v_result -> 'meta' ->> 'has_more')::boolean
                = ((v_result -> 'meta' ->> 'total_count')::int
                   > (v_result -> 'meta' ->> 'returned_count')::int)
      then 'PASS' else 'FAIL' end
      || ': 6. the limit bounds the page, and the total still counts the whole quiet set ('
      || coalesce(v_result -> 'meta' ->> 'returned_count', 'null') || ' of '
      || coalesce(v_result -> 'meta' ->> 'total_count', 'null') || ')'
  );

  -- ------------------------------------------------- 10. neither one moved anything
  execute 'reset role';

  select count(*) into v_products_after from public.products where pharmacy_id = v_pharmacy;
  select count(*) into v_batches_after from public.product_batches where pharmacy_id = v_pharmacy;

  v_log := array_append(
    v_log,
    case when v_products_after = v_products_before
          and v_batches_after = v_batches_before
      then 'PASS' else 'FAIL' end
      || ': 10. reading the aggregates moves nothing (products ' || v_products_before
      || '->' || v_products_after || ', batches ' || v_batches_before
      || '->' || v_batches_after || ')'
  );

  -- -------------------------------------------------- 11. both functions' contract
  select p.prosecdef, p.provolatile, p.proconfig
    into v_prosecdef, v_provolatile, v_proconfig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'top_products';

  v_log := array_append(
    v_log,
    case when v_prosecdef then 'PASS' else 'FAIL' end
      || ': 11. top_products is SECURITY DEFINER, so it scopes by hand (the view it reads follows the owner inside it)'
  );

  v_log := array_append(
    v_log,
    case when v_provolatile = 's' then 'PASS' else 'FAIL' end
      || ': 11. it is STABLE - an aggregate cannot move stock (got ' || coalesce(v_provolatile::text, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1 from unnest(coalesce(v_proconfig, array[]::text[])) c
       where c like 'search_path=%' and c like '%public%'
    ) then 'PASS' else 'FAIL' end
      || ': 11. its search_path is pinned'
  );

  select pg_get_function_identity_arguments(p.oid) into v_identity
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'top_products';
  v_log := array_append(
    v_log,
    case when v_identity not like '%pharmacy%' then 'PASS' else 'FAIL' end
      || ': 11. the pharmacy is not an argument (' || coalesce(v_identity, 'missing') || ')'
  );

  select p.prosecdef, p.provolatile
    into v_prosecdef, v_provolatile
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'dead_stock';
  v_log := array_append(
    v_log,
    case when v_prosecdef and v_provolatile = 's' then 'PASS' else 'FAIL' end
      || ': 11. dead_stock is SECURITY DEFINER and STABLE too (got '
      || coalesce(v_provolatile::text, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('authenticated', 'public.top_products(date,date,int,text)', 'EXECUTE')
          and has_function_privilege('authenticated', 'public.dead_stock(int,int)', 'EXECUTE')
      then 'PASS' else 'FAIL' end
      || ': 11. authenticated may read both aggregates'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('anon', 'public.top_products(date,date,int,text)', 'EXECUTE')
          or has_function_privilege('anon', 'public.dead_stock(int,int)', 'EXECUTE')
      then 'FAIL' else 'PASS' end
      || ': 11. anon may read neither'
  );

  select count(*) into v_pass from unnest(v_log) l where l like 'PASS%';
  select count(*) into v_fail from unnest(v_log) l where l like 'FAIL%';
  v_log := array_append(
    v_log,
    'SUMMARY: ' || v_pass || ' PASS / ' || v_fail || ' FAIL of '
      || (array_length(v_log, 1) + 1) || ' assertions'
  );

  raise exception E'PHASE5 CHAT AGGREGATES TEST\n%', array_to_string(v_log, chr(10));
end $$;
