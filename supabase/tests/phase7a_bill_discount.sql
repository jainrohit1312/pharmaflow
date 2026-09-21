-- Phase 7a bill discount - functional test for migration 20260921000042.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase7a_bill_discount.sql
--
-- COUNTING
--   The last line reads "<n> PASS / <m> FAIL of <k> assertions", where k counts assertion lines
--   only, and the self-check on the line above it asserts that every logged line is a PASS or a
--   FAIL. The self-check is itself one of the counted assertions, because it is one. This file
--   follows phase7a_sale_types.sql and phase7a_sale_document.sql, not the older files that count
--   the summary line itself into their total.
--
-- HOW TO READ THE RESULT
--   The evidence comes back in the error message: every line is either "PASS: ..." or
--   "FAIL: ...", and the last line counts them. A non-zero exit code is expected and means the
--   script ran to completion, not that it failed. Every FAIL that concerns a refusal prints the
--   message the server actually raised, so a wrong sentence diagnoses itself.
--
-- WHY IT ENDS WITH RAISE EXCEPTION
--   The whole file is one DO block, which is one statement and therefore one implicit
--   transaction. Raising at the end rolls every fixture back, so it is safe against the hosted
--   project and leaves no residue.
--
-- IMPERSONATION
--   `checkout_sale` takes its tenant from `get_my_pharmacy_id()`, which resolves `auth.uid()`.
--   The fixtures are written as the owner first (RLS not in the way), then the session becomes the
--   seeded owner profile - JWT claims set, role switched to `authenticated` - the way
--   phase3_sale_triggers.sql and phase7a_sale_document.sql do it.
--
-- WHAT IT PROVES
--   1.  The owner's own example, on a two-line bill whose tax-inclusive total is 546: a discount
--       of 46 leaves 500 to pay, the discount is shared 17.69 / 28.31, and the tax is extracted
--       from each line's DISCOUNTED inclusive total - 9.16 at 5% and 32.97 at 12%.
--   2.  `discount_total` is the owner's own 46.00 - the figure the receipt prints - and
--       `sub_total + tax_total = grand_total` still holds, because the header is the sum of the
--       rebuilt lines.
--   3.  The four tax heads still add back to the tax charged.
--   4.  The shares add back to the rupee EXACTLY: 0.07 across three lines comes to 0.01 / 0.02 /
--       0.04, with the last line absorbing the remainder.
--   5.  A payload that names no discount - and one that names a zero - is priced exactly as it was
--       before this migration.
--   6.  Exactly 10% of the bill is allowed; a paisa above it is refused with the counter's own
--       sentence, naming the approval workflow that does not exist.
--   7.  A discount larger than the bill is refused, and by its own message rather than the cap's.
--   8.  A negative discount is refused.
--   9.  A package sale and a transfer refuse a bill discount outright - they have no discount
--       concept (D-067, D-071).
--   10. The legacy seam is untouched: an untyped payload's figures are stored verbatim and a
--       `bill_discount` key on it is left alone, exactly as every other unknown key is.
--   11. A line's OWN discount and the bill's share are both in `sale_items.discount_amount`, so
--       the header stays the sum of the lines (21.00 + 9.00 = 30.00).
--   12. `sales_payment_check` still refuses a sale paid beyond its discounted total, and an
--       idempotency key still returns the original sale rather than a second one.
--   13. The assertion count is the assertions - and every logged line is a PASS or a FAIL, so a
--       skipped or truncated check cannot hide behind the arithmetic.

do $$
declare
  v_log           text[] := array[]::text[];
  v_pharmacy      uuid;
  v_user          uuid;
  v_product_a     uuid;
  v_product_b     uuid;
  v_product_c     uuid;
  v_product_d     uuid;
  v_batch_a       uuid;
  v_batch_b       uuid;
  v_batch_c       uuid;
  v_batch_d       uuid;
  v_hospital_acct uuid;
  v_patient       public.customers;
  v_sale          public.sales;
  v_sale2         public.sales;
  v_line_a        public.sale_items;
  v_line_c        public.sale_items;
  v_msg           text;
  v_sum           numeric;
  v_cgst_sum      numeric;
  v_sgst_sum      numeric;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE7A BILL DISCOUNT TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user
    from public.profiles
   where pharmacy_id = v_pharmacy
   order by created_at
   limit 1;
  if v_user is null then
    raise exception 'PHASE7A BILL DISCOUNT TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------ fixtures
  -- As postgres, so RLS is not in the way of setting the scene.
  --
  -- Four packs, one per slab the test needs: 5% (the common counter slab), 12%, a second 5% pack
  -- with round MRPs for the three-line remainder, and a 0% pack whose recorded zero must survive
  -- a discount. The MRPs are the line rates this test charges, because a retail rate may not
  -- exceed MRP.
  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 42 five percent', 5)
  returning id into v_product_a;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product_a, 'ZZTEST-42-A', current_date + 365, 1000, 80, 105
  ) returning id into v_batch_a;

  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 42 twelve percent', 12)
  returning id into v_product_b;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product_b, 'ZZTEST-42-B', current_date + 365, 1000, 120, 168
  ) returning id into v_batch_b;

  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 42 remainder', 5)
  returning id into v_product_c;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product_c, 'ZZTEST-42-C', current_date + 365, 1000, 80, 100
  ) returning id into v_batch_c;

  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 42 zero slab', 0)
  returning id into v_product_d;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product_d, 'ZZTEST-42-D', current_date + 365, 1000, 40, 60
  ) returning id into v_batch_d;

  -- The hospital's own account row, which is the debtor on a package sale (D-067).
  insert into public.customers (pharmacy_id, name, phone)
  values (v_pharmacy, 'ZZTEST 42 hospital account', '9000000041')
  returning id into v_hospital_acct;

  -- A package sale is priced at cost plus this markup, so it has to be configured for the
  -- package case below to reach the DISCOUNT refusal rather than the markup one.
  update public.pharmacies p set package_markup_percent = 20 where p.id = v_pharmacy;

  -- ------------------------------------------------- behave as the owner
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  v_patient := public.save_patient(
    p_name => 'ZZTEST 42 patient',
    p_mobile => '9000000040'
  );

  -- ============================================ 1-3. the owner's own example: 546 -> 46 -> 500
  -- Two lines, 2 x 105 at 5% and 2 x 168 at 12%, so the bill's tax-inclusive total is 546.00.
  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'amount_paid', 500,
    'bill_discount', 46,
    'items', jsonb_build_array(
      jsonb_build_object('product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 2, 'rate', 105),
      jsonb_build_object('product_id', v_product_b, 'batch_id', v_batch_b, 'qty', 2, 'rate', 168)
    )
  ));

  select * into v_line_a
    from public.sale_items si
   where si.sale_id = v_sale.id and si.rate = 105;

  -- 210 of the 546 is the 5% line, so its share is 210 x 46 / 546 = 17.69 (and the 12% line takes
  -- the remainder, 28.31), and its discounted inclusive total is 192.31 - from which the tax is
  -- EXTRACTED: 192.31 / 1.05 = 183.15 taxable, leaving 9.16 of tax.
  v_log := array_append(v_log, case
    when v_line_a.discount_amount = 17.69 and v_line_a.total_amount = 192.31 then 'PASS' else 'FAIL' end
    || ': 1. the 5% line takes its share of the discount and its discounted total '
    || '(got discount ' || v_line_a.discount_amount || ', total ' || v_line_a.total_amount || ')');

  v_log := array_append(v_log, case
    when v_line_a.tax_amount = 9.16 then 'PASS' else 'FAIL' end
    || ': 1. and its tax is extracted from the DISCOUNTED total, not the original'
    || ' (expected 9.16, got ' || v_line_a.tax_amount || ')');

  select * into v_line_a
    from public.sale_items si
   where si.sale_id = v_sale.id and si.rate = 168;

  v_log := array_append(v_log, case
    when v_line_a.discount_amount = 28.31 and v_line_a.total_amount = 307.69
     and v_line_a.tax_amount = 32.97 then 'PASS' else 'FAIL' end
    || ': 1. the 12% line takes the remainder, 28.31, and 307.69 of it is 274.72 + 32.97 GST '
    || '(got discount ' || v_line_a.discount_amount || ', total ' || v_line_a.total_amount
    || ', tax ' || v_line_a.tax_amount || ')');

  v_log := array_append(v_log, case
    when v_sale.grand_total = 500.00 then 'PASS' else 'FAIL' end
    || ': 1. a bill of 546 less 46 is 500 to pay (got ' || v_sale.grand_total || ')');

  -- The receipt's `Discount -Rs 46.00` line is the STORED figure, and it is the sum of the lines'
  -- discounts rather than the payload's number copied onto the header.
  v_log := array_append(v_log, case
    when v_sale.discount_total = 46.00 then 'PASS' else 'FAIL' end
    || ': 2. discount_total is the owner''s own 46.00 (got ' || v_sale.discount_total || ')');

  v_log := array_append(v_log, case
    when v_sale.tax_total = 42.13 and v_sale.sub_total = 457.87 then 'PASS' else 'FAIL' end
    || ': 2. the taxable value and the tax come off 500, not off 546 (got taxable '
    || v_sale.sub_total || ', tax ' || v_sale.tax_total || ')');

  v_log := array_append(v_log, case
    when v_sale.sub_total + v_sale.tax_total = v_sale.grand_total then 'PASS' else 'FAIL' end
    || ': 2. sub_total + tax_total = grand_total still holds ('
    || v_sale.sub_total || ' + ' || v_sale.tax_total || ' vs ' || v_sale.grand_total || ')');

  select coalesce(sum(si.total_amount), 0), coalesce(sum(si.cgst_amount), 0),
         coalesce(sum(si.sgst_amount), 0)
    into v_sum, v_cgst_sum, v_sgst_sum
    from public.sale_items si
   where si.sale_id = v_sale.id;

  v_log := array_append(v_log, case
    when v_sum = v_sale.grand_total then 'PASS' else 'FAIL' end
    || ': 2. the stored lines still add up to the header (lines ' || v_sum || ' vs grand '
    || v_sale.grand_total || ')');

  -- The rounded half first, then the remainder (D-057): 9.16 -> 4.58/4.58, 32.97 -> 16.49/16.48.
  v_log := array_append(v_log, case
    when v_cgst_sum + v_sgst_sum = v_sale.tax_total then 'PASS' else 'FAIL' end
    || ': 3. the two heads add back to the tax charged ('
    || v_cgst_sum || ' + ' || v_sgst_sum || ' vs ' || v_sale.tax_total || ')');

  v_log := array_append(v_log, case
    when v_sale.balance_due = 0.00 then 'PASS' else 'FAIL' end
    || ': 3. the 500 settles the bill rather than leaving a balance (got '
    || v_sale.balance_due || ')');

  -- A zero-slab line keeps its zero: the discount moves money, not the slab.
  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'amount_paid', 54,
    'bill_discount', 6,
    'items', jsonb_build_array(
      jsonb_build_object('product_id', v_product_d, 'batch_id', v_batch_d, 'qty', 1, 'rate', 60)
    )
  ));

  v_log := array_append(v_log, case
    when v_sale2.grand_total = 54.00 and v_sale2.tax_total = 0.00
     and v_sale2.discount_total = 6.00 then 'PASS' else 'FAIL' end
    || ': 1. a recorded zero slab still means zero tax under a bill discount (got grand '
    || v_sale2.grand_total || ', tax ' || v_sale2.tax_total || ')');

  -- ============================================= 4. the shares add to the rupee exactly
  -- Three lines of 10.00, 20.00 and 30.00 and a discount of seven paise. Seven is not divisible
  -- by three in proportion, so this is the case the "last line absorbs the remainder" rule exists
  -- for: 10 x 0.07/60 = 0.0116... -> 0.01, 20 x 0.07/60 = 0.0233... -> 0.02, and the last line
  -- takes the remaining 0.04 rather than its own 0.03.
  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'amount_paid', 59.93,
    'bill_discount', 0.07,
    'items', jsonb_build_array(
      jsonb_build_object('product_id', v_product_c, 'batch_id', v_batch_c, 'qty', 1, 'rate', 10),
      jsonb_build_object('product_id', v_product_c, 'batch_id', v_batch_c, 'qty', 1, 'rate', 20),
      jsonb_build_object('product_id', v_product_c, 'batch_id', v_batch_c, 'qty', 1, 'rate', 30)
    )
  ));

  select count(*) into v_sum
    from public.sale_items si
   where si.sale_id = v_sale.id and si.discount_amount in (0.01, 0.02, 0.04);

  v_log := array_append(v_log, case when v_sum = 3 then 'PASS' else 'FAIL' end
    || ': 4. the three shares are 0.01, 0.02 and 0.04 exactly (expected 3 such lines, got '
    || v_sum || ')');

  select * into v_line_c
    from public.sale_items si
   where si.sale_id = v_sale.id and si.rate = 30;

  v_log := array_append(v_log, case
    when v_line_c.discount_amount = 0.04 then 'PASS' else 'FAIL' end
    || ': 4. the LAST line takes the rounding remainder rather than its own share (expected '
    || '0.04, got ' || v_line_c.discount_amount || ')');

  v_log := array_append(v_log, case
    when v_sale.discount_total = 0.07 then 'PASS' else 'FAIL' end
    || ': 4. and the shares add back to the rupee figure exactly (got '
    || v_sale.discount_total || ')');

  v_log := array_append(v_log, case
    when v_sale.grand_total = 59.93 and v_sale.sub_total + v_sale.tax_total = v_sale.grand_total
      then 'PASS' else 'FAIL' end
    || ': 4. the header still holds after a remainder split (grand ' || v_sale.grand_total
    || ', taxable ' || v_sale.sub_total || ', tax ' || v_sale.tax_total || ')');

  -- ============================================= 5. no discount, and a zero, are unchanged
  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'items', jsonb_build_array(
      jsonb_build_object('product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 2, 'rate', 105)
    )
  ));

  v_log := array_append(v_log, case
    when v_sale.grand_total = 210.00 and v_sale.sub_total = 200.00
     and v_sale.tax_total = 10.00 and v_sale.discount_total = 0.00 then 'PASS' else 'FAIL' end
    || ': 5. a payload that names no discount is priced exactly as before (got grand '
    || v_sale.grand_total || ', taxable ' || v_sale.sub_total || ', tax ' || v_sale.tax_total || ')');

  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'bill_discount', 0,
    'items', jsonb_build_array(
      jsonb_build_object('product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 2, 'rate', 105)
    )
  ));

  v_log := array_append(v_log, case
    when v_sale2.grand_total = v_sale.grand_total
     and v_sale2.tax_total = v_sale.tax_total
     and v_sale2.discount_total = 0.00 then 'PASS' else 'FAIL' end
    || ': 5. a named zero is the same bill as no discount at all (got '
    || v_sale2.grand_total || ')');

  -- ================================================= 6-8. the refusals
  -- Exactly 10% of the bill is allowed; the cap is a ceiling, not a prompt (D-071).
  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'amount_paid', 491.40,
    'bill_discount', 54.60,
    'items', jsonb_build_array(
      jsonb_build_object('product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 2, 'rate', 105),
      jsonb_build_object('product_id', v_product_b, 'batch_id', v_batch_b, 'qty', 2, 'rate', 168)
    )
  ));

  v_log := array_append(v_log, case
    when v_sale.grand_total = 491.40 and v_sale.discount_total = 54.60 then 'PASS' else 'FAIL' end
    || ': 6. a discount of exactly 10% of the bill is allowed (got grand '
    || v_sale.grand_total || ')');

  -- One paisa above it is refused, in the counter's own words. The whole sentence is asserted,
  -- because the brief's point is that the sentence stays TRUTHFUL rather than that it exists.
  v_msg := null;
  begin
    v_sale2 := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'bill_discount', 54.61,
      'items', jsonb_build_array(
        jsonb_build_object('product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 2, 'rate', 105),
        jsonb_build_object('product_id', v_product_b, 'batch_id', v_batch_b, 'qty', 2, 'rate', 168)
      )
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;

  v_log := array_append(v_log, case
    when v_msg = 'a discount above 10% of the bill needs the owner''s approval, and the approval workflow (Phase 6.5c) is not built yet - bill at 10% or less'
      then 'PASS' else 'FAIL' end
    || ': 6. a discount above the cap is refused with the counter''s sentence (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- More than the bill is a different, more fundamental error: the cap must not be the message a
  -- counter sees when the discount cannot come off the bill at all.
  v_msg := null;
  begin
    v_sale2 := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'bill_discount', 600,
      'items', jsonb_build_array(
        jsonb_build_object('product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 2, 'rate', 105),
        jsonb_build_object('product_id', v_product_b, 'batch_id', v_batch_b, 'qty', 2, 'rate', 168)
      )
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;

  v_log := array_append(v_log, case
    when v_msg = 'the discount of 600.00 is larger than the bill''s 546.00'
      then 'PASS' else 'FAIL' end
    || ': 7. a discount larger than the bill is refused, in its own words (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_sale2 := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'bill_discount', -5,
      'items', jsonb_build_array(
        jsonb_build_object('product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 2, 'rate', 105)
      )
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;

  v_log := array_append(v_log, case
    when v_msg = 'a discount cannot be negative' then 'PASS' else 'FAIL' end
    || ': 8. a negative discount is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  -- A package sale and a transfer have no discount concept (D-067, D-071), and the refusal is the
  -- same one their per-line discounts get.
  v_msg := null;
  begin
    v_sale2 := public.checkout_sale(jsonb_build_object(
      'sale_type', 'package',
      'customer_id', v_hospital_acct,
      'patient_name', 'ZZTEST 42 package patient',
      'patient_mobile', '9000000039',
      'hospital_reference', 'ZZTEST-42-PKG',
      'bill_discount', 1,
      'items', jsonb_build_array(
        jsonb_build_object('product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 1)
      )
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;

  v_log := array_append(v_log, case
    when v_msg = 'a package sale has no discount' then 'PASS' else 'FAIL' end
    || ': 9. a package sale refuses a bill discount (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_sale2 := public.checkout_sale(jsonb_build_object(
      'sale_type', 'transfer',
      'from_location', 'ZZTEST 42 main shelf',
      'to_location', 'ZZTEST 42 ward',
      'transfer_reason', 'ZZTEST 42 stock support',
      'bill_discount', 1,
      'items', jsonb_build_array(
        jsonb_build_object('product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 1)
      )
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;

  v_log := array_append(v_log, case
    when v_msg = 'a transfer sale has no discount' then 'PASS' else 'FAIL' end
    || ': 9. a transfer refuses a bill discount (got ' || coalesce(v_msg, 'NULL') || ')');

  -- ======================================================= 10. the legacy seam is untouched
  -- An untyped payload is the legacy counter sale, whose figures are stored verbatim. The key is
  -- ignored exactly as every other key the function does not know is, so this pins a decision
  -- rather than a coincidence: a legacy caller cannot take a bill discount.
  v_sale := public.checkout_sale(jsonb_build_object(
    'amount_paid', 100,
    'bill_discount', 46,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 1, 'rate', 100,
      'total_amount', 100, 'gst_percent', 5
    ))
  ));

  v_log := array_append(v_log, case
    when v_sale.grand_total = 100.00 and v_sale.discount_total = 0.00 then 'PASS' else 'FAIL' end
    || ': 10. an untyped payload stores its own figures verbatim, and ignores bill_discount '
    || '(got grand ' || v_sale.grand_total || ', discount ' || v_sale.discount_total || ')');

  -- ============================================ 11. a line's own discount plus the bill's share
  -- 2 x 105 at 5% with a 10% line discount is 189.00; a further 9.00 off the bill leaves 180.00,
  -- and the line's stored discount_amount is BOTH (21.00 + 9.00), which is what keeps the header's
  -- discount_total the sum of the lines.
  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'amount_paid', 180,
    'bill_discount', 9,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 2, 'rate', 105,
      'discount_percent', 10
    ))
  ));

  select * into v_line_a
    from public.sale_items si
   where si.sale_id = v_sale.id;

  v_log := array_append(v_log, case
    when v_line_a.discount_amount = 30.00 and v_line_a.discount_percent = 10.00
      then 'PASS' else 'FAIL' end
    || ': 11. a line''s own 21.00 and the bill''s 9.00 are both in discount_amount (got '
    || v_line_a.discount_amount || ')');

  v_log := array_append(v_log, case
    when v_sale.discount_total = 30.00 and v_sale.grand_total = 180.00
     and v_sale.tax_total = 8.57 then 'PASS' else 'FAIL' end
    || ': 11. and the header is the sum of the lines, with the tax off the discounted 180 '
    || '(got discount ' || v_sale.discount_total || ', grand ' || v_sale.grand_total
    || ', tax ' || v_sale.tax_total || ')');

  -- =========================================================== 12. the two guards that stand
  -- An over-payment is still refused, and it is the DISCOUNTED total it is measured against.
  v_msg := null;
  begin
    v_sale2 := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'amount_paid', 501,
      'bill_discount', 46,
      'items', jsonb_build_array(
        jsonb_build_object('product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 2, 'rate', 105),
        jsonb_build_object('product_id', v_product_b, 'batch_id', v_batch_b, 'qty', 2, 'rate', 168)
      )
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;

  v_log := array_append(v_log, case
    when v_msg like 'a sale cannot be paid more than its total (501.00 tendered for 500.00)%'
      then 'PASS' else 'FAIL' end
    || ': 12. sales_payment_check still refuses a sale paid beyond its discounted total (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- A retried submit is the same sale, discount and all.
  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'amount_paid', 500,
    'bill_discount', 46,
    'idempotency_key', 'zztest-42-idem-' || gen_random_uuid()::text,
    'items', jsonb_build_array(
      jsonb_build_object('product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 2, 'rate', 105),
      jsonb_build_object('product_id', v_product_b, 'batch_id', v_batch_b, 'qty', 2, 'rate', 168)
    )
  ));

  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'amount_paid', 500,
    'bill_discount', 0,
    'idempotency_key', v_sale.idempotency_key,
    'items', jsonb_build_array(
      jsonb_build_object('product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 2, 'rate', 105),
      jsonb_build_object('product_id', v_product_b, 'batch_id', v_batch_b, 'qty', 2, 'rate', 168)
    )
  ));

  v_log := array_append(v_log, case
    when v_sale2.id = v_sale.id and v_sale2.grand_total = 500.00
     and v_sale2.discount_total = 46.00 then 'PASS' else 'FAIL' end
    || ': 12. a retried submit returns the original discounted sale (got '
    || coalesce(v_sale2.id::text, 'NULL') || ' / ' || v_sale2.grand_total || ')');

  -- ================================================================ summary
  -- The count is the ASSERTIONS, not the log's length: the summary line itself is appended to the
  -- same array, and is not counted. The self-check below is what proves nothing is hidden by that
  -- arithmetic - a line that is neither a PASS nor a FAIL would fail it.
  v_log := array_append(v_log, case
    when (select count(*) from unnest(v_log) l
           where coalesce(l, '') not like 'PASS%'
             and coalesce(l, '') not like 'FAIL%') = 0
      then 'PASS' else 'FAIL' end
    || ': 13. every logged line is a PASS or a FAIL (nothing skipped, nothing truncated)');

  v_log := array_append(v_log, 'SUMMARY: '
    || (select count(*) from unnest(v_log) l where l like 'PASS%') || ' PASS / '
    || (select count(*) from unnest(v_log) l where l like 'FAIL%') || ' FAIL of '
    || (select count(*) from unnest(v_log) l
         where l like 'PASS%' or l like 'FAIL%') || ' assertions');

  raise exception E'PHASE7A BILL DISCOUNT TEST\n%', array_to_string(v_log, chr(10));
end $$;
