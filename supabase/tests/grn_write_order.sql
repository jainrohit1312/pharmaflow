-- GRN WRITE ORDER TEST - the exact sequence the app's receive() performs.
--
-- Run:
--   supabase db query --linked --file supabase/tests/grn_write_order.sql
--
-- The point of this file is the *order* and the *payload shapes*, not the
-- triggers on their own (those are covered by phase2_stock_triggers.sql). It
-- reproduces what the Dart repository sends:
--
--   1. product_batches upserted on (pharmacy_id, product_id, batch_no) WITHOUT
--      qty - which in PostgREST is `resolution=merge-duplicates`, i.e. exactly
--      the ON CONFLICT DO UPDATE below, setting only the columns in the payload;
--   2. purchase_items replaced wholesale by rows carrying their batch_id and
--      their share of the tax, as `_replaceLines` builds them;
--   3. purchases updated with its totals AND status='received' in one statement,
--      because the ledger trigger reads grand_total off the row it is handed.
--
-- Every assertion is PASS/FAIL. The script ends by raising, so it rolls back: it
-- leaves no supplier, purchase, batch, item or ledger row behind.

do $$
declare
  v_log        text := '';
  v_pharmacy   uuid;
  v_supplier   uuid;
  v_product    uuid;
  v_purchase   uuid;
  v_batch      uuid;
  v_batch2     uuid;
  v_qty        int;
  v_landed     numeric;
  v_marker     timestamptz;
  v_credit     numeric;
  v_rows       int;
  v_line_tax   numeric;
  v_line_split numeric;
  v_sum_total  numeric;
  v_sum_tax    numeric;
  v_outcome    text;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'GRN TEST ABORTED: no pharmacy row to test against';
  end if;

  -- ---------------------------------------------------------------- fixtures
  insert into public.suppliers (pharmacy_id, name)
  values (v_pharmacy, 'ZZGRN supplier') returning id into v_supplier;

  insert into public.products (pharmacy_id, name, pack_size)
  values (v_pharmacy, 'ZZGRN product', '10 tab') returning id into v_product;

  -- A draft purchase with one line and no batch: a draft creates none.
  insert into public.purchases (
    pharmacy_id, supplier_id, invoice_no, invoice_date, status, grand_total
  ) values (
    v_pharmacy, v_supplier, 'ZZGRN-INV-1', current_date, 'draft', 0
  ) returning id into v_purchase;

  insert into public.purchase_items (
    pharmacy_id, purchase_id, product_id, qty, free_qty, purchase_rate, mrp,
    gst_percent
  ) values (
    v_pharmacy, v_purchase, v_product, 10, 2, 100, 200, 12
  );

  select qty into v_qty
    from public.product_batches
   where pharmacy_id = v_pharmacy and product_id = v_product;
  v_log := v_log || case when v_qty is null then 'PASS' else 'FAIL' end
    || ': a draft creates no batch (expected none, found qty '
    || coalesce(v_qty::text, 'NULL') || ')' || chr(10);

  -- ------------------------------------- step 1: batches, without qty
  -- This is what `upsert(..., onConflict: 'pharmacy_id,product_id,batch_no')`
  -- becomes. `qty` is absent from the column list, which is the whole trick.
  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, mfg_date,
    purchase_rate, mrp, selling_rate
  ) values (
    v_pharmacy, v_product, 'ZZGRN-B1', current_date + 365, current_date,
    100, 200, 200
  )
  on conflict (pharmacy_id, product_id, batch_no) do update
    set expiry_date = excluded.expiry_date,
        mfg_date = excluded.mfg_date,
        purchase_rate = excluded.purchase_rate,
        mrp = excluded.mrp,
        selling_rate = excluded.selling_rate
  returning id into v_batch;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product, 'ZZGRN-B2', current_date + 200, 50, 100
  )
  returning id into v_batch2;

  select qty, landed_cost_per_unit into v_qty, v_landed
    from public.product_batches where id = v_batch;
  v_log := v_log || case when v_qty = 0 then 'PASS' else 'FAIL' end
    || ': a new batch starts at zero before receipt (expected 0, got ' || v_qty || ')' || chr(10);
  v_log := v_log || case when v_landed is null then 'PASS' else 'FAIL' end
    || ': a new batch has no landed cost before receipt (expected NULL, got '
    || coalesce(v_landed::text, 'NULL') || ')' || chr(10);

  -- ------------------------ step 2: lines replaced, carrying money and batch_id
  -- `_replaceLines` deletes first, then inserts rows shaped like these. Line 1:
  -- 10 paid + 2 free at 100, 12% GST. Line 2: 4 paid at 50, 12% GST.
  delete from public.purchase_items where purchase_id = v_purchase;

  insert into public.purchase_items (
    pharmacy_id, purchase_id, product_id, batch_id, product_name_raw, batch_no,
    expiry_date, qty, free_qty, purchase_rate, mrp, selling_rate,
    discount_percent, gst_percent, cgst_amount, sgst_amount, igst_amount,
    tax_amount, total_amount
  ) values
    (v_pharmacy, v_purchase, v_product, v_batch, 'ZZGRN product', 'ZZGRN-B1',
     current_date + 365, 10, 2, 100, 200, 200, 0, 12, 60, 60, 0, 120, 1120),
    (v_pharmacy, v_purchase, v_product, v_batch2, 'ZZGRN product', 'ZZGRN-B2',
     current_date + 200, 4, 0, 50, 100, 100, 0, 12, 12, 12, 0, 24, 224);

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := v_log || case when v_qty = 0 then 'PASS' else 'FAIL' end
    || ': writing lines before receipt moves nothing (expected 0, got ' || v_qty || ')' || chr(10);

  -- ------------------------------------- step 3: totals + status together
  update public.purchases
     set sub_total = 1200,
         discount_total = 0,
         tax_total = 144,
         grand_total = 1344,
         status = 'received'
   where id = v_purchase;

  select qty, landed_cost_per_unit into v_qty, v_landed
    from public.product_batches where id = v_batch;
  v_log := v_log || case when v_qty = 12 then 'PASS' else 'FAIL' end
    || ': receipt applies qty + free_qty (expected 12, got ' || v_qty || ')' || chr(10);
  v_log := v_log || case when abs(v_landed - 83.3333) <= 0.0001 then 'PASS' else 'FAIL' end
    || ': receipt sets the landed cost (expected 83.3333, got '
    || coalesce(v_landed::text, 'NULL') || ')' || chr(10);

  select qty into v_qty from public.product_batches where id = v_batch2;
  v_log := v_log || case when v_qty = 4 then 'PASS' else 'FAIL' end
    || ': every line of the receipt is applied, not just the first (expected 4, got '
    || v_qty || ')' || chr(10);

  select stock_posted_at into v_marker from public.purchases where id = v_purchase;
  v_log := v_log || case when v_marker is not null then 'PASS' else 'FAIL' end
    || ': receipt stamps the posting marker' || chr(10);

  select count(*), coalesce(sum(credit), 0) into v_rows, v_credit
    from public.ledger_entries
   where reference_type = 'purchase' and reference_id = v_purchase;
  v_log := v_log || case when v_rows = 1 and v_credit = 1344 then 'PASS' else 'FAIL' end
    || ': the ledger posts the grand total from the SAME statement as the status '
    || '(expected 1 row / 1344, got ' || v_rows || ' / ' || v_credit || ')' || chr(10);

  -- ------------------------- the invariant that crosses tables
  -- The header's totals and its lines are written by two different statements, so
  -- nothing in the database keeps them agreeing: this is what catches a client
  -- that computes one of them differently.
  select sum(total_amount), sum(tax_amount) into v_sum_total, v_sum_tax
    from public.purchase_items where purchase_id = v_purchase;
  v_log := v_log || case when v_sum_total = 1344 then 'PASS' else 'FAIL' end
    || ': the lines add up to the document grand total (expected 1344, got '
    || v_sum_total || ')' || chr(10);
  v_log := v_log || case when v_sum_tax = 144 then 'PASS' else 'FAIL' end
    || ': the lines add up to the document tax total (expected 144, got '
    || v_sum_tax || ')' || chr(10);

  select tax_amount, cgst_amount + sgst_amount + igst_amount
    into v_line_tax, v_line_split
    from public.purchase_items
   where purchase_id = v_purchase and batch_no = 'ZZGRN-B1';
  v_log := v_log || case when v_line_tax = 120 and v_line_split = 120 then 'PASS' else 'FAIL' end
    || ': a line stores a tax its split adds up to (tax ' || v_line_tax
    || ', split ' || v_line_split || ')' || chr(10);

  -- ------------------------------------- the re-receipt trap
  -- A second GRN naming the same batch runs the same upsert. If `qty` were in the
  -- payload this would zero a batch holding 12 units, and no trigger would put
  -- them back.
  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, mfg_date,
    purchase_rate, mrp, selling_rate
  ) values (
    v_pharmacy, v_product, 'ZZGRN-B1', current_date + 400, current_date,
    110, 220, 220
  )
  on conflict (pharmacy_id, product_id, batch_no) do update
    set expiry_date = excluded.expiry_date,
        mfg_date = excluded.mfg_date,
        purchase_rate = excluded.purchase_rate,
        mrp = excluded.mrp,
        selling_rate = excluded.selling_rate
  returning id into v_batch2;

  select qty into v_qty from public.product_batches where id = v_batch;
  v_log := v_log || case when v_qty = 12 then 'PASS' else 'FAIL' end
    || ': a repeat upsert of the same batch does NOT reset its stock '
    || '(expected 12, got ' || v_qty || ')' || chr(10);
  v_log := v_log || case when v_batch2 = v_batch then 'PASS' else 'FAIL' end
    || ': the repeat upsert resolves to the same batch row' || chr(10);

  -- ------------------------------------- why validateLines() exists
  -- Two payload rows naming one batch are refused by Postgres outright, so the
  -- repository rejects that line set before it ever gets here.
  v_outcome := 'FAIL: the database allowed two payload rows for one batch';
  begin
    insert into public.product_batches (
      pharmacy_id, product_id, batch_no, expiry_date, purchase_rate, mrp
    ) values
      (v_pharmacy, v_product, 'ZZGRN-B9', current_date + 365, 10, 20),
      (v_pharmacy, v_product, 'ZZGRN-B9', current_date + 365, 10, 20)
    on conflict (pharmacy_id, product_id, batch_no) do update
      set purchase_rate = excluded.purchase_rate;
  exception
    when others then
      v_outcome := 'PASS: two payload rows for one batch are refused ('
        || sqlstate || ')';
  end;
  v_log := v_log || v_outcome || chr(10);

  raise exception E'GRN WRITE ORDER TEST\n%', v_log;
end $$;
