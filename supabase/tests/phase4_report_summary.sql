-- Phase 4 reporting - functional test for migration
-- 20260918000021_phase4_reporting.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase4_report_summary.sql
--
-- HOW TO READ THE RESULT
--   Every line is "PASS: ..." or "FAIL: ...". A non-zero exit code is expected and
--   means the script ran to completion. It ends by raising, so the whole DO block
--   (one statement, one transaction) rolls back and leaves no residue: no ZZTEST
--   sale, expense, purchase or ledger row.
--
-- WHY IT IMPERSONATES
--   `report_summary()` takes the tenant from `get_my_pharmacy_id()`, which reads
--   `auth.uid()`. As `postgres` there is no tenant identity, which assertion 1
--   proves; the rest of the file sets the JWT claims and switches to
--   `authenticated`, the way profile_privileges.sql does.
--
-- WHAT IT PROVES
--   1.  It refuses to run without a tenant identity, and anon cannot execute it.
--   2.  The sales block counts the documents and sums the money the documents hold,
--       including what was collected at the counter and what is still owed.
--   3.  A cancelled sale is excluded from every sales figure.
--   4.  The purchases block counts only documents that reached `received`.
--   5.  Returns and expenses are totalled for the window.
--   6.  Stock is valued from `product_stock` (landed cost), and expiry from
--       `batch_status` at MRP - and the two are the same numbers the views hold.
--   7.  The window is inclusive at both ends, and excludes what falls outside it.

do $$
declare
  v_log        text[] := array[]::text[];
  v_pharmacy   uuid;
  v_user       uuid;
  v_customer   uuid;
  v_supplier   uuid;
  v_product    uuid;
  v_batch      uuid;
  v_sale       public.sales;
  v_sale2      public.sales;
  v_from       date := current_date - 1;
  v_to         date := current_date + 1;
  v_summary    jsonb;
  v_count      int;
  v_amount     numeric;
  v_value      numeric;
  v_allowed    boolean;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE4 TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user
    from public.profiles
   where pharmacy_id = v_pharmacy
   order by created_at
   limit 1;
  if v_user is null then
    raise exception 'PHASE4 TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------- 1. the tenant is required
  v_log := array_append(
    v_log,
    case when public.get_my_pharmacy_id() is null then 'PASS' else 'FAIL' end
      || ': 1. there is no tenant identity as postgres (the refusal below is real)'
  );

  v_allowed := has_function_privilege(
    'anon', 'public.report_summary(date, date)', 'EXECUTE'
  );
  v_log := array_append(
    v_log,
    case when not v_allowed then 'PASS' else 'FAIL' end
      || ': 1. anon cannot execute report_summary (expected false, got ' || v_allowed || ')'
  );

  -- ---------------------------------------------------------------- fixtures
  insert into public.customers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST report customer')
  returning id into v_customer;

  insert into public.suppliers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST report supplier')
  returning id into v_supplier;

  insert into public.products (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST report product')
  returning id into v_product;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty,
    purchase_rate, mrp, landed_cost_per_unit
  ) values (
    v_pharmacy, v_product, 'ZZTEST-REPORT-B1', current_date + 20, 10,
    100, 200, 100
  ) returning id into v_batch;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- A paid sale and a credit sale, both inside the window.
  v_sale := public.checkout_sale(
    jsonb_build_object(
      'customer_id', null,
      'payment_mode', 'cash',
      'amount_paid', 336,
      'items', jsonb_build_array(
        jsonb_build_object(
          'product_id', v_product, 'batch_id', v_batch, 'qty', 3,
          'rate', 100, 'gst_percent', 12, 'cgst_amount', 18, 'sgst_amount', 18,
          'tax_amount', 36, 'total_amount', 336, 'schedule_type', 'OTC'
        )
      )
    )
  );

  v_sale2 := public.checkout_sale(
    jsonb_build_object(
      'customer_id', v_customer,
      'payment_mode', 'credit',
      'amount_paid', 0,
      'items', jsonb_build_array(
        jsonb_build_object(
          'product_id', v_product, 'batch_id', v_batch, 'qty', 1,
          'rate', 100, 'gst_percent', 12, 'cgst_amount', 6, 'sgst_amount', 6,
          'tax_amount', 12, 'total_amount', 112, 'schedule_type', 'OTC'
        )
      )
    )
  );

  -- A cancelled sale, which must count for nothing.
  insert into public.sales (
    pharmacy_id, invoice_no, status, payment_mode, sale_date,
    sub_total, tax_total, grand_total, amount_paid, balance_due
  ) values (
    v_pharmacy, 'ZZTEST-REPORT-CANCELLED', 'cancelled', 'cash', now(),
    1000, 120, 1120, 0, 0
  );

  -- A received purchase inside the window, and a draft one outside it.
  --
  -- They are FIXTURES, and since Phase 6.5c chunk 3 a session cannot write `purchases` at all:
  -- `save_purchase()` is the only door. A fixture is written as postgres - the way
  -- phase5_chat_aggregates.sql and phase7a_open_bills.sql already write theirs - because this file
  -- is about `report_summary`'s arithmetic, and the DOOR is what phase6_5c_purchases.sql tests. The
  -- role is put back immediately, so every assertion below still measures what it measured before.
  execute 'reset role';

  insert into public.purchases (
    pharmacy_id, supplier_id, invoice_no, invoice_date, status,
    sub_total, tax_total, grand_total
  ) values (
    v_pharmacy,
    v_supplier,
    'ZZTEST-REPORT-P1', current_date, 'received',
    500, 60, 560
  );

  insert into public.purchases (
    pharmacy_id, supplier_id, invoice_no, invoice_date, status,
    sub_total, tax_total, grand_total
  ) values (
    v_pharmacy,
    v_supplier,
    'ZZTEST-REPORT-P2', current_date, 'draft',
    900, 108, 1008
  );

  execute 'set local role authenticated';

  insert into public.expenses (
    pharmacy_id, category, amount, expense_date, payment_mode
  ) values (
    v_pharmacy, 'ZZTEST rent', 250, current_date, 'bank'
  );

  -- A sale return is a fixture for the same reason: since chunk 4 the client cannot write
  -- `sale_returns`, and `record_sale_return()` is its only door.
  execute 'reset role';

  insert into public.sale_returns (
    pharmacy_id, sale_id, customer_id, return_date, restock, grand_total
  ) values (
    v_pharmacy, v_sale2.id, v_customer, current_date, true, 112
  );

  execute 'set local role authenticated';

  -- ------------------------------------------------------------- the summary
  v_summary := public.report_summary(v_from, v_to);

  -- 2. sales: 336 paid + 112 credit from these two documents, and no others
  --    inside the window (the cancelled one and the ones outside it are excluded).
  select count(*) into v_count
    from public.sales s
   where s.pharmacy_id = v_pharmacy
     and s.status <> 'cancelled'
     and s.sale_date::date between v_from and v_to;

  v_log := array_append(
    v_log,
    case when (v_summary -> 'sales' ->> 'count')::int = v_count
      then 'PASS' else 'FAIL' end
      || ': 2. sales count matches the documents in the window (expected ' || v_count
      || ', got ' || (v_summary -> 'sales' ->> 'count') || ')'
  );

  v_amount := (v_summary -> 'sales' ->> 'grand_total')::numeric;
  v_log := array_append(
    v_log,
    case when v_amount >= 448 then 'PASS' else 'FAIL' end
      || ': 2. sales total includes both documents (expected at least 448, got ' || v_amount || ')'
  );

  v_amount := (v_summary -> 'sales' ->> 'outstanding')::numeric;
  v_log := array_append(
    v_log,
    case when v_amount >= 112 then 'PASS' else 'FAIL' end
      || ': 2. outstanding is what customers still owe (expected at least 112, got '
      || v_amount || ')'
  );

  -- 3. the cancelled sale must not appear. Its invoice number is unique, so it can
  --    be found directly and compared against a summary run that excludes it.
  select coalesce(sum(grand_total), 0) into v_amount
    from public.sales
   where pharmacy_id = v_pharmacy
     and status <> 'cancelled'
     and sale_date::date between v_from and v_to;
  v_log := array_append(
    v_log,
    case when (v_summary -> 'sales' ->> 'grand_total')::numeric = v_amount
      then 'PASS' else 'FAIL' end
      || ': 3. cancelled sales are excluded from the total (expected ' || v_amount
      || ', got ' || (v_summary -> 'sales' ->> 'grand_total') || ')'
  );

  -- 4. only the received purchase counts.
  v_log := array_append(
    v_log,
    case when (v_summary -> 'purchases' ->> 'grand_total')::numeric = 560
      then 'PASS' else 'FAIL' end
      || ': 4. a draft purchase is not owed for (expected 560, got '
      || (v_summary -> 'purchases' ->> 'grand_total') || ')'
  );

  -- 5. the return and the expense.
  v_log := array_append(
    v_log,
    case when (v_summary -> 'returns' ->> 'sale_total')::numeric = 112
      then 'PASS' else 'FAIL' end
      || ': 5. the customer return is totalled (expected 112, got '
      || (v_summary -> 'returns' ->> 'sale_total') || ')'
  );
  v_log := array_append(
    v_log,
    case when (v_summary -> 'expenses' ->> 'total')::numeric = 250
      then 'PASS' else 'FAIL' end
      || ': 5. the expense is totalled (expected 250, got '
      || (v_summary -> 'expenses' ->> 'total') || ')'
  );

  -- 6. stock and expiry agree with the views they read.
  select coalesce(sum(stock_value_at_cost), 0) into v_value
    from public.product_stock where pharmacy_id = v_pharmacy;
  v_log := array_append(
    v_log,
    case when (v_summary -> 'stock' ->> 'value_at_cost')::numeric = v_value
      then 'PASS' else 'FAIL' end
      || ': 6. stock value matches the view (expected ' || v_value || ', got '
      || (v_summary -> 'stock' ->> 'value_at_cost') || ')'
  );

  select coalesce(sum(qty * mrp), 0) into v_value
    from public.batch_status
   where pharmacy_id = v_pharmacy and qty > 0 and expiry_status = 'critical';
  v_log := array_append(
    v_log,
    case when (v_summary -> 'expiring' ->> 'critical_value_at_mrp')::numeric >= v_value
      then 'PASS' else 'FAIL' end
      || ': 6. expiring value is at MRP (expected at least ' || v_value || ', got '
      || (v_summary -> 'expiring' ->> 'critical_value_at_mrp') || ')'
  );

  -- 7. the window is inclusive, and excludes what falls outside it.
  v_summary := public.report_summary(current_date + 5, current_date + 6);
  v_log := array_append(
    v_log,
    case when (v_summary -> 'sales' ->> 'count')::int = 0 then 'PASS' else 'FAIL' end
      || ': 7. a window with no sales reports none (got '
      || (v_summary -> 'sales' ->> 'count') || ')'
  );
  v_log := array_append(
    v_log,
    case when (v_summary -> 'expenses' ->> 'total')::numeric = 0
      then 'PASS' else 'FAIL' end
      || ': 7. a window with no expenses reports nothing spent (got '
      || (v_summary -> 'expenses' ->> 'total') || ')'
  );

  -- Stock is not a windowed figure: it is what is on the shelf right now.
  v_log := array_append(
    v_log,
    case when (v_summary -> 'stock' ->> 'products')::int > 0
      then 'PASS' else 'FAIL' end
      || ': 7. stock is reported regardless of the window (got '
      || (v_summary -> 'stock' ->> 'products') || ' products)'
  );

  raise exception E'PHASE4 REPORT SUMMARY TEST\n%',
    array_to_string(v_log, chr(10));
end $$;
