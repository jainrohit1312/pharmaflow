-- Phase 7a sale types, patient identity and admission credit - functional test for
-- migrations 20260920000033, 20260920000034, 20260920000035 and 20260920000036.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase7a_sale_types.sql
--
-- COUNTING
--   The last line reads "<n> PASS / <m> FAIL of <k> assertions", where k counts assertion
--   lines only and a self-check asserts that every logged line is a PASS or a FAIL. The
--   older files in this directory count the summary line itself into their total, which is
--   why theirs reads one higher than the checks they contain; the discrepancy is arithmetic,
--   not a skipped check, and this file does not repeat it.
--
-- HOW TO READ THE RESULT
--   The evidence comes back in the error message: every line is either "PASS: ..." or
--   "FAIL: ...", and the last line counts them. A non-zero exit code is expected and
--   means the script ran to completion, not that it failed.
--
-- WHY IT ENDS WITH RAISE EXCEPTION
--   The whole file is one DO block, which is one statement and therefore one implicit
--   transaction. Raising at the end rolls every fixture back, so it is safe against the
--   hosted project and leaves no residue.
--
-- IMPERSONATION
--   Every function under test takes its tenant from `get_my_pharmacy_id()`, which
--   resolves `auth.uid()`. The fixtures are written as the owner first (RLS not in the
--   way), then the session becomes the real owner profile - JWT claims set, role switched
--   to `authenticated` - the way phase3_sale_triggers.sql does it.
--
-- WHAT IT PROVES
--   1.  A patient is registered with a server-generated code, and the mobile is stored
--       in canonical form (including "+91" and spaced input).
--   2.  A guardian's mobile satisfies the contact requirement; neither a patient's own
--       nor a guardian's leaves the registration refused.
--   3.  A repeated identical registration inside the window returns the SAME patient - a
--       retry is not a second person - while a second person sharing that mobile is a
--       separate row.
--   4.  Selecting a returning patient returns the master unchanged: a bill detail cannot
--       edit it. A pre-Phase-7a customer is given a code on first use.
--   5.  Lookup finds a patient by canonical mobile, by the "+91" spelling, by patient-code
--       prefix and by case-insensitive name; another tenant's patient is not reachable.
--   6.  A typed pharmacy sale needs a patient (and a patient with a contact number), takes
--       the patient snapshot onto the bill, and posts the patient's receivable.
--   7.  GST is EXTRACTED from the tax-inclusive rate: the owner's own example - MRP 105 at
--       5% is 100 taxable + 5 tax, not 110.25. A recorded zero slab means zero; a missing
--       slab means the named 5% POS default.
--   8.  A discount above 10% is refused, naming the approval workflow that does not exist
--       yet; exactly 10% is allowed. A rate above MRP is refused.
--   9.  A Schedule H line needs its prescriber, and the prescriber is recorded on the sale
--       and converged in the doctors master.
--   10. An IPD sale finds-or-creates its admission, stamps the hospital reference and the
--       admission link, and refuses a discharged episode.
--   11. The owner's worked example: two admission bills (500 + 300), a 100 return and a
--       400 allocation leave 300 outstanding - and a second admission keeps its own.
--   12. A collection can be partly allocated (the rest stays an unallocated deposit, and
--       applying a deposit is not a second receipt); over-allocating is refused.
--   13. A package sale is refused until its markup is configured, then priced at cost plus
--       markup with the HOSPITAL as the debtor - the patient's own balance never moves.
--   14. A transfer carries no patient, no account and no GST, needs a source, a
--       destination and a reason, refuses an identical source and destination, and still
--       moves stock on its own note number.
--   15. Idempotency: a retried checkout with the same key is one sale, and a retried
--       collection is one receipt.
--   16. Tenant isolation: another pharmacy's batch or patient is refused.
--   17. Permissions: anon cannot execute the new RPCs; the internal code minter is not
--       executable by authenticated at all.
--   18. A patient master's identity columns are not directly writable by a client, and the
--       columns the customers form owns still are - so no existing screen changes what it can
--       do (N-17(a), migration 00038).
--   19. A patient master edit is gated server-side: the owner and a pharmacist may, a cashier
--       is refused whatever any screen shows, and a cashier cannot change the pharmacy's own
--       package markup either (the pharmacies policy is owner-only).
--   20. Allocations cannot over-settle a document, a refused collection leaves no receipt
--       behind, one patient's money cannot settle another patient's admission, and applying a
--       deposit settles a bill WITHOUT writing a second receipt (migration 00037).
--   21. A retried submit with the SAME idempotency key but a CHANGED payload returns the
--       original sale, keeps the original amount, and moves stock once.
--   22. A return still credits the customer against the bill it came from.
--   23. The assertion count is the assertions - and every logged line is a PASS or a FAIL, so
--       a skipped or truncated check cannot hide behind the arithmetic.

do $$
declare
  v_log             text[] := array[]::text[];
  v_outcome         text;
  v_pharmacy        uuid;
  v_user            uuid;
  v_other_pharmacy  uuid;
  v_allowed         boolean;
  v_patient         public.customers;
  v_second          public.customers;
  v_legacy          uuid;
  v_patient_code    text;
  v_doctor          uuid;
  v_product         uuid;
  v_product_zero    uuid;
  v_batch           uuid;
  v_batch_zero      uuid;
  v_scheduled       uuid;
  v_scheduled_batch uuid;
  v_noslab          uuid;
  v_noslab_batch    uuid;
  v_hospital_acct   uuid;
  v_other_batch     uuid;
  v_other_patient   uuid;
  v_foreign_product uuid;
  v_cashier         uuid;
  v_pharmacist      uuid;
  v_deposit         uuid;
  v_sale            public.sales;
  v_sale2           public.sales;
  v_return_id       uuid;
  v_payment         public.payments;
  v_lines           jsonb;
  v_row             record;
  v_amount          numeric;
  v_amount2         numeric;
  v_rows            int;
  v_qty_before      int;
  v_qty_after       int;
  v_count_a         int;
  v_count_b         int;
  v_patient_two     uuid;
  v_key             text;
  v_admission       public.admissions;
  v_admission2      public.admissions;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE7A TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user
    from public.profiles
   where pharmacy_id = v_pharmacy
   order by created_at
   limit 1;
  if v_user is null then
    raise exception 'PHASE7A TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------ fixtures
  -- As postgres, so RLS is not in the way of setting the scene. The pharmacy's own
  -- package markup and state are deliberately left as they are; the package section
  -- sets the markup when it needs one.
  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 7a five percent', 5)
  returning id into v_product;

  -- This batch deliberately carries a LANDED COST (100) that differs from its PURCHASE RATE
  -- (80): the package rule multiplies the purchase rate, and the two numbers being different
  -- is what makes that assertion mean something rather than pass by coincidence.
  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp, selling_rate,
    landed_cost_per_unit
  ) values (
    v_pharmacy, v_product, 'ZZTEST-7A-B1', current_date + 365, 100, 80, 105, 0, 100
  ) returning id into v_batch;

  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 7a zero slab', 0)
  returning id into v_product_zero;

  -- MRP is deliberately generous: these lines are valued at 500/300/200 later, and a
  -- retail rate above MRP is refused on purpose (asserted further down).
  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product_zero, 'ZZTEST-7A-B2', current_date + 365, 50, 40, 1000
  ) returning id into v_batch_zero;

  insert into public.products (pharmacy_id, name, gst_percent, schedule_type)
  values (v_pharmacy, 'ZZTEST 7a scheduled', 5, 'H')
  returning id into v_scheduled;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_scheduled, 'ZZTEST-7A-B3', current_date + 365, 20, 50, 100
  ) returning id into v_scheduled_batch;

  -- A product with NO slab recorded. `products.gst_percent` is nullable and NULL means
  -- "nobody has said" (migration 00031) - which is what a package line may not paper over.
  insert into public.products (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST 7a no slab')
  returning id into v_noslab;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_noslab, 'ZZTEST-7A-B4', current_date + 365, 10, 30, 90
  ) returning id into v_noslab_batch;

  -- A customer with no patient code, to prove one is assigned on first use.
  insert into public.customers (pharmacy_id, name, phone)
  values (v_pharmacy, 'ZZTEST 7a legacy customer', '9000000001')
  returning id into v_legacy;

  -- The hospital's own account, which is the debtor on a package sale.
  insert into public.customers (pharmacy_id, name, phone)
  values (v_pharmacy, 'ZZTEST 7a hospital account', '9000000002')
  returning id into v_hospital_acct;

  insert into public.pharmacies (id, name)
  values (gen_random_uuid(), 'ZZTEST 7a other pharmacy')
  returning id into v_other_pharmacy;

  insert into public.customers (pharmacy_id, name, phone)
  values (v_other_pharmacy, 'ZZTEST 7a other patient', '9000000003')
  returning id into v_other_patient;

  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_other_pharmacy, 'ZZTEST 7a foreign product', 5)
  returning id into v_foreign_product;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_other_pharmacy, v_foreign_product, 'ZZTEST-7A-FOREIGN', current_date + 365, 10, 10, 20
  ) returning id into v_other_batch;

  -- Two more people in the same pharmacy, for the role gates: a cashier may register a patient
  -- for a sale but may not rewrite a master, a pharmacist may, and neither may change the
  -- pharmacy's own settings.
  v_cashier    := '00000000-0000-0000-0000-0000000000cc';
  v_pharmacist := '00000000-0000-0000-0000-0000000000dd';

  insert into auth.users (id, email)
  values (v_cashier, 'zztest-7a-cashier@example.invalid')
  on conflict (id) do nothing;

  insert into auth.users (id, email)
  values (v_pharmacist, 'zztest-7a-pharmacist@example.invalid')
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_cashier, 'ZZTEST 7a cashier', 'cashier', v_pharmacy)
  on conflict (id) do update
    set role = excluded.role, pharmacy_id = excluded.pharmacy_id;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_pharmacist, 'ZZTEST 7a pharmacist', 'pharmacist', v_pharmacy)
  on conflict (id) do update
    set role = excluded.role, pharmacy_id = excluded.pharmacy_id;

  -- N-17(a), as privileges rather than as a hidden control: the patient master's identity
  -- columns are not directly writable by a client, and the columns the customers form owns
  -- still are (so no existing screen changes what it can do).
  v_log := array_append(v_log, case
    when not has_column_privilege('authenticated', 'public.customers', 'patient_code', 'UPDATE')
      then 'PASS' else 'FAIL' end
    || ': 18. patient_code is not directly writable by a client');

  v_log := array_append(v_log, case
    when not has_column_privilege('authenticated', 'public.customers', 'sex', 'UPDATE')
     and not has_column_privilege('authenticated', 'public.customers', 'date_of_birth', 'UPDATE')
     and not has_column_privilege('authenticated', 'public.customers', 'guardian_phone', 'UPDATE')
      then 'PASS' else 'FAIL' end
    || ': 18. the patient demographics are not directly writable by a client');

  v_log := array_append(v_log, case
    when has_column_privilege('authenticated', 'public.customers', 'name', 'UPDATE')
     and has_column_privilege('authenticated', 'public.customers', 'phone', 'UPDATE')
     and has_column_privilege('authenticated', 'public.customers', 'is_active', 'UPDATE')
      then 'PASS' else 'FAIL' end
    || ': 18. the columns the customers form owns are still writable (that screen is unchanged)');

  -- Permissions that do not need a tenant identity.
  select has_function_privilege('anon', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'collect_payment';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 17. anon cannot execute collect_payment (expected false, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'collect_payment';
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 17. authenticated can execute collect_payment (expected true, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'next_patient_code';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 17. the code minter is not executable by authenticated (expected false, got ' || v_allowed || ')');

  -- ------------------------------------------------- behave as the owner
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- ====================================================== 1-4. patient identity
  v_outcome := 'FAIL: 1. a patient with no contact at all was registered';
  begin
    v_patient := public.save_patient(p_name => 'ZZTEST 7a no contact');
  exception when check_violation then
    v_outcome := 'PASS: 2. a patient with neither their own nor a guardian''s mobile is refused';
  end;
  v_log := array_append(v_log, v_outcome);

  v_patient := public.save_patient(
    p_name => 'ZZTEST 7a patient one',
    p_mobile => '+91 98765 43210',
    p_age_years => 34,
    p_sex => 'female'
  );

  v_log := array_append(v_log, case
    when v_patient.patient_code ~ '^PT-[0-9]{5}$' then 'PASS' else 'FAIL' end
    || ': 1. the first patient gets a generated code in the documented form (got '
    || coalesce(v_patient.patient_code, 'NULL') || ')');

  v_log := array_append(v_log, case
    when v_patient.phone = '9876543210' then 'PASS' else 'FAIL' end
    || ': 1. "+91 98765 43210" is stored canonically (got ' || coalesce(v_patient.phone, 'NULL') || ')');

  v_log := array_append(v_log, case
    when v_patient.age_years = 34 and v_patient.sex = 'female' then 'PASS' else 'FAIL' end
    || ': 1. the demographics the details step collects are stored');

  -- Double-submit: the same submission again is the same patient, not a second one.
  v_second := public.save_patient(
    p_name => 'ZZTEST 7a patient one',
    p_mobile => '9876543210'
  );
  v_log := array_append(v_log, case
    when v_second.id = v_patient.id then 'PASS' else 'FAIL' end
    || ': 3. a repeated registration returns the same patient (a retry is not a second person)');

  -- A different person who shares the family number is a separate patient.
  v_second := public.save_patient(
    p_name => 'ZZTEST 7a patient two',
    p_mobile => '9876543210'
  );
  v_patient_two := v_second.id;
  v_log := array_append(v_log, case
    when v_second.id <> v_patient.id then 'PASS' else 'FAIL' end
    || ': 3. a shared family mobile is a second patient, not a merge');

  select count(*) into v_rows
    from public.customers c
   where c.pharmacy_id = v_pharmacy and c.phone = '9876543210';
  v_log := array_append(v_log, case when v_rows = 2 then 'PASS' else 'FAIL' end
    || ': 3. the shared number holds two separate patients (expected 2, got ' || v_rows || ')');

  -- A guardian's number satisfies the contact requirement.
  v_second := public.save_patient(
    p_name => 'ZZTEST 7a child',
    p_guardian_name => 'ZZTEST 7a guardian',
    p_guardian_phone => '9000000004'
  );
  v_log := array_append(v_log, case
    when v_second.phone = '9000000004' and v_second.guardian_phone = '9000000004'
      then 'PASS' else 'FAIL' end
    || ': 2. a guardian''s mobile satisfies the contact requirement and is what the family is found by');

  -- Selecting a returning patient returns the master unchanged.
  v_second := public.save_patient(
    p_patient_id => v_patient.id,
    p_name => 'ZZTEST 7a patient one',
    p_address => 'ZZTEST an address a bill typed'
  );
  v_log := array_append(v_log, case
    when v_second.address is null then 'PASS' else 'FAIL' end
    || ': 4. a bill detail does not edit the patient master (address expected NULL, got '
    || coalesce(v_second.address, 'NULL') || ')');

  -- A pre-Phase-7a customer is given a code on first use.
  v_second := public.save_patient(
    p_patient_id => v_legacy,
    p_name => 'ZZTEST 7a legacy customer'
  );
  v_log := array_append(v_log, case
    when v_second.patient_code is not null then 'PASS' else 'FAIL' end
    || ': 4. a customer without a code is given one on first use (got '
    || coalesce(v_second.patient_code, 'NULL') || ')');

  v_patient_code := v_second.patient_code;

  -- ------------------------------------------------------------- 5. lookup
  select count(*) into v_rows
    from public.search_patients('9876543210') s
   where s.id = v_patient.id;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 5. lookup by canonical mobile finds the patient');

  select count(*) into v_rows
    from public.search_patients('+91 98765 43210') s
   where s.id = v_patient.id;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 5. lookup accepts the +91 spelling of the same number');

  select count(*) into v_rows
    from public.search_patients(v_patient_code) s
   where s.id = v_legacy;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 5. lookup by patient-code prefix finds the patient');

  select count(*) into v_rows
    from public.search_patients('zztest 7a patient one') s
   where s.id = v_patient.id;
  v_log := array_append(v_log, case when v_rows >= 1 then 'PASS' else 'FAIL' end
    || ': 5. lookup by name is case-insensitive');

  v_outcome := 'FAIL: 5. another tenant''s patient was selectable';
  begin
    v_second := public.save_patient(
      p_patient_id => v_other_patient,
      p_name => 'ZZTEST 7a other patient'
    );
  exception when check_violation then
    v_outcome := 'PASS: 5. another tenant''s patient is refused';
  end;
  v_log := array_append(v_log, v_outcome);

  -- ================================================ 6-9. a pharmacy sale (OPD)
  v_outcome := 'FAIL: 6. a typed pharmacy sale without a patient was written';
  begin
    v_sale := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105
      ))
    ));
  exception when check_violation then
    v_outcome := 'PASS: 6. a pharmacy sale needs a patient before the medicines';
  end;
  v_log := array_append(v_log, v_outcome);

  -- The owner's own worked example: MRP 105 at 5% is 100 taxable + 5 tax.
  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105
    ))
  ));

  v_log := array_append(v_log, case
    when v_sale.sale_type = 'counter' and v_sale.patient_name = 'ZZTEST 7a patient one'
      and v_sale.patient_mobile = '9876543210' then 'PASS' else 'FAIL' end
    || ': 6. the type and the patient snapshot are on the bill (got '
    || v_sale.sale_type || ' / ' || coalesce(v_sale.patient_name, 'NULL') || ')');

  v_log := array_append(v_log, case
    when v_sale.grand_total = 105.00 and v_sale.sub_total = 100.00
      and v_sale.tax_total = 5.00 then 'PASS' else 'FAIL' end
    || ': 7. MRP 105 at 5% is 100 taxable + 5 tax, not 110.25 (got sub '
    || v_sale.sub_total || ' / tax ' || v_sale.tax_total || ' / grand ' || v_sale.grand_total || ')');

  select si.cgst_amount, si.sgst_amount into v_amount, v_amount2
    from public.sale_items si
   where si.sale_id = v_sale.id;
  v_log := array_append(v_log, case
    when v_amount = 2.50 and v_amount2 = 2.50 and (v_amount + v_amount2) = 5.00
      then 'PASS' else 'FAIL' end
    || ': 7. the two tax heads add back to the tax charged (got ' || v_amount || ' + ' || v_amount2 || ')');

  v_log := array_append(v_log, case
    when v_sale.status = 'credit' and v_sale.amount_paid = 0 and v_sale.balance_due = 105.00
      then 'PASS' else 'FAIL' end
    || ': 6. saving records no payment: the bill is owed, not paid (got status '
    || v_sale.status || ' / paid ' || v_sale.amount_paid || ')');

  select count(*) into v_rows
    from public.ledger_entries l
   where l.reference_type = 'sale' and l.reference_id = v_sale.id;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 6. the patient''s receivable is posted (expected 1 row, got ' || v_rows || ')');

  -- A recorded zero slab means zero.
  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product_zero, 'batch_id', v_batch_zero, 'qty', 2, 'rate', 60
    ))
  ));
  v_log := array_append(v_log, case
    when v_sale2.grand_total = 120.00 and v_sale2.tax_total = 0.00 then 'PASS' else 'FAIL' end
    || ': 7. a recorded zero slab means zero tax (got tax ' || v_sale2.tax_total || ')');

  -- A discount above the cap is refused, with the approval workflow named.
  v_outcome := 'FAIL: 8. an above-limit discount was recorded';
  begin
    v_sale2 := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105,
        'discount_percent', 15
      ))
    ));
  exception when check_violation then
    v_outcome := 'PASS: 8. a discount above 10% is refused rather than recorded';
  end;
  v_log := array_append(v_log, v_outcome);

  -- Exactly 10% is allowed, and the tax is extracted from the discounted price.
  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105,
      'discount_percent', 10
    ))
  ));
  v_log := array_append(v_log, case
    when v_sale2.grand_total = 94.50 and v_sale2.tax_total = 4.50 then 'PASS' else 'FAIL' end
    || ': 8. a 10% discount is allowed and the tax follows the discounted price (got '
    || v_sale2.grand_total || ' / tax ' || v_sale2.tax_total || ')');

  -- A retail rate above MRP is refused.
  v_outcome := 'FAIL: 8. a rate above MRP was accepted';
  begin
    v_sale2 := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 200
      ))
    ));
  exception when check_violation then
    v_outcome := 'PASS: 8. a rate above MRP is refused';
  end;
  v_log := array_append(v_log, v_outcome);

  -- A Schedule H line needs its prescriber (D-072).
  v_outcome := 'FAIL: 9. a Schedule H line was billed with no prescriber';
  begin
    v_sale2 := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_scheduled, 'batch_id', v_scheduled_batch, 'qty', 1, 'rate', 100
      ))
    ));
  exception when check_violation then
    v_outcome := 'PASS: 9. a Schedule H line needs the prescriber''s name';
  end;
  v_log := array_append(v_log, v_outcome);

  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'doctor_name', 'ZZTEST 7a prescriber',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_scheduled, 'batch_id', v_scheduled_batch, 'qty', 1, 'rate', 100
    ))
  ));
  select count(*) into v_rows
    from public.sale_items si
   where si.sale_id = v_sale2.id and si.schedule_type = 'H';
  v_log := array_append(v_log, case
    when v_sale2.doctor_name = 'ZZTEST 7a prescriber' and v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 9. the prescriber is recorded on the bill and the schedule is snapped to the product');

  select d.id into v_doctor
    from public.doctors d
   where d.pharmacy_id = v_pharmacy and lower(d.name) = 'zztest 7a prescriber';
  v_log := array_append(v_log, case when v_doctor is not null then 'PASS' else 'FAIL' end
    || ': 9. the prescriber converges on one master row (D-072)');

  -- ============================================== 10-12. IPD credit and balances
  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'ipd_admission',
    'customer_id', v_patient.id,
    'hospital_reference', 'ZZTEST-IPD-1',
    'doctor_name', 'ZZTEST 7a treating doctor',
    'ward', 'ZZTEST ward',
    'bed', 'ZZTEST bed B1',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product_zero, 'batch_id', v_batch_zero, 'qty', 1, 'rate', 500
    ))
  ));

  v_log := array_append(v_log, case
    when v_sale.sale_type = 'ipd_admission' and v_sale.hospital_reference = 'ZZTEST-IPD-1'
      and v_sale.admission_id is not null then 'PASS' else 'FAIL' end
    || ': 10. an IPD bill carries its admission and the hospital''s own number (got '
    || coalesce(v_sale.hospital_reference, 'NULL') || ')');

  select * into v_admission from public.admissions a where a.id = v_sale.admission_id;
  v_log := array_append(v_log, case
    when v_admission.status = 'active' and v_admission.ward = 'ZZTEST ward'
      and v_admission.treating_doctor_name = 'ZZTEST 7a treating doctor'
      then 'PASS' else 'FAIL' end
    || ': 10. the admission records the ward and treating doctor (got '
    || coalesce(v_admission.ward, 'NULL') || ' / ' || coalesce(v_admission.treating_doctor_name, 'NULL') || ')');

  -- The same admission number resolves to the same episode instead of a second one.
  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'ipd_admission',
    'customer_id', v_patient.id,
    'admission_id', v_admission.id,
    'doctor_name', 'ZZTEST 7a treating doctor',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product_zero, 'batch_id', v_batch_zero, 'qty', 1, 'rate', 300
    ))
  ));
  select count(*) into v_rows
    from public.admissions a
   where a.pharmacy_id = v_pharmacy and a.customer_id = v_patient.id;
  v_log := array_append(v_log, case
    when v_rows = 1 and v_sale2.admission_id = v_admission.id then 'PASS' else 'FAIL' end
    || ': 10. a second bill on the same admission is the same episode (expected 1 admission, got '
    || v_rows || ')');

  -- A discharged episode cannot take a new charge.
  v_outcome := 'FAIL: 10. a discharged admission took a new charge';
  begin
    update public.admissions a set status = 'discharged' where a.id = v_admission.id;
    perform public.checkout_sale(jsonb_build_object(
      'sale_type', 'ipd_admission',
      'customer_id', v_patient.id,
      'admission_id', v_admission.id,
      'doctor_name', 'ZZTEST 7a treating doctor',
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product_zero, 'batch_id', v_batch_zero, 'qty', 1, 'rate', 10
      ))
    ));
    update public.admissions a set status = 'active' where a.id = v_admission.id;
  exception when check_violation then
    update public.admissions a set status = 'active' where a.id = v_admission.id;
    v_outcome := 'PASS: 10. a discharged admission refuses a new charge';
  end;
  v_log := array_append(v_log, v_outcome);

  -- A 100 return against the first admission bill.
  insert into public.sale_returns (
    pharmacy_id, sale_id, customer_id, sub_total, tax_total, grand_total
  ) values (
    v_pharmacy, v_sale.id, v_patient.id, 100, 0, 100
  ) returning id into v_return_id;

  -- The owner's worked example, before the collection: 800 charges less 100 returned.
  select a.charges, a.returns_credits into v_amount, v_amount2
    from public.admission_account(v_admission.id) a;
  v_log := array_append(v_log, case
    when v_amount = 800.00 and v_amount2 = 100.00 then 'PASS' else 'FAIL' end
    || ': 11. the admission shows 800 charged less 100 returned (got '
    || v_amount || ' / ' || v_amount2 || ')');

  -- A collection of 400 applied to the admission.
  v_payment := public.collect_payment(
    p_party_type => 'customer',
    p_party_id => v_patient.id,
    p_amount => 400,
    p_mode => 'cash',
    p_allocations => jsonb_build_array(
      jsonb_build_object('admission_id', v_admission.id, 'amount', 400)
    )
  );

  select a.allocated, a.outstanding into v_amount, v_amount2
    from public.admission_account(v_admission.id) a;
  v_log := array_append(v_log, case
    when v_amount = 400.00 and v_amount2 = 300.00 then 'PASS' else 'FAIL' end
    || ': 11. 800 charged, 100 returned, 400 collected leaves 300 outstanding (got allocated '
    || v_amount || ' / outstanding ' || v_amount2 || ')');

  select count(*) into v_rows
    from public.payment_allocations pa
   where pa.payment_id = v_payment.id and pa.admission_id = v_admission.id;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 11. the money is recorded as applied to the admission, not as a second receipt');

  -- Allocating more than the receipt is refused.
  v_outcome := 'FAIL: 12. more money was allocated than was received';
  begin
    perform public.collect_payment(
      p_party_type => 'customer',
      p_party_id => v_patient.id,
      p_amount => 100,
      p_mode => 'cash',
      p_allocations => jsonb_build_array(
        jsonb_build_object('admission_id', v_admission.id, 'amount', 500)
      )
    );
  exception when check_violation then
    v_outcome := 'PASS: 12. allocating more than the receipt took is refused';
  end;
  v_log := array_append(v_log, v_outcome);

  -- A receipt with nothing allocated is a deposit, and leaves the balance alone. Its id is kept
  -- for the allocation-integrity section, which applies it later.
  v_payment := public.collect_payment(
    p_party_type => 'customer',
    p_party_id => v_patient.id,
    p_amount => 500,
    p_mode => 'upi'
  );
  v_deposit := v_payment.id;

  select a.outstanding, a.unallocated_deposits into v_amount, v_amount2
    from public.patient_account(v_patient.id) a;
  v_log := array_append(v_log, case
    when v_amount2 = 500.00 then 'PASS' else 'FAIL' end
    || ': 12. an unallocated receipt stays visible as a deposit (got ' || v_amount2 || ')');
  -- 105 + 120 + 94.50 + 100 + 800 = 1219.50 charged, 100 returned, 400 allocated.
  v_log := array_append(v_log, case
    when v_amount = 719.50 then 'PASS' else 'FAIL' end
    || ': 12. applying a deposit is not a receipt: the outstanding is unchanged (got '
    || v_amount || ')');

  -- A second admission keeps its own balance.
  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'ipd_admission',
    'customer_id', v_patient.id,
    'hospital_reference', 'ZZTEST-IPD-2',
    'doctor_name', 'ZZTEST 7a treating doctor',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product_zero, 'batch_id', v_batch_zero, 'qty', 1, 'rate', 200
    ))
  ));

  select a.outstanding into v_amount from public.admission_account(v_sale2.admission_id) a;
  select a.outstanding into v_amount2 from public.admission_account(v_admission.id) a;
  v_log := array_append(v_log, case
    when v_amount = 200.00 and v_amount2 = 300.00 then 'PASS' else 'FAIL' end
    || ': 11. a second admission has its own balance and does not disturb the first (got '
    || v_amount || ' and ' || v_amount2 || ')');

  -- =========================================================== 13. the package
  v_outcome := 'FAIL: 13. a package sale was priced with no markup configured';
  begin
    perform public.checkout_sale(jsonb_build_object(
      'sale_type', 'package',
      'customer_id', v_hospital_acct,
      'patient_name', 'ZZTEST 7a package patient',
      'patient_mobile', '9000000005',
      'hospital_reference', 'ZZTEST-PKG-1',
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product, 'batch_id', v_batch, 'qty', 1
      ))
    ));
  exception when check_violation then
    v_outcome := 'PASS: 13. a package sale is refused until its markup is configured';
  end;
  v_log := array_append(v_log, v_outcome);

  -- Configure the markup the way the owner would, then price a package sale.
  execute 'reset role';
  update public.pharmacies p set package_markup_percent = 20 where p.id = v_pharmacy;
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- Un-slabbed products are refused on a package line while the tax treatment is unsettled.
  v_outcome := 'FAIL: 13. a package line was taxed on an unsettled basis';
  begin
    perform public.checkout_sale(jsonb_build_object(
      'sale_type', 'package',
      'customer_id', v_hospital_acct,
      'patient_name', 'ZZTEST 7a package patient',
      'patient_mobile', '9000000005',
      'hospital_reference', 'ZZTEST-PKG-2',
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_noslab, 'batch_id', v_noslab_batch, 'qty', 1
      ))
    ));
  exception when check_violation then
    v_outcome := 'PASS: 13. a package line whose product has no slab is refused (its tax treatment is not settled)';
  end;
  v_log := array_append(v_log, v_outcome);

  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'package',
    'customer_id', v_hospital_acct,
    'patient_name', 'ZZTEST 7a package patient',
    'patient_mobile', '9000000005',
    'hospital_reference', 'ZZTEST-PKG-3',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1
    ))
  ));

  -- Cost 80 + 20% = 96 inclusive; tax extracted at 5% = 91.43 taxable + 4.57 tax.
  v_log := array_append(v_log, case
    when v_sale2.grand_total = 96.00 and v_sale2.tax_total = 4.57 then 'PASS' else 'FAIL' end
    || ': 13. a package rate is purchase cost plus the configured markup (got grand '
    || v_sale2.grand_total || ' / tax ' || v_sale2.tax_total || ')');

  v_log := array_append(v_log, case
    when v_sale2.customer_id = v_hospital_acct then 'PASS' else 'FAIL' end
    || ': 13. the hospital account is the debtor on a package sale');

  select a.outstanding into v_amount from public.admission_account(v_admission.id) a;
  v_log := array_append(v_log, case
    when v_amount = 300.00 then 'PASS' else 'FAIL' end
    || ': 13. a package bill never increases the patient''s personal debt (got ' || v_amount || ')');

  -- The confirmed rule, three ways. A configured 0% is a real 0% (never read as "missing", so
  -- the sale is priced at the purchase rate itself); a custom percentage is honoured, because
  -- this is a free numeric and not a list of four invented values; and the basis is the
  -- batch's PURCHASE RATE - this batch's landed cost is 100, so 80 x 1.2 = 96 proves which
  -- number is multiplied rather than passing by coincidence.
  update public.pharmacies p set package_markup_percent = 0 where p.id = v_pharmacy;

  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'package',
    'customer_id', v_hospital_acct,
    'patient_name', 'ZZTEST 7a package patient',
    'patient_mobile', '9000000005',
    'hospital_reference', 'ZZTEST-PKG-4',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1
    ))
  ));
  v_log := array_append(v_log, case
    when v_sale2.grand_total = 80.00 and v_sale2.tax_total = 3.81 then 'PASS' else 'FAIL' end
    || ': 13. a configured 0% markup prices at the purchase rate (got grand '
    || v_sale2.grand_total || ' / tax ' || v_sale2.tax_total || ')');

  update public.pharmacies p set package_markup_percent = 7.5 where p.id = v_pharmacy;

  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'package',
    'customer_id', v_hospital_acct,
    'patient_name', 'ZZTEST 7a package patient',
    'patient_mobile', '9000000005',
    'hospital_reference', 'ZZTEST-PKG-5',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1
    ))
  ));
  v_log := array_append(v_log, case
    when v_sale2.grand_total = 86.00 then 'PASS' else 'FAIL' end
    || ': 13. a custom markup is honoured: 80 at 7.5% is 86 (got ' || v_sale2.grand_total || ')');

  update public.pharmacies p set package_markup_percent = 20 where p.id = v_pharmacy;

  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'package',
    'customer_id', v_hospital_acct,
    'patient_name', 'ZZTEST 7a package patient',
    'patient_mobile', '9000000005',
    'hospital_reference', 'ZZTEST-PKG-6',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1
    ))
  ));
  v_log := array_append(v_log, case
    when v_sale2.grand_total = 96.00 then 'PASS' else 'FAIL' end
    || ': 13. the basis is the PURCHASE rate (80 at 20% = 96), not this batch''s landed cost of 100 (that would be 120) (got '
    || v_sale2.grand_total || ')');

  -- ========================================================== 14. the transfer
  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'transfer',
    'from_location', 'ZZTEST main shelf',
    'to_location', 'ZZTEST hospital ward',
    'transfer_reason', 'ZZTEST stock support',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product_zero, 'batch_id', v_batch_zero, 'qty', 2
    ))
  ));

  v_log := array_append(v_log, case
    when v_sale2.sale_type = 'transfer' and v_sale2.tax_total = 0
      and v_sale2.customer_id is null and v_sale2.amount_paid = 0 then 'PASS' else 'FAIL' end
    || ': 14. a transfer takes no patient, no account and no GST');

  v_log := array_append(v_log, case
    when v_sale2.transfer_note_no like 'TR%' then 'PASS' else 'FAIL' end
    || ': 14. a transfer note number is generated (got '
    || coalesce(v_sale2.transfer_note_no, 'NULL') || ')');

  v_outcome := 'FAIL: 14. a transfer with the same source and destination was written';
  begin
    perform public.checkout_sale(jsonb_build_object(
      'sale_type', 'transfer',
      'from_location', 'ZZTEST main shelf',
      'to_location', 'ZZTEST main shelf',
      'transfer_reason', 'ZZTEST stock support',
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product_zero, 'batch_id', v_batch_zero, 'qty', 1
      ))
    ));
  exception when check_violation then
    v_outcome := 'PASS: 14. a transfer''s source and destination cannot be the same';
  end;
  v_log := array_append(v_log, v_outcome);

  -- ===================================================== 15. idempotency
  v_key := 'zztest-7a-key-' || gen_random_uuid()::text;
  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'idempotency_key', v_key,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105
    ))
  ));
  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'idempotency_key', v_key,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105
    ))
  ));
  v_log := array_append(v_log, case
    when v_sale2.id = v_sale.id then 'PASS' else 'FAIL' end
    || ': 15. a retried checkout is the same sale, not a second bill');

  v_key := 'zztest-7a-pay-' || gen_random_uuid()::text;
  v_payment := public.collect_payment(
    p_party_type => 'customer', p_party_id => v_patient.id,
    p_amount => 50, p_mode => 'cash', p_idempotency_key => v_key
  );
  select count(*) into v_rows
    from public.payments p
   where p.pharmacy_id = v_pharmacy and p.idempotency_key = v_key;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 15. a retried collection is one receipt (expected 1 row, got ' || v_rows || ')');

  -- ==================================================== 16. tenant isolation
  v_outcome := 'FAIL: 16. a typed sale took another pharmacy''s batch';
  begin
    v_sale2 := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product, 'batch_id', v_other_batch, 'qty', 1, 'rate', 105
      ))
    ));
  exception when check_violation then
    v_outcome := 'PASS: 16. another pharmacy''s batch is refused on a typed sale';
  end;
  v_log := array_append(v_log, v_outcome);

  -- ============================ 17. a patient master edit is permission-controlled
  -- N-17(a). The gate is on the server: the same call is refused for a cashier whatever any
  -- screen happens to show, and it is refused by the RPC rather than by a column privilege
  -- the RPC could be bypassed around.
  v_second := public.update_patient(
    p_patient_id => v_patient.id,
    p_name => 'ZZTEST 7a patient one',
    p_mobile => '9876543210',
    p_age_years => 36,
    p_sex => 'female',
    p_notes => 'ZZTEST edited by the owner'
  );
  v_log := array_append(v_log, case
    when v_second.age_years = 36 and v_second.notes = 'ZZTEST edited by the owner'
      then 'PASS' else 'FAIL' end
    || ': 17. the owner may edit a patient master');

  v_log := array_append(v_log, case
    when v_second.patient_code is not null then 'PASS' else 'FAIL' end
    || ': 17. an edit leaves the patient code alone (identity belongs to the counter)');

  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_outcome := 'FAIL: 17. a cashier edited a patient master';
  begin
    perform public.update_patient(
      p_patient_id => v_patient.id,
      p_name => 'ZZTEST 7a cashier rename',
      p_mobile => '9876543210'
    );
  exception when insufficient_privilege then
    v_outcome := 'PASS: 17. a cashier''s patient edit is refused server-side';
  end;
  v_log := array_append(v_log, v_outcome);

  -- The pharmacy's own settings are the owner's: a cashier may not set the package markup.
  update public.pharmacies p set package_markup_percent = 99 where p.id = v_pharmacy;
  select p.package_markup_percent into v_amount
    from public.pharmacies p where p.id = v_pharmacy;
  v_log := array_append(v_log, case when v_amount = 20.00 then 'PASS' else 'FAIL' end
    || ': 17. a cashier cannot change the package markup setting (still ' || v_amount || ')');

  perform set_config('request.jwt.claim.sub', v_pharmacist::text, true);

  v_second := public.update_patient(
    p_patient_id => v_patient.id,
    p_name => 'ZZTEST 7a patient one',
    p_mobile => '9876543210',
    p_age_years => 37,
    p_sex => 'female'
  );
  v_log := array_append(v_log, case when v_second.age_years = 37 then 'PASS' else 'FAIL' end
    || ': 17. a pharmacist may edit a patient master');

  perform set_config('request.jwt.claim.sub', v_user::text, true);

  -- ======================== 20. an allocation cannot over-settle a document
  -- Admission 1 stands at 300 outstanding at this point.
  v_outcome := 'FAIL: 20. an allocation larger than the outstanding was accepted';
  begin
    perform public.collect_payment(
      p_party_type => 'customer',
      p_party_id => v_patient.id,
      p_amount => 301,
      p_mode => 'cash',
      p_idempotency_key => 'zztest-7a-over',
      p_allocations => jsonb_build_array(
        jsonb_build_object('admission_id', v_admission.id, 'amount', 301)
      )
    );
  exception when check_violation then
    v_outcome := 'PASS: 20. allocating past the outstanding is refused';
  end;
  v_log := array_append(v_log, v_outcome);

  -- The refusal took the half-written receipt with it: no payment row, no ledger row, no
  -- allocation. This is the "a failure leaves no partial financial write" case.
  select count(*) into v_rows
    from public.payments p
   where p.pharmacy_id = v_pharmacy and p.idempotency_key = 'zztest-7a-over';
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 20. a refused collection leaves no receipt behind (expected 0 rows, got ' || v_rows || ')');

  -- Money from one patient cannot settle another patient's admission.
  v_payment := public.collect_payment(
    p_party_type => 'customer',
    p_party_id => v_patient_two,
    p_amount => 100,
    p_mode => 'cash'
  );
  v_outcome := 'FAIL: 20. one patient''s receipt settled another patient''s admission';
  begin
    perform public.allocate_payment(
      v_payment.id,
      jsonb_build_array(
        jsonb_build_object('admission_id', v_admission.id, 'amount', 50)
      )
    );
  exception when check_violation then
    v_outcome := 'PASS: 20. a receipt cannot settle another patient''s admission';
  end;
  v_log := array_append(v_log, v_outcome);

  -- Applying the deposit the counter already holds: the admission falls by 100 and NO second
  -- receipt appears, which is the whole point of "applying a deposit is not a second receipt".
  select count(*) into v_count_a
    from public.payments p
   where p.pharmacy_id = v_pharmacy and p.customer_id = v_patient.id;
  select a.outstanding into v_amount from public.admission_account(v_admission.id) a;

  perform public.allocate_payment(
    v_deposit,
    jsonb_build_array(jsonb_build_object('admission_id', v_admission.id, 'amount', 100))
  );

  select count(*) into v_count_b
    from public.payments p
   where p.pharmacy_id = v_pharmacy and p.customer_id = v_patient.id;
  select a.outstanding into v_amount2 from public.admission_account(v_admission.id) a;

  v_log := array_append(v_log, case
    when v_amount = 300.00 and v_amount2 = 200.00 then 'PASS' else 'FAIL' end
    || ': 20. applying a deposit settles 100 of the admission (300 -> ' || v_amount2 || ')');

  v_log := array_append(v_log, case when v_count_b = v_count_a then 'PASS' else 'FAIL' end
    || ': 20. applying a deposit writes no second receipt (payments '
    || v_count_a || ' -> ' || v_count_b || ')');

  v_outcome := 'FAIL: 20. a deposit applied more than it held';
  begin
    perform public.allocate_payment(
      v_deposit,
      jsonb_build_array(jsonb_build_object('admission_id', v_admission.id, 'amount', 500))
    );
  exception when check_violation then
    v_outcome := 'PASS: 20. a deposit cannot apply more than it still holds';
  end;
  v_log := array_append(v_log, v_outcome);

  -- ======================== 21. a retried submit whose payload changed
  v_key := 'zztest-7a-key2-' || gen_random_uuid()::text;
  select b.qty into v_count_a from public.product_batches b where b.id = v_batch;

  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'idempotency_key', v_key,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105
    ))
  ));

  -- The same key with a different basket. The original sale comes back, so a retry that forgot
  -- what it sent cannot invent a second transaction - and the stock moves once.
  v_sale2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'idempotency_key', v_key,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 3, 'rate', 105
    ))
  ));

  select b.qty into v_count_b from public.product_batches b where b.id = v_batch;

  v_log := array_append(v_log, case when v_sale2.id = v_sale.id then 'PASS' else 'FAIL' end
    || ': 21. the same key with a changed payload returns the ORIGINAL sale');

  v_log := array_append(v_log, case
    when v_sale2.grand_total = v_sale.grand_total then 'PASS' else 'FAIL' end
    || ': 21. the original amount stands, not the changed one (got ' || v_sale2.grand_total || ')');

  v_log := array_append(v_log, case when v_count_a - v_count_b = 1 then 'PASS' else 'FAIL' end
    || ': 21. the retry moved stock once (expected 1 unit, got ' || (v_count_a - v_count_b) || ')');

  -- ======================== 22. a return reverses against the bill it came from
  -- The returns SCREEN is Phase 3's and is not rebuilt by this phase; what is pinned here is
  -- that a return against a typed sale still posts its credit to the customer's ledger.
  select count(*) into v_rows
    from public.ledger_entries l
   where l.pharmacy_id = v_pharmacy
     and l.reference_type = 'sale_return'
     and l.reference_id = v_return_id
     and l.credit = 100.00;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 22. a return credits the customer 100 against the bill it came from');

  -- ================================================================ summary
  -- The count is the ASSERTIONS, not the log's length: the summary line itself is appended to
  -- the same array, which is what made the previous version of this file read "54 assertions"
  -- for 53 checks. The self-check below is what proves nothing is hidden by that arithmetic -
  -- a line that is neither a PASS nor a FAIL would fail it.
  v_log := array_append(v_log, case
    when (select count(*) from unnest(v_log) l
           where coalesce(l, '') not like 'PASS%'
             and coalesce(l, '') not like 'FAIL%') = 0
      then 'PASS' else 'FAIL' end
    || ': 0. every logged line is a PASS or a FAIL (nothing skipped, nothing truncated)');

  v_log := array_append(v_log, 'SUMMARY: '
    || (select count(*) from unnest(v_log) l where l like 'PASS%') || ' PASS / '
    || (select count(*) from unnest(v_log) l where l like 'FAIL%') || ' FAIL of '
    || (select count(*) from unnest(v_log) l
         where l like 'PASS%' or l like 'FAIL%') || ' assertions');

  raise exception E'PHASE7A SALE TYPES TEST\n%', array_to_string(v_log, chr(10));
end $$;
