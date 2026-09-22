-- Phase 5 alert sources - functional test for migration
-- 20260919000027_phase5_alert_sources, re-expressed against the envelope and the business
-- clock added by 20260922000050_phase5_alert_envelope_and_business_clock.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase5_alerts.sql
--
-- HOW TO READ THE RESULT
--   Every line is "PASS: ..." or "FAIL: ...", and the last line is
--   "SUMMARY: n PASS / n FAIL of n assertions". A non-zero exit code is expected and means
--   the script ran to completion: it ends by raising, so the whole DO block (one statement,
--   one transaction) rolls back and no ZZTEST pharmacy, product or batch survives.
--
--   The summary counts assertions, not log lines, so it does not count itself (the older
--   files' `array_length(v_log, 1) + 1` does, and reads one too high). Every logged line is
--   asserted to be a PASS or a FAIL, so a skipped or half-written check cannot hide behind
--   the arithmetic.
--
-- WHY IT IMPERSONATES
--   Both functions are SECURITY DEFINER, so RLS is NOT applied to their own queries - and
--   the views they read are `security_invoker = true`, which follows the *current* user, so
--   inside a definer function that is the owner. The only way to prove they scope by hand is
--   to call them as `authenticated` with a JWT set and to put a second tenant's low-stock and
--   expiring rows in reach.
--
-- WHAT IT PROVES
--   1.  The reorder boundary: `< min_stock_level` reports, `= min_stock_level` does not, a
--       product with no batches at all is 0 and does report, and a deactivated product never
--       does. The rule is STATED in `meta.rule`, in the database's own words.
--   2.  The shortfall is the units that close the gap, and the worst one is first.
--   3.  The expiry horizon and its buckets: an already-expired batch is reported with a
--       negative `days_left` and comes first, one past the horizon does not, one with nothing
--       left in it does not, and one with no expiry does not. `meta.horizon_days` is the
--       CLAMPED horizon that actually ran.
--   4.  Tenant isolation both ways: another pharmacy's low-stock product and expiring batch
--       are invisible to us.
--   5.  Neither function moves anything: the product and batch counts are the same after as
--       before.
--   6.  Both functions' own contract: SECURITY DEFINER, STABLE (they cannot write),
--       search_path pinned, no pharmacy argument, EXECUTE for `authenticated` and not for
--       `anon`.
--   7.  **The envelope (00050)**: `{meta, rows}`; `total_count` is the whole set and
--       `returned_count` the page, with their difference stated in `has_more` - asserted
--       BOTH ways (a cap below the set, and a cap above it); `limit` is the clamped cap that
--       ran; `as_of` and `timezone` are the business day and its zone.
--   8.  **The business clock (00050)**: `business_today()` is the IST day and does NOT follow
--       the session's TimeZone, the boundary at 18:30 UTC is pinned by arithmetic rather than
--       by what time it happens to be, and the reports' `as_of` (and `report_summary`'s
--       default period) come from it. `batch_status`' buckets do too: a batch expiring on the
--       business day is `critical`, not `expired`.

do $$
declare
  v_log       text[] := array[]::text[];
  v_pass      int;
  v_fail      int;
  v_asserts   int;
  v_unlogged  int;
  v_pharmacy  uuid;
  v_user      uuid;
  v_other     uuid;
  v_low       uuid;   -- no batches at all: the biggest shortfall
  v_part      uuid;   -- a batch of 4 plus an expired batch of 2, against a level of 10
  v_at        uuid;   -- exactly at its level: not an alert
  v_inactive  uuid;   -- discontinued, and short
  v_far       uuid;   -- an active product whose batch is 400 days out
  v_noexpiry  uuid;   -- an active product whose batch has no expiry date
  v_ontoday   uuid;   -- an active product whose batch expires on the business day
  v_other_low uuid;   -- another pharmacy's low-stock product
  v_b_exp     uuid;
  v_b_gone    uuid;
  v_b_far     uuid;
  v_b_empty   uuid;
  v_b_none    uuid;
  v_b_at      uuid;
  v_b_today   uuid;
  v_b_other   uuid;
  v_b_other_tenant uuid;
  v_result    jsonb;
  v_meta      jsonb;
  v_rows      jsonb;
  v_row       jsonb;
  v_n         int;
  v_days      int;
  v_total     int;
  v_returned  int;
  v_ist       date;
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
    raise exception 'PHASE5 ALERTS TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user from public.profiles where pharmacy_id = v_pharmacy order by created_at limit 1;
  if v_user is null then
    raise exception 'PHASE5 ALERTS TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------- fixtures
  -- Every product and batch here is built so that exactly one rule decides it, and
  -- a product is never shared between two assertions that could interfere.
  insert into public.pharmacies (name) values ('ZZTEST alerts other pharmacy')
  returning id into v_other;

  insert into public.products (pharmacy_id, name, min_stock_level)
  values (v_pharmacy, 'ZZTEST Alerts Nothing Left', 10) returning id into v_low;
  insert into public.products (pharmacy_id, name, min_stock_level)
  values (v_pharmacy, 'ZZTEST Alerts Partly There', 10) returning id into v_part;
  insert into public.products (pharmacy_id, name, min_stock_level)
  values (v_pharmacy, 'ZZTEST Alerts Exactly There', 10) returning id into v_at;
  insert into public.products (pharmacy_id, name, min_stock_level, is_active)
  values (v_pharmacy, 'ZZTEST Alerts Discontinued', 10, false) returning id into v_inactive;
  insert into public.products (pharmacy_id, name, min_stock_level)
  values (v_pharmacy, 'ZZTEST Alerts Far Horizon', 0) returning id into v_far;
  insert into public.products (pharmacy_id, name, min_stock_level)
  values (v_pharmacy, 'ZZTEST Alerts Expires Today', 0) returning id into v_ontoday;
  insert into public.products (pharmacy_id, name, min_stock_level)
  values (v_other, 'ZZTEST Alerts Other Tenant', 10) returning id into v_other_low;

  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_part, 'A-1', public.business_today() + 5, 4) returning id into v_b_exp;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_part, 'A-EXPIRED', public.business_today() - 1, 2) returning id into v_b_gone;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_at, 'A-2', public.business_today() + 3, 10) returning id into v_b_at;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_inactive, 'A-3', public.business_today() + 6, 3) returning id into v_b_other;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_far, 'A-FAR', public.business_today() + 400, 7) returning id into v_b_far;
  -- An empty batch on a product whose level is 0: not low stock (0 < 0 is false)
  -- and not a waste risk (nothing left to waste).
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_low, 'A-EMPTY', public.business_today() + 2, 0) returning id into v_b_empty;
  -- Expiring ON the business day: not yet expired (the rule is `< today`), so `critical`.
  -- This is the assertion the business clock turned into behaviour: on the server's UTC day
  -- this batch flipped a day early for five and a half hours a day.
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_ontoday, 'A-TODAY', public.business_today(), 3) returning id into v_b_today;
  -- No expiry at all. Legitimate since migration 00031 - the source did not record one, and
  -- "unknown" is not "safe". `v_noexpiry`/`v_b_none` have been declared in this file since the
  -- day it was written and never used, because while `expiry_date` was NOT NULL this fixture
  -- could not exist; 00031 made it possible, so the coverage it was meant for lives here.
  insert into public.products (pharmacy_id, name, min_stock_level)
  values (v_pharmacy, 'ZZTEST Alerts Undated', 0) returning id into v_noexpiry;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_noexpiry, 'A-UNDATED', null, 6) returning id into v_b_none;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_other, v_other_low, 'B-1', public.business_today() + 1, 5) returning id into v_b_other_tenant;

  -- ------------------------------------------------------------------ as the user
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  select count(*) into v_products_before from public.products where pharmacy_id = v_pharmacy;
  select count(*) into v_batches_before from public.product_batches where pharmacy_id = v_pharmacy;

  -- ------------------------------------------------------------- 1. low stock
  v_result := public.low_stock_products(200);
  v_meta   := v_result -> 'meta';
  v_rows   := v_result -> 'rows';

  v_log := array_append(
    v_log,
    case when jsonb_typeof(v_result) = 'object'
          and jsonb_typeof(v_rows) = 'array'
          and jsonb_typeof(v_meta) = 'object'
      then 'PASS' else 'FAIL' end
      || ': 7. the low-stock answer is {meta, rows}, not a bare array (00050)'
  );

  v_log := array_append(
    v_log,
    case when v_meta ->> 'rule' = 'total_qty < min_stock_level' then 'PASS' else 'FAIL' end
      || ': 1. the envelope states the rule in the database''s own words (got '
      || coalesce(v_meta ->> 'rule', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_meta ->> 'as_of' = public.business_today()::text
          and v_meta ->> 'timezone' = 'Asia/Kolkata'
      then 'PASS' else 'FAIL' end
      || ': 8. and the business day it was evaluated on, with its zone (got '
      || coalesce(v_meta ->> 'as_of', 'null') || ' in ' || coalesce(v_meta ->> 'timezone', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1 from jsonb_array_elements(v_rows) r where r->>'product_id' = v_low::text
    ) then 'PASS' else 'FAIL' end
      || ': 1. a product with no batches at all is reported (total_qty 0 against a level of 10)'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1 from jsonb_array_elements(v_rows) r where r->>'product_id' = v_part::text
    ) then 'PASS' else 'FAIL' end
      || ': 1. and one that is merely short is too'
  );

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_rows) r where r->>'product_id' = v_at::text
    ) then 'PASS' else 'FAIL' end
      || ': 1. a product exactly AT its reorder level is not an alert (< is the rule the app already uses)'
  );

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_rows) r where r->>'product_id' = v_inactive::text
    ) then 'PASS' else 'FAIL' end
      || ': 1. a discontinued product is never suggested for reordering'
  );

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_rows) r where r->>'product_id' = v_other_low::text
    ) then 'PASS' else 'FAIL' end
      || ': 4. another pharmacy''s low stock is invisible to us'
  );

  select r into v_row from jsonb_array_elements(v_rows) r
   where r->>'product_id' = v_part::text;
  v_log := array_append(
    v_log,
    case when (v_row->>'shortfall')::int = 4
          and (v_row->>'total_qty')::int = 6
          and (v_row->>'min_stock_level')::int = 10
      then 'PASS' else 'FAIL' end
      || ': 2. the shortfall is the units that close the gap: 6 in stock (4 usable and 2 expired) against a level of 10 is 4 (got '
      || coalesce(v_row->>'shortfall', 'null') || ')'
  );

  -- The order is asserted as a RELATION rather than against a fixture row: on hosted the
  -- owner's own catalogue shares these tables, and "the fixture is first" is a claim about
  -- the data, not about the report. The report's claim is that they come worst-first.
  v_log := array_append(
    v_log,
    case when (v_rows -> 0 ->> 'shortfall')::int >= (v_rows -> 1 ->> 'shortfall')::int
      then 'PASS' else 'FAIL' end
      || ': 2. the worst one is first ('
      || coalesce(v_rows -> 0 ->> 'shortfall', 'null') || ' then '
      || coalesce(v_rows -> 1 ->> 'shortfall', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when (v_meta ->> 'limit')::int = 200 then 'PASS' else 'FAIL' end
      || ': 7. meta.limit is the capped value that ran (got '
      || coalesce(v_meta ->> 'limit', 'null') || ')'
  );

  -- ------------------------------- 7. the total is the whole set, and has_more both ways
  v_result   := public.low_stock_products(200);
  v_meta     := v_result -> 'meta';
  v_rows     := v_result -> 'rows';
  v_total    := (v_meta ->> 'total_count')::int;
  v_returned := (v_meta ->> 'returned_count')::int;

  v_log := array_append(
    v_log,
    case when v_returned = jsonb_array_length(v_rows)
          and v_total >= v_returned
          and (v_meta ->> 'has_more')::boolean = (v_total > v_returned)
      then 'PASS' else 'FAIL' end
      || ': 7. returned_count is the page and total_count is at least it ('
      || v_returned || ' of ' || v_total || ', has_more ' || coalesce(v_meta ->> 'has_more', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_total >= 2 then 'PASS' else 'FAIL' end
      || ': 7. and it counts the WHOLE set, not the page: both fixture products are in it (got '
      || v_total || ' against a page of ' || v_returned || ')'
  );

  v_log := array_append(
    v_log,
    case when (v_meta ->> 'has_more')::boolean = false then 'PASS' else 'FAIL' end
      || ': 7. a cap above the set says there is nothing more'
  );

  -- A cap BELOW the set. The fixtures guarantee at least two low products, so one row is
  -- always a page - and this is the case the chatbot's sentence reads a total from.
  v_result   := public.low_stock_products(1);
  v_meta     := v_result -> 'meta';
  v_rows     := v_result -> 'rows';
  v_total    := (v_meta ->> 'total_count')::int;
  v_returned := (v_meta ->> 'returned_count')::int;

  v_log := array_append(
    v_log,
    case when jsonb_array_length(v_rows) = 1
          and v_returned = 1
          and (v_meta ->> 'limit')::int = 1
      then 'PASS' else 'FAIL' end
      || ': 7. the limit bounds the page (got ' || v_returned || ' row, limit '
      || coalesce(v_meta ->> 'limit', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_total > v_returned and (v_meta ->> 'has_more')::boolean
      then 'PASS' else 'FAIL' end
      || ': 7. and has_more is TRUE when the page is short of the set ('
      || v_returned || ' of ' || v_total || ')'
  );

  -- The clamp: a cap OUTSIDE the range is clamped to the range's end (only NULL takes the
  -- report's own default), and the envelope says what ran rather than echoing the request.
  v_log := array_append(
    v_log,
    case when (public.low_stock_products(5000) -> 'meta' ->> 'limit')::int = 200
          and (public.low_stock_products(0) -> 'meta' ->> 'limit')::int = 1
          and (public.low_stock_products(null) -> 'meta' ->> 'limit')::int = 50
      then 'PASS' else 'FAIL' end
      || ': 7. meta.limit is the clamp, not the request (5000->'
      || coalesce((public.low_stock_products(5000) -> 'meta' ->> 'limit'), 'null')
      || ', 0->' || coalesce((public.low_stock_products(0) -> 'meta' ->> 'limit'), 'null')
      || ', null->' || coalesce((public.low_stock_products(null) -> 'meta' ->> 'limit'), 'null') || ')'
  );

  -- ---------------------------------------------------------- 2. expiry horizon
  v_result := public.expiring_batches(90, 200);
  v_meta   := v_result -> 'meta';
  v_rows   := v_result -> 'rows';

  v_log := array_append(
    v_log,
    case when jsonb_typeof(v_meta) = 'object' and jsonb_typeof(v_rows) = 'array'
      then 'PASS' else 'FAIL' end
      || ': 7. the expiry answer is {meta, rows} too (00050)'
  );

  v_log := array_append(
    v_log,
    case when (v_meta ->> 'horizon_days')::int = 90
          and v_meta ->> 'as_of' = public.business_today()::text
      then 'PASS' else 'FAIL' end
      || ': 3. the envelope states the horizon it actually queried, on the business day (got '
      || coalesce(v_meta ->> 'horizon_days', 'null') || ' days from ' || coalesce(v_meta ->> 'as_of', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_rows) r where r->>'batch_id' = v_b_far::text
    ) then 'PASS' else 'FAIL' end
      || ': 3. a batch 400 days out is not in a 90-day horizon'
  );

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_rows) r where r->>'batch_id' = v_b_empty::text
    ) then 'PASS' else 'FAIL' end
      || ': 3. a batch with nothing left in it is not a waste risk'
  );

  -- `expiring_batches` guards `expiry_date is not null`. Until migration 00031 that guard could
  -- never fire: the column was NOT NULL, so no batch could reach the alert without a date, and
  -- this assertion recorded the guard as a mirror of the schema rather than as behaviour. 00031
  -- deliberately made the column nullable - the opening-stock import has 145 rows whose source
  -- recorded no expiry, and the schema has to be able to hold "unknown" - which turned the guard
  -- into something load-bearing. The assertion now tests what the guard protects: an undated
  -- batch is a legal row, and it is NOT reported as expiring, because there is no date for it to
  -- be inside a horizon of.
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public'
     and table_name = 'product_batches'
     and column_name = 'expiry_date'
     and is_nullable = 'YES';
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 3. expiry_date is nullable, so an unknown expiry is representable (migration 00031)'
  );

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_rows) r where r->>'batch_id' = v_b_none::text
    ) then 'PASS' else 'FAIL' end
      || ': 3. a batch with NO expiry is not reported as expiring in a 90-day horizon'
  );

  -- ...and the view behind the same idea labels it, rather than calling it safe.
  select b.expiry_status into v_identity
    from public.batch_status b
   where b.id = v_b_none;
  v_log := array_append(
    v_log,
    case when v_identity = 'unknown' then 'PASS' else 'FAIL' end
      || ': 3. batch_status reports an undated batch as ''unknown'', not ''safe'' (got '
      || coalesce(v_identity, 'null') || ')'
  );

  -- ------------------------------------- 8. the buckets are the pharmacy's days (00050)
  select b.expiry_status into v_identity from public.batch_status b where b.id = v_b_today;
  v_log := array_append(
    v_log,
    case when v_identity = 'critical' then 'PASS' else 'FAIL' end
      || ': 8. a batch expiring ON the business day is critical, not expired (got '
      || coalesce(v_identity, 'null') || ')'
  );

  select b.expiry_status into v_identity from public.batch_status b where b.id = v_b_gone;
  v_log := array_append(
    v_log,
    case when v_identity = 'expired' then 'PASS' else 'FAIL' end
      || ': 8. and one from yesterday IS expired (got ' || coalesce(v_identity, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_rows) r where r->>'batch_id' = v_b_other_tenant::text
    ) then 'PASS' else 'FAIL' end
      || ': 4. another pharmacy''s expiring batch is invisible to us'
  );

  select (r->>'days_left')::int into v_days from jsonb_array_elements(v_rows) r
   where r->>'batch_id' = v_b_exp::text;
  v_log := array_append(
    v_log,
    case when v_days = 5 then 'PASS' else 'FAIL' end
      || ': 3. days_left counts forward from the BUSINESS day (got ' || coalesce(v_days::text, 'null') || ')'
  );

  select (r->>'days_left')::int into v_days from jsonb_array_elements(v_rows) r
   where r->>'batch_id' = v_b_gone::text;
  v_log := array_append(
    v_log,
    case when v_days = -1 then 'PASS' else 'FAIL' end
      || ': 3. and goes negative for one that has already expired (got ' || coalesce(v_days::text, 'null') || ')'
  );

  -- Relational again, for the same hosted-data reason as the low-stock order.
  v_log := array_append(
    v_log,
    case when (v_rows -> 0 ->> 'days_left')::int
             <= (select min((q->>'days_left')::int) from jsonb_array_elements(v_rows) q)
      then 'PASS' else 'FAIL' end
      || ': 3. the soonest is first, so an already-expired one leads (got '
      || coalesce(v_rows -> 0 ->> 'days_left', 'null') || ')'
  );

  v_result   := public.expiring_batches(90, 2);
  v_meta     := v_result -> 'meta';
  v_total    := (v_meta ->> 'total_count')::int;
  v_returned := (v_meta ->> 'returned_count')::int;
  v_log := array_append(
    v_log,
    case when v_returned = 2
          and v_total >= 3
          and (v_meta ->> 'has_more')::boolean
      then 'PASS' else 'FAIL' end
      || ': 7. the expiry envelope counts the whole horizon, not the page ('
      || v_returned || ' of ' || v_total || ')'
  );

  v_result := public.expiring_batches(90, 500);
  v_log := array_append(
    v_log,
    case when (v_result -> 'meta' ->> 'has_more')::boolean = false then 'PASS' else 'FAIL' end
      || ': 7. and a cap above the set says there is nothing more'
  );

  -- A horizon outside the range is clamped to the range's end (only NULL takes the report's
  -- own default), and meta.horizon_days states what ran.
  v_log := array_append(
    v_log,
    case when (public.expiring_batches(5000, 200) -> 'meta' ->> 'horizon_days')::int = 3650
          and (public.expiring_batches(0, 200) -> 'meta' ->> 'horizon_days')::int = 1
          and (public.expiring_batches(null, 200) -> 'meta' ->> 'horizon_days')::int = 90
      then 'PASS' else 'FAIL' end
      || ': 3. meta.horizon_days is the clamp, so the sentence can state a horizon that is true (5000->'
      || coalesce((public.expiring_batches(5000, 200) -> 'meta' ->> 'horizon_days'), 'null')
      || ', 0->' || coalesce((public.expiring_batches(0, 200) -> 'meta' ->> 'horizon_days'), 'null')
      || ', null->' || coalesce((public.expiring_batches(null, 200) -> 'meta' ->> 'horizon_days'), 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1 from jsonb_array_elements(public.expiring_batches(500, 200) -> 'rows') r
       where r->>'batch_id' = v_b_far::text
    ) then 'PASS' else 'FAIL' end
      || ': 3. a wider horizon finds it, so the window is the caller''s to choose'
  );

  -- ----------------------------------------- 8. the clock itself, and its boundary
  v_ist := (now() at time zone 'Asia/Kolkata')::date;

  v_log := array_append(
    v_log,
    case when public.business_today() = v_ist then 'PASS' else 'FAIL' end
      || ': 8. business_today() is the IST day (got ' || public.business_today() || ')'
  );

  -- The REASON, pinned by arithmetic rather than by what time it happens to be: at 19:00 UTC
  -- the IST day has already turned while the UTC day has not. A UTC-based "today" is
  -- therefore yesterday's business for five and a half hours a day.
  v_log := array_append(
    v_log,
    case when (timestamptz '2026-09-22 19:00:00+00' at time zone 'Asia/Kolkata')::date
               = date '2026-09-23'
          and (timestamptz '2026-09-22 19:00:00+00' at time zone 'UTC')::date
               = date '2026-09-22'
      then 'PASS' else 'FAIL' end
      || ': 8. the boundary is real: 19:00 UTC is already the 23rd in IST and still the 22nd in UTC'
  );

  -- The clock does NOT follow the session: `current_date` does, which is exactly why a report
  -- that used it would answer differently depending on who asked.
  perform set_config('TimeZone', 'Etc/GMT+12', true);

  v_log := array_append(
    v_log,
    case when public.business_today() = v_ist then 'PASS' else 'FAIL' end
      || ': 8. business_today() ignores the session TimeZone, so a report cannot answer differently per caller'
  );

  v_log := array_append(
    v_log,
    case when public.low_stock_products(200) -> 'meta' ->> 'as_of' = v_ist::text
          and public.expiring_batches(90, 200) -> 'meta' ->> 'as_of' = v_ist::text
          and public.dead_stock(90, 200) -> 'meta' ->> 'as_of' = v_ist::text
      then 'PASS' else 'FAIL' end
      || ': 8. the reports take their as_of from it, not from the session'
  );

  v_log := array_append(
    v_log,
    case when public.report_summary(null, null) ->> 'as_of' = v_ist::text
          and public.report_summary(null, null) ->> 'from' = v_ist::text
          and public.report_summary(null, null) ->> 'to' = v_ist::text
      then 'PASS' else 'FAIL' end
      || ': 8. and a summary with no period named defaults to the business day'
  );

  v_log := array_append(
    v_log,
    case when public.top_products(null, null, 5, null) -> 'meta' ->> 'window_to' = v_ist::text
          and public.top_products(null, null, 5, null) -> 'meta' ->> 'timezone' = 'Asia/Kolkata'
      then 'PASS' else 'FAIL' end
      || ': 8. the rolling window ends on the business day too'
  );

  perform set_config('TimeZone', 'UTC', true);

  -- --------------------------------------------------- 5. neither one moved anything
  select count(*) into v_products_after from public.products where pharmacy_id = v_pharmacy;
  select count(*) into v_batches_after from public.product_batches where pharmacy_id = v_pharmacy;

  v_log := array_append(
    v_log,
    case when v_products_after = v_products_before
          and v_batches_after = v_batches_before
      then 'PASS' else 'FAIL' end
      || ': 5. reading the alerts moves nothing (products ' || v_products_before
      || '->' || v_products_after || ', batches ' || v_batches_before
      || '->' || v_batches_after || ')'
  );

  execute 'reset role';

  -- ------------------------------------------------------- 6. both functions' contract
  select p.prosecdef, p.provolatile, p.proconfig
    into v_prosecdef, v_provolatile, v_proconfig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'low_stock_products';

  v_log := array_append(
    v_log,
    case when v_prosecdef then 'PASS' else 'FAIL' end
      || ': 6. low_stock_products is SECURITY DEFINER, so it scopes by hand (the view it reads follows the owner inside it)'
  );

  v_log := array_append(
    v_log,
    case when v_provolatile = 's' then 'PASS' else 'FAIL' end
      || ': 6. it is STABLE - an alert cannot move stock (got ' || coalesce(v_provolatile::text, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1 from unnest(coalesce(v_proconfig, array[]::text[])) c
       where c like 'search_path=%' and c like '%public%'
    ) then 'PASS' else 'FAIL' end
      || ': 6. its search_path is pinned'
  );

  select p.prosecdef, p.provolatile, p.proconfig
    into v_prosecdef, v_provolatile, v_proconfig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'expiring_batches';

  v_log := array_append(
    v_log,
    case when v_prosecdef and v_provolatile = 's' then 'PASS' else 'FAIL' end
      || ': 6. expiring_batches is SECURITY DEFINER and STABLE too (got '
      || coalesce(v_provolatile::text, 'null') || ')'
  );

  select pg_get_function_identity_arguments(p.oid) into v_identity
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'low_stock_products';
  v_log := array_append(
    v_log,
    case when v_identity not like '%pharmacy%' then 'PASS' else 'FAIL' end
      || ': 6. the pharmacy is not an argument (' || coalesce(v_identity, 'missing') || ')'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('authenticated', 'public.low_stock_products(int)', 'EXECUTE')
          and has_function_privilege('authenticated', 'public.expiring_batches(int,int)', 'EXECUTE')
      then 'PASS' else 'FAIL' end
      || ': 6. authenticated may read both alerts'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('anon', 'public.low_stock_products(int)', 'EXECUTE')
          or has_function_privilege('anon', 'public.expiring_batches(int,int)', 'EXECUTE')
      then 'FAIL' else 'PASS' end
      || ': 6. anon may read neither'
  );

  select p.prosecdef, p.provolatile into v_prosecdef, v_provolatile
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_today';
  v_log := array_append(
    v_log,
    case when v_provolatile = 's' then 'PASS' else 'FAIL' end
      || ': 8. business_today is STABLE, not IMMUTABLE - the planner must not freeze the day it was built (got '
      || coalesce(v_provolatile::text, 'null') || ')'
  );

  -- -------------------------------------------------------------- the count itself
  select count(*) into v_unlogged from unnest(v_log) l
   where l not like 'PASS%' and l not like 'FAIL%';
  v_log := array_append(
    v_log,
    case when v_unlogged = 0 then 'PASS' else 'FAIL' end
      || ': 0. every logged line is a PASS or a FAIL, so nothing is skipped or truncated'
  );

  select count(*) into v_pass from unnest(v_log) l where l like 'PASS%';
  select count(*) into v_fail from unnest(v_log) l where l like 'FAIL%';
  v_asserts := v_pass + v_fail;
  v_log := array_append(
    v_log,
    'SUMMARY: ' || v_pass || ' PASS / ' || v_fail || ' FAIL of ' || v_asserts || ' assertions'
  );

  raise exception E'PHASE5 ALERTS TEST\n%', array_to_string(v_log, chr(10));
end $$;
