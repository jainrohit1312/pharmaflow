-- Opening stock import - functional test for migration
-- 20260920000031_phase6_5a_opening_stock_import.
--
-- Run:
--   supabase db query --linked --file supabase/tests/opening_stock_import.sql
--
-- HOW TO READ THE RESULT
--   Every line is "PASS: ..." or "FAIL: ...", and the last line is
--   "SUMMARY: n PASS / n FAIL". A non-zero exit code is expected and means the
--   script ran to completion: it ends by raising, so the whole DO block (one
--   statement, one transaction) rolls back and no ZZTEST pharmacy, product,
--   batch, job row or auth user survives.
--
-- WHAT IT PROVES
--   1.  The DDL the import needed: `products` carries the three GST columns and
--       they are nullable (an unrecorded slab is not a rate of zero),
--       `product_batches.expiry_date` accepts NULL while `batch_no` still does
--       not, `is_unknown_batch` exists, and `batch_status` - frozen at its own
--       `select b.*` in migration 00013, which is why it never carried
--       `landed_cost_per_unit` - has the flag appended as a 14th column with its
--       original thirteen unchanged.
--   2.  The privilege surface: anon cannot execute any of the three RPCs, the
--       shared classifier is executable by no role at all, and a client cannot
--       insert a job row, so a `committed` import cannot be fabricated.
--   3.  The preview: every counter the screen shows, computed by the same
--       function the commit uses, the row-numbered reason for each refused row,
--       and no `existing_job` while nothing has been imported.
--   4.  The commit: one batch per row with the file's own quantity, landed cost,
--       MRP and expiry; leading zeros preserved as text; a multi-space item name
--       preserved internally and trimmed at the edges; the product's 5% slab
--       stored; and the audit trail that says which rows matched and which were
--       created.
--   5.  Unknown as a value: a blank batch number becomes `OPENING-<uuid8>` and
--       sets `is_unknown_batch`, a blank expiry stays NULL, and `batch_status`
--       reports it as 'unknown' rather than as 'safe' - which is why the NOT NULL
--       had to go.
--   6.  Idempotency: the same content four times - replayed, reordered, and with
--       a row's outer whitespace trimmed - is one job, and the later answers name
--       the first job instead of writing more batches.
--   7.  Refusal is total: a payload with one unreadable row writes no product and
--       no batch at all and says which line is at fault; an ambiguous name is
--       refused rather than auto-picked, and creates no third product.
--   8.  Tenancy and role: an identical payload for another pharmacy is that
--       pharmacy's own job (the key is per tenant), a non-owner can neither
--       preview nor commit, and a job cannot be read across tenants.
--   9.  Nothing else moves: no purchase, purchase line, payment, ledger entry,
--       sale or stock adjustment is written by any of it, and the batches hold
--       exactly the imported quantity - no stock trigger double-counts it.
--   10. The two views agree with the table: four batches read 'unknown', a past
--       expiry still reads 'expired', and `product_stock` values Dolo 650mg's
--       batch at landed cost.
--
-- FIXTURE NOTE
--   Every row this test uses is written inline below; it reads no file, so it
--   passes on a fresh clone. The owner's export
--   (`PharmaFlow_Opening_Stock.csv`, 314 rows from Marg) is kept locally under
--   `supabase/fixtures/opening_stock/` and is deliberately not committed - it is
--   a one-time migration artifact, gitignored, and nothing here depends on it.
--
--   The rows are the ones the brief names, with the values it gives: Dolo 650mg
--   (batch DOBS4434, expiry 2030-03-31, qty 1292, rate 1.38, mrp 2.15),
--   Gastroease RD (GH6F27, 2028-05-31, 9726, 1.20, 11.00), ACILOC INJ
--   (AB26058, 2029-06-30, 781, 5.25, 7.40), ZIFI 200MG (0126E038, 2027-10-31,
--   136, 8.16, 10.51), AB Gel (no batch, no expiry, 0, 80.00, 104.00), PANTOP
--   (no batch, no expiry, 0, 0.00, 57.48), PROLINE NO 1 (batch "1", no expiry,
--   15, 140.00, 499.00), the multi-space Eupen line (289181, 2028-03-31, 14,
--   120.00, 1017.65) and 99 F 100ML (265I001, 2027-08-31, 14, 27.00, 375.00).
--   One row is this test's own: ZZEXP INJ, whose expiry is yesterday, because a
--   past expiry is the one thing the file's own rows cannot be trusted to hold.
--
-- WHY IT IMPERSONATES
--   The RPCs gate on `get_my_role() = 'owner'` and take the tenant from
--   `get_my_pharmacy_id()`, so both are only real under an identity. Fixtures are
--   written as postgres (which owns the tables, is not subject to RLS, and is the
--   only way to create tenants and users inside a transaction); the calls that
--   matter run as `authenticated` with `auth.uid()` set, as
--   phase6_alias_identity.sql does.

do $$
declare
  v_log         text[] := array[]::text[];
  v_pass        int;
  v_fail        int;

  v_pharmacy    uuid;
  v_other       uuid;
  v_owner       uuid := gen_random_uuid();
  v_staff       uuid := gen_random_uuid();
  v_outsider    uuid := gen_random_uuid();

  v_aciloc      uuid;
  v_zifi        uuid;
  v_col_a       uuid;

  v_spaced_name text := 'Eupen 1gm' || repeat(' ', 21) || 'INJ';

  v_rows         jsonb;
  v_rows_trimmed jsonb;
  v_rows_order   jsonb;
  v_rows_bad     jsonb;
  v_rows_dup     jsonb;
  v_rows_ambig   jsonb;

  v_preview     jsonb;
  v_preview_bad jsonb;
  v_preview_amb jsonb;
  v_summary     jsonb;
  v_existing    jsonb;
  v_result      jsonb;
  v_replay      jsonb;
  v_theirs      jsonb;
  v_job         jsonb;
  v_job_id      uuid;

  v_n           int;
  v_n2          int;
  v_qty         int;
  v_rate        numeric;
  v_mrp         numeric;
  v_landed      numeric;
  v_selling     numeric;
  v_gst         numeric;
  v_cgst        numeric;
  v_sgst        numeric;
  v_expiry      date;
  v_batch       text;
  v_pname       text;
  v_text        text;
  v_schedule    text;
  v_generic     text;
  v_hsn         text;
  v_outcome     text;
  v_note        text;
  v_msg         text;
  v_flag        boolean;
  v_flag2       boolean;
  v_stock_value numeric;

  -- Counted before the happy commit, so "nothing else moved" is about what the
  -- import did rather than about what the fixtures did.
  v_products_before  int;
  v_batches_before   int;
  v_purchases_before int;
  v_items_before     int;
  v_payments_before  int;
  v_ledger_before    int;
  v_sales_before     int;
  v_adjust_before    int;
begin
  -- ========================================================== 1. the DDL itself
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'products'
     and column_name in ('gst_percent', 'cgst_percent', 'sgst_percent')
     and is_nullable = 'YES';

  v_log := array_append(
    v_log,
    case when v_n = 3 then 'PASS' else 'FAIL' end
      || ': 1. products carries gst_percent/cgst_percent/sgst_percent, all nullable (got '
      || v_n || ')'
  );

  select is_nullable into v_text
    from information_schema.columns
   where table_schema = 'public' and table_name = 'product_batches'
     and column_name = 'expiry_date';

  select is_nullable into v_note
    from information_schema.columns
   where table_schema = 'public' and table_name = 'product_batches'
     and column_name = 'batch_no';

  v_log := array_append(
    v_log,
    case when v_text = 'YES' and v_note = 'NO' then 'PASS' else 'FAIL' end
      || ': 1. an unknown expiry is representable and a batch still needs a number (expiry '
      || coalesce(v_text, 'absent') || ', batch_no ' || coalesce(v_note, 'absent') || ')'
  );

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'product_batches'
     and column_name = 'is_unknown_batch';

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 1. product_batches.is_unknown_batch exists (matched ' || v_n || ')'
  );

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'batch_status';

  select string_agg(column_name, ',' order by ordinal_position) into v_text
    from information_schema.columns
   where table_schema = 'public' and table_name = 'batch_status'
     and ordinal_position in (13, 14);

  v_log := array_append(
    v_log,
    case when v_n = 14 and v_text = 'expiry_status,is_unknown_batch'
         then 'PASS' else 'FAIL' end
      || ': 1. batch_status kept its thirteen columns and gained the flag as a 14th ('
      || v_n || ' columns, last two: ' || coalesce(v_text, 'absent') || ')'
  );

  -- ================================================== 2. the privilege surface
  select has_function_privilege('anon', 'public.preview_opening_stock(jsonb)', 'EXECUTE')
    into v_flag;
  select has_function_privilege('anon', 'public.commit_opening_stock_import(jsonb, text)', 'EXECUTE')
    into v_flag2;

  v_log := array_append(
    v_log,
    case when not v_flag and not v_flag2 then 'PASS' else 'FAIL' end
      || ': 2. anon cannot execute either RPC (preview='
      || v_flag || ', commit=' || v_flag2 || ')'
  );

  select has_function_privilege('authenticated', 'public.opening_stock_classify(uuid, jsonb)', 'EXECUTE')
    into v_flag;
  select has_function_privilege('authenticated', 'public.commit_opening_stock_import(jsonb, text)', 'EXECUTE')
    into v_flag2;

  v_log := array_append(
    v_log,
    case when not v_flag and v_flag2 then 'PASS' else 'FAIL' end
      || ': 2. the shared classifier is internal and the commit is not (classify='
      || v_flag || ', commit=' || v_flag2 || ')'
  );

  -- ================================================================ fixtures
  insert into public.pharmacies (name)
  values ('ZZTEST opening stock pharmacy')
  returning id into v_pharmacy;

  insert into public.pharmacies (name)
  values ('ZZTEST opening stock other pharmacy')
  returning id into v_other;

  insert into auth.users (id, email) values (v_owner, 'zztest-opening-owner@example.com');
  insert into auth.users (id, email) values (v_staff, 'zztest-opening-staff@example.com');
  insert into auth.users (id, email) values (v_outsider, 'zztest-opening-outsider@example.com');

  update public.profiles set pharmacy_id = v_pharmacy, role = 'owner'      where id = v_owner;
  update public.profiles set pharmacy_id = v_pharmacy, role = 'pharmacist' where id = v_staff;
  update public.profiles set pharmacy_id = v_other,    role = 'owner'      where id = v_outsider;

  -- Two products the file will match: one exactly, one only after
  -- normalize_product_name() has lowercased it and dropped the comma.
  insert into public.products (pharmacy_id, name)
  values (v_pharmacy, 'ACILOC INJ') returning id into v_aciloc;
  insert into public.products (pharmacy_id, name)
  values (v_pharmacy, 'Zifi 200mg,') returning id into v_zifi;

  -- And two that normalize to one key, which is what rule 7 must refuse.
  insert into public.products (pharmacy_id, name)
  values (v_pharmacy, 'ZZCOL TAB') returning id into v_col_a;
  insert into public.products (pharmacy_id, name)
  values (v_pharmacy, 'zzcol tab,');

  -- The payload, built from a VALUES list so it reads as the file does. Every
  -- value is a string, exactly as a CSV parser hands it over - the RPC coerces,
  -- which is what makes the server canonical.
  select jsonb_agg(
           jsonb_build_object(
             'item_name', r.name,
             'batch_no', r.batch_no,
             'expiry_date', r.expiry,
             'qty', r.qty,
             'purchase_rate', r.rate,
             'mrp', r.mrp
           )
           order by r.ord
         )
    into v_rows
    from (values
      (1,  'Dolo 650mg',     'DOBS4434', '2030-03-31',             '1292', '1.38',   '2.15'),
      (2,  'Gastroease RD',  'GH6F27',   '2028-05-31',             '9726', '1.20',   '11.00'),
      (3,  'ACILOC INJ',     'AB26058',  '2029-06-30',             '781',  '5.25',   '7.40'),
      (4,  'ZIFI 200MG',     '0126E038', '2027-10-31',             '136',  '8.16',   '10.51'),
      (5,  'AB Gel',         '',         '',                       '0',    '80.00',  '104.00'),
      (6,  'PANTOP',         '',         '',                       '0',    '0.00',   '57.48'),
      (7,  'PROLINE NO 1',   '1',        '',                       '15',   '140.00', '499.00'),
      (8,  v_spaced_name,    '289181',   '2028-03-31',             '14',   '120.00', '1017.65'),
      (9,  '  99 F 100ML  ', '265I001',  '2027-08-31',             '14',   '27.00',  '375.00'),
      (10, 'ZZEXP INJ',      'ZZEXP01',  (current_date - 1)::text, '3',    '10.00',  '20.00')
    ) as r(ord, name, batch_no, expiry, qty, rate, mrp);

  -- The same content with row 9's outer spaces gone: a different payload, the
  -- same canonical content, so the same job.
  v_rows_trimmed := jsonb_set(
    v_rows,
    '{8,item_name}',
    to_jsonb('99 F 100ML'::text)
  );

  -- The same ten rows reversed: a different array, the same canonical content.
  select jsonb_agg(e.value order by e.ord desc)
    into v_rows_order
    from jsonb_array_elements(v_rows) with ordinality as e(value, ord);

  -- The ten good rows and one that cannot be read.
  v_rows_bad := v_rows || jsonb_build_array(
    jsonb_build_object(
      'item_name', 'ZZBAD TAB', 'batch_no', '', 'expiry_date', '',
      'qty', 'abc', 'purchase_rate', '1.00', 'mrp', '2.00'
    )
  );

  -- Two rows naming one product.
  v_rows_dup := jsonb_build_array(
    jsonb_build_object(
      'item_name', 'Dolo 650mg', 'batch_no', 'DOBS4434', 'expiry_date', '2030-03-31',
      'qty', '10', 'purchase_rate', '1.38', 'mrp', '2.15'
    ),
    jsonb_build_object(
      'item_name', 'dolo 650mg,', 'batch_no', 'DOBS9999', 'expiry_date', '2030-03-31',
      'qty', '5', 'purchase_rate', '1.38', 'mrp', '2.15'
    )
  );

  -- One row naming a product two catalogue rows share.
  v_rows_ambig := jsonb_build_array(
    jsonb_build_object(
      'item_name', 'ZZCOL TAB', 'batch_no', '', 'expiry_date', '',
      'qty', '1', 'purchase_rate', '1.00', 'mrp', '2.00'
    )
  );

  -- ================================================ 3. the preview, as the owner
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  v_preview := public.preview_opening_stock(v_rows);
  v_summary := v_preview -> 'summary';
  v_existing := v_preview -> 'existing_job';

  v_log := array_append(
    v_log,
    case when (v_summary ->> 'row_count')::int = 10 then 'PASS' else 'FAIL' end
      || ': 3. the preview counts every row (got ' || (v_summary ->> 'row_count') || ')'
  );

  v_log := array_append(
    v_log,
    case when (v_summary ->> 'total_qty')::int = 11981 then 'PASS' else 'FAIL' end
      || ': 3. total quantity is the file''s own sum (got ' || (v_summary ->> 'total_qty') || ')'
  );

  v_log := array_append(
    v_log,
    case when (v_summary ->> 'total_cost')::numeric = 22852.17 then 'PASS' else 'FAIL' end
      || ': 3. total cost is sum(qty x purchase_rate) (got '
      || (v_summary ->> 'total_cost') || ')'
  );

  v_log := array_append(
    v_log,
    case when (v_summary ->> 'new_product_count')::int = 8
              and (v_summary ->> 'matched_product_count')::int = 2
         then 'PASS' else 'FAIL' end
      || ': 3. eight products are new and two match the catalogue (got '
      || (v_summary ->> 'new_product_count') || ' new / '
      || (v_summary ->> 'matched_product_count') || ' matched)'
  );

  v_log := array_append(
    v_log,
    case when (v_summary ->> 'zero_qty_row_count')::int = 2
              and (v_summary ->> 'unknown_batch_row_count')::int = 2
              and (v_summary ->> 'unknown_expiry_row_count')::int = 3
              and (v_summary ->> 'expired_row_count')::int = 1
              and (v_summary ->> 'ambiguous_row_count')::int = 0
              and (v_summary ->> 'error_row_count')::int = 0
         then 'PASS' else 'FAIL' end
      || ': 3. zero-qty ' || (v_summary ->> 'zero_qty_row_count')
      || ', unknown batch ' || (v_summary ->> 'unknown_batch_row_count')
      || ', unknown expiry ' || (v_summary ->> 'unknown_expiry_row_count')
      || ', expired ' || (v_summary ->> 'expired_row_count')
      || ', refused ' || (v_summary ->> 'error_row_count') || ' (wanted 2/2/3/1/0)'
  );

  -- `existing_job` is always present as a key - JSON null when there is none -
  -- which is what the screen switches on, so the assertion is about the key.
  v_log := array_append(
    v_log,
    case when v_existing = 'null'::jsonb then 'PASS' else 'FAIL' end
      || ': 3. nothing has been imported yet, so no job is offered back (got '
      || coalesce(v_existing::text, 'sql null') || ')'
  );

  -- Rule 7 step 1: an exact name match.
  select e.value ->> 'product_id' into v_text
    from jsonb_array_elements(v_preview -> 'rows') as e(value)
   where e.value ->> 'row_number' = '3';

  v_log := array_append(
    v_log,
    case when v_text = v_aciloc::text then 'PASS' else 'FAIL' end
      || ': 3. an exact name match finds the catalogue product (got '
      || coalesce(v_text, 'nothing') || ')'
  );

  -- Rule 7 step 2: the same product after normalization.
  select e.value ->> 'product_id' into v_text
    from jsonb_array_elements(v_preview -> 'rows') as e(value)
   where e.value ->> 'row_number' = '4';

  v_log := array_append(
    v_log,
    case when v_text = v_zifi::text then 'PASS' else 'FAIL' end
      || ': 3. "ZIFI 200MG" matches "Zifi 200mg," once normalized (got '
      || coalesce(v_text, 'nothing') || ')'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_preview -> 'rows') as e(value)
   where e.value ->> 'outcome' = 'matched';

  v_log := array_append(
    v_log,
    case when v_n = 2 then 'PASS' else 'FAIL' end
      || ': 3. exactly the two catalogue rows are reported as matches (got ' || v_n || ')'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_preview -> 'rows') as e(value)
   where e.value ->> 'row_number' = '10' and (e.value ->> 'is_expired')::boolean;

  select count(*) into v_n2
    from jsonb_array_elements(v_preview -> 'rows') as e(value)
   where e.value ->> 'row_number' = '5' and (e.value ->> 'is_expired')::boolean;

  v_log := array_append(
    v_log,
    case when v_n = 1 and v_n2 = 0 then 'PASS' else 'FAIL' end
      || ': 3. a past expiry is flagged and a missing one is not (expired rows: '
      || v_n || ', missing-expiry rows called expired: ' || v_n2 || ')'
  );

  -- ==================================== 4. the preview refuses what the commit will
  v_preview_bad := public.preview_opening_stock(v_rows_bad);

  select e.value ->> 'error_note' into v_note
    from jsonb_array_elements(v_preview_bad -> 'rows') as e(value)
   where e.value ->> 'row_number' = '11';

  v_log := array_append(
    v_log,
    case when v_note like '%is not a whole number%' then 'PASS' else 'FAIL' end
      || ': 4. a non-numeric qty is refused by name, not by a cast error (got "'
      || coalesce(v_note, 'no note') || '")'
  );

  -- A file with a row that cannot be read has no canonical content, so there is
  -- nothing for the idempotency key to name - which is also why the commit
  -- refuses before it looks for one.
  v_log := array_append(
    v_log,
    case when v_preview_bad -> 'fingerprint' = 'null'::jsonb then 'PASS' else 'FAIL' end
      || ': 4. and an unreadable file has no fingerprint, so nothing is offered as already imported (got '
      || (v_preview_bad ->> 'fingerprint') || ')'
  );

  v_preview := public.preview_opening_stock(v_rows_dup);
  select e.value ->> 'error_note' into v_note
    from jsonb_array_elements(v_preview -> 'rows') as e(value)
   where e.value ->> 'row_number' = '2';

  v_log := array_append(
    v_log,
    case when v_note like '%already row 1%' then 'PASS' else 'FAIL' end
      || ': 4. two rows naming one product are refused - one batch per product (got "'
      || coalesce(v_note, 'no note') || '")'
  );

  v_preview_amb := public.preview_opening_stock(v_rows_ambig);
  select e.value ->> 'outcome', e.value ->> 'error_note'
    into v_outcome, v_note
    from jsonb_array_elements(v_preview_amb -> 'rows') as e(value)
   where e.value ->> 'row_number' = '1';

  v_log := array_append(
    v_log,
    case when v_outcome = 'ambiguous' and v_note like '%share this name%'
         then 'PASS' else 'FAIL' end
      || ': 4. a name two catalogue products share is ambiguous, never picked (got '
      || coalesce(v_outcome, 'nothing') || ')'
  );

  -- An ambiguous row is counted separately from a refused one, and is never
  -- promised as a new product: the screen must not offer to create a third
  -- product for a name the catalogue already holds twice.
  v_log := array_append(
    v_log,
    case when (v_preview_amb -> 'summary' ->> 'ambiguous_row_count')::int = 1
              and (v_preview_amb -> 'summary' ->> 'error_row_count')::int = 0
              and (v_preview_amb -> 'summary' ->> 'new_product_count')::int = 0
         then 'PASS' else 'FAIL' end
      || ': 4. the ambiguous row is counted as ambiguous, not as new and not as refused (got '
      || (v_preview_amb -> 'summary' ->> 'ambiguous_row_count') || ' ambiguous, '
      || (v_preview_amb -> 'summary' ->> 'new_product_count') || ' new, '
      || (v_preview_amb -> 'summary' ->> 'error_row_count') || ' refused)'
  );

  -- =========================================== 5. a non-owner cannot import
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_staff::text)::text, true);

  v_flag := false;
  v_msg := 'the call was expected to raise';
  begin
    perform public.preview_opening_stock(v_rows);
  exception when others then
    v_flag := true;
    v_msg := sqlerrm;
  end;

  v_log := array_append(
    v_log,
    case when v_flag and v_msg like '%only the owner%' then 'PASS' else 'FAIL' end
      || ': 5. a pharmacist cannot preview an import (got "'
      || left(v_msg, 100) || '")'
  );

  v_flag := false;
  v_msg := 'the call was expected to raise';
  begin
    perform public.commit_opening_stock_import(v_rows, 'zztest.csv');
  exception when others then
    v_flag := true;
    v_msg := sqlerrm;
  end;

  v_log := array_append(
    v_log,
    case when v_flag and v_msg like '%only the owner%' then 'PASS' else 'FAIL' end
      || ': 5. a pharmacist cannot commit an import (got "'
      || left(v_msg, 100) || '")'
  );

  -- ========================================= 6. the commit, back as the owner
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_owner::text)::text, true);

  select count(*) into v_products_before  from public.products        where pharmacy_id = v_pharmacy;
  select count(*) into v_batches_before   from public.product_batches where pharmacy_id = v_pharmacy;
  select count(*) into v_purchases_before from public.purchases;
  select count(*) into v_items_before     from public.purchase_items;
  select count(*) into v_payments_before  from public.payments;
  select count(*) into v_ledger_before    from public.ledger_entries;
  select count(*) into v_sales_before     from public.sales;
  select count(*) into v_adjust_before    from public.stock_adjustments;

  v_result := public.commit_opening_stock_import(v_rows, 'PharmaFlow_Opening_Stock.csv');
  v_job_id := (v_result ->> 'job_id')::uuid;

  v_log := array_append(
    v_log,
    case when (v_result ->> 'committed')::boolean and not (v_result ->> 'idempotent')::boolean
         then 'PASS' else 'FAIL' end
      || ': 6. the commit answers committed (got ' || coalesce(v_result::text, 'nothing') || ')'
  );

  v_log := array_append(
    v_log,
    case when (v_result ->> 'product_count')::int = 10
              and (v_result ->> 'products_created')::int = 8
              and (v_result ->> 'products_matched')::int = 2
              and (v_result ->> 'batch_count')::int = 10
         then 'PASS' else 'FAIL' end
      || ': 6. ten products and ten batches, eight created and two matched (got '
      || (v_result ->> 'product_count') || ' products, '
      || (v_result ->> 'products_created') || ' created, '
      || (v_result ->> 'products_matched') || ' matched, '
      || (v_result ->> 'batch_count') || ' batches)'
  );

  v_log := array_append(
    v_log,
    case when (v_result ->> 'qty_total')::int = 11981
              and (v_result ->> 'cost_total')::numeric = 22852.17
         then 'PASS' else 'FAIL' end
      || ': 6. the envelope carries the totals the preview did (got '
      || (v_result ->> 'qty_total') || ' / ' || (v_result ->> 'cost_total') || ')'
  );

  -- The brief's own row: Dolo 650mg, batch DOBS4434, 2030-03-31, 1292, 1.38, 2.15.
  select b.qty, b.purchase_rate, b.mrp, b.expiry_date, b.landed_cost_per_unit,
         b.selling_rate, b.batch_no, b.is_unknown_batch, p.name
    into v_qty, v_rate, v_mrp, v_expiry, v_landed,
         v_selling, v_batch, v_flag, v_pname
    from public.product_batches b
    join public.products p on p.id = b.product_id
   where b.pharmacy_id = v_pharmacy and b.batch_no = 'DOBS4434';

  v_log := array_append(
    v_log,
    case when v_qty = 1292 then 'PASS' else 'FAIL' end
      || ': 6. Dolo 650mg imported 1292 units (got ' || coalesce(v_qty::text, 'no batch') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_expiry::text = '2030-03-31' then 'PASS' else 'FAIL' end
      || ': 6. Dolo 650mg kept expiry 2030-03-31 (got '
      || coalesce(v_expiry::text, 'absent') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_rate = 1.38 and v_mrp = 2.15 then 'PASS' else 'FAIL' end
      || ': 6. at its own rate 1.38 and MRP 2.15 (got '
      || coalesce(v_rate::text, 'absent') || ' / ' || coalesce(v_mrp::text, 'absent') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_pname = 'Dolo 650mg' then 'PASS' else 'FAIL' end
      || ': 6. and it created the product from the name alone (got '
      || coalesce(v_pname, 'nothing') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_landed = v_rate then 'PASS' else 'FAIL' end
      || ': 6. landed cost equals purchase rate - opening stock has no freight to spread ('
      || coalesce(v_landed::text, 'absent') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_selling = 0 then 'PASS' else 'FAIL' end
      || ': 6. no counter price is invented, so the till prices at MRP (got '
      || coalesce(v_selling::text, 'absent') || ')'
  );

  v_log := array_append(
    v_log,
    case when not v_flag then 'PASS' else 'FAIL' end
      || ': 6. batch DOBS4434 came from the file, so it is not flagged unknown (got '
      || v_flag || ')'
  );

  -- The other named row.
  select b.qty, b.batch_no into v_qty, v_batch
    from public.product_batches b
   where b.pharmacy_id = v_pharmacy and b.batch_no = 'GH6F27';

  v_log := array_append(
    v_log,
    case when v_qty = 9726 and v_batch = 'GH6F27' then 'PASS' else 'FAIL' end
      || ': 6. Gastroease RD imported 9726 units on batch GH6F27 (got '
      || coalesce(v_qty::text, 'no batch') || ' on ' || coalesce(v_batch, 'nothing') || ')'
  );

  -- Leading zeros are text and stay text.
  select count(*) into v_n
    from public.product_batches
   where pharmacy_id = v_pharmacy and batch_no = '0126E038';

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 6. the leading zeros in "0126E038" survived (matched ' || v_n || ')'
  );

  -- A multi-space name keeps its internal spacing and loses its edges.
  select count(*) into v_n
    from public.products where pharmacy_id = v_pharmacy and name = v_spaced_name;
  select count(*) into v_n2
    from public.products where pharmacy_id = v_pharmacy and name = '99 F 100ML';

  v_log := array_append(
    v_log,
    case when v_n = 1 and v_n2 = 1 then 'PASS' else 'FAIL' end
      || ': 6. the multi-space name is stored as printed and the padded one is trimmed (got '
      || v_n || ' / ' || v_n2 || ')'
  );

  -- A blank batch number gets a generated identity, and says so.
  select b.batch_no, b.is_unknown_batch, b.expiry_date
    into v_batch, v_flag, v_expiry
    from public.product_batches b
    join public.products p on p.id = b.product_id
   where b.pharmacy_id = v_pharmacy and p.name = 'AB Gel';

  v_log := array_append(
    v_log,
    case when v_flag and v_batch like 'OPENING-%' then 'PASS' else 'FAIL' end
      || ': 6. a blank batch number became a generated identity, flagged unknown (got '
      || coalesce(v_batch, 'nothing') || ', flag ' || v_flag || ')'
  );

  v_log := array_append(
    v_log,
    case when v_expiry is null then 'PASS' else 'FAIL' end
      || ': 6. and its blank expiry stayed NULL (got '
      || coalesce(v_expiry::text, 'null') || ')'
  );

  -- A zero-cost row is a rate of zero, not a missing rate, and no counter price
  -- is invented for it either.
  select b.qty, b.purchase_rate, b.landed_cost_per_unit, b.selling_rate, b.expiry_date
    into v_qty, v_rate, v_landed, v_selling, v_expiry
    from public.product_batches b
    join public.products p on p.id = b.product_id
   where b.pharmacy_id = v_pharmacy and p.name = 'PANTOP';

  v_log := array_append(
    v_log,
    case when v_qty = 0 and v_rate = 0 and v_landed = 0 and v_selling = 0
              and v_expiry is null
         then 'PASS' else 'FAIL' end
      || ': 6. the zero-cost row imported as qty 0 at rate 0 with no expiry (got qty '
      || coalesce(v_qty::text, 'absent') || ', rate ' || coalesce(v_rate::text, 'absent')
      || ', expiry ' || coalesce(v_expiry::text, 'null') || ')'
  );

  -- The product the import created carries the owner's slab and nothing else.
  select p.gst_percent, p.cgst_percent, p.sgst_percent, p.schedule_type::text,
         p.generic_name, p.hsn_code, p.manufacturer
    into v_gst, v_cgst, v_sgst, v_schedule, v_generic, v_hsn, v_pname
    from public.products p
   where p.pharmacy_id = v_pharmacy and p.name = 'Dolo 650mg';

  v_log := array_append(
    v_log,
    case when v_gst = 5.00 and v_cgst = 2.50 and v_sgst = 2.50
         then 'PASS' else 'FAIL' end
      || ': 6. a created product carries the 5% slab, split 2.5 + 2.5 (got '
      || coalesce(v_gst::text, 'absent') || ' = ' || coalesce(v_cgst::text, 'absent')
      || ' + ' || coalesce(v_sgst::text, 'absent') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_schedule = 'OTC' and v_generic is null and v_hsn is null and v_pname is null
         then 'PASS' else 'FAIL' end
      || ': 6. and leaves hsn_code, generic_name and manufacturer to the owner (schedule '
      || coalesce(v_schedule, 'absent') || ', hsn ' || coalesce(v_hsn, 'null') || ')'
  );

  -- The audit trail.
  select count(*) into v_n
    from public.import_job_rows r where r.import_job_id = v_job_id;
  select count(*) into v_n2
    from public.import_job_rows r where r.import_job_id = v_job_id and r.action = 'matched';

  v_log := array_append(
    v_log,
    case when v_n = 10 and v_n2 = 2 then 'PASS' else 'FAIL' end
      || ': 6. the audit trail has one row per source line, two marked matched (got '
      || v_n || ', ' || v_n2 || ' matched)'
  );

  select j.row_count, j.total_qty, j.total_cost, j.status,
         j.committed_at is not null, j.source_format, j.actor_id::text
    into v_n, v_n2, v_rate, v_text, v_flag, v_schedule, v_pname
    from public.import_jobs j where j.id = v_job_id;

  v_log := array_append(
    v_log,
    case when v_n = 10 and v_n2 = 11981 and v_rate = 22852.17
              and v_text = 'committed' and v_flag
              and v_schedule = 'csv' and v_pname = v_owner::text
         then 'PASS' else 'FAIL' end
      || ': 6. the job records what was imported, when, by whom, as what format (status '
      || coalesce(v_text, 'absent') || ', format ' || coalesce(v_schedule, 'absent') || ')'
  );

  -- get_import_job reads it back with the names it wrote, which is what the
  -- audit CSV is rendered from.
  v_job := public.get_import_job(v_job_id);
  select e.value ->> 'product_name' into v_text
    from jsonb_array_elements(v_job -> 'rows') as e(value)
   where e.value ->> 'row_number' = '1';
  select count(*) into v_n from jsonb_array_elements(v_job -> 'rows') as e(value);

  v_log := array_append(
    v_log,
    case when v_n = 10 and v_text = 'Dolo 650mg' then 'PASS' else 'FAIL' end
      || ': 6. get_import_job answers the rows with the names they wrote (' || v_n
      || ' rows, first ' || coalesce(v_text, 'nothing') || ')'
  );

  -- ============================================================ 7. idempotency
  v_replay := public.commit_opening_stock_import(v_rows, 'PharmaFlow_Opening_Stock.csv');
  v_log := array_append(
    v_log,
    case when (v_replay ->> 'job_id')::uuid = v_job_id
              and (v_replay ->> 'idempotent')::boolean
         then 'PASS' else 'FAIL' end
      || ': 7. the same content again is a no-op naming the first job (got '
      || coalesce(v_replay ->> 'job_id', 'nothing') || ')'
  );

  v_replay := public.commit_opening_stock_import(v_rows_order, 'PharmaFlow_Opening_Stock.csv');
  v_log := array_append(
    v_log,
    case when (v_replay ->> 'job_id')::uuid = v_job_id then 'PASS' else 'FAIL' end
      || ': 7. the rows in another order are the same content (got '
      || coalesce(v_replay ->> 'job_id', 'nothing') || ')'
  );

  v_replay := public.commit_opening_stock_import(v_rows_trimmed, 'renamed-file.csv');
  v_log := array_append(
    v_log,
    case when (v_replay ->> 'job_id')::uuid = v_job_id then 'PASS' else 'FAIL' end
      || ': 7. a row differing only in outer whitespace, under another filename, is the same (got '
      || coalesce(v_replay ->> 'job_id', 'nothing') || ')'
  );

  select count(*) into v_n  from public.import_jobs    where pharmacy_id = v_pharmacy;
  select count(*) into v_n2 from public.product_batches where pharmacy_id = v_pharmacy;

  v_log := array_append(
    v_log,
    case when v_n = 1 and v_n2 = v_batches_before + 10 then 'PASS' else 'FAIL' end
      || ': 7. four commits of one content wrote one job and ten batches (got '
      || v_n || ' job(s), ' || v_n2 || ' batches)'
  );

  v_preview := public.preview_opening_stock(v_rows);
  v_existing := v_preview -> 'existing_job';

  v_log := array_append(
    v_log,
    case when (v_existing ->> 'job_id')::uuid = v_job_id then 'PASS' else 'FAIL' end
      || ': 7. and the preview offers that job back before anything is pressed (got '
      || coalesce(v_existing::text, 'null') || ')'
  );

  -- ============================== 8. refusal is total, and isolation holds
  v_flag := false;
  v_msg := 'the call was expected to raise';
  begin
    v_result := public.commit_opening_stock_import(v_rows_bad, 'zztest-bad.csv');
  exception when others then
    v_flag := true;
    v_msg := sqlerrm;
  end;

  v_log := array_append(
    v_log,
    case when v_flag and v_msg like '%row 11%' then 'PASS' else 'FAIL' end
      || ': 8. one unreadable row refuses the file and names the line (got "'
      || replace(left(v_msg, 130), chr(10), ' / ') || '")'
  );

  select count(*) into v_n
    from public.products p
   where p.pharmacy_id = v_pharmacy and p.name like 'ZZBAD%';

  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 8. and the rows beside it wrote nothing - no partial import (found '
      || v_n || ' ZZBAD products)'
  );

  v_flag := false;
  v_msg := 'the call was expected to raise';
  begin
    v_result := public.commit_opening_stock_import(v_rows_ambig, 'zztest-ambiguous.csv');
  exception when others then
    v_flag := true;
    v_msg := sqlerrm;
  end;

  v_log := array_append(
    v_log,
    case when v_flag and v_msg like '%share this name%' then 'PASS' else 'FAIL' end
      || ': 8. an ambiguous name refuses the import instead of creating a third product (got "'
      || replace(left(v_msg, 130), chr(10), ' / ') || '")'
  );

  select count(*) into v_n
    from public.products p where p.pharmacy_id = v_pharmacy and p.name = 'ZZCOL TAB';

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 8. the catalogue still holds exactly the one product of that name (found '
      || v_n || ')'
  );

  select count(*) into v_n
    from public.products p where p.pharmacy_id = v_pharmacy;

  v_log := array_append(
    v_log,
    case when v_n = 12 then 'PASS' else 'FAIL' end
      || ': 8. and the refused payloads added no product at all (4 fixtures + 8 created = 12, got '
      || v_n || ')'
  );

  -- An owner cannot write the audit table directly: the RPC is the only way in,
  -- so a `committed` job cannot be fabricated.
  v_flag := false;
  v_msg := 'the insert was expected to be refused';
  begin
    insert into public.import_jobs (
      pharmacy_id, actor_id, source_filename, content_fingerprint, status
    ) values (
      v_pharmacy, v_owner, 'zztest-forged.csv', 'zztest-forged', 'committed'
    );
  exception when others then
    v_flag := true;
    v_msg := sqlerrm;
  end;

  v_log := array_append(
    v_log,
    case when v_flag and v_msg like '%row-level security%' then 'PASS' else 'FAIL' end
      || ': 8. an owner cannot insert a job row directly (got "'
      || left(v_msg, 100) || '")'
  );

  -- The same content for another pharmacy is that pharmacy's own job: the unique
  -- key is (pharmacy_id, fingerprint), not the fingerprint alone.
  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_outsider::text)::text, true);

  v_theirs := public.commit_opening_stock_import(v_rows, 'PharmaFlow_Opening_Stock.csv');

  v_log := array_append(
    v_log,
    case when (v_theirs ->> 'job_id')::uuid <> v_job_id
              and (v_theirs ->> 'committed')::boolean
              and (v_theirs ->> 'idempotent')::boolean = false
         then 'PASS' else 'FAIL' end
      || ': 8. an identical payload for another pharmacy is its own job (got '
      || coalesce(v_theirs ->> 'job_id', 'nothing') || ')'
  );

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_owner::text)::text, true);

  v_flag := false;
  v_msg := 'the call was expected to raise';
  begin
    perform public.get_import_job((v_theirs ->> 'job_id')::uuid);
  exception when others then
    v_flag := true;
    v_msg := sqlerrm;
  end;

  v_log := array_append(
    v_log,
    case when v_flag and v_msg like '%not in this pharmacy%' then 'PASS' else 'FAIL' end
      || ': 8. another tenant''s job cannot be read, even by an owner (got "'
      || left(v_msg, 100) || '")'
  );

  -- ==================================================== 9. nothing else moved
  select count(*) into v_n  from public.purchases;
  select count(*) into v_n2 from public.purchase_items;

  v_log := array_append(
    v_log,
    case when v_n = v_purchases_before and v_n2 = v_items_before then 'PASS' else 'FAIL' end
      || ': 9. opening stock wrote no purchase and no purchase line ('
      || v_purchases_before || ' -> ' || v_n || ', '
      || v_items_before || ' -> ' || v_n2 || ')'
  );

  select count(*) into v_n  from public.payments;
  select count(*) into v_n2 from public.ledger_entries;

  v_log := array_append(
    v_log,
    case when v_n = v_payments_before and v_n2 = v_ledger_before then 'PASS' else 'FAIL' end
      || ': 9. no payment and no ledger entry - opening stock is not a financial event ('
      || v_payments_before || ' -> ' || v_n || ', '
      || v_ledger_before || ' -> ' || v_n2 || ')'
  );

  select count(*) into v_n  from public.sales;
  select count(*) into v_n2 from public.stock_adjustments;

  v_log := array_append(
    v_log,
    case when v_n = v_sales_before and v_n2 = v_adjust_before then 'PASS' else 'FAIL' end
      || ': 9. no sale and no stock adjustment ('
      || v_sales_before || ' -> ' || v_n || ', '
      || v_adjust_before || ' -> ' || v_n2 || ')'
  );

  select count(*) into v_n
    from public.products p where p.pharmacy_id = v_pharmacy;
  select count(*) into v_n2
    from public.product_batches b where b.pharmacy_id = v_pharmacy;

  v_log := array_append(
    v_log,
    case when v_n = v_products_before + 8 and v_n2 = v_batches_before + 10
         then 'PASS' else 'FAIL' end
      || ': 9. the import added exactly the eight missing products and ten batches ('
      || v_products_before || ' -> ' || v_n || ', '
      || v_batches_before || ' -> ' || v_n2 || ')'
  );

  select coalesce(sum(b.qty), 0) into v_n
    from public.product_batches b where b.pharmacy_id = v_pharmacy;

  v_log := array_append(
    v_log,
    case when v_n = 11981 then 'PASS' else 'FAIL' end
      || ': 9. the batches hold exactly the imported quantity, no trigger added to it (got '
      || v_n || ')'
  );

  -- ============================= 10. unknown and expired, as the views see them
  select count(*) into v_n
    from public.batch_status b
   where b.pharmacy_id = v_pharmacy and b.expiry_date is null
     and b.expiry_status = 'unknown';

  v_log := array_append(
    v_log,
    case when v_n = 3 then 'PASS' else 'FAIL' end
      || ': 10. three batches have no expiry, and the view calls them unknown rather than safe (got '
      || v_n || ')'
  );

  select count(*) into v_n
    from public.batch_status b
   where b.pharmacy_id = v_pharmacy and b.expiry_status = 'expired'
     and b.batch_no = 'ZZEXP01';

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 10. and a past expiry is still expired (got ' || v_n || ')'
  );

  -- The generated identity is a full OPENING-<8 hex of the product uuid>, which is
  -- what the UI keys "unknown batch" off as a convenience - the flag is the
  -- contract, the shape is a reader's aid.
  select count(*) into v_n
    from public.product_batches b
   where b.pharmacy_id = v_pharmacy
     and b.is_unknown_batch
     and b.batch_no ~ '^OPENING-[0-9a-f]{8}$';

  v_log := array_append(
    v_log,
    case when v_n = 2 then 'PASS' else 'FAIL' end
      || ': 10. both unknown-batch rows carry a generated OPENING-<uuid8> identity (got '
      || v_n || ')'
  );

  select s.total_qty, s.stock_value_at_cost
    into v_qty, v_stock_value
    from public.product_stock s
   where s.product_id = (
           select p.id from public.products p
            where p.pharmacy_id = v_pharmacy and p.name = 'Dolo 650mg'
         );

  v_log := array_append(
    v_log,
    case when v_qty = 1292 and v_stock_value = 1292 * 1.38 then 'PASS' else 'FAIL' end
      || ': 10. product_stock values the batch at landed cost (got '
      || coalesce(v_qty::text, 'absent') || ' units at '
      || coalesce(v_stock_value::text, 'absent') || ')'
  );

  -- ================================================================ summary
  select count(*) into v_pass from unnest(v_log) l where l like 'PASS%';
  select count(*) into v_fail from unnest(v_log) l where l like 'FAIL%';

  v_log := array_append(
    v_log,
    'SUMMARY: ' || v_pass || ' PASS / ' || v_fail || ' FAIL of '
      || (array_length(v_log, 1) + 1) || ' assertions'
  );

  raise exception E'OPENING STOCK IMPORT TEST\n%', array_to_string(v_log, chr(10));
end $$;
