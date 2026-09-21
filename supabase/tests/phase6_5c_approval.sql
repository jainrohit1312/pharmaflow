-- Phase 6.5c chunk 1 - functional test for migration 20260921000043 (the approval mechanism,
-- proved on D-071's above-cap discount).
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase6_5c_approval.sql
--
-- COUNTING
--   The last line reads "<n> PASS / <m> FAIL of <k> assertions", where k counts assertion lines
--   only, and the self-check on the line above it asserts that every logged line is a PASS or a
--   FAIL. The self-check is itself one of the counted assertions, because it is one.
--
-- HOW TO READ THE RESULT
--   The evidence comes back in the error message: every line is either "PASS: ..." or "FAIL: ...",
--   and the last line counts them. A non-zero exit code is expected and means the script ran to
--   completion, not that it failed. Every refusal assertion prints the message the server actually
--   raised, so a wrong sentence diagnoses itself.
--
-- WHY IT ENDS WITH RAISE EXCEPTION
--   The whole file is one DO block, which is one statement and therefore one implicit transaction.
--   Raising at the end rolls every fixture back, so it is safe against the hosted project.
--
-- IMPERSONATION
--   The mechanism is about WHO may do what, so this file switches identity repeatedly: fixtures are
--   written as the owner of the database, then the session becomes `authenticated` and the JWT
--   claims are re-pointed at the owner, at a **cashier** (who may ask but not decide) and at a
--   **second pharmacy's owner** (whose approval must be worthless here). RLS applies to this file's
--   own SELECTs after that, which is how the read policies are asserted rather than assumed.
--
-- WHAT IT PROVES
--   1.  The shape the design rests on: `anon` cannot execute either function and `authenticated`
--       can; the table has exactly ONE policy and it is SELECT, so nothing holding a session can
--       forge a request or decide its own; RLS is on; `sales.discount_above_limit_request_id` is a
--       real foreign key to `approval_requests` and a UNIQUE one.
--   2.  Any authorised member of the pharmacy may ASK - the cashier's request lands `pending`, with
--       him as the asker and nobody as the decider.
--   3.  An action type this build cannot execute is refused, named, rather than accepted into the
--       owner's list where approving it would do nothing.
--   4.  A discount the counter could simply give is refused: an ask spends the owner's attention.
--       A discount ask with no figures is refused too.
--   5.  A repeated ask with the same idempotency key is the same request, not a second one in the
--       owner's list.
--   6.  The owner sees every request in his pharmacy; a cashier sees only his own.
--   7.  Only the owner may decide, and a request can be decided once.
--   8.  The discount's wiring: over the cap, a bill with no approval is refused; a PENDING one is
--       refused; an approval for DIFFERENT figures is refused - so "approved 100 off 546" cannot
--       become authority for 200 off it or for any other bill's figures; the right approval lets
--       the bill through and the sale records it.
--   9.  One approval authorises ONE bill: the database refuses the second sale that quotes it.
--   10. The owner is free (2026-09-21): his own above-cap discount needs no approval at all.
--   11. Another pharmacy's approval is worthless here.
--   12. Nothing that worked before broke: a discount within the cap still bills silently, and a
--       per-line discount above 10% is still refused, now in truthful words.
--   13. The assertion count is the assertions - every logged line is a PASS or a FAIL.

do $$
declare
  v_log             text[] := array[]::text[];
  v_outcome         text;
  v_pharmacy        uuid;
  v_owner           uuid;
  v_cashier         uuid := '00000000-0000-0000-0000-000000000043';
  v_other_pharmacy  uuid;
  v_other_owner     uuid := '00000000-0000-0000-0000-000000000044';
  v_product_ch      uuid;
  v_batch_ch        uuid;
  v_product_line    uuid;
  v_batch_line      uuid;
  v_patient         public.customers;
  v_sale            public.sales;
  v_sale2           public.sales;
  v_request         public.approval_requests;
  v_other_request   public.approval_requests;
  v_approved        uuid;
  v_rows            int;
  v_cmds            text;
  v_msg             text;
  v_allowed         boolean;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE6.5C APPROVAL TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_owner
    from public.profiles
   where pharmacy_id = v_pharmacy and role = 'owner'
   order by created_at
   limit 1;
  if v_owner is null then
    raise exception 'PHASE6.5C APPROVAL TEST ABORTED: no owner profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------ fixtures
  insert into auth.users (id, email)
  values (v_cashier, 'zztest-43-cashier@example.invalid')
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_cashier, 'ZZTEST 43 cashier', 'cashier', v_pharmacy)
  on conflict (id) do update
    set role = excluded.role, pharmacy_id = excluded.pharmacy_id;

  insert into public.pharmacies (id, name)
  values (gen_random_uuid(), 'ZZTEST 43 other pharmacy')
  returning id into v_other_pharmacy;

  insert into auth.users (id, email)
  values (v_other_owner, 'zztest-43-other-owner@example.invalid')
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_other_owner, 'ZZTEST 43 other owner', 'owner', v_other_pharmacy)
  on conflict (id) do update
    set role = excluded.role, pharmacy_id = excluded.pharmacy_id;

  -- The two packs the owner's own example bill is made of: 546 of shelf price, discounted by 46.
  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 43 five percent', 5)
  returning id into v_product_ch;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product_ch, 'ZZTEST-43-A', current_date + 365, 1000, 80, 105
  ) returning id into v_batch_ch;

  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 43 twelve percent', 12)
  returning id into v_product_line;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product_line, 'ZZTEST-43-B', current_date + 365, 1000, 120, 168
  ) returning id into v_batch_line;

  -- ------------------------------------------------- behave as the pharmacy
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);
  execute 'set local role authenticated';

  v_patient := public.save_patient(
    p_name => 'ZZTEST 43 patient',
    p_mobile => '9000000043'
  );

  -- ================================================ 1. the shape the design rests on
  select has_function_privilege('anon', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'request_approval';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. anon cannot execute request_approval (expected false, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'decide_approval';
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated can execute decide_approval (expected true, got ' || v_allowed || ')');

  -- The load-bearing one: ONE policy, and it is SELECT. No INSERT, UPDATE or DELETE policy means
  -- no session can forge a request or stamp its own decision - the same idiom `payment_allocations`
  -- records for a table only a validated writer may touch.
  select count(*), coalesce(string_agg(distinct cmd, ',' order by cmd), '') into v_rows, v_cmds
    from pg_policies
   where schemaname = 'public' and tablename = 'approval_requests';
  v_log := array_append(v_log, case
    when v_rows = 1 and v_cmds = 'SELECT' then 'PASS' else 'FAIL' end
    || ': 1. approval_requests has exactly one policy and it is SELECT (got ' || v_rows
    || ' policies: [' || v_cmds || '])');

  select c.relrowsecurity into v_allowed
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'approval_requests';
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. row level security is enabled on approval_requests (got ' || v_allowed || ')');

  select count(*) into v_rows
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_class f on f.oid = c.confrelid
   where c.contype = 'f'
     and t.relname = 'sales'
     and f.relname = 'approval_requests';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 1. sales.discount_above_limit_request_id is a REAL foreign key to approval_requests (got '
    || v_rows || ' such constraint)');

  select count(*) into v_rows
    from pg_indexes
   where schemaname = 'public'
     and tablename = 'sales'
     and indexname = 'sales_discount_approval_key'
     and indexdef like '%UNIQUE%';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 1. and a UNIQUE one, so one approval authorises one bill (got ' || v_rows || ')');

  select count(*) into v_rows
    from pg_constraint
   where conname = 'approval_requests_decided_check';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 1. a decided request cannot be anonymous (got ' || v_rows || ' check constraint)');

  -- ==================================================== 2-5. asking for approval
  v_request := public.request_approval(
    p_action_type => 'discount_above_limit',
    p_title => 'ZZTEST 43 discount 100 on a bill of 546',
    p_summary => 'Over the 10% cap: the counter cannot give this without the owner',
    p_payload => jsonb_build_object('discount_amount', 100, 'bill_gross', 546)
  );

  v_log := array_append(v_log, case
    when v_request.status = 'pending'::public.approval_status
     and v_request.requested_by = v_cashier
     and v_request.decided_by is null
     and v_request.decided_at is null then 'PASS' else 'FAIL' end
    || ': 2. a cashier may ask, and the ask lands pending with him as the asker and no decider');

  v_log := array_append(v_log, case
    when v_request.pharmacy_id = v_pharmacy then 'PASS' else 'FAIL' end
    || ': 2. and it belongs to the pharmacy that asked (got '
    || coalesce(v_request.pharmacy_id::text, 'NULL') || ')');

  -- An action type with no executor must not be askable: the alternative is a row in the owner's
  -- list that approving would silently do nothing about.
  --
  -- The example was `purchase` until Phase 6.5c chunk 3 built it, which is why it is a
  -- `purchase_return` now: the assertion is about the RULE - an unimplemented action type is
  -- refused, in words naming it - and the rule is unchanged, so the example moves to one whose
  -- chunk has not landed yet rather than the assertion being dropped. That `purchase` itself is
  -- now askable is asserted where it is implemented, in phase6_5c_purchases.sql.
  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'purchase_return',
      p_title => 'ZZTEST 43 purchase return'
    );
  exception when feature_not_supported then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'the approval for purchase_return is not available yet' then 'PASS' else 'FAIL' end
    || ': 3. an action type this build cannot execute is refused, named (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'discount_above_limit',
      p_title => 'ZZTEST 43 small discount',
      p_payload => jsonb_build_object('discount_amount', 10, 'bill_gross', 546)
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that discount is within the 10% the counter may give, so no approval is needed'
      then 'PASS' else 'FAIL' end
    || ': 4. a discount within the cap is refused as an ask - the owner''s attention is not spent '
    || 'on a figure the counter may simply give (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'discount_above_limit',
      p_title => 'ZZTEST 43 no figures'
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'a discount request needs the discount and the bill it is taken off'
      then 'PASS' else 'FAIL' end
    || ': 4. an ask with no figures is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  v_request := public.request_approval(
    p_action_type => 'discount_above_limit',
    p_title => 'ZZTEST 43 discount 100 on a bill of 546',
    p_payload => jsonb_build_object('discount_amount', 100, 'bill_gross', 546),
    p_idempotency_key => 'zztest-43-key'
  );
  v_approved := v_request.id;

  v_request := public.request_approval(
    p_action_type => 'discount_above_limit',
    p_title => 'ZZTEST 43 discount 100 again',
    p_payload => jsonb_build_object('discount_amount', 100, 'bill_gross', 546),
    p_idempotency_key => 'zztest-43-key'
  );

  v_log := array_append(v_log, case
    when v_request.id = v_approved then 'PASS' else 'FAIL' end
    || ': 5. the same key is the same request, not a second ask in the owner''s list');

  -- ==================================================== 6. who sees what
  -- Two rows carry this cashier's name: the first ask, and the keyed one the assertions bubble
  -- from here on. The refused asks left nothing behind.
  select count(*) into v_rows from public.approval_requests;
  v_log := array_append(v_log, case when v_rows = 2 then 'PASS' else 'FAIL' end
    || ': 6. a cashier sees only his own requests (expected 2, got ' || v_rows || ')');

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  select count(*) into v_rows from public.approval_requests;
  v_log := array_append(v_log, case when v_rows >= 2 then 'PASS' else 'FAIL' end
    || ': 6. the owner sees the requests in his pharmacy (got ' || v_rows || ')');

  -- ==================================================== 7. deciding
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_msg := null;
  begin
    v_request := public.decide_approval(v_approved, true);
  exception when insufficient_privilege then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'only the owner can decide an approval request' then 'PASS' else 'FAIL' end
    || ': 7. a cashier cannot decide his own request (got ' || coalesce(v_msg, 'NULL') || ')');

  -- ==================================================== 8. the discount's wiring
  -- Over the cap, with no approval at all.
  v_msg := null;
  begin
    v_sale := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'bill_discount', 100,
      'items', jsonb_build_array(
        jsonb_build_object('product_id', v_product_ch, 'batch_id', v_batch_ch, 'qty', 2, 'rate', 105),
        jsonb_build_object('product_id', v_product_line, 'batch_id', v_batch_line, 'qty', 2, 'rate', 168)
      )
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'a discount above 10% of the bill needs the owner''s approval: ask for it, and bill once he has given it'
      then 'PASS' else 'FAIL' end
    || ': 8. over the cap with no approval, the bill is refused (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- With the request still PENDING.
  v_msg := null;
  begin
    v_sale := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'bill_discount', 100,
      'discount_approval_id', v_approved,
      'items', jsonb_build_array(
        jsonb_build_object('product_id', v_product_ch, 'batch_id', v_batch_ch, 'qty', 2, 'rate', 105),
        jsonb_build_object('product_id', v_product_line, 'batch_id', v_batch_line, 'qty', 2, 'rate', 168)
      )
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that approval is not one this pharmacy has given for a discount'
      then 'PASS' else 'FAIL' end
    || ': 8. a PENDING request does not authorise the bill (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- The owner approves it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_request := public.decide_approval(v_approved, true, 'OK');

  v_log := array_append(v_log, case
    when v_request.status = 'approved'::public.approval_status
     and v_request.decided_by = v_owner
     and v_request.decided_at is not null then 'PASS' else 'FAIL' end
    || ': 7. the owner''s approval is recorded with who gave it and when');

  v_msg := null;
  begin
    v_request := public.decide_approval(v_approved, false);
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like 'that request has already been decided%' then 'PASS' else 'FAIL' end
    || ': 7. a request can be decided once (got ' || coalesce(v_msg, 'NULL') || ')');

  -- ==================================================== 9. the bill it authorises
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  -- The right approval, but the WRONG figures: he approved 100 off 546, and this is 200 off 546.
  v_msg := null;
  begin
    v_sale := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'bill_discount', 200,
      'discount_approval_id', v_approved,
      'items', jsonb_build_array(
        jsonb_build_object('product_id', v_product_ch, 'batch_id', v_batch_ch, 'qty', 2, 'rate', 105),
        jsonb_build_object('product_id', v_product_line, 'batch_id', v_batch_line, 'qty', 2, 'rate', 168)
      )
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like '%not 200.00 on 546.00%' then 'PASS' else 'FAIL' end
    || ': 9. an approval for other figures does not authorise this bill (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- The figures he approved, on the bill he approved them for.
  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'amount_paid', 446,
    'bill_discount', 100,
    'discount_approval_id', v_approved,
    'items', jsonb_build_array(
      jsonb_build_object('product_id', v_product_ch, 'batch_id', v_batch_ch, 'qty', 2, 'rate', 105),
      jsonb_build_object('product_id', v_product_line, 'batch_id', v_batch_line, 'qty', 2, 'rate', 168)
    )
  ));

  v_log := array_append(v_log, case
    when v_sale.grand_total = 446.00 and v_sale.discount_total = 100.00 then 'PASS' else 'FAIL' end
    || ': 9. the approved discount bills the way the counter gave it (got grand '
    || v_sale.grand_total || ', discount ' || v_sale.discount_total || ')');

  v_log := array_append(v_log, case
    when v_sale.discount_above_limit_request_id = v_approved then 'PASS' else 'FAIL' end
    || ': 9. and the sale records WHICH approval let it through (got '
    || coalesce(v_sale.discount_above_limit_request_id::text, 'NULL') || ')');

  -- The same approval again, on a second bill: the database refuses it.
  v_msg := null;
  begin
    v_sale2 := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'amount_paid', 446,
      'bill_discount', 100,
      'discount_approval_id', v_approved,
      'items', jsonb_build_array(
        jsonb_build_object('product_id', v_product_ch, 'batch_id', v_batch_ch, 'qty', 2, 'rate', 105),
        jsonb_build_object('product_id', v_product_line, 'batch_id', v_batch_line, 'qty', 2, 'rate', 168)
      )
    ));
    v_msg := 'no error raised';
  exception when unique_violation then
    v_msg := null;
  end;
  v_log := array_append(v_log, case when v_msg is null then 'PASS' else 'FAIL' end
    || ': 9. one approval authorises ONE bill - the second sale quoting it is refused');

  -- ==================================================== 10. the owner is free
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'amount_paid', 446,
    'bill_discount', 100,
    'items', jsonb_build_array(
      jsonb_build_object('product_id', v_product_ch, 'batch_id', v_batch_ch, 'qty', 2, 'rate', 105),
      jsonb_build_object('product_id', v_product_line, 'batch_id', v_batch_line, 'qty', 2, 'rate', 168)
    )
  ));

  v_log := array_append(v_log, case
    when v_sale.grand_total = 446.00
     and v_sale.discount_above_limit_request_id is null then 'PASS' else 'FAIL' end
    || ': 10. the owner''s own above-cap discount needs no approval (got grand '
    || v_sale.grand_total || ', approval '
    || coalesce(v_sale.discount_above_limit_request_id::text, 'NULL') || ')');

  -- ==================================================== 11. another pharmacy's approval
  -- The other pharmacy's owner approves a discount in HIS pharmacy, so the id the cashier will
  -- try to spend next is a genuinely approved one - just not his.
  perform set_config('request.jwt.claims', json_build_object('sub', v_other_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_other_owner::text, true);

  v_other_request := public.request_approval(
    p_action_type => 'discount_above_limit',
    p_title => 'ZZTEST 43 other pharmacy discount',
    p_payload => jsonb_build_object('discount_amount', 100, 'bill_gross', 546)
  );
  v_other_request := public.decide_approval(v_other_request.id, true);

  v_log := array_append(v_log, case
    when v_other_request.status = 'approved'::public.approval_status
      then 'PASS' else 'FAIL' end
    || ': 11. the other pharmacy''s owner can approve in his own pharmacy');

  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_msg := null;
  begin
    v_sale := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'bill_discount', 100,
      'discount_approval_id', v_other_request.id,
      'items', jsonb_build_array(
        jsonb_build_object('product_id', v_product_ch, 'batch_id', v_batch_ch, 'qty', 2, 'rate', 105),
        jsonb_build_object('product_id', v_product_line, 'batch_id', v_batch_line, 'qty', 2, 'rate', 168)
      )
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that approval is not one this pharmacy has given for a discount'
      then 'PASS' else 'FAIL' end
    || ': 11. another pharmacy''s approval is worthless here (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- ==================================================== 12. nothing that worked before broke
  -- Within the cap, no approval, exactly as before this migration.
  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'amount_paid', 491.40,
    'bill_discount', 54.60,
    'items', jsonb_build_array(
      jsonb_build_object('product_id', v_product_ch, 'batch_id', v_batch_ch, 'qty', 2, 'rate', 105),
      jsonb_build_object('product_id', v_product_line, 'batch_id', v_batch_line, 'qty', 2, 'rate', 168)
    )
  ));

  v_log := array_append(v_log, case
    when v_sale.grand_total = 491.40 and v_sale.discount_above_limit_request_id is null
      then 'PASS' else 'FAIL' end
    || ': 12. exactly 10% of the bill still bills silently (got grand '
    || v_sale.grand_total || ')');

  -- A per-line discount above 10% is still refused, in words that are now true.
  v_msg := null;
  begin
    v_sale := public.checkout_sale(jsonb_build_object(
      'sale_type', 'counter',
      'customer_id', v_patient.id,
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product_ch, 'batch_id', v_batch_ch, 'qty', 1, 'rate', 105,
        'discount_percent', 15
      ))
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'a line discount above 10% is not accepted: give the extra on the bill''s discount, where the owner can approve it'
      then 'PASS' else 'FAIL' end
    || ': 12. a per-line discount above 10% is still refused (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- ================================================================ summary
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

  raise exception E'PHASE6.5C APPROVAL TEST\n%', array_to_string(v_log, chr(10));
end $$;
