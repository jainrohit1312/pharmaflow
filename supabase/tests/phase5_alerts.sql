-- Phase 5 alert sources - functional test for migration
-- 20260919000027_phase5_alert_sources.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase5_alerts.sql
--
-- HOW TO READ THE RESULT
--   Every line is "PASS: ..." or "FAIL: ...", and the last line is
--   "SUMMARY: n PASS / n FAIL". A non-zero exit code is expected and means the
--   script ran to completion: it ends by raising, so the whole DO block (one
--   statement, one transaction) rolls back and no ZZTEST pharmacy, product or
--   batch survives.
--
-- WHY IT IMPERSONATES
--   Both functions are SECURITY DEFINER, so RLS is NOT applied to their own
--   queries - and the views they read are `security_invoker = true`, which follows
--   the *current* user, so inside a definer function that is the owner. The only
--   way to prove they scope by hand is to call them as `authenticated` with a JWT
--   set and to put a second tenant's low-stock and expiring rows in reach.
--
-- WHAT IT PROVES
--   1.  The reorder boundary: `< min_stock_level` reports, `= min_stock_level`
--       does not, a product with no batches at all is 0 and does report, and a
--       deactivated product never does.
--   2.  The shortfall is the units that close the gap, and the worst one is first.
--   3.  The expiry horizon and its buckets: an already-expired batch is reported
--       with a negative `days_left` and comes first, one past the horizon does not,
--       one with nothing left in it does not, and one with no expiry does not.
--   4.  Tenant isolation both ways: another pharmacy's low-stock product and
--       expiring batch are invisible to us.
--   5.  Neither function moves anything: the product and batch counts are the same
--       after as before.
--   6.  Both functions' own contract: SECURITY DEFINER, STABLE (they cannot
--       write), search_path pinned, no pharmacy argument, EXECUTE for
--       `authenticated` and not for `anon`.

do $$
declare
  v_log       text[] := array[]::text[];
  v_pass      int;
  v_fail      int;
  v_pharmacy  uuid;
  v_user      uuid;
  v_other     uuid;
  v_low       uuid;   -- no batches at all: the biggest shortfall
  v_part      uuid;   -- a batch of 4 plus an expired batch of 2, against a level of 10
  v_at        uuid;   -- exactly at its level: not an alert
  v_inactive  uuid;   -- discontinued, and short
  v_far       uuid;   -- an active product whose batch is 400 days out
  v_noexpiry  uuid;   -- an active product whose batch has no expiry date
  v_other_low uuid;   -- another pharmacy's low-stock product
  v_b_exp     uuid;
  v_b_gone    uuid;
  v_b_far     uuid;
  v_b_empty   uuid;
  v_b_none    uuid;
  v_b_at      uuid;
  v_b_other   uuid;
  v_b_other_tenant uuid;
  v_result    jsonb;
  v_row       jsonb;
  v_n         int;
  v_days      int;
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
  values (v_other, 'ZZTEST Alerts Other Tenant', 10) returning id into v_other_low;

  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_part, 'A-1', current_date + 5, 4) returning id into v_b_exp;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_part, 'A-EXPIRED', current_date - 1, 2) returning id into v_b_gone;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_at, 'A-2', current_date + 3, 10) returning id into v_b_at;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_inactive, 'A-3', current_date + 6, 3) returning id into v_b_other;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_far, 'A-FAR', current_date + 400, 7) returning id into v_b_far;
  -- An empty batch on a product whose level is 0: not low stock (0 < 0 is false)
  -- and not a waste risk (nothing left to waste).
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_low, 'A-EMPTY', current_date + 2, 0) returning id into v_b_empty;
  -- No expiry at all. Legitimate since migration 00031 - the source did not record one, and
  -- "unknown" is not "safe". `v_noexpiry`/`v_b_none` have been declared in this file since the
  -- day it was written and never used, because while `expiry_date` was NOT NULL this fixture
  -- could not exist; 00031 made it possible, so the coverage it was meant for lives here.
  insert into public.products (pharmacy_id, name, min_stock_level)
  values (v_pharmacy, 'ZZTEST Alerts Undated', 0) returning id into v_noexpiry;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_pharmacy, v_noexpiry, 'A-UNDATED', null, 6) returning id into v_b_none;
  insert into public.product_batches (pharmacy_id, product_id, batch_no, expiry_date, qty)
  values (v_other, v_other_low, 'B-1', current_date + 1, 5) returning id into v_b_other_tenant;

  -- ------------------------------------------------------------------ as the user
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  select count(*) into v_products_before from public.products where pharmacy_id = v_pharmacy;
  select count(*) into v_batches_before from public.product_batches where pharmacy_id = v_pharmacy;

  -- ------------------------------------------------------------- 1. low stock
  v_result := public.low_stock_products(200);

  v_log := array_append(
    v_log,
    case when jsonb_typeof(v_result) = 'array' then 'PASS' else 'FAIL' end
      || ': 1. the low-stock answer is a list'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1 from jsonb_array_elements(v_result) r where r->>'product_id' = v_low::text
    ) then 'PASS' else 'FAIL' end
      || ': 1. a product with no batches at all is reported (total_qty 0 against a level of 10)'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1 from jsonb_array_elements(v_result) r where r->>'product_id' = v_part::text
    ) then 'PASS' else 'FAIL' end
      || ': 1. and one that is merely short is too'
  );

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_result) r where r->>'product_id' = v_at::text
    ) then 'PASS' else 'FAIL' end
      || ': 1. a product exactly AT its reorder level is not an alert (< is the rule the app already uses)'
  );

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_result) r where r->>'product_id' = v_inactive::text
    ) then 'PASS' else 'FAIL' end
      || ': 1. a discontinued product is never suggested for reordering'
  );

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_result) r where r->>'product_id' = v_other_low::text
    ) then 'PASS' else 'FAIL' end
      || ': 4. another pharmacy''s low stock is invisible to us'
  );

  select r into v_row from jsonb_array_elements(v_result) r
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

  v_log := array_append(
    v_log,
    case when (v_result->0->>'shortfall')::int >= (v_result->1->>'shortfall')::int
      then 'PASS' else 'FAIL' end
      || ': 2. the worst one is first ('
      || coalesce(v_result->0->>'shortfall', 'null') || ' then '
      || coalesce(v_result->1->>'shortfall', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when jsonb_array_length(public.low_stock_products(1)) = 1
      then 'PASS' else 'FAIL' end
      || ': 2. the limit bounds the answer'
  );

  -- ---------------------------------------------------------- 2. expiry horizon
  v_result := public.expiring_batches(90, 200);

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_result) r where r->>'batch_id' = v_b_far::text
    ) then 'PASS' else 'FAIL' end
      || ': 3. a batch 400 days out is not in a 90-day horizon'
  );

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_result) r where r->>'batch_id' = v_b_empty::text
    ) then 'PASS' else 'FAIL' end
      || ': 3. a batch with nothing left in it is not a waste risk'
  );

  -- `expiring_batches` guards `expiry_date is not null`. Until migration 00031 that guard could
  -- never fire: the column was NOT NULL, so no batch could reach the alert without a date, and
  -- this assertion recorded the guard as a mirror of the schema rather than as behaviour. 00031
  -- deliberately made the column nullable - the opening-stock import has 145 rows whose source
  -- recorded no expiry, and the schema has to be able to hold "unknown" - which turned the guard
  -- into something load-bearing. The assertion now tests what the guard protects, which is the
  -- only version of it with any value: an undated batch is a legal row, and it is NOT reported
  -- as expiring, because there is no date for it to be inside a horizon of.
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
      select 1 from jsonb_array_elements(v_result) r where r->>'batch_id' = v_b_none::text
    ) then 'PASS' else 'FAIL' end
      || ': 3. a batch with NO expiry is not reported as expiring in a 90-day horizon'
  );

  -- ...and the view behind the same idea labels it, rather than calling it safe: a row nobody
  -- can date must not read as having more than ninety days of shelf life.
  select b.expiry_status into v_identity
    from public.batch_status b
   where b.id = v_b_none;
  v_log := array_append(
    v_log,
    case when v_identity = 'unknown' then 'PASS' else 'FAIL' end
      || ': 3. batch_status reports an undated batch as ''unknown'', not ''safe'' (got '
      || coalesce(v_identity, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when not exists (
      select 1 from jsonb_array_elements(v_result) r where r->>'batch_id' = v_b_other_tenant::text
    ) then 'PASS' else 'FAIL' end
      || ': 4. another pharmacy''s expiring batch is invisible to us'
  );

  select (r->>'days_left')::int into v_days from jsonb_array_elements(v_result) r
   where r->>'batch_id' = v_b_exp::text;
  v_log := array_append(
    v_log,
    case when v_days = 5 then 'PASS' else 'FAIL' end
      || ': 3. days_left counts forward from today (got ' || coalesce(v_days::text, 'null') || ')'
  );

  select (r->>'days_left')::int into v_days from jsonb_array_elements(v_result) r
   where r->>'batch_id' = v_b_gone::text;
  v_log := array_append(
    v_log,
    case when v_days = -1 then 'PASS' else 'FAIL' end
      || ': 3. and goes negative for one that has already expired (got ' || coalesce(v_days::text, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when (v_result->0->>'batch_id') = v_b_gone::text then 'PASS' else 'FAIL' end
      || ': 3. an already-expired batch is first, because it is the one that is already a loss'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1 from jsonb_array_elements(public.expiring_batches(500, 200)) r
       where r->>'batch_id' = v_b_far::text
    ) then 'PASS' else 'FAIL' end
      || ': 3. a wider horizon finds it, so the window is the caller''s to choose'
  );

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

  select count(*) into v_pass from unnest(v_log) l where l like 'PASS%';
  select count(*) into v_fail from unnest(v_log) l where l like 'FAIL%';
  v_log := array_append(
    v_log,
    'SUMMARY: ' || v_pass || ' PASS / ' || v_fail || ' FAIL of '
      || (array_length(v_log, 1) + 1) || ' assertions'
  );

  raise exception E'PHASE5 ALERTS TEST\n%', array_to_string(v_log, chr(10));
end $$;
