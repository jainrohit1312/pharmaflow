-- Phase 3 sale automation - functional test for migration
-- 20260918000019_phase3_sale_automation.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase3_sale_triggers.sql
--
-- HOW TO READ THE RESULT
--   The evidence comes back in the error message: every line is either
--   "PASS: ..." or "FAIL: ...". A non-zero exit code is expected and means the
--   script ran to completion, not that it failed.
--
-- WHY IT ENDS WITH RAISE EXCEPTION
--   Everything runs inside one DO block, which is one statement and therefore
--   one implicit transaction. Raising at the end (the only way to abort a DO
--   block) rolls every test row back, so this file is safe to run against the
--   hosted project and leaves no residue: no ZZTEST product, batch, customer,
--   sale, return, ledger entry or audit row. A failing assertion still rolls
--   back; the line just says FAIL.
--
-- IMPERSONATION
--   `checkout_sale()` and `next_sale_invoice_no()` take the tenant from
--   `get_my_pharmacy_id()`, which resolves `auth.uid()`. Running as `postgres`
--   there is no tenant identity at all, so this file impersonates the real owner
--   profile the way profile_privileges.sql does: set the JWT claims, switch to
--   the `authenticated` role, and check that the scope resolves. The first
--   assertion proves the refusal when it does not.
--
-- WHAT IT PROVES
--   1.  checkout_sale refuses to run with no tenant identity, and the counter
--       function is callable by authenticated but not by anon.
--   2.  next_sale_invoice_no() hands out distinct, formatted numbers.
--   3.  checkout_sale rejects an empty cart.
--   4.  A walk-in cash sale (no customer) succeeds, moves stock, and posts no
--       ledger row and no payment - there is no party to post against.
--   5.  A customer's cash sale posts the receivable AND the counter settlement,
--       so the party's ledger nets to zero instead of standing in debt.
--   6.  A credit sale is posted at sale time (the shipped gate would have left
--       it unposted), with balance_due on the document.
--   7.  A sale with an unpaid balance and no customer is refused.
--   8.  The header's money is the sum of its lines, never a client figure.
--   9.  Overselling is refused by check_violation AND leaves nothing behind:
--       no sale row, no ledger row, and the batch untouched - the whole checkout
--       is one transaction.
--   10. A line naming another pharmacy's batch is refused.
--   11. A cancelled sale never moves stock and never posts.
--   12. A sale return restocks only when restock is true, and credits the
--       customer either way.
--   13. The audit trail records inserts, updates and deletes.
--   14. invoice_counters is unreachable from a client session (RLS, no policy).

do $$
declare
  -- An array of lines rather than one concatenated string: `||` yields NULL if
  -- any operand is NULL, so a single unexpected NULL would have replaced the
  -- whole report with "<NULL>" - which is exactly what happened the first time
  -- this file ran. Appending to an array cannot lose the lines already collected.
  v_log            text[] := array[]::text[];
  v_pharmacy       uuid;
  v_user           uuid;
  v_customer       uuid;
  v_product        uuid;
  v_batch          uuid;
  v_batch2         uuid;
  v_other_pharmacy uuid;
  v_other_product  uuid;
  v_other_batch    uuid;
  v_sale           public.sales;
  v_sale_id        uuid;
  v_return_id      uuid;
  v_invoice_1      text;
  v_invoice_2      text;
  v_qty            int;
  v_qty_before     int;
  v_rows           int;
  v_amount         numeric;
  v_balance        numeric;
  v_status         public.sale_status;
  v_outcome        text;
  v_allowed        boolean;
  v_audit          int;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE3 TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user
    from public.profiles
   where pharmacy_id = v_pharmacy
   order by created_at
   limit 1;
  if v_user is null then
    raise exception 'PHASE3 TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- ---------------------------------------------------------------- fixtures
  -- As postgres, so RLS is not in the way of setting the scene.
  insert into public.customers (pharmacy_id, name, phone)
  values (v_pharmacy, 'ZZTEST customer 00019', '9000000000')
  returning id into v_customer;

  insert into public.products (pharmacy_id, name, pack_size, hsn_code)
  values (v_pharmacy, 'ZZTEST sale product 00019', '10 tab', '3004')
  returning id into v_product;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product, 'ZZTEST-SALE-B1', current_date + 365, 100, 100, 200
  ) returning id into v_batch;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product, 'ZZTEST-SALE-B2', current_date + 400, 50, 90, 180
  ) returning id into v_batch2;

  -- A second tenant, to prove the definer function cannot be handed someone
  -- else's batch.
  insert into public.pharmacies (name)
  values ('ZZTEST pharmacy 00019')
  returning id into v_other_pharmacy;

  insert into public.products (pharmacy_id, name)
  values (v_other_pharmacy, 'ZZTEST foreign product 00019')
  returning id into v_other_product;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_other_pharmacy, v_other_product, 'ZZTEST-FOREIGN-B1', current_date + 365, 10, 10, 20
  ) returning id into v_other_batch;

  -- ------------------------------------------------- 1. the scope is required
  v_outcome := 'FAIL: 1. checkout_sale ran with no tenant identity';
  begin
    perform public.checkout_sale('{"items": []}'::jsonb);
  exception when insufficient_privilege then
    v_outcome := 'PASS: 1. checkout_sale refuses to run without a tenant identity';
  end;
  v_log := array_append(v_log, v_outcome || chr(10));

  v_allowed := has_function_privilege(
    'authenticated', 'public.checkout_sale(jsonb)', 'EXECUTE'
  );
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated can execute checkout_sale (expected true, got ' || v_allowed || ')' || chr(10));

  v_allowed := has_function_privilege(
    'anon', 'public.checkout_sale(jsonb)', 'EXECUTE'
  );
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. anon cannot execute checkout_sale (expected false, got ' || v_allowed || ')' || chr(10));

  v_allowed := has_function_privilege(
    'authenticated', 'public.next_sale_invoice_no()', 'EXECUTE'
  );
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated can execute next_sale_invoice_no (expected true, got ' || v_allowed || ')' || chr(10));

  -- --------------------------------------------------- behave as the user
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- The counter table is reachable only through its definer function.
  select count(*) into v_rows from public.invoice_counters;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 14. invoice_counters is hidden from a client session (expected 0 rows, got ' || v_rows || ')' || chr(10));

  -- ------------------------------------------------------- 2. invoice numbers
  v_invoice_1 := public.next_sale_invoice_no();
  v_invoice_2 := public.next_sale_invoice_no();
  v_log := array_append(v_log, case when v_invoice_1 <> v_invoice_2 then 'PASS' else 'FAIL' end
    || ': 2. invoice numbers advance (got ' || v_invoice_1 || ' then ' || v_invoice_2 || ')' || chr(10));
  v_log := array_append(v_log, case when v_invoice_1 ~ '^SL[0-9]{6}-[0-9]{4}$' then 'PASS' else 'FAIL' end
    || ': 2. invoice number is formatted (got ' || v_invoice_1 || ')' || chr(10));

  -- ------------------------------------------------------------ 3. empty cart
  v_outcome := 'FAIL: 3. an empty cart was written as a sale';
  begin
    perform public.checkout_sale('{"items": []}'::jsonb);
  exception when check_violation then
    v_outcome := 'PASS: 3. checkout_sale rejects an empty cart';
  end;
  v_log := array_append(v_log, v_outcome || chr(10));

  -- ------------------------------------------- 4. a walk-in, cash, no party
  -- 3 units at 100 with 12% GST: 300 taxable, 36 tax, 336 total.
  v_sale := public.checkout_sale(
    jsonb_build_object(
      'customer_id', null,
      'payment_mode', 'cash',
      'amount_paid', 336,
      'place_of_supply', 'Maharashtra',
      'items', jsonb_build_array(
        jsonb_build_object(
          'product_id', v_product,
          'batch_id', v_batch,
          'qty', 3,
          'rate', 100,
          'discount_percent', 0,
          'discount_amount', 0,
          'gst_percent', 12,
          'cgst_amount', 18,
          'sgst_amount', 18,
          'igst_amount', 0,
          'tax_amount', 36,
          'total_amount', 336,
          'schedule_type', 'OTC'
        )
      )
    )
  );
  v_sale_id := v_sale.id;

  v_log := array_append(v_log, case when v_sale.status = 'completed' then 'PASS' else 'FAIL' end
    || ': 4. a paid walk-in sale is completed (got ' || v_sale.status || ')' || chr(10));
  v_log := array_append(v_log, case when v_sale.grand_total = 336.00 and v_sale.sub_total = 300.00
                              and v_sale.tax_total = 36.00 and v_sale.balance_due = 0.00
                         then 'PASS' else 'FAIL' end
    || ': 4. header money is summed from the lines (got sub ' || v_sale.sub_total
    || ' / tax ' || v_sale.tax_total || ' / grand ' || v_sale.grand_total
    || ' / due ' || v_sale.balance_due || ')' || chr(10));
  v_log := array_append(v_log, case when v_sale.invoice_no is not null and v_sale.invoice_no <> ''
                         then 'PASS' else 'FAIL' end
    || ': 4. the sale was numbered (got ' || coalesce(v_sale.invoice_no, 'NULL') || ')' || chr(10));

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := array_append(v_log, case when v_qty = 97 then 'PASS' else 'FAIL' end
    || ': 4. a sale decrements its batch (expected 97, got ' || v_qty || ')' || chr(10));

  select count(*) into v_rows from public.ledger_entries
   where reference_type = 'sale' and reference_id = v_sale_id;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 4. a sale with no customer posts no receivable (expected 0 rows, got ' || v_rows || ')' || chr(10));

  select count(*) into v_rows from public.payments
   where pharmacy_id = v_pharmacy and reference_no = v_sale.invoice_no;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 4. a sale with no customer writes no payment (expected 0 rows, got ' || v_rows || ')' || chr(10));

  -- ------------------------- 5. a customer's cash sale nets to zero, not debt
  v_sale := public.checkout_sale(
    jsonb_build_object(
      'customer_id', v_customer,
      'payment_mode', 'cash',
      'amount_paid', 336,
      'items', jsonb_build_array(
        jsonb_build_object(
          'product_id', v_product,
          'batch_id', v_batch,
          'qty', 3,
          'rate', 100,
          'discount_percent', 0,
          'discount_amount', 0,
          'gst_percent', 12,
          'cgst_amount', 18,
          'sgst_amount', 18,
          'igst_amount', 0,
          'tax_amount', 36,
          'total_amount', 336,
          'schedule_type', 'OTC'
        )
      )
    )
  );

  select count(*), coalesce(sum(debit), 0) into v_rows, v_amount
    from public.ledger_entries
   where reference_type = 'sale' and reference_id = v_sale.id;
  v_log := array_append(v_log, case when v_rows = 1 and v_amount = 336.00 then 'PASS' else 'FAIL' end
    || ': 5. a customer sale posts one receivable (expected 1 row / 336 debit, got '
    || v_rows || ' row(s) / ' || v_amount || ')' || chr(10));

  select count(*) into v_rows from public.payments
   where pharmacy_id = v_pharmacy and customer_id = v_customer
     and reference_no = v_sale.invoice_no;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 5. the counter settlement is recorded as a payment (expected 1 row, got ' || v_rows || ')' || chr(10));

  -- The whole point of the added ledger credit: a customer-attached cash sale
  -- must not leave a receivable standing forever.
  select coalesce(sum(debit) - sum(credit), 0) into v_balance
    from public.ledger_entries
   where pharmacy_id = v_pharmacy
     and party_type = 'customer'
     and customer_id = v_customer;
  v_log := array_append(v_log, case when v_balance = 0.00 then 'PASS' else 'FAIL' end
    || ': 5. a paid sale leaves no standing receivable (expected balance 0, got ' || v_balance || ')' || chr(10));

  -- ------------------------------------------------ 6. a credit sale is posted
  v_sale := public.checkout_sale(
    jsonb_build_object(
      'customer_id', v_customer,
      'payment_mode', 'credit',
      'amount_paid', 100,
      'items', jsonb_build_array(
        jsonb_build_object(
          'product_id', v_product,
          'batch_id', v_batch2,
          'qty', 1,
          'rate', 100,
          'discount_percent', 0,
          'discount_amount', 0,
          'gst_percent', 12,
          'cgst_amount', 6,
          'sgst_amount', 6,
          'igst_amount', 0,
          'tax_amount', 12,
          'total_amount', 112,
          'schedule_type', 'H'
        )
      )
    )
  );

  v_log := array_append(v_log, case when v_sale.status = 'credit' then 'PASS' else 'FAIL' end
    || ': 6. an unpaid sale is a credit sale (got ' || v_sale.status || ')' || chr(10));
  v_log := array_append(v_log, case when v_sale.balance_due = 12.00 then 'PASS' else 'FAIL' end
    || ': 6. balance_due is what is left (expected 12.00, got ' || v_sale.balance_due || ')' || chr(10));

  select count(*) into v_rows from public.ledger_entries
   where reference_type = 'sale' and reference_id = v_sale.id;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 6. a credit sale posts its receivable at sale time (expected 1 row, got ' || v_rows || ')' || chr(10));

  select count(*) into v_rows from public.ledger_entries
   where reference_type = 'payment' and reference_id in (
     select id from public.payments
      where pharmacy_id = v_pharmacy and reference_no = v_sale.invoice_no
   );
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 6. the part that was paid posts a settlement (expected 1 row, got ' || v_rows || ')' || chr(10));

  -- The schedule snapshot is what the statutory register reports on.
  select count(*) into v_rows from public.sale_items
   where sale_id = v_sale.id and schedule_type = 'H';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 6. the line carries its schedule snapshot (expected 1 H line, got ' || v_rows || ')' || chr(10));

  -- -------------------------------------- 7. no customer cannot owe anything
  v_outcome := 'FAIL: 7. an unpaid sale with no customer was written';
  begin
    perform public.checkout_sale(
      jsonb_build_object(
        'customer_id', null,
        'payment_mode', 'credit',
        'amount_paid', 0,
        'items', jsonb_build_array(
          jsonb_build_object(
            'product_id', v_product, 'batch_id', v_batch, 'qty', 1,
            'rate', 100, 'gst_percent', 12, 'tax_amount', 12, 'total_amount', 112,
            'schedule_type', 'OTC'
          )
        )
      )
    );
  exception when check_violation then
    v_outcome := 'PASS: 7. a sale with an unpaid balance needs a customer';
  end;
  v_log := array_append(v_log, v_outcome || chr(10));

  -- ----------------------------------- 8. header is the sum of its own lines
  -- Tendered exactly: a sale cannot be paid more than its bill (asserted below),
  -- because the change a cashier hands back is not a payment.
  v_sale := public.checkout_sale(
    jsonb_build_object(
      'customer_id', null,
      'payment_mode', 'cash',
      'amount_paid', 217,
      'items', jsonb_build_array(
        jsonb_build_object(
          'product_id', v_product, 'batch_id', v_batch, 'qty', 1,
          'rate', 100, 'gst_percent', 12, 'cgst_amount', 6, 'sgst_amount', 6,
          'tax_amount', 12, 'total_amount', 112, 'schedule_type', 'OTC'
        ),
        jsonb_build_object(
          'product_id', v_product, 'batch_id', v_batch2, 'qty', 2,
          'rate', 50, 'gst_percent', 5, 'cgst_amount', 2.5, 'sgst_amount', 2.5,
          'tax_amount', 5, 'total_amount', 105, 'schedule_type', 'H1'
        )
      )
    )
  );

  v_log := array_append(v_log, case when v_sale.grand_total = 217.00 and v_sale.tax_total = 17.00
                              and v_sale.sub_total = 200.00
                         then 'PASS' else 'FAIL' end
    || ': 8. a two-line sale totals its lines (expected 200 / 17 / 217, got '
    || v_sale.sub_total || ' / ' || v_sale.tax_total || ' / ' || v_sale.grand_total || ')' || chr(10));

  select coalesce(sum(total_amount), 0), count(*) into v_amount, v_rows
    from public.sale_items where sale_id = v_sale.id;
  v_log := array_append(v_log, case when v_amount = v_sale.grand_total and v_rows = 2 then 'PASS' else 'FAIL' end
    || ': 8. the stored lines add up to the stored header (lines ' || v_amount
    || ' over ' || v_rows || ' rows vs header ' || v_sale.grand_total || ')' || chr(10));

  -- `amount_paid` beyond the total is not a balance in the other direction, and
  -- it is not a payment either: the change a cashier hands back is not revenue.
  v_outcome := 'FAIL: 8. an overpayment was recorded as a negative balance';
  begin
    perform public.checkout_sale(
      jsonb_build_object(
        'customer_id', v_customer,
        'payment_mode', 'cash',
        'amount_paid', 5000,
        'items', jsonb_build_array(
          jsonb_build_object(
            'product_id', v_product, 'batch_id', v_batch, 'qty', 1,
            'rate', 100, 'gst_percent', 12, 'tax_amount', 12, 'total_amount', 112,
            'schedule_type', 'OTC'
          )
        )
      )
    );
  exception when check_violation then
    v_outcome := 'PASS: 8. tendering more than the bill is refused';
  end;
  v_log := array_append(v_log, v_outcome || chr(10));

  -- ------------------------------------------- 9. oversell writes nothing
  select qty into v_qty_before from public.product_batches where id = v_batch2;
  v_outcome := 'FAIL: 9. overselling was allowed';
  begin
    perform public.checkout_sale(
      jsonb_build_object(
        'customer_id', null,
        'payment_mode', 'cash',
        'amount_paid', 100000,
        'items', jsonb_build_array(
          jsonb_build_object(
            'product_id', v_product, 'batch_id', v_batch2, 'qty', v_qty_before + 999,
            'rate', 100, 'gst_percent', 12, 'tax_amount', 12, 'total_amount', 112,
            'schedule_type', 'OTC'
          )
        )
      )
    );
  exception when check_violation then
    v_outcome := 'PASS: 9. overselling is refused with check_violation';
  end;
  v_log := array_append(v_log, v_outcome || chr(10));

  -- Compared against the balance before the attempt, not a hand-computed number:
  -- the property is "a refused checkout moved nothing", and every earlier case in
  -- this file has already moved stock.
  select qty into v_qty from public.product_batches where id = v_batch2;
  v_log := array_append(v_log, case when v_qty = v_qty_before then 'PASS' else 'FAIL' end
    || ': 9. a refused checkout leaves the batch untouched (expected ' || v_qty_before
    || ', got ' || v_qty || ')' || chr(10));

  select count(*) into v_rows from public.ledger_entries
   where pharmacy_id = v_pharmacy and reference_type = 'sale'
     and reference_id not in (select id from public.sales);
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 9. a refused checkout leaves no orphan ledger row (expected 0, got ' || v_rows || ')' || chr(10));

  -- ------------------------------------------------ 10. cross-tenant refusal
  v_outcome := 'FAIL: 10. a line naming another pharmacy''s batch was written';
  begin
    perform public.checkout_sale(
      jsonb_build_object(
        'customer_id', null,
        'payment_mode', 'cash',
        'amount_paid', 100,
        'items', jsonb_build_array(
          jsonb_build_object(
            'product_id', v_other_product, 'batch_id', v_other_batch, 'qty', 1,
            'rate', 10, 'gst_percent', 0, 'tax_amount', 0, 'total_amount', 10,
            'schedule_type', 'OTC'
          )
        )
      )
    );
  exception when check_violation then
    v_outcome := 'PASS: 10. a foreign batch or product is refused';
  end;
  v_log := array_append(v_log, v_outcome || chr(10));

  select qty into v_qty from public.product_batches where id = v_other_batch;
  v_log := array_append(v_log, case when v_qty = 10 then 'PASS' else 'FAIL' end
    || ': 10. the other tenant''s batch is untouched (expected 10, got ' || v_qty || ')' || chr(10));

  execute 'reset role';

  -- ------------------------------------------ 11. a cancelled sale moves nothing
  -- Re-read: `v_qty_before` still holds batch 2's balance from section 9.
  select qty into v_qty_before from public.product_batches where id = v_batch;

  insert into public.sales (
    pharmacy_id, customer_id, invoice_no, status, payment_mode,
    sub_total, tax_total, grand_total, amount_paid, balance_due
  ) values (
    v_pharmacy, v_customer, 'ZZTEST-CANCELLED-00019', 'cancelled', 'cash',
    0, 0, 0, 0, 0
  ) returning id into v_sale_id;

  insert into public.sale_items (
    pharmacy_id, sale_id, product_id, batch_id, qty, rate, gst_percent,
    tax_amount, total_amount, schedule_type
  ) values (
    v_pharmacy, v_sale_id, v_product, v_batch, 5, 100, 12, 60, 560, 'OTC'
  );

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := array_append(v_log, case when v_qty = v_qty_before then 'PASS' else 'FAIL' end
    || ': 11. a cancelled sale takes no stock (expected ' || v_qty_before
    || ', got ' || v_qty || ')' || chr(10));

  select count(*) into v_rows from public.ledger_entries
   where reference_id = v_sale_id;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 11. a cancelled sale posts nothing (expected 0 rows, got ' || v_rows || ')' || chr(10));

  -- ------------------------------------------------ 12. sale returns
  -- Every assertion here is relative to the balance as this section finds it:
  -- the batch has been through sale cases 4, 5 and 8 already.
  select qty into v_qty_before from public.product_batches where id = v_batch;

  -- 2 units back, resellable: stock goes up and the customer is credited.
  insert into public.sale_returns (
    pharmacy_id, sale_id, customer_id, reason, restock, grand_total
  ) values (
    v_pharmacy, v_sale_id, v_customer, 'ZZTEST not needed', true, 224
  ) returning id into v_return_id;

  insert into public.sale_return_items (
    pharmacy_id, sale_return_id, product_id, batch_id, qty, rate,
    gst_percent, tax_amount, total_amount
  ) values (
    v_pharmacy, v_return_id, v_product, v_batch, 2, 100, 12, 24, 224
  );

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := array_append(v_log, case when v_qty = v_qty_before + 2 then 'PASS' else 'FAIL' end
    || ': 12. a resellable return restocks the batch (expected ' || (v_qty_before + 2)
    || ', got ' || v_qty || ')' || chr(10));

  select count(*), coalesce(sum(credit), 0) into v_rows, v_amount
    from public.ledger_entries
   where reference_type = 'sale_return' and reference_id = v_return_id;
  v_log := array_append(v_log, case when v_rows = 1 and v_amount = 224.00 then 'PASS' else 'FAIL' end
    || ': 12. a return credits the customer (expected 1 row / 224 credit, got '
    || v_rows || ' row(s) / ' || v_amount || ')' || chr(10));

  v_qty_before := v_qty;

  -- 3 units back that cannot be resold: paperwork and credit, no shelf.
  insert into public.sale_returns (
    pharmacy_id, sale_id, customer_id, reason, restock, grand_total
  ) values (
    v_pharmacy, v_sale_id, v_customer, 'ZZTEST damaged', false, 112
  ) returning id into v_return_id;

  insert into public.sale_return_items (
    pharmacy_id, sale_return_id, product_id, batch_id, qty, rate,
    gst_percent, tax_amount, total_amount
  ) values (
    v_pharmacy, v_return_id, v_product, v_batch, 3, 100, 12, 36, 336
  );

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := array_append(v_log, case when v_qty = v_qty_before then 'PASS' else 'FAIL' end
    || ': 12. an unsellable return restocks nothing (expected ' || v_qty_before
    || ', got ' || v_qty || ')' || chr(10));

  select count(*) into v_rows from public.ledger_entries
   where reference_type = 'sale_return' and reference_id = v_return_id;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 12. an unsellable return is still credited (expected 1 row, got ' || v_rows || ')' || chr(10));

  -- A walk-in's return has nobody to credit, and must not fail on the check.
  insert into public.sale_returns (
    pharmacy_id, sale_id, customer_id, reason, restock, grand_total
  ) values (
    v_pharmacy, v_sale_id, null, 'ZZTEST walk-in', true, 50
  ) returning id into v_return_id;

  insert into public.sale_return_items (
    pharmacy_id, sale_return_id, product_id, batch_id, qty, rate,
    gst_percent, tax_amount, total_amount
  ) values (
    v_pharmacy, v_return_id, v_product, v_batch, 1, 50, 0, 0, 50
  );

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := array_append(v_log, case when v_qty = v_qty_before + 1 then 'PASS' else 'FAIL' end
    || ': 12. a walk-in return still restocks (expected ' || (v_qty_before + 1)
    || ', got ' || v_qty || ')' || chr(10));

  select count(*) into v_rows from public.ledger_entries
   where reference_type = 'sale_return' and reference_id = v_return_id;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 12. a walk-in return posts nothing (expected 0 rows, got ' || v_rows || ')' || chr(10));

  -- --------------------------------------------------------- 13. the audit log
  select count(*) into v_audit from public.audit_logs
   where pharmacy_id = v_pharmacy and table_name = 'sales'
     and record_id = v_sale_id and action = 'INSERT';
  v_log := array_append(v_log, case when v_audit = 1 then 'PASS' else 'FAIL' end
    || ': 13. the audit log records a sale insert (expected 1 row, got ' || v_audit || ')' || chr(10));

  update public.sales set place_of_supply = 'ZZTEST state' where id = v_sale_id;

  select count(*) into v_audit from public.audit_logs
   where pharmacy_id = v_pharmacy and table_name = 'sales'
     and record_id = v_sale_id and action = 'UPDATE';
  v_log := array_append(v_log, case when v_audit = 1 then 'PASS' else 'FAIL' end
    || ': 13. the audit log records an update (expected 1 row, got ' || v_audit || ')' || chr(10));

  -- The DELETE branch, exercised on a table that is safe to delete from.
  declare
    v_adjustment uuid;
  begin
    insert into public.stock_adjustments (
      pharmacy_id, product_id, batch_id, adjustment_type, qty, reason
    ) values (
      v_pharmacy, v_product, v_batch, 'increase', 1, 'ZZTEST audit'
    ) returning id into v_adjustment;

    delete from public.stock_adjustments where id = v_adjustment;

    select count(*) into v_audit from public.audit_logs
     where pharmacy_id = v_pharmacy and table_name = 'stock_adjustments'
       and record_id = v_adjustment and action = 'DELETE';
    v_log := array_append(v_log, case when v_audit = 1 then 'PASS' else 'FAIL' end
      || ': 13. the audit log records a delete (expected 1 row, got ' || v_audit || ')' || chr(10));
  end;

  -- ------------------------------------------------------------------- report
  raise exception E'PHASE3 SALE/LEDGER TRIGGER TEST\n%',
    array_to_string(v_log, chr(10));
end $$;
