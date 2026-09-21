-- Phase 7a open_bills - functional test for migration 20260921000040.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase7a_open_bills.sql
--
-- COUNTING
--   The last line reads "<n> PASS / <m> FAIL of <k> assertions", where k counts assertion lines
--   only, and the self-check on the line above it asserts that every logged line is a PASS or a
--   FAIL. The self-check is itself one of the counted assertions, because it is one. The older
--   files in this directory count the summary line itself into their total; this file follows
--   phase7a_sale_types.sql and phase7a_sale_document.sql, which do not.
--
-- HOW TO READ THE RESULT
--   The evidence comes back in the error message: every line is either "PASS: ..." or "FAIL: ...",
--   and the last line counts them. A non-zero exit code is expected and means the script ran to
--   completion, not that it failed.
--
-- WHY IT ENDS WITH RAISE EXCEPTION
--   The whole file is one DO block, which is one statement and therefore one implicit transaction.
--   Raising at the end rolls every fixture back, so it is safe against the hosted project.
--
-- IMPERSONATION
--   The reader takes its tenant from `get_my_pharmacy_id()`, which resolves `auth.uid()`. Fixtures
--   are written as the owner first, then the session becomes the real owner profile - JWT claims
--   set, role switched to `authenticated` - as the other phase 7a tests do. One fixture (the return
--   against a bill) is written as postgres, because it is scene-setting rather than the thing under
--   test, and it is written with `reset role` / `set local role authenticated` around it.
--
-- WHAT IT PROVES
--   1.  The function's own shape: not executable by `anon`, executable by `authenticated`, SECURITY
--       INVOKER (so the caller's RLS applies as well as the pharmacy guard), STABLE, and with its
--       `search_path` pinned.
--   2.  A party's open bills, each with the server's own `outstanding` = `grand_total` less
--       non-cancelled returns less allocations, and the bills oldest first.
--   3.  The sum of the bills equals `total_outstanding`.
--   4.  **The round trip**: the total this reader returns is the `outstanding` the *aggregate*
--       reader (`patient_account()`) reports for the same party - the two figures cannot disagree,
--       because the second is not derived from the first.
--   5.  **The lock agrees**: a slice one paisa larger than a bill's figure is refused, and exactly
--       that figure settles it - so the limit a refusal names is the limit this list showed.
--   6.  A settled bill leaves the list, and a fully settled party has none.
--   7.  Cross-party and cross-tenant isolation, a supplier answering an empty list rather than a
--       wrong one, and an unknown party answering empty.
--   8.  The assertion count is the assertions - and every logged line is a PASS or a FAIL, so a
--       skipped or truncated check cannot hide behind the arithmetic.

do $$
declare
  v_log             text[] := array[]::text[];
  v_pharmacy        uuid;
  v_user            uuid;
  v_other_pharmacy  uuid;
  v_other_user      uuid;
  v_product         uuid;
  v_batch           uuid;
  v_patient_a       public.customers;
  v_patient_b       public.customers;
  v_sale_a1         public.sales;
  v_sale_a2         public.sales;
  v_sale_b          public.sales;
  v_bills           jsonb;
  v_bill            jsonb;
  v_total           numeric;
  v_aggregate       numeric;
  v_allowed         boolean;
  v_definer         boolean;
  v_volatile        "char";
  v_settings        text[];
  v_count           int;
  v_outcome         text;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE7A OPEN BILLS TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user
    from public.profiles
   where pharmacy_id = v_pharmacy
   order by created_at
   limit 1;
  if v_user is null then
    raise exception 'PHASE7A OPEN BILLS TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------ 1. the function's own shape
  select has_function_privilege('anon', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'open_bills';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. anon cannot execute open_bills (expected false, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'open_bills';
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated can execute open_bills (expected true, got ' || v_allowed || ')');

  select p.prosecdef, p.provolatile, p.proconfig
    into v_definer, v_volatile, v_settings
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'open_bills';

  v_log := array_append(v_log, case when not v_definer then 'PASS' else 'FAIL' end
    || ': 1. the function is security INVOKER, so the caller''s RLS applies too (prosecdef = '
    || v_definer || ')');

  v_log := array_append(v_log, case when v_volatile::text = 's' then 'PASS' else 'FAIL' end
    || ': 1. the function is STABLE - it reads, it writes nothing (provolatile = '
    || v_volatile::text || ')');

  v_log := array_append(v_log, case
    when v_settings is not null
     and exists (select 1 from unnest(v_settings) s where s like 'search_path=%')
      then 'PASS' else 'FAIL' end
    || ': 1. search_path is pinned (proconfig = '
    || coalesce(array_to_string(v_settings, ','), 'NULL') || ')');

  -- ------------------------------------------------------------------ fixtures
  -- As postgres, so RLS is not in the way of setting the scene.
  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 40 five percent', 5)
  returning id into v_product;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product, 'ZZTEST-40-A', current_date + 365, 100, 60, 200
  ) returning id into v_batch;

  insert into public.pharmacies (id, name)
  values (gen_random_uuid(), 'ZZTEST 40 other pharmacy')
  returning id into v_other_pharmacy;

  v_other_user := '00000000-0000-0000-0000-000000000040';

  insert into auth.users (id, email)
  values (v_other_user, 'zztest-40-other@example.invalid')
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_other_user, 'ZZTEST 40 other owner', 'owner', v_other_pharmacy)
  on conflict (id) do update
    set role = excluded.role, pharmacy_id = excluded.pharmacy_id;

  -- ------------------------------------------------- behave as the owner
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  v_patient_a := public.save_patient(
    p_name => 'ZZTEST 40 patient A',
    p_mobile => '9000000040'
  );

  v_patient_b := public.save_patient(
    p_name => 'ZZTEST 40 patient B',
    p_mobile => '9000000041'
  );

  -- Two bills for A (200 and 100) and one for B. **No `amount_paid`**: a sale paid at the counter
  -- gets a settlement allocated to it by the sale trigger, and that would settle the bill this test
  -- is about before it can look at it.
  v_sale_a1 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient_a.id,
    'idempotency_key', 'zztest-40-a1-' || gen_random_uuid()::text,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 2, 'rate', 100
    ))
  ));

  v_sale_a2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient_a.id,
    'idempotency_key', 'zztest-40-a2-' || gen_random_uuid()::text,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 100
    ))
  ));

  v_sale_b := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient_b.id,
    'idempotency_key', 'zztest-40-b-' || gen_random_uuid()::text,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 100
    ))
  ));

  -- A return of 50 against A's first bill, written as postgres: the returns *screen* is Phase 3's
  -- and is not under test here, only its effect on an open bill.
  execute 'reset role';
  insert into public.sale_returns (pharmacy_id, sale_id, customer_id, grand_total)
  values (v_pharmacy, v_sale_a1.id, v_patient_a.id, 50);
  execute 'set local role authenticated';

  -- A receipt of 60 from A, aimed at A's second bill - through the real collection path.
  perform public.collect_payment(
    p_party_type => 'customer',
    p_party_id => v_patient_a.id,
    p_amount => 60,
    p_mode => 'cash',
    p_allocations => jsonb_build_array(jsonb_build_object(
      'sale_id', v_sale_a2.id, 'amount', 60
    ))
  );

  -- ==================================================== 2-3. A's open bills
  v_bills := public.open_bills('customer', v_patient_a.id);

  v_log := array_append(v_log, case
    when jsonb_array_length(v_bills -> 'bills') = 2 then 'PASS' else 'FAIL' end
    || ': 2. the party has two open bills (got '
    || jsonb_array_length(v_bills -> 'bills') || ')');

  v_log := array_append(v_log, case
    when v_bills -> 'bills' -> 0 ->> 'sale_id' = v_sale_a1.id::text
     and v_bills -> 'bills' -> 1 ->> 'sale_id' = v_sale_a2.id::text
      then 'PASS' else 'FAIL' end
    || ': 2. and they come oldest first (got '
    || coalesce(v_bills -> 'bills' -> 0 ->> 'invoice_no', 'NULL') || ' then '
    || coalesce(v_bills -> 'bills' -> 1 ->> 'invoice_no', 'NULL') || ')');

  v_bill := v_bills -> 'bills' -> 0;

  v_log := array_append(v_log, case
    when (v_bill ->> 'grand_total')::numeric = 200.00
     and (v_bill ->> 'returned_total')::numeric = 50.00
     and (v_bill ->> 'allocated_total')::numeric = 0.00
     and (v_bill ->> 'outstanding')::numeric = 150.00
      then 'PASS' else 'FAIL' end
    || ': 2. a returned bill carries the stored total, its returns, its allocations and the '
    || 'outstanding between them (got grand ' || coalesce(v_bill ->> 'grand_total', 'NULL')
    || ' / returned ' || coalesce(v_bill ->> 'returned_total', 'NULL')
    || ' / allocated ' || coalesce(v_bill ->> 'allocated_total', 'NULL')
    || ' / outstanding ' || coalesce(v_bill ->> 'outstanding', 'NULL') || ')');

  v_bill := v_bills -> 'bills' -> 1;

  v_log := array_append(v_log, case
    when (v_bill ->> 'grand_total')::numeric = 100.00
     and (v_bill ->> 'returned_total')::numeric = 0.00
     and (v_bill ->> 'allocated_total')::numeric = 60.00
     and (v_bill ->> 'outstanding')::numeric = 40.00
      then 'PASS' else 'FAIL' end
    || ': 2. an allocated bill carries what has been applied to it (got outstanding '
    || coalesce(v_bill ->> 'outstanding', 'NULL') || ')');

  v_log := array_append(v_log, case
    when v_bill ->> 'sale_type' = 'counter' and v_bill ->> 'invoice_no' is not null
      then 'PASS' else 'FAIL' end
    || ': 2. and names the bill it is (got ' || coalesce(v_bill ->> 'invoice_no', 'NULL') || ')');

  v_total := (v_bills ->> 'total_outstanding')::numeric;
  v_log := array_append(v_log, case when v_total = 190.00 then 'PASS' else 'FAIL' end
    || ': 3. the bills add up to the total it reports (expected 190, got ' || v_total || ')');

  -- ======================================== 4. the round trip with the aggregate
  select (a.outstanding) into v_aggregate
    from public.patient_account(v_patient_a.id) a;

  v_log := array_append(v_log, case when v_aggregate = v_total then 'PASS' else 'FAIL' end
    || ': 4. the total here IS the outstanding patient_account() reports for the same party ('
    || coalesce(v_aggregate::text, 'NULL') || ' vs ' || v_total || ')');

  -- ==================================== 5. the lock agrees with this list
  v_outcome := 'FAIL: 5. a slice larger than the bill was accepted';
  begin
    perform public.collect_payment(
      p_party_type => 'customer',
      p_party_id => v_patient_a.id,
      p_amount => 150.01,
      p_mode => 'cash',
      p_allocations => jsonb_build_array(jsonb_build_object(
        'sale_id', v_sale_a1.id, 'amount', 150.01
      ))
    );
  exception when check_violation then
    v_outcome := 'PASS: 5. one paisa more than the figure this list showed is refused';
  end;
  v_log := array_append(v_log, v_outcome);

  -- And exactly the figure settles it.
  perform public.collect_payment(
    p_party_type => 'customer',
    p_party_id => v_patient_a.id,
    p_amount => 150,
    p_mode => 'cash',
    p_allocations => jsonb_build_array(jsonb_build_object(
      'sale_id', v_sale_a1.id, 'amount', 150
    ))
  );

  v_bills := public.open_bills('customer', v_patient_a.id);

  -- ========================================== 6. a settled bill leaves the list
  v_log := array_append(v_log, case
    when jsonb_array_length(v_bills -> 'bills') = 1 then 'PASS' else 'FAIL' end
    || ': 6. the settled bill leaves the list (got '
    || jsonb_array_length(v_bills -> 'bills') || ' left)');

  v_log := array_append(v_log, case
    when (v_bills ->> 'total_outstanding')::numeric = 40.00 then 'PASS' else 'FAIL' end
    || ': 6. and the total follows it (expected 40, got '
    || coalesce(v_bills ->> 'total_outstanding', 'NULL') || ')');

  perform public.collect_payment(
    p_party_type => 'customer',
    p_party_id => v_patient_a.id,
    p_amount => 40,
    p_mode => 'cash',
    p_allocations => jsonb_build_array(jsonb_build_object(
      'sale_id', v_sale_a2.id, 'amount', 40
    ))
  );

  v_bills := public.open_bills('customer', v_patient_a.id);

  v_log := array_append(v_log, case
    when jsonb_array_length(v_bills -> 'bills') = 0
     and (v_bills ->> 'total_outstanding')::numeric = 0
      then 'PASS' else 'FAIL' end
    || ': 6. a fully settled party has no open bills and a zero total');

  -- ============================================== 7. isolation, and the gaps
  v_bills := public.open_bills('customer', v_patient_b.id);
  v_log := array_append(v_log, case
    when jsonb_array_length(v_bills -> 'bills') = 1
     and v_bills -> 'bills' -> 0 ->> 'sale_id' = v_sale_b.id::text
      then 'PASS' else 'FAIL' end
    || ': 7. another patient''s bill is not in this patient''s list, and hers is');

  v_bills := public.open_bills('customer', gen_random_uuid());
  v_log := array_append(v_log, case
    when jsonb_array_length(v_bills -> 'bills') = 0
     and (v_bills ->> 'total_outstanding')::numeric = 0
      then 'PASS' else 'FAIL' end
    || ': 7. a party with no bills answers an empty list rather than failing');

  -- A supplier: an answer, not a wrong one.
  v_bills := public.open_bills('supplier', v_patient_a.id);
  v_log := array_append(v_log, case
    when jsonb_array_length(v_bills -> 'bills') = 0
     and (v_bills ->> 'total_outstanding')::numeric = 0
      then 'PASS' else 'FAIL' end
    || ': 7. a supplier answers an empty list - a supplier''s open documents are purchases, '
    || 'which this reader does not return');

  -- Become the other pharmacy's owner: the same call must answer nothing.
  perform set_config('request.jwt.claims', json_build_object('sub', v_other_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_other_user::text, true);

  v_bills := public.open_bills('customer', v_patient_b.id);
  v_log := array_append(v_log, case
    when jsonb_array_length(v_bills -> 'bills') = 0 then 'PASS' else 'FAIL' end
    || ': 7. another pharmacy''s caller sees none of this pharmacy''s bills');

  -- ================================================================ summary
  v_log := array_append(v_log, case
    when (select count(*) from unnest(v_log) l
           where coalesce(l, '') not like 'PASS%'
             and coalesce(l, '') not like 'FAIL%') = 0
      then 'PASS' else 'FAIL' end
    || ': 8. every logged line is a PASS or a FAIL (nothing skipped, nothing truncated)');

  v_log := array_append(v_log, 'SUMMARY: '
    || (select count(*) from unnest(v_log) l where l like 'PASS%') || ' PASS / '
    || (select count(*) from unnest(v_log) l where l like 'FAIL%') || ' FAIL of '
    || (select count(*) from unnest(v_log) l
         where l like 'PASS%' or l like 'FAIL%') || ' assertions');

  raise exception E'PHASE7A OPEN BILLS TEST\n%', array_to_string(v_log, chr(10));
end $$;
