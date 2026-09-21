-- Phase 6.5c chunk 5d - functional test for migration 20260921000047 (the two sale acts: cancelling
-- a posted bill, and the narrow identity edit).
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase6_5c_sale_acts.sql
--
-- COUNTING
--   The last line reads "<n> PASS / <m> FAIL of <k> assertions", where k counts assertion lines only,
--   and the self-check on the line above it asserts that every logged line is a PASS or a FAIL.
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
--   Fixtures are written as the owner of the database, then the session becomes `authenticated` and
--   the JWT claims are re-pointed at the owner (who is not gated), at a **cashier** (who may only
--   ask) and at a second pharmacy's owner.
--
-- WHAT IT PROVES
--   1.  The shape: `sales` and `sale_items` take no INSERT/UPDATE/DELETE from `authenticated` any
--       more - the last pair of tables that still did - and are still readable; both sale action
--       types have executors, the applier is not reachable by a session, and the enum's comment now
--       says every declared value is either implemented or retired.
--   2.  A staff cancellation is a REQUEST: the status does not move, and the owner's ask says in its
--       own words what a cancel does NOT do - the goods stay out and the money is not reversed.
--   3.  A cancel is only for a bill NOTHING has happened to, and each of the three ways a bill can
--       have moved is refused IN WORDS: a return against it, a receipt applied to it SINCE it was
--       raised, and money still owed on it. The bill's OWN counter settlement is not one of them -
--       `ledger_auto_entry_sale()` writes it in the sale's own transaction - which is what keeps an
--       ordinary paid-over-the-counter bill cancellable at all, and that is asserted by the cancel
--       succeeding. The ask path is held to the same refusals, so no unanswerable question reaches
--       the owner's list.
--   4.  The owner's own cancellation is the status flip and NOTHING else: the goods are not returned,
--       the bill's ledger entry stands, and a question his staff had standing about that bill is
--       closed rather than left waiting for an answer that can no longer change anything. This is
--       the trade the owner chose (D-087): the goods a correction involves come back through a sale
--       return, which he also approves.
--   5.  `sale_edit` is the PRINTED identity only: the patient name/mobile/address, the prescriber's
--       name and the hospital reference change, and the money, the lines, the stock and the patient
--       master do not.
--   6.  The narrow scope is enforced by a WHITELIST, so a payload naming a money or line key is
--       refused BY NAME in a sentence that names the sale return.
--   7.  Two schema rules the edit could otherwise break are checked rather than raised: a pharmacy
--       bill carries the patient's name and number together (00035), and an admission bill keeps its
--       hospital reference (`sales_ipd_needs_reference`).
--   8.  Approving writes exactly what the owner's own act writes, and a refusal writes nothing.
--   9.  A recorded sale return closes the CANCELLATION ask it strands - approving one could never
--       land after a return, so the row would stay pending and fail on every tap - and leaves the
--       IDENTITY edit standing, because a return does not touch the printed details. Both go through
--       the ONE closure, whose action-type list is what makes the difference (chunk 6).

do $$
declare
  v_log            text[] := array[]::text[];
  v_pharmacy       uuid;
  v_owner          uuid;
  v_cashier        uuid := '00000000-0000-0000-0000-000000000061';
  v_other_pharmacy uuid;
  v_other_owner    uuid := '00000000-0000-0000-0000-000000000062';
  v_product        uuid;
  v_batch          uuid;
  v_patient        uuid;
  v_paid           public.sales;
  v_paid2          public.sales;
  v_credit         public.sales;
  v_allocated      public.sales;
  v_returned       public.sales;
  v_transfer       public.sales;
  v_stranded       public.sales;
  v_ipd            public.sales;
  v_other_sale     public.sales;
  v_sale           public.sales;
  v_receipt        uuid;
  v_qty_before     int;
  v_qty_after      int;
  v_rows           int;
  v_note           text;
  v_sale_by        uuid;
  v_allowed        boolean;
  v_msg            text;
  v_out            jsonb;
  v_out2           jsonb;
  v_request        public.approval_requests;
  v_decided        public.approval_requests;
  v_comment        text;
  v_master_name    text;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE6.5C SALE ACTS TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_owner
    from public.profiles
   where pharmacy_id = v_pharmacy and role = 'owner'
   order by created_at
   limit 1;
  if v_owner is null then
    raise exception 'PHASE6.5C SALE ACTS TEST ABORTED: no owner profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------ fixtures
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_cashier, 'zztest-61-cashier@example.invalid', '{"full_name":"ZZTEST 61 cashier"}'::jsonb)
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_cashier, 'ZZTEST 61 cashier', 'cashier', v_pharmacy)
  on conflict (id) do update
    set full_name = excluded.full_name,
        role = excluded.role,
        pharmacy_id = excluded.pharmacy_id;

  insert into public.pharmacies (id, name)
  values (gen_random_uuid(), 'ZZTEST 61 other pharmacy')
  returning id into v_other_pharmacy;

  insert into auth.users (id, email) values (v_other_owner, 'zztest-61-other@example.invalid')
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_other_owner, 'ZZTEST 61 other owner', 'owner', v_other_pharmacy)
  on conflict (id) do update
    set full_name = excluded.full_name,
        role = excluded.role,
        pharmacy_id = excluded.pharmacy_id;

  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 61 paracetamol', 5)
  returning id into v_product;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp, selling_rate
  ) values (
    v_pharmacy, v_product, 'ZZTEST-61-A', current_date + 365, 1000, 80, 105, 105
  ) returning id into v_batch;

  insert into public.customers (pharmacy_id, name, phone)
  values (v_pharmacy, 'ZZTEST 61 patient', '9876500061')
  returning id into v_patient;

  insert into public.sales (
    pharmacy_id, invoice_no, sale_type, status, payment_mode,
    patient_name, patient_mobile, hospital_reference, sub_total, tax_total, grand_total
  ) values (
    v_pharmacy, 'ZZTEST-61-IPD', 'ipd_admission', 'credit', 'credit',
    'ZZTEST 61 ipd patient', '9876500062', 'IPD-61', 100, 5, 105
  ) returning * into v_ipd;

  insert into public.sales (
    pharmacy_id, invoice_no, status, payment_mode,
    sub_total, tax_total, grand_total, amount_paid, balance_due
  ) values (
    v_other_pharmacy, 'ZZTEST-61-OP', 'completed', 'cash', 0, 0, 0, 0, 0
  ) returning * into v_other_sale;

  -- Everything below is written through the pharmacy's own write path, because these are the bills
  -- the acts are asked about. MRP 105 at a recorded 5% slab is 100 taxable + 5 tax, so one unit at
  -- 105 bills 105 - the figure the "paid in full" fixtures settle.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';

  -- Paid in full at the counter: balance_due 0, and NO receipt row - which is what makes an
  -- ordinary counter bill cancellable at all.
  v_paid := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient,
    'payment_mode', 'cash',
    'amount_paid', 105,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105
    ))
  ));

  v_paid2 := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient,
    'payment_mode', 'cash',
    'amount_paid', 105,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105
    ))
  ));

  -- Owed, not paid: the case the third refusal exists for.
  v_credit := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient,
    'amount_paid', 0,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105
    ))
  ));

  -- Paid, then a receipt applied to it.
  v_allocated := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient,
    'payment_mode', 'cash',
    'amount_paid', 105,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105
    ))
  ));

  -- Paid, then returned.
  v_returned := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient,
    'payment_mode', 'cash',
    'amount_paid', 105,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105
    ))
  ));

  -- A transfer: no patient, no prescriber, nothing this file's edit could legitimately change.
  v_transfer := public.checkout_sale(jsonb_build_object(
    'sale_type', 'transfer',
    'from_location', 'Main shelf',
    'to_location', 'Clinic box',
    'transfer_reason', 'ZZTEST 61 relocation',
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 80
    ))
  ));

  -- A receipt applied to the bill AFTER it was raised. Its `reference_no` is NOT the bill's invoice
  -- number, which is what separates it from the counter's own settlement - the payment
  -- `ledger_auto_entry_sale()` writes in the sale's own transaction, whose reference IS the invoice.
  -- Both exist here: the assertion below is that the FIRST is ignored and the SECOND is refused.
  execute 'reset role';

  insert into public.payments (
    pharmacy_id, party_type, customer_id, amount, mode, reference_no, payment_date, created_by
  ) values (
    v_pharmacy, 'customer', v_patient, 50, 'cash', 'ZZTEST-61-LATER', current_date, v_owner
  ) returning id into v_receipt;

  insert into public.payment_allocations (
    pharmacy_id, payment_id, sale_id, amount, created_by
  ) values (
    v_pharmacy, v_receipt, v_allocated.id, 50, v_owner
  );

  insert into public.sale_returns (
    pharmacy_id, sale_id, customer_id, return_date, restock, grand_total
  ) values (
    v_pharmacy, v_returned.id, v_patient, now(), true, 105
  );

  execute 'set local role authenticated';

  -- ==================================================== 1. the shape
  select has_table_privilege('authenticated', 'public.sales', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated cannot INSERT a bill (expected false, got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.sales', 'UPDATE') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor UPDATE one, which is the status a cancel moves (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.sales', 'DELETE') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor DELETE one (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.sale_items', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor INSERT a line (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.sale_items', 'UPDATE') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor UPDATE a line, which is what re-pricing a bill would need (got '
    || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.sale_items', 'DELETE') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor DELETE one (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.sales', 'SELECT') into v_allowed;
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. while the bill is still readable (expected true, got ' || v_allowed || ')');

  v_log := array_append(v_log, case
    when public.approval_has_executor('sale_cancel') then 'PASS' else 'FAIL' end
    || ': 1. approval_has_executor() answers yes for sale_cancel');

  v_log := array_append(v_log, case
    when public.approval_has_executor('sale_edit') then 'PASS' else 'FAIL' end
    || ': 1. and for sale_edit - so no declared type is left without a chunk');

  select has_function_privilege('anon', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'cancel_sale';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. anon cannot execute cancel_sale (expected false, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_sale_identity';
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated can execute save_sale_identity (expected true, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'sale_apply_decision';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. while the sale applier is not reachable by a session (expected false, got '
    || v_allowed || ')');

  select obj_description('public.approval_action_type'::regtype, 'pg_type') into v_comment;
  v_log := array_append(v_log, case
    when v_comment like '%sale_cancel and sale_edit%' then 'PASS' else 'FAIL' end
    || ': 1. and the enum''s comment names both sale acts as implemented');

  v_log := array_append(v_log, case
    when v_comment like '%EITHER IMPLEMENTED OR RETIRED%' then 'PASS' else 'FAIL' end
    || ': 1. and says every declared value is one or the other');

  -- ================================ 2. a cashier''s cancellation is a REQUEST
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_out := public.cancel_sale(jsonb_build_object('sale_id', v_paid.id));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'staged' then 'PASS' else 'FAIL' end
    || ': 2. a cashier''s cancel comes back staged (got ' || (v_out ->> 'outcome') || ')');

  v_log := array_append(v_log, case when v_out ->> 'document' is null then 'PASS' else 'FAIL' end
    || ': 2. with no document, because the bill did not move');

  select * into v_sale from public.sales s where s.id = v_paid.id;
  v_log := array_append(v_log, case
    when v_sale.status = 'completed'::public.sale_status then 'PASS' else 'FAIL' end
    || ': 2. and the bill is still completed (got ' || v_sale.status || ')');

  select * into v_request from public.approval_requests a where a.id = (v_out ->> 'request_id')::uuid;

  v_log := array_append(v_log, case
    when v_request.action_type = 'sale_cancel'::public.approval_action_type then 'PASS' else 'FAIL' end
    || ': 2. the ask is a sale_cancel');

  v_log := array_append(v_log, case
    when v_request.target_table = 'sales' and v_request.target_id = v_paid.id then 'PASS' else 'FAIL' end
    || ': 2. aimed at that bill');

  v_log := array_append(v_log, case
    when v_request.requested_by = v_cashier then 'PASS' else 'FAIL' end
    || ': 2. and it records who asked');

  v_log := array_append(v_log, case
    when v_request.title = 'Cancel bill: ' || v_paid.invoice_no then 'PASS' else 'FAIL' end
    || ': 2. titled with the bill (got ' || v_request.title || ')');

  -- The trade, in the owner's own words, on the screen he decides from - not buried in a comment.
  v_log := array_append(v_log, case
    when v_request.summary like '%the goods stay out of stock%'
     and v_request.summary like '%the money it moved is not reversed%'
     and v_request.summary like '%a sale return%' then 'PASS' else 'FAIL' end
    || ': 2. and its summary says what a cancel does NOT do (got ' || v_request.summary || ')');

  -- One undecided ask per bill: a second one is a revision, not a rival.
  v_out := public.cancel_sale(jsonb_build_object('sale_id', v_paid.id));
  select count(*) into v_rows from public.approval_requests a
   where a.pharmacy_id = v_pharmacy
     and a.action_type = 'sale_cancel'::public.approval_action_type
     and a.target_id = v_paid.id
     and a.status = 'pending'::public.approval_status;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 2. a second ask about the same bill refreshes the one already there (expected 1, got '
    || v_rows || ')');

  -- ==================================================== 3. the three refusals
  v_msg := null;
  begin
    v_out := public.cancel_sale(jsonb_build_object('sale_id', v_credit.id));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like 'that bill is not settled%' then 'PASS' else 'FAIL' end
    || ': 3. a bill with money still owed on it is refused, in words (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.cancel_sale(jsonb_build_object('sale_id', v_allocated.id));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like 'a receipt has been applied to that bill since it was raised%'
      then 'PASS' else 'FAIL' end
    || ': 3. a bill a receipt has been applied to SINCE is refused (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.cancel_sale(jsonb_build_object('sale_id', v_returned.id));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like 'that bill has a sale return against it%' then 'PASS' else 'FAIL' end
    || ': 3. a bill the goods came back from is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.cancel_sale(jsonb_build_object('sale_id', v_other_sale.id));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that bill is not in this pharmacy' then 'PASS' else 'FAIL' end
    || ': 3. another pharmacy''s bill is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  -- The ASK path is held to the same three, so no unanswerable question reaches the owner's list.
  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'sale_cancel',
      p_title => 'ZZTEST 61 an ask about a bill that has moved',
      p_payload => jsonb_build_object('sale_id', v_returned.id)
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like 'that bill has a sale return against it%' then 'PASS' else 'FAIL' end
    || ': 3. and the ask path is refused by the same check, in the same words (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- ============================== 4. the owner''s own cancel: the status and NOTHING else
  select b.qty into v_qty_before from public.product_batches b where b.id = v_batch;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_out := public.cancel_sale(jsonb_build_object('sale_id', v_paid.id));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'recorded' then 'PASS' else 'FAIL' end
    || ': 4. the owner''s own cancel lands directly (got ' || (v_out ->> 'outcome') || ')');

  v_log := array_append(v_log, case
    when (v_out #>> '{document,status}') = 'cancelled' then 'PASS' else 'FAIL' end
    || ': 4. and he is answered with the cancelled row');

  -- The honest half of the option he chose: the flip is the WHOLE act.
  select b.qty into v_qty_after from public.product_batches b where b.id = v_batch;
  v_log := array_append(v_log, case when v_qty_after = v_qty_before then 'PASS' else 'FAIL' end
    || ': 4. and NOT ONE unit came back to the shelf (' || v_qty_before || ' -> ' || v_qty_after
    || '): a cancel is not a reversal');

  select count(*) into v_rows from public.ledger_entries l
   where l.pharmacy_id = v_pharmacy
     and l.reference_type = 'sale'
     and l.reference_id = v_paid.id;
  v_log := array_append(v_log, case when v_rows >= 1 then 'PASS' else 'FAIL' end
    || ': 4. and the bill''s own ledger entry stands (got ' || v_rows || ' row(s))');

  -- A question his staff had standing about that bill is closed, not left stuck.
  select count(*) into v_rows from public.approval_requests a
   where a.pharmacy_id = v_pharmacy
     and a.target_id = v_paid.id
     and a.status = 'pending'::public.approval_status;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 4. and the cancellation closed the question that was standing about it (pending: '
    || v_rows || ')');

  select a.decision_note into v_note from public.approval_requests a
   where a.pharmacy_id = v_pharmacy
     and a.target_id = v_paid.id
     and a.status = 'rejected'::public.approval_status
   order by a.requested_at
   limit 1;
  v_log := array_append(v_log, case
    when v_note like 'the bill was cancelled%' then 'PASS' else 'FAIL' end
    || ': 4. closed as REFUSED, with a note saying why (got ' || coalesce(v_note, 'NULL') || ')');

  -- ========================================= 5. approving writes what his own act writes
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_out := public.cancel_sale(jsonb_build_object(
    'sale_id', v_paid2.id, 'idempotency_key', 'zztest-61-cancel'
  ));

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  select * into v_request from public.approval_requests a where a.id = (v_out ->> 'request_id')::uuid;

  v_decided := public.decide_approval(p_id => v_request.id, p_approve => true, p_note => 'ZZTEST 61 ok');

  v_log := array_append(v_log, case
    when v_decided.status = 'approved'::public.approval_status then 'PASS' else 'FAIL' end
    || ': 5. the owner approves the cashier''s cancellation');

  select * into v_sale from public.sales s where s.id = v_paid2.id;
  v_log := array_append(v_log, case
    when v_sale.status = 'cancelled'::public.sale_status then 'PASS' else 'FAIL' end
    || ': 5. and the bill is cancelled by the approval, not by a second act');

  -- A cancellation is refused the second time, which is what keeps it a single decision.
  v_msg := null;
  begin
    v_out := public.cancel_sale(jsonb_build_object('sale_id', v_paid2.id));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that bill is cancelled already' then 'PASS' else 'FAIL' end
    || ': 5. and cancelling it again is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  -- ============================================================ 6. the narrow edit
  v_out := public.save_sale_identity(jsonb_build_object(
    'sale_id', v_returned.id,
    'patient_name', 'ZZTEST 61 patient renamed',
    'doctor_name', 'ZZTEST 61 Dr Rao',
    'hospital_reference', 'OPD-61'
  ));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'recorded' then 'PASS' else 'FAIL' end
    || ': 6. the owner may correct a bill''s printed identity (got ' || (v_out ->> 'outcome') || ')');

  v_log := array_append(v_log, case
    when (v_out #>> '{document,patient_name}') = 'ZZTEST 61 patient renamed'
     and (v_out #>> '{document,doctor_name}') = 'ZZTEST 61 Dr Rao'
     and (v_out #>> '{document,hospital_reference}') = 'OPD-61'
      then 'PASS' else 'FAIL' end
    || ': 6. and the three fields it named are changed');

  select * into v_sale from public.sales s where s.id = v_returned.id;

  v_log := array_append(v_log, case
    when v_sale.grand_total = 105 then 'PASS' else 'FAIL' end
    || ': 6. while the bill''s money is untouched (grand ' || v_sale.grand_total || ')');

  v_log := array_append(v_log, case
    when v_sale.customer_id = v_patient then 'PASS' else 'FAIL' end
    || ': 6. and the ledger''s party is unchanged - the patient link is not the printed name');

  select count(*) into v_rows from public.sale_items i
   where i.sale_id = v_returned.id and i.qty = 1 and i.rate = 105;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 6. and its lines are exactly as they were (expected 1 untouched line, got ' || v_rows || ')');

  select c.name into v_master_name from public.customers c where c.id = v_patient;
  v_log := array_append(v_log, case
    when v_master_name = 'ZZTEST 61 patient' then 'PASS' else 'FAIL' end
    || ': 6. and the patient MASTER is unchanged, because the bill carries a snapshot (got '
    || v_master_name || ')');

  -- A cashier''s edit is a request, and it moves nothing.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_out := public.save_sale_identity(jsonb_build_object(
    'sale_id', v_returned.id, 'doctor_name', 'ZZTEST 61 Dr Kulkarni'
  ));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'staged' then 'PASS' else 'FAIL' end
    || ': 6. a cashier''s identity edit is a request (got ' || (v_out ->> 'outcome') || ')');

  select * into v_sale from public.sales s where s.id = v_returned.id;
  v_log := array_append(v_log, case
    when v_sale.doctor_name = 'ZZTEST 61 Dr Rao' then 'PASS' else 'FAIL' end
    || ': 6. and the bill is unchanged (prescriber ' || v_sale.doctor_name || ')');

  select * into v_request from public.approval_requests a where a.id = (v_out ->> 'request_id')::uuid;
  v_log := array_append(v_log, case
    when v_request.action_type = 'sale_edit'::public.approval_action_type
     and v_request.target_id = v_returned.id
     and v_request.summary like '%doctor_name%' then 'PASS' else 'FAIL' end
    || ': 6. and the ask names the column it would change (got '
    || coalesce(v_request.summary, 'NULL') || ')');

  -- The owner approves it, and the bill takes the approved document''s value.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_decided := public.decide_approval(p_id => v_request.id, p_approve => true);

  v_log := array_append(v_log, case
    when v_decided.status = 'approved'::public.approval_status then 'PASS' else 'FAIL' end
    || ': 6. the owner approves the identity edit');

  select * into v_sale from public.sales s where s.id = v_returned.id;
  v_log := array_append(v_log, case
    when v_sale.doctor_name = 'ZZTEST 61 Dr Kulkarni' then 'PASS' else 'FAIL' end
    || ': 6. and the bill now reads what the approved document said');

  -- =================================================== 7. the scope is a WHITELIST
  v_msg := null;
  begin
    v_out := public.save_sale_identity(jsonb_build_object(
      'sale_id', v_returned.id, 'doctor_name', 'ZZTEST 61 Dr Who', 'grand_total', 5
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like 'a posted bill''s grand_total is not editable here%'
     and v_msg like '%sale return%' then 'PASS' else 'FAIL' end
    || ': 7. a money column is refused BY NAME, in a sentence naming the sale return (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.save_sale_identity(jsonb_build_object(
      'sale_id', v_returned.id, 'items', jsonb_build_array(jsonb_build_object('qty', 2))
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like '%items%' and v_msg like '%sale return%' then 'PASS' else 'FAIL' end
    || ': 7. and so is a payload carrying lines (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.save_sale_identity(jsonb_build_object(
      'sale_id', v_returned.id, 'customer_id', v_patient
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like '%customer_id%' then 'PASS' else 'FAIL' end
    || ': 7. and one that would move the bill to another party (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.save_sale_identity(jsonb_build_object('sale_id', v_returned.id));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that bill edit changes nothing' then 'PASS' else 'FAIL' end
    || ': 7. an edit that changes nothing is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.save_sale_identity(jsonb_build_object(
      'sale_id', v_transfer.id, 'doctor_name', 'ZZTEST 61 Dr Rao'
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like 'a transfer carries no patient and no prescriber%' then 'PASS' else 'FAIL' end
    || ': 7. a transfer has no printed identity to edit (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.save_sale_identity(jsonb_build_object(
      'sale_id', v_paid2.id, 'doctor_name', 'ZZTEST 61 Dr Rao'
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that bill is cancelled, so there is nothing left to edit on it'
      then 'PASS' else 'FAIL' end
    || ': 7. and a cancelled bill has nothing left to edit (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.save_sale_identity(jsonb_build_object(
      'sale_id', v_other_sale.id, 'doctor_name', 'ZZTEST 61 Dr Rao'
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that bill is not in this pharmacy' then 'PASS' else 'FAIL' end
    || ': 7. and another pharmacy''s bill is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  -- ============== 8. the two schema rules the edit must not break, checked in words
  v_msg := null;
  begin
    v_out := public.save_sale_identity(jsonb_build_object(
      'sale_id', v_credit.id, 'patient_mobile', '', 'patient_name', 'ZZTEST 61 nameless'
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like 'a pharmacy bill carries the patient''s name and number together%'
      then 'PASS' else 'FAIL' end
    || ': 8. an edit that would leave a name with no number is refused, not raised at the '
    || 'constraint (got ' || coalesce(v_msg, 'NULL') || ')');

  -- Both halves together are accepted, which makes the rule a rule rather than a ban.
  v_out := public.save_sale_identity(jsonb_build_object(
    'sale_id', v_credit.id, 'patient_name', 'ZZTEST 61 both', 'patient_mobile', '+91 98765 00061'
  ));
  v_log := array_append(v_log, case
    when (v_out #>> '{document,patient_name}') = 'ZZTEST 61 both'
     and (v_out #>> '{document,patient_mobile}') = '9876500061'
      then 'PASS' else 'FAIL' end
    || ': 8. while sending both works, with the number stored canonically');

  v_msg := null;
  begin
    v_out := public.save_sale_identity(jsonb_build_object(
      'sale_id', v_ipd.id, 'hospital_reference', ''
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'an admission bill has to keep the hospital''s reference' then 'PASS' else 'FAIL' end
    || ': 8. an admission bill keeps a reference (got ' || coalesce(v_msg, 'NULL') || ')');

  v_out := public.save_sale_identity(jsonb_build_object(
    'sale_id', v_ipd.id, 'hospital_reference', 'IPD-61 corrected'
  ));
  v_log := array_append(v_log, case
    when (v_out #>> '{document,hospital_reference}') = 'IPD-61 corrected' then 'PASS' else 'FAIL' end
    || ': 8. and correcting one is the edit it is for');

  -- ============== 9. a recorded sale return closes the cancellation ask it strands
  -- The bill below is one his staff have asked TWO things about: to cancel it, and to correct its
  -- printed identity. A return then comes back against it. The cancellation can never be ANSWERED
  -- after that - `document_payload_problem()` refuses exactly this state, so approving it would
  -- raise on every tap and the row would stay pending - while the identity edit is untouched by a
  -- return, because the printed details of a bill that has had something returned are still
  -- correctable. That difference is the whole reason the ONE closure takes an action-type list
  -- rather than closing everything about the document (chunk 6, D-088).
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_stranded := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient,
    'payment_mode', 'cash',
    'amount_paid', 105,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1, 'rate', 105
    ))
  ));

  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_out := public.cancel_sale(jsonb_build_object('sale_id', v_stranded.id));
  v_out2 := public.save_sale_identity(jsonb_build_object(
    'sale_id', v_stranded.id,
    'patient_name', 'ZZTEST 61 stranded',
    'patient_mobile', '9876500061'
  ));

  select count(*) into v_rows from public.approval_requests a
   where a.pharmacy_id = v_pharmacy
     and a.target_id = v_stranded.id
     and a.status = 'pending'::public.approval_status;
  v_log := array_append(v_log, case
    when (v_out ->> 'outcome') = 'staged' and (v_out2 ->> 'outcome') = 'staged' and v_rows = 2
      then 'PASS' else 'FAIL' end
    || ': 9. his staff ask to cancel the bill AND to correct its printed identity (two pending: '
    || v_rows || ')');

  -- The return is recorded by the OWNER, through the door, so it is written rather than asked about.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_out := public.record_sale_return(jsonb_build_object(
    'sale_id', v_stranded.id,
    'restock', true,
    'grand_total', 105,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', v_product, 'batch_id', v_batch, 'qty', 1,
      'rate', 105, 'gst_percent', 5, 'tax_amount', 5, 'total_amount', 105
    ))
  ));
  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'recorded' then 'PASS' else 'FAIL' end
    || ': 9. and a sale return is recorded against it (got ' || coalesce(v_out ->> 'outcome', 'NULL')
    || ')');

  select count(*) into v_rows from public.approval_requests a
   where a.pharmacy_id = v_pharmacy
     and a.target_id = v_stranded.id
     and a.action_type = 'sale_cancel'::public.approval_action_type
     and a.status = 'pending'::public.approval_status;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 9. so the CANCEL ask is closed - approving it could never land (still pending: '
    || v_rows || ')');

  select a.decision_note, a.decided_by into v_note, v_sale_by
    from public.approval_requests a
   where a.pharmacy_id = v_pharmacy
     and a.target_id = v_stranded.id
     and a.action_type = 'sale_cancel'::public.approval_action_type;

  v_log := array_append(v_log, case
    when v_note = 'a sale return was recorded against the bill, so it can no longer be cancelled'
      then 'PASS' else 'FAIL' end
    || ': 9. closed as REFUSED with a note naming what washed it out (got '
    || coalesce(v_note, 'NULL') || ')');

  v_log := array_append(v_log, case when v_sale_by = v_owner then 'PASS' else 'FAIL' end
    || ': 9. and decided by the owner, which is what the decision columns require of a decided row (got '
    || coalesce(v_sale_by::text, 'NULL') || ')');

  select count(*) into v_rows from public.approval_requests a
   where a.pharmacy_id = v_pharmacy
     and a.target_id = v_stranded.id
     and a.action_type = 'sale_edit'::public.approval_action_type
     and a.status = 'pending'::public.approval_status;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 9. while the identity edit is LEFT STANDING, because a return does not touch the printed '
    || 'details (pending: ' || v_rows || ')');

  -- Not just "still pending" - still ANSWERABLE, which is the reason the filter exists at all.
  select * into v_request from public.approval_requests a
   where a.pharmacy_id = v_pharmacy
     and a.target_id = v_stranded.id
     and a.action_type = 'sale_edit'::public.approval_action_type;

  v_decided := public.decide_approval(v_request.id, true);
  v_log := array_append(v_log, case
    when v_decided.status = 'approved'::public.approval_status then 'PASS' else 'FAIL' end
    || ': 9. and the owner can still approve it (got ' || v_decided.status || ')');

  select s.patient_name into v_note from public.sales s where s.id = v_stranded.id;
  v_log := array_append(v_log, case when v_note = 'ZZTEST 61 stranded' then 'PASS' else 'FAIL' end
    || ': 9. and it did what it said: the bill prints the corrected name (got '
    || coalesce(v_note, 'NULL') || ')');

  -- The rule has to be readable where the row lives, or the next reader re-derives it from a chat log.
  select obj_description('public.approval_requests'::regclass, 'pg_class') into v_comment;
  v_log := array_append(v_log, case
    when v_comment like '%LIFECYCLE%'
     and v_comment like '%approval_close_target_asks%'
     and v_comment like '%no scheduler%' then 'PASS' else 'FAIL' end
    || ': 9. and the approval_requests table says in its own comment what closes a stale ask, and why '
    || 'an expiry could not (D-088)');

  -- ================================================================ summary
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

  raise exception E'PHASE6.5C SALE ACTS TEST\n%', array_to_string(v_log, chr(10));
end $$;
