-- Phase 2 automation layer - functional test for migrations
-- 20260918000015_phase2_extras and 20260918000016_landed_cost.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase2_stock_triggers.sql
--
-- HOW TO READ THE RESULT
--   The evidence comes back in the error message: every line is either
--   "PASS: ..." or "FAIL: ...". A non-zero exit code is expected and means the
--   script ran to completion, not that it failed.
--
-- WHY IT ENDS WITH RAISE EXCEPTION
--   The whole exercise runs inside one DO block, which is one statement and
--   therefore one implicit transaction. Raising at the end (the only way to
--   abort a DO block) rolls every test row back, so this file is safe to run
--   against the hosted project and leaves no residue: no test product, no test
--   supplier, no test purchase, no test ledger entry. If any assertion fails
--   the script still rolls back - the failing line just says FAIL.
--
-- WHAT IT PROVES
--   1.  Draft/ordered purchase lines never move stock.
--   2.  Reaching 'received' applies qty + free_qty exactly once.
--   3.  Reaching 'received' posts exactly one supplier ledger row (credit).
--   4.  Moving back out of 'received' does NOT reverse stock.
--   5.  Re-entering 'received' does not post a second time (no double count).
--   6.  A line added to an already-received document still moves stock once.
--   7.  A stock adjustment moves its batch and is refused if it would go negative.
--   8.  A product-level adjustment (no batch) is recorded without moving stock.
--   9.  A purchase return moves stock down and is refused on oversell.
--   10. The stock-posting marker is stamped on receipt and never cleared.
--   11. Landed cost spreads the paid amount over paid + free units, and stock
--       value uses it rather than the purchase rate (1000, not 1200).
--   12. A second receipt into the same batch is weighted, not overwritten.

do $$
declare
  v_log          text := '';
  v_pharmacy     uuid;
  v_supplier     uuid;
  v_product      uuid;
  v_batch        uuid;
  v_purchase     uuid;
  v_qty          int;
  v_marker       timestamptz;
  v_ledger_rows  int;
  v_ledger_credit numeric;
  v_landed       numeric;
  v_value        numeric;
  v_product2     uuid;
  v_batch2       uuid;
  v_purchase2    uuid;
  v_purchase3    uuid;
  v_outcome      text;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE2 TEST ABORTED: no pharmacy row exists to test against';
  end if;

  -- ---------------------------------------------------------------- fixtures
  insert into public.suppliers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST supplier 00015')
  returning id into v_supplier;

  insert into public.products (pharmacy_id, name, pack_size)
  values (v_pharmacy, 'ZZTEST product 00015', '10 tab')
  returning id into v_product;

  -- The GRN contract: the batch row exists first, created at qty = 0, so the
  -- trigger increments are the only writes to the balance.
  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product, 'ZZTEST-BATCH-00015', current_date + 365, 0, 100, 200
  ) returning id into v_batch;

  -- ------------------------------------------------------------------- 1
  insert into public.purchases (
    pharmacy_id, supplier_id, invoice_no, status, grand_total
  ) values (
    v_pharmacy, v_supplier, 'ZZTEST-INV-00015', 'draft', 1000
  ) returning id into v_purchase;

  -- 10 paid at 100 plus 2 scheme units: 1000 of cost behind 12 units.
  insert into public.purchase_items (
    pharmacy_id, purchase_id, product_id, batch_id,
    qty, free_qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_purchase, v_product, v_batch,
    10, 2, 100, 200
  );

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := v_log || case when v_qty = 0 then 'PASS' else 'FAIL' end
    || ': 1. draft line does not move stock (expected qty 0, got ' || v_qty || ')' || chr(10);

  select stock_posted_at into v_marker from public.purchases where id = v_purchase;
  v_log := v_log || case when v_marker is null then 'PASS' else 'FAIL' end
    || ': 1. draft document is unposted (stock_posted_at expected NULL, got ' || coalesce(v_marker::text, 'NULL') || ')' || chr(10);

  -- ------------------------------------------------------------------- 2/3
  update public.purchases set status = 'received' where id = v_purchase;

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := v_log || case when v_qty = 12 then 'PASS' else 'FAIL' end
    || ': 2. receipt applies qty + free_qty (expected 12, got ' || v_qty || ')' || chr(10);

  select stock_posted_at into v_marker from public.purchases where id = v_purchase;
  v_log := v_log || case when v_marker is not null then 'PASS' else 'FAIL' end
    || ': 10. marker stamped on receipt (expected non-NULL, got ' || coalesce(v_marker::text, 'NULL') || ')' || chr(10);

  select count(*), coalesce(sum(credit), 0) into v_ledger_rows, v_ledger_credit
    from public.ledger_entries
   where reference_type = 'purchase' and reference_id = v_purchase;
  v_log := v_log || case when v_ledger_rows = 1 and v_ledger_credit = 1000 then 'PASS' else 'FAIL' end
    || ': 3. one supplier ledger row credited with grand_total (expected 1 row / 1000, got '
    || v_ledger_rows || ' row(s) / ' || v_ledger_credit || ')' || chr(10);

  -- ------------------------------------------------------------------- 11
  -- 10 paid at 100 over 12 units -> 83.3333, so 12 units are worth 1000.00.
  select landed_cost_per_unit into v_landed
    from public.product_batches where id = v_batch;
  v_log := v_log || case when abs(v_landed - 83.3333) <= 0.0001 then 'PASS' else 'FAIL' end
    || ': 11. landed cost spreads cost over paid + free units (expected 83.3333, got ' || v_landed || ')' || chr(10);

  select stock_value_at_cost into v_value
    from public.product_stock where product_id = v_product;
  v_log := v_log || case when v_value = 1000.00 then 'PASS' else 'FAIL' end
    || ': 11. stock value uses landed cost, not purchase rate (expected 1000.00 not 1200.00, got ' || v_value || ')' || chr(10);

  -- ------------------------------------------------------------------- 4
  update public.purchases set status = 'draft' where id = v_purchase;
  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := v_log || case when v_qty = 12 then 'PASS' else 'FAIL' end
    || ': 4. reverting status does not reverse stock (expected qty still 12, got ' || v_qty || ')' || chr(10);

  -- ------------------------------------------------------------------- 5
  update public.purchases set status = 'received' where id = v_purchase;
  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := v_log || case when v_qty = 12 then 'PASS' else 'FAIL' end
    || ': 5. re-receiving does not double count (expected qty still 12, got ' || v_qty || ')' || chr(10);

  select count(*) into v_ledger_rows from public.ledger_entries
   where reference_type = 'purchase' and reference_id = v_purchase;
  v_log := v_log || case when v_ledger_rows = 1 then 'PASS' else 'FAIL' end
    || ': 5. re-receiving does not double post (expected 1 ledger row, got ' || v_ledger_rows || ')' || chr(10);

  -- ------------------------------------------------------------------- 6
  insert into public.purchase_items (
    pharmacy_id, purchase_id, product_id, batch_id,
    qty, free_qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_purchase, v_product, v_batch,
    1, 0, 100, 200
  );

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := v_log || case when v_qty = 13 then 'PASS' else 'FAIL' end
    || ': 6. line added to a received document moves stock once (expected 13, got ' || v_qty || ')' || chr(10);

  -- ------------------------------------------------------------------- 7
  insert into public.stock_adjustments (
    pharmacy_id, product_id, batch_id, adjustment_type, qty, reason
  ) values (
    v_pharmacy, v_product, v_batch, 'decrease', 5, 'ZZTEST breakage'
  );

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := v_log || case when v_qty = 8 then 'PASS' else 'FAIL' end
    || ': 7. decrease adjustment applies (expected 8, got ' || v_qty || ')' || chr(10);

  v_outcome := 'FAIL: 7. decrease below zero was allowed';
  begin
    insert into public.stock_adjustments (
      pharmacy_id, product_id, batch_id, adjustment_type, qty, reason
    ) values (
      v_pharmacy, v_product, v_batch, 'decrease', 100, 'ZZTEST oversell'
    );
  exception when check_violation then
    v_outcome := 'PASS: 7. decrease below zero rejected with check_violation';
  end;
  v_log := v_log || v_outcome || chr(10);

  insert into public.stock_adjustments (
    pharmacy_id, product_id, batch_id, adjustment_type, qty, reason
  ) values (
    v_pharmacy, v_product, v_batch, 'increase', 2, 'ZZTEST found stock'
  );

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := v_log || case when v_qty = 10 then 'PASS' else 'FAIL' end
    || ': 7. increase adjustment applies (expected 10, got ' || v_qty || ')' || chr(10);

  -- ------------------------------------------------------------------- 8
  insert into public.stock_adjustments (
    pharmacy_id, product_id, batch_id, adjustment_type, qty, reason
  ) values (
    v_pharmacy, v_product, null, 'decrease', 4, 'ZZTEST product-level note'
  );

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := v_log || case when v_qty = 10 then 'PASS' else 'FAIL' end
    || ': 8. product-level adjustment is recorded without moving stock (expected 10, got ' || v_qty || ')' || chr(10);

  -- ------------------------------------------------------------------- 9
  declare
    v_return uuid;
  begin
    insert into public.purchase_returns (
      pharmacy_id, purchase_id, supplier_id, reason
    ) values (
      v_pharmacy, v_purchase, v_supplier, 'ZZTEST damaged'
    ) returning id into v_return;

    insert into public.purchase_return_items (
      pharmacy_id, purchase_return_id, product_id, batch_id,
      qty, purchase_rate, mrp
    ) values (
      v_pharmacy, v_return, v_product, v_batch, 3, 100, 200
    );

    select qty into v_qty from public.product_batches where id = v_batch;
    v_log := v_log || case when v_qty = 7 then 'PASS' else 'FAIL' end
      || ': 9. purchase return decrements stock (expected 7, got ' || v_qty || ')' || chr(10);

    v_outcome := 'FAIL: 9. return oversell was allowed';
    begin
      insert into public.purchase_return_items (
        pharmacy_id, purchase_return_id, product_id, batch_id,
        qty, purchase_rate, mrp
      ) values (
        v_pharmacy, v_return, v_product, v_batch, 999, 100, 200
      );
    exception when check_violation then
      v_outcome := 'PASS: 9. return oversell rejected with check_violation';
    end;
    v_log := v_log || v_outcome || chr(10);
  end;

  -- ------------------------------------------------------------------- 12
  -- A second receipt into the SAME batch must average, not overwrite: the units
  -- already on hand keep their basis, and the new units bring their own.
  insert into public.products (pharmacy_id, name, pack_size)
  values (v_pharmacy, 'ZZTEST product 00016', '10 tab')
  returning id into v_product2;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product2, 'ZZTEST-BATCH-00016', current_date + 365, 0, 100, 200
  ) returning id into v_batch2;

  insert into public.purchases (
    pharmacy_id, supplier_id, invoice_no, status, grand_total
  ) values (
    v_pharmacy, v_supplier, 'ZZTEST-INV-00016-A', 'received', 1000
  ) returning id into v_purchase2;

  insert into public.purchase_items (
    pharmacy_id, purchase_id, product_id, batch_id,
    qty, free_qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_purchase2, v_product2, v_batch2,
    10, 2, 100, 200
  );

  select landed_cost_per_unit into v_landed
    from public.product_batches where id = v_batch2;
  v_log := v_log || case when abs(v_landed - 83.3333) <= 0.0001 then 'PASS' else 'FAIL' end
    || ': 12. first receipt sets the landed cost (expected 83.3333, got ' || v_landed || ')' || chr(10);

  insert into public.purchases (
    pharmacy_id, supplier_id, invoice_no, status, grand_total
  ) values (
    v_pharmacy, v_supplier, 'ZZTEST-INV-00016-B', 'received', 100
  ) returning id into v_purchase3;

  insert into public.purchase_items (
    pharmacy_id, purchase_id, product_id, batch_id,
    qty, free_qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_purchase3, v_product2, v_batch2,
    1, 0, 100, 200
  );

  select qty, landed_cost_per_unit into v_qty, v_landed
    from public.product_batches where id = v_batch2;
  v_log := v_log || case when v_qty = 13 then 'PASS' else 'FAIL' end
    || ': 12. second receipt adds to the same batch (expected qty 13, got ' || v_qty || ')' || chr(10);

  -- 1000 + 100 = 1100 of cost over 13 units. Overwriting instead of averaging
  -- would leave 13 x 100 = 1300, which is the number that must not appear.
  select stock_value_at_cost into v_value
    from public.product_stock where product_id = v_product2;
  v_log := v_log || case when v_value = 1100.00 then 'PASS' else 'FAIL' end
    || ': 12. second receipt is weighted, not overwritten (expected cost basis 1100.00 not 1300.00, got ' || v_value || ')' || chr(10);

  -- ------------------------------------------------------------------- report
  raise exception E'PHASE2 STOCK/LEDGER TRIGGER TEST\n%', v_log;
end $$;
