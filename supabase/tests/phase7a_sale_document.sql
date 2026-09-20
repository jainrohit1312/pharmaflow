-- Phase 7a sale_document - functional test for migration 20260920000039.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase7a_sale_document.sql
--
-- COUNTING
--   The last line reads "<n> PASS / <m> FAIL of <k> assertions", where k counts assertion lines
--   only, and the self-check on the line above it asserts that every logged line is a PASS or a
--   FAIL. The self-check is itself one of the counted assertions, because it is one. The older
--   files in this directory count the summary line itself into their total, which is why theirs
--   reads one higher than the checks they contain; this file follows phase7a_sale_types.sql,
--   which does not repeat that.
--
-- HOW TO READ THE RESULT
--   The evidence comes back in the error message: every line is either "PASS: ..." or
--   "FAIL: ...", and the last line counts them. A non-zero exit code is expected and means the
--   script ran to completion, not that it failed.
--
-- WHY IT ENDS WITH RAISE EXCEPTION
--   The whole file is one DO block, which is one statement and therefore one implicit
--   transaction. Raising at the end rolls every fixture back, so it is safe against the hosted
--   project and leaves no residue.
--
-- IMPERSONATION
--   `sale_document` takes its tenant from `get_my_pharmacy_id()`, which resolves `auth.uid()`.
--   The fixtures are written as the owner first (RLS not in the way), then the session becomes
--   the real owner profile - JWT claims set, role switched to `authenticated` - the way
--   phase3_sale_triggers.sql does it. The tenant-guard section at the end then becomes a SECOND
--   pharmacy's owner in the same transaction, which is what proves the guard rather than assumes
--   it.
--
-- WHAT IT PROVES
--   1.  The function exists for `authenticated`, is NOT executable by `anon`, is SECURITY
--       INVOKER (so the caller's RLS applies as well as the pharmacy guard), is STABLE (it
--       reads and writes nothing) and has its `search_path` pinned.
--   2.  The document carries the sale's own stored row - id, invoice number and the three money
--       columns byte-for-byte - so the receipt prints the server's figures and this function
--       computes none of them.
--   3.  One line per `sale_items` row, in insertion order.
--   4.  Each line carries its OWN batch: two lines from two batches come back with two
--       different batch numbers, which is what a mis-join would get wrong.
--   5.  A recorded expiry round-trips, and a pack with no expiry answers `null` with
--       `is_unknown_batch` true - the common case here (145 of the owner's opening-stock
--       batches carry no date), where the receipt must print an em dash, never a fake date.
--   6.  A line carries the stored `sale_items` row itself: quantity, rate, slab and money.
--   7.  The patient's `patient_code` is joined on `sales.customer_id` and is the generated
--       `PT-00001` form.
--   8.  On a package sale the key is present and `null`, because that bill's party is the
--       hospital's ACCOUNT row - and the party really is the account, not a patient.
--   9.  A sale with no party at all (a transfer) answers `null` for the code rather than
--       failing, and its line still names its pack.
--   10. Another pharmacy's caller gets `null` for this sale rather than someone else's
--       document, and an id that names no sale answers `null`.
--   11. The assertion count is the assertions - and every logged line is a PASS or a FAIL, so a
--       skipped or truncated check cannot hide behind the arithmetic.

do $$
declare
  v_log             text[] := array[]::text[];
  v_outcome         text;
  v_pharmacy        uuid;
  v_user            uuid;
  v_other_pharmacy  uuid;
  v_other_user      uuid;
  v_product_a       uuid;
  v_batch_a         uuid;
  v_product_b       uuid;
  v_batch_b         uuid;
  v_hospital_acct   uuid;
  v_patient         public.customers;
  v_sale            public.sales;
  v_package_sale    public.sales;
  v_transfer_sale   public.sales;
  v_doc             jsonb;
  v_line            jsonb;
  v_allowed         boolean;
  v_definer         boolean;
  v_volatile        "char";
  v_settings        text[];
  v_batch_a_expiry  date;
  v_rows            int;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE7A SALE DOCUMENT TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user
    from public.profiles
   where pharmacy_id = v_pharmacy
   order by created_at
   limit 1;
  if v_user is null then
    raise exception 'PHASE7A SALE DOCUMENT TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------- 1. the function's own shape
  -- Permissions and attributes do not need a tenant identity.
  select has_function_privilege('anon', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'sale_document';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. anon cannot execute sale_document (expected false, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'sale_document';
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated can execute sale_document (expected true, got ' || v_allowed || ')');

  select p.prosecdef, p.provolatile, p.proconfig
    into v_definer, v_volatile, v_settings
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'sale_document';

  -- SECURITY INVOKER is load-bearing rather than stylistic: it is what puts the caller's own
  -- RLS policies on the read as well as the explicit pharmacy guard below.
  v_log := array_append(v_log, case when not v_definer then 'PASS' else 'FAIL' end
    || ': 1. the function is security INVOKER, so the caller''s RLS applies too (prosecdef = '
    || v_definer || ')');

  v_log := array_append(v_log, case when v_volatile::text = 's' then 'PASS' else 'FAIL' end
    || ': 1. the function is STABLE - it reads, it writes nothing (provolatile = '
    || v_volatile::text || ')');

  v_log := array_append(v_log, case
    when v_settings is not null
     and exists (
       select 1 from unnest(v_settings) s where s like 'search_path=%'
     )
      then 'PASS' else 'FAIL' end
    || ': 1. search_path is pinned, so the unqualified table names cannot be hijacked (proconfig = '
    || coalesce(array_to_string(v_settings, ','), 'NULL') || ')');

  -- ------------------------------------------------------------------ fixtures
  -- As postgres, so RLS is not in the way of setting the scene.
  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 39 five percent', 5)
  returning id into v_product_a;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product_a, 'ZZTEST-39-A', current_date + 365, 100, 80, 105
  ) returning id into v_batch_a;

  -- The second pack deliberately has NO expiry and is flagged unknown. That is the common case
  -- in this catalogue rather than a corner: 145 of the owner's opening-stock batches carry no
  -- date (migration 00031), so a receipt that could not say "unknown" would be wrong most often.
  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 39 no expiry', 5)
  returning id into v_product_b;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp, is_unknown_batch
  ) values (
    v_pharmacy, v_product_b, 'ZZTEST-39-B', null, 100, 40, 200, true
  ) returning id into v_batch_b;

  -- The hospital's own account row, which is the debtor on a package sale (D-067). It is a
  -- plain customer: it has no patient code and must not be given one, because the patient on a
  -- package bill is the sale's own name-and-mobile snapshot.
  insert into public.customers (pharmacy_id, name, phone)
  values (v_pharmacy, 'ZZTEST 39 hospital account', '9000000039')
  returning id into v_hospital_acct;

  update public.pharmacies p set package_markup_percent = 20 where p.id = v_pharmacy;

  -- A second pharmacy with its own owner, for the tenant-guard section.
  insert into public.pharmacies (id, name)
  values (gen_random_uuid(), 'ZZTEST 39 other pharmacy')
  returning id into v_other_pharmacy;

  v_other_user := '00000000-0000-0000-0000-000000000039';

  insert into auth.users (id, email)
  values (v_other_user, 'zztest-39-other@example.invalid')
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_other_user, 'ZZTEST 39 other owner', 'owner', v_other_pharmacy)
  on conflict (id) do update
    set role = excluded.role, pharmacy_id = excluded.pharmacy_id;

  -- ------------------------------------------------- behave as the owner
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- ============================== 2-6. a counter sale: the header, the lines, the packs
  v_patient := public.save_patient(
    p_name => 'ZZTEST 39 patient',
    p_mobile => '9000000038'
  );

  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'idempotency_key', 'zztest-39-doc-' || gen_random_uuid()::text,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 2, 'rate', 100
      ),
      jsonb_build_object(
        'product_id', v_product_b, 'batch_id', v_batch_b, 'qty', 1, 'rate', 50
      )
    )
  ));

  v_doc := public.sale_document(v_sale.id);

  v_log := array_append(v_log, case
    when v_doc -> 'sale' ->> 'id' = v_sale.id::text then 'PASS' else 'FAIL' end
    || ': 2. the document carries the sale row itself (id '
    || coalesce(v_doc -> 'sale' ->> 'id', 'NULL') || ')');

  v_log := array_append(v_log, case
    when v_doc -> 'sale' ->> 'invoice_no' = v_sale.invoice_no then 'PASS' else 'FAIL' end
    || ': 2. and the invoice number is the stored one (got '
    || coalesce(v_doc -> 'sale' ->> 'invoice_no', 'NULL') || ')');

  -- The reader computes no money: these three are the row's own figures, whatever they are.
  v_log := array_append(v_log, case
    when (v_doc -> 'sale' ->> 'grand_total')::numeric = v_sale.grand_total
     and (v_doc -> 'sale' ->> 'tax_total')::numeric = v_sale.tax_total
     and (v_doc -> 'sale' ->> 'sub_total')::numeric = v_sale.sub_total
      then 'PASS' else 'FAIL' end
    || ': 2. the totals are the STORED row''s, not recomputed (grand '
    || coalesce(v_doc -> 'sale' ->> 'grand_total', 'NULL')
    || ' / tax ' || coalesce(v_doc -> 'sale' ->> 'tax_total', 'NULL')
    || ' / taxable ' || coalesce(v_doc -> 'sale' ->> 'sub_total', 'NULL') || ')');

  select count(*) into v_rows
    from public.sale_items si
   where si.sale_id = v_sale.id;

  v_log := array_append(v_log, case
    when jsonb_array_length(v_doc -> 'lines') = v_rows then 'PASS' else 'FAIL' end
    || ': 3. one line per sale_items row (expected ' || v_rows || ', got '
    || jsonb_array_length(v_doc -> 'lines') || ')');

  -- Order AND the join: two lines out of two different batches must come back with two
  -- different batch numbers, in the order they were inserted. A mis-join would show one
  -- pack's number on both lines, which is the defect this reader exists to prevent.
  v_log := array_append(v_log, case
    when v_doc -> 'lines' -> 0 ->> 'batch_no' = 'ZZTEST-39-A'
     and v_doc -> 'lines' -> 1 ->> 'batch_no' = 'ZZTEST-39-B'
      then 'PASS' else 'FAIL' end
    || ': 4. each line names its OWN pack, in insertion order (got '
    || coalesce(v_doc -> 'lines' -> 0 ->> 'batch_no', 'NULL') || ' then '
    || coalesce(v_doc -> 'lines' -> 1 ->> 'batch_no', 'NULL') || ')');

  v_line := v_doc -> 'lines' -> 0;

  -- 2 x 100 on a 5% slab: total 200.00 with the tax extracted from it (D-075), so the line
  -- money the receipt prints is the stored line's.
  v_log := array_append(v_log, case
    when (v_line -> 'item' ->> 'qty')::int = 2
     and (v_line -> 'item' ->> 'rate')::numeric = 100.00
     and (v_line -> 'item' ->> 'gst_percent')::numeric = 5
     and (v_line -> 'item' ->> 'total_amount')::numeric = 200.00
      then 'PASS' else 'FAIL' end
    || ': 6. a line carries the stored sale_items row (2 x 100 at 5% = 200, got '
    || coalesce(v_line -> 'item' ->> 'total_amount', 'NULL') || ')');

  select b.expiry_date into v_batch_a_expiry
    from public.product_batches b
   where b.id = v_batch_a;

  v_log := array_append(v_log, case
    when (v_line ->> 'expiry_date')::date = v_batch_a_expiry
     and (v_line ->> 'is_unknown_batch')::boolean = false
      then 'PASS' else 'FAIL' end
    || ': 5. a recorded expiry round-trips, and the pack is not flagged unknown (got '
    || coalesce(v_line ->> 'expiry_date', 'NULL') || ')');

  v_line := v_doc -> 'lines' -> 1;

  -- The `->` form on purpose: it distinguishes a key that is present and null from one that is
  -- missing, and the receipt's em dash depends on the key being there.
  v_log := array_append(v_log, case
    when v_line -> 'expiry_date' = 'null'::jsonb then 'PASS' else 'FAIL' end
    || ': 5. a pack with no expiry answers null, so the receipt prints an em dash rather than a '
    || 'fabricated date (got ' || coalesce(v_line ->> 'expiry_date', 'NULL') || ')');

  v_log := array_append(v_log, case
    when (v_line ->> 'is_unknown_batch')::boolean = true then 'PASS' else 'FAIL' end
    || ': 5. and that pack is flagged unknown (is_unknown_batch = '
    || coalesce(v_line ->> 'is_unknown_batch', 'NULL') || ')');

  -- ============================================================== 7. the patient's code
  v_log := array_append(v_log, case
    when v_doc ->> 'patient_code' = v_patient.patient_code then 'PASS' else 'FAIL' end
    || ': 7. the patient''s code is joined on sales.customer_id (got '
    || coalesce(v_doc ->> 'patient_code', 'NULL') || ', expected '
    || coalesce(v_patient.patient_code, 'NULL') || ')');

  v_log := array_append(v_log, case
    when v_doc ->> 'patient_code' ~ '^PT-[0-9]{5}$' then 'PASS' else 'FAIL' end
    || ': 7. and it is the generated form the counter mints (got '
    || coalesce(v_doc ->> 'patient_code', 'NULL') || ')');

  -- ================================================= 8. a package sale: the account row
  v_package_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'package',
    'customer_id', v_hospital_acct,
    'patient_name', 'ZZTEST 39 package patient',
    'patient_mobile', '9000000037',
    'hospital_reference', 'ZZTEST-39-PKG',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product_a, 'batch_id', v_batch_a, 'qty', 1
    ))
  ));

  v_doc := public.sale_document(v_package_sale.id);

  v_log := array_append(v_log, case
    when v_doc -> 'patient_code' = 'null'::jsonb then 'PASS' else 'FAIL' end
    || ': 8. a package bill''s party has no patient code, so the key is present and null - the '
    || 'reason is the party, not a missing join (got '
    || coalesce(v_doc ->> 'patient_code', 'NULL') || ')');

  v_log := array_append(v_log, case
    when v_doc -> 'sale' ->> 'customer_id' = v_hospital_acct::text
      then 'PASS' else 'FAIL' end
    || ': 8. and the party on that bill really is the hospital''s account row (got '
    || coalesce(v_doc -> 'sale' ->> 'customer_id', 'NULL') || ')');

  -- ================================================== 9. a sale with no party at all
  v_transfer_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'transfer',
    'from_location', 'ZZTEST 39 main shelf',
    'to_location', 'ZZTEST 39 ward',
    'transfer_reason', 'ZZTEST 39 stock support',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product_b, 'batch_id', v_batch_b, 'qty', 1
    ))
  ));

  v_doc := public.sale_document(v_transfer_sale.id);

  v_log := array_append(v_log, case
    when v_doc -> 'patient_code' = 'null'::jsonb
     and v_doc -> 'sale' -> 'customer_id' = 'null'::jsonb
      then 'PASS' else 'FAIL' end
    || ': 9. a sale with no party at all (a transfer) answers null rather than failing');

  v_log := array_append(v_log, case
    when v_doc -> 'lines' -> 0 ->> 'batch_no' = 'ZZTEST-39-B'
     and v_doc -> 'lines' -> 0 -> 'expiry_date' = 'null'::jsonb
      then 'PASS' else 'FAIL' end
    || ': 9. and its line still names its pack, with no expiry (got '
    || coalesce(v_doc -> 'lines' -> 0 ->> 'batch_no', 'NULL') || ')');

  -- =================================================== 10. the tenant guard, and absence
  -- Become the OTHER pharmacy's owner in this same transaction. Both the explicit
  -- `pharmacy_id = get_my_pharmacy_id()` guard and the caller's own RLS are in play now.
  perform set_config('request.jwt.claims', json_build_object('sub', v_other_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_other_user::text, true);

  v_log := array_append(v_log, case
    when public.sale_document(v_sale.id) is null then 'PASS' else 'FAIL' end
    || ': 10. another pharmacy''s caller gets nothing for this sale, not someone else''s document');

  v_log := array_append(v_log, case
    when public.sale_document(gen_random_uuid()) is null then 'PASS' else 'FAIL' end
    || ': 10. an id that names no sale answers null');

  -- ================================================================ summary
  -- The count is the ASSERTIONS, not the log's length: the summary line itself is appended to
  -- the same array, and is not counted. The self-check below is what proves nothing is hidden by
  -- that arithmetic - a line that is neither a PASS nor a FAIL would fail it.
  v_log := array_append(v_log, case
    when (select count(*) from unnest(v_log) l
           where coalesce(l, '') not like 'PASS%'
             and coalesce(l, '') not like 'FAIL%') = 0
      then 'PASS' else 'FAIL' end
    || ': 11. every logged line is a PASS or a FAIL (nothing skipped, nothing truncated)');

  v_log := array_append(v_log, 'SUMMARY: '
    || (select count(*) from unnest(v_log) l where l like 'PASS%') || ' PASS / '
    || (select count(*) from unnest(v_log) l where l like 'FAIL%') || ' FAIL of '
    || (select count(*) from unnest(v_log) l
         where l like 'PASS%' or l like 'FAIL%') || ' assertions');

  raise exception E'PHASE7A SALE DOCUMENT TEST\n%', array_to_string(v_log, chr(10));
end $$;
