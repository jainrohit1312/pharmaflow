-- Phase 6.5c chunk 4 - functional test for migration 20260921000045 (purchase returns, sale
-- returns and stock adjustments behind the owner's approval).
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase6_5c_returns.sql
--
-- COUNTING
--   The last line reads "<n> PASS / <m> FAIL of <k> assertions", where k counts assertion lines
--   only, and the self-check on the line above it asserts that every logged line is a PASS or a
--   FAIL. The self-check is itself one of the counted assertions, because it is one.
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
--   ask) and at a **second pharmacy's owner** (whose writes must not reach this pharmacy's
--   documents).
--
-- WHAT IT PROVES
--   1.  The shape: the five protected tables take no INSERT/UPDATE/DELETE from `authenticated` any
--       more, the three write RPCs are callable, the mechanism's internals are not, and the three
--       new action types have executors while the ones D-085 retired never will.
--   2.  A staff return or adjustment is a REQUEST: nothing is written, no stock moves, no ledger row
--       exists, and the owner has one ask carrying the whole document.
--   3.  The same submit twice is one ask, not two - which is what keeps a double tap from becoming
--       two returns when the owner answers both.
--   4.  Approving writes exactly what a direct write wrote: the same rows, the same stock movement,
--       the same ledger entry, in the trigger's own words.
--   5.  The owner's own write is not gated, and is the same RPC.
--   6.  A refusal writes nothing at all - there is no half-document to put back.
--   7.  A write that cannot be carried out (goods no longer there, stock since sold) is REFUSED
--       rather than recorded: the request stays pending and the owner can see why.
--   8.  A payload that could not produce a document is refused when it is ASKED for, naming what is
--       missing - so nothing sits in the owner's list that answering would raise on.

do $$
declare
  v_log            text[] := array[]::text[];
  v_pharmacy       uuid;
  v_owner          uuid;
  v_cashier        uuid := '00000000-0000-0000-0000-000000000047';
  v_other_pharmacy uuid;
  v_other_owner    uuid := '00000000-0000-0000-0000-000000000048';
  v_supplier       uuid;
  v_other_supplier uuid;
  v_purchase       uuid;
  v_other_purchase uuid;
  v_product        uuid;
  v_batch          uuid;
  v_patient        public.customers;
  v_sale           public.sales;
  v_sale_item      uuid;
  v_batch_qty      int;
  v_rows           int;
  v_amount         numeric(14,2);
  v_msg            text;
  v_allowed        boolean;
  v_outcome        jsonb;
  v_request        public.approval_requests;
  v_request2       public.approval_requests;
  v_approved       uuid;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE6.5C RETURNS TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_owner
    from public.profiles
   where pharmacy_id = v_pharmacy and role = 'owner'
   order by created_at
   limit 1;
  if v_owner is null then
    raise exception 'PHASE6.5C RETURNS TEST ABORTED: no owner profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------ fixtures
  insert into auth.users (id, email)
  values (v_cashier, 'zztest-47-cashier@example.invalid')
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_cashier, 'ZZTEST 47 cashier', 'cashier', v_pharmacy)
  on conflict (id) do update
    set role = excluded.role, pharmacy_id = excluded.pharmacy_id;

  insert into public.pharmacies (id, name)
  values (gen_random_uuid(), 'ZZTEST 47 other pharmacy')
  returning id into v_other_pharmacy;

  insert into auth.users (id, email)
  values (v_other_owner, 'zztest-47-other-owner@example.invalid')
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_other_owner, 'ZZTEST 47 other owner', 'owner', v_other_pharmacy)
  on conflict (id) do update
    set role = excluded.role, pharmacy_id = excluded.pharmacy_id;

  insert into public.suppliers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST 47 Distributors')
  returning id into v_supplier;

  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 47 paracetamol', 12)
  returning id into v_product;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp, selling_rate
  ) values (
    v_pharmacy, v_product, 'ZZTEST-47-A', current_date + 365, 100, 80, 150, 140
  ) returning id into v_batch;

  -- The invoice the returns are against. Written as a DRAFT on purpose: a received purchase
  -- would post its lines into the batch and move the quantity every assertion below is measured
  -- from, and a return only needs the document to exist.
  insert into public.purchases (
    pharmacy_id, supplier_id, invoice_no, invoice_date, status,
    sub_total, tax_total, grand_total, created_by
  ) values (
    v_pharmacy, v_supplier, 'ZZTEST-47-P', current_date, 'draft',
    800, 96, 896, v_owner
  ) returning id into v_purchase;

  insert into public.purchase_items (
    pharmacy_id, purchase_id, product_id, batch_id, batch_no, qty,
    purchase_rate, mrp, gst_percent, tax_amount, total_amount
  ) values (
    v_pharmacy, v_purchase, v_product, v_batch, 'ZZTEST-47-A', 10,
    80, 150, 12, 96, 896
  );

  -- The other pharmacy's own invoice, so "another pharmacy's purchase" is a real id rather than a
  -- NULL that any check would refuse for the wrong reason.
  insert into public.suppliers (pharmacy_id, name)
  values (v_other_pharmacy, 'ZZTEST 47 other supplier')
  returning id into v_other_supplier;

  insert into public.purchases (
    pharmacy_id, supplier_id, invoice_no, invoice_date, status,
    sub_total, tax_total, grand_total
  ) values (
    v_other_pharmacy, v_other_supplier, 'ZZTEST-47-OP', current_date, 'draft',
    0, 0, 0
  ) returning id into v_other_purchase;

  -- ------------------------------------------------- behave as the pharmacy
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);
  execute 'set local role authenticated';

  -- ==================================================== 1. the shape
  select has_table_privilege('authenticated', 'public.purchase_returns', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated cannot INSERT a purchase return (expected false, got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.purchase_return_items', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor a purchase return line (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.sale_returns', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor a sale return (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.sale_return_items', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor a sale return line (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.stock_adjustments', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor a stock adjustment (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.stock_adjustments', 'SELECT') into v_allowed;
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. while every one of them is still readable (expected true, got ' || v_allowed || ')');

  v_log := array_append(v_log, case
    when public.approval_has_executor('purchase_return') then 'PASS' else 'FAIL' end
    || ': 1. approval_has_executor() answers yes for purchase_return');

  v_log := array_append(v_log, case
    when public.approval_has_executor('sale_return') then 'PASS' else 'FAIL' end
    || ': 1. and for sale_return');

  v_log := array_append(v_log, case
    when public.approval_has_executor('stock_adjustment') then 'PASS' else 'FAIL' end
    || ': 1. and for stock_adjustment');

  v_log := array_append(v_log, case
    when not public.approval_has_executor('expense_create') then 'PASS' else 'FAIL' end
    || ': 1. and never for an action type D-085 retired (expense_create)');

  select has_function_privilege('anon', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_sale_return';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. anon cannot execute record_sale_return (expected false, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_sale_return';
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated can (expected true, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'approval_execute';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. and the dispatch itself is not callable by a session (got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'document_apply_decision';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor the applier (got ' || v_allowed || ')');

  -- ==================================================== 2. a staff return is a request
  v_outcome := public.record_purchase_return(jsonb_build_object(
    'purchase_id', v_purchase,
    'return_date', current_date,
    'reason', 'near expiry',
    'sub_total', 800,
    'tax_total', 96,
    'grand_total', 896,
    'items', jsonb_build_array(
      jsonb_build_object(
        'batch_id', v_batch, 'product_id', v_product, 'qty', 10,
        'purchase_rate', 80, 'mrp', 150, 'gst_percent', 12,
        'tax_amount', 96, 'total_amount', 896
      )
    ),
    'idempotency_key', 'zztest-47-key'
  ));

  v_log := array_append(v_log, case
    when v_outcome ->> 'outcome' = 'staged'
     and v_outcome -> 'document' = 'null'::jsonb
     and nullif(v_outcome ->> 'request_id', '') is not null then 'PASS' else 'FAIL' end
    || ': 2. a cashier''s return answers "staged" with no document (got '
    || coalesce(v_outcome::text, 'NULL') || ')');

  v_approved := (v_outcome ->> 'request_id')::uuid;

  select count(*) into v_rows
    from public.purchase_returns r
   where r.pharmacy_id = v_pharmacy;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 2. and NOTHING was written - there is no return to find (got ' || v_rows || ')');

  select b.qty into v_batch_qty from public.product_batches b where b.id = v_batch;
  v_log := array_append(v_log, case when v_batch_qty = 100 then 'PASS' else 'FAIL' end
    || ': 2. no stock moved (expected 100, got ' || v_batch_qty || ')');

  select * into v_request
    from public.approval_requests a
   where a.id = v_approved;

  v_log := array_append(v_log, case
    when v_request.action_type = 'purchase_return'::public.approval_action_type
     and v_request.requested_by = v_cashier
     and v_request.status = 'pending'::public.approval_status then 'PASS' else 'FAIL' end
    || ': 2. the ask is the cashier''s, of the right type, and undecided');

  v_log := array_append(v_log, case
    when v_request.payload -> 'items' = '[]'::jsonb then 'FAIL' else 'PASS' end
    || ': 2. and it carries the whole document rather than a reference to one');

  v_log := array_append(v_log, case
    when v_request.title like 'Purchase return to ZZTEST 47 Distributors (%' then 'PASS' else 'FAIL' end
    || ': 2. its title names the supplier and the invoice it returns to (got '
    || v_request.title || ')');

  v_log := array_append(v_log, case
    when v_request.summary like '%debits the supplier%' then 'PASS' else 'FAIL' end
    || ': 2. and says which way the money goes (got ' || v_request.summary || ')');

  -- ==================================================== 3. one submit, one ask
  v_outcome := public.record_purchase_return(jsonb_build_object(
    'purchase_id', v_purchase,
    'return_date', current_date,
    'reason', 'near expiry',
    'sub_total', 800,
    'tax_total', 96,
    'grand_total', 896,
    'items', jsonb_build_array(
      jsonb_build_object(
        'batch_id', v_batch, 'product_id', v_product, 'qty', 10,
        'purchase_rate', 80, 'mrp', 150, 'gst_percent', 12,
        'tax_amount', 96, 'total_amount', 896
      )
    ),
    'idempotency_key', 'zztest-47-key'
  ));

  v_log := array_append(v_log, case
    when (v_outcome ->> 'request_id')::uuid = v_approved then 'PASS' else 'FAIL' end
    || ': 3. the same submit twice is the same ask, not a second one (got '
    || coalesce(v_outcome ->> 'request_id', 'NULL') || ')');

  select count(*) into v_rows
    from public.approval_requests a
   where a.pharmacy_id = v_pharmacy and a.status = 'pending';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 3. so the owner has one question, not two (got ' || v_rows || ')');

  -- ==================================================== 4. approving writes the return
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_request := public.decide_approval(v_approved, true, 'OK');

  v_log := array_append(v_log, case
    when v_request.status = 'approved'::public.approval_status then 'PASS' else 'FAIL' end
    || ': 4. the owner''s approval is recorded');

  select count(*) into v_rows from public.purchase_returns r where r.pharmacy_id = v_pharmacy;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 4. the return was written when he approved it (got ' || v_rows || ')');

  select coalesce(sum(r.grand_total), 0) into v_amount
    from public.purchase_returns r where r.pharmacy_id = v_pharmacy;
  v_log := array_append(v_log, case when v_amount = 896.00 then 'PASS' else 'FAIL' end
    || ': 4. with the figures the person who asked for it sent (got ' || v_amount || ')');

  select count(*) into v_rows
    from public.purchase_return_items i
   where i.pharmacy_id = v_pharmacy;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 4. and its lines (got ' || v_rows || ')');

  select b.qty into v_batch_qty from public.product_batches b where b.id = v_batch;
  v_log := array_append(v_log, case when v_batch_qty = 90 then 'PASS' else 'FAIL' end
    || ': 4. the stock moved, exactly as a direct write moved it (expected 90, got '
    || v_batch_qty || ')');

  select count(*) into v_rows
    from public.ledger_entries l
   where l.reference_type = 'purchase_return'
     and l.debit = 896.00;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 4. and the supplier was DEBITED - the contra entry the return always posted (got '
    || v_rows || ')');

  -- ==================================================== 5. the owner is not gated
  v_outcome := public.record_purchase_return(jsonb_build_object(
    'purchase_id', v_purchase,
    'return_date', current_date,
    'sub_total', 160,
    'tax_total', 19.2,
    'grand_total', 179.20,
    'items', jsonb_build_array(
      jsonb_build_object(
        'batch_id', v_batch, 'product_id', v_product, 'qty', 2,
        'purchase_rate', 80, 'mrp', 150, 'gst_percent', 12,
        'tax_amount', 19.2, 'total_amount', 179.20
      )
    )
  ));

  v_log := array_append(v_log, case
    when v_outcome ->> 'outcome' = 'recorded'
     and v_outcome -> 'document' ->> 'id' is not null then 'PASS' else 'FAIL' end
    || ': 5. the owner''s own return answers "recorded" with the document (got '
    || coalesce(v_outcome ->> 'outcome', 'NULL') || ')');

  select b.qty into v_batch_qty from public.product_batches b where b.id = v_batch;
  v_log := array_append(v_log, case when v_batch_qty = 88 then 'PASS' else 'FAIL' end
    || ': 5. and it posted straight away, as it always did (expected 88, got '
    || v_batch_qty || ')');

  select count(*) into v_rows
    from public.approval_requests a
   where a.pharmacy_id = v_pharmacy and a.status = 'pending';
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 5. with no ask raised at all (got ' || v_rows || ')');

  -- ==================================================== 6. a refusal writes nothing
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_outcome := public.record_purchase_return(jsonb_build_object(
    'purchase_id', v_purchase,
    'return_date', current_date,
    'sub_total', 80,
    'tax_total', 9.6,
    'grand_total', 89.60,
    'items', jsonb_build_array(
      jsonb_build_object(
        'batch_id', v_batch, 'product_id', v_product, 'qty', 1,
        'purchase_rate', 80, 'mrp', 150, 'gst_percent', 12,
        'tax_amount', 9.6, 'total_amount', 89.60
      )
    ),
    'idempotency_key', 'zztest-47-key-2'
  ));

  v_approved := (v_outcome ->> 'request_id')::uuid;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_request := public.decide_approval(v_approved, false, 'not this one');

  v_log := array_append(v_log, case
    when v_request.status = 'rejected'::public.approval_status then 'PASS' else 'FAIL' end
    || ': 6. the refusal is recorded as a refusal');

  select count(*) into v_rows from public.purchase_returns r where r.pharmacy_id = v_pharmacy;
  v_log := array_append(v_log, case when v_rows = 2 then 'PASS' else 'FAIL' end
    || ': 6. and it wrote nothing - the two returns that exist are the two that were allowed '
    || '(got ' || v_rows || ')');

  select b.qty into v_batch_qty from public.product_batches b where b.id = v_batch;
  v_log := array_append(v_log, case when v_batch_qty = 88 then 'PASS' else 'FAIL' end
    || ': 6. and no stock moved for it (expected 88, got ' || v_batch_qty || ')');

  select count(*) into v_rows
    from public.ledger_entries l
   where l.reference_type = 'purchase_return' and l.debit = 89.60;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 6. nor was any credit note posted (got ' || v_rows || ')');

  -- ==================================================== 7. a write that cannot land is refused
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_outcome := public.record_purchase_return(jsonb_build_object(
    'purchase_id', v_purchase,
    'return_date', current_date,
    'sub_total', 80000,
    'tax_total', 9600,
    'grand_total', 89600,
    'items', jsonb_build_array(
      jsonb_build_object(
        'batch_id', v_batch, 'product_id', v_product, 'qty', 1000,
        'purchase_rate', 80, 'mrp', 150, 'gst_percent', 12,
        'tax_amount', 9600, 'total_amount', 89600
      )
    ),
    'idempotency_key', 'zztest-47-key-3'
  ));

  v_approved := (v_outcome ->> 'request_id')::uuid;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_msg := null;
  begin
    v_request := public.decide_approval(v_approved, true);
  exception when check_violation then
    v_msg := sqlerrm;
  end;

  v_log := array_append(v_log, case
    when v_msg like 'insufficient stock in batch%' then 'PASS' else 'FAIL' end
    || ': 7. approving more than the batch holds is refused, in the stock trigger''s own words '
    || '(got ' || coalesce(v_msg, 'NULL') || ')');

  select count(*) into v_rows
    from public.approval_requests a
   where a.id = v_approved and a.status = 'pending';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 7. and the request is left PENDING rather than stamped approved (got ' || v_rows || ')');

  select b.qty into v_batch_qty from public.product_batches b where b.id = v_batch;
  v_log := array_append(v_log, case when v_batch_qty = 88 then 'PASS' else 'FAIL' end
    || ': 7. with nothing moved for it (expected 88, got ' || v_batch_qty || ')');

  -- ==================================================== 8. a sale return
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_patient := public.save_patient(
    p_name => 'ZZTEST 47 patient',
    p_mobile => '9000000047'
  );

  v_sale := public.checkout_sale(jsonb_build_object(
    'sale_type', 'counter',
    'customer_id', v_patient.id,
    'amount_paid', 560,
    'items', jsonb_build_array(
      jsonb_build_object('product_id', v_product, 'batch_id', v_batch, 'qty', 4, 'rate', 140)
    )
  ));

  select i.id into v_sale_item
    from public.sale_items i
   where i.sale_id = v_sale.id
   limit 1;

  v_batch_qty := null;
  select b.qty into v_batch_qty from public.product_batches b where b.id = v_batch;

  v_outcome := public.record_sale_return(jsonb_build_object(
    'sale_id', v_sale.id,
    'return_date', current_date,
    'reason', 'wrong item',
    'refund_mode', 'cash',
    'restock', true,
    'sub_total', 250,
    'tax_total', 30,
    'grand_total', 280,
    'items', jsonb_build_array(
      jsonb_build_object(
        'sale_item_id', v_sale_item, 'product_id', v_product, 'batch_id', v_batch,
        'qty', 2, 'rate', 140, 'gst_percent', 12,
        'tax_amount', 30, 'total_amount', 280
      )
    ),
    'idempotency_key', 'zztest-47-sale-key'
  ));

  v_log := array_append(v_log, case
    when v_outcome ->> 'outcome' = 'staged' then 'PASS' else 'FAIL' end
    || ': 8. a cashier''s sale return is a request too (got '
    || coalesce(v_outcome ->> 'outcome', 'NULL') || ')');

  select count(*) into v_rows from public.sale_returns r where r.pharmacy_id = v_pharmacy;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 8. with nothing written and no stock restored (got ' || v_rows || ' returns)');

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_request := public.decide_approval((v_outcome ->> 'request_id')::uuid, true);

  select count(*) into v_rows from public.sale_returns r where r.pharmacy_id = v_pharmacy;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 8. approving it writes the return (got ' || v_rows || ')');

  v_log := array_append(v_log, case
    when v_request.status = 'approved'::public.approval_status then 'PASS' else 'FAIL' end
    || ': 8. and the approval is recorded');

  select b.qty into v_batch_qty from public.product_batches b where b.id = v_batch;
  v_log := array_append(v_log, case when v_batch_qty = 86 then 'PASS' else 'FAIL' end
    || ': 8. the two units that came back went onto the shelf, because the return said restock '
    || '(expected 86 - the batch held 88, the sale took 4, the return put 2 back - got '
    || v_batch_qty || ')');

  select count(*) into v_rows
    from public.ledger_entries l
   where l.reference_type = 'sale_return'
     and l.credit = 280.00
     and l.customer_id = v_patient.id;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 8. and the patient was credited (got ' || v_rows || ')');

  -- ==================================================== 9. a stock adjustment
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_outcome := public.record_stock_adjustment(jsonb_build_object(
    'product_id', v_product,
    'batch_id', v_batch,
    'adjustment_type', 'decrease',
    'qty', 5,
    'reason', 'breakage',
    'idempotency_key', 'zztest-47-adj-key'
  ));

  v_log := array_append(v_log, case
    when v_outcome ->> 'outcome' = 'staged' then 'PASS' else 'FAIL' end
    || ': 9. a cashier''s stock adjustment is a request (got '
    || coalesce(v_outcome ->> 'outcome', 'NULL') || ')');

  select count(*) into v_rows from public.stock_adjustments a where a.pharmacy_id = v_pharmacy;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 9. and NOTHING was adjusted (got ' || v_rows || ' rows)');

  select * into v_request
    from public.approval_requests a
   where a.id = (v_outcome ->> 'request_id')::uuid;

  v_log := array_append(v_log, case
    when v_request.title like 'Stock adjustment: ZZTEST 47 paracetamol%' then 'PASS' else 'FAIL' end
    || ': 9. its title names the product (got ' || v_request.title || ')');

  v_log := array_append(v_log, case
    when v_request.summary like '5 units out of batch ZZTEST-47-A%' then 'PASS' else 'FAIL' end
    || ': 9. and its summary says which way and out of which batch (got '
    || v_request.summary || ')');

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_request := public.decide_approval(v_request.id, true);

  select count(*) into v_rows
    from public.stock_adjustments a
   where a.pharmacy_id = v_pharmacy
     and a.adjustment_type = 'decrease'
     and a.qty = 5;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 9. approving it records the adjustment (got ' || v_rows || ')');

  select b.qty into v_batch_qty from public.product_batches b where b.id = v_batch;
  v_log := array_append(v_log, case when v_batch_qty = 81 then 'PASS' else 'FAIL' end
    || ': 9. and the stock moved (expected 81, got ' || v_batch_qty || ')');

  -- ==================================================== 10. what cannot be asked for
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_msg := null;
  begin
    v_outcome := public.record_purchase_return(jsonb_build_object(
      'purchase_id', v_purchase,
      'items', '[]'::jsonb
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'a purchase return needs at least one line' then 'PASS' else 'FAIL' end
    || ': 10. a return with no lines is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_outcome := public.record_purchase_return(jsonb_build_object(
      'purchase_id', v_other_purchase,
      'items', jsonb_build_array(jsonb_build_object('qty', 1, 'batch_id', v_batch))
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that purchase is not in this pharmacy' then 'PASS' else 'FAIL' end
    || ': 10. a return against another pharmacy''s purchase is refused (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_outcome := public.record_sale_return(jsonb_build_object(
      'sale_id', v_sale.id,
      'items', jsonb_build_array(jsonb_build_object('qty', 1))
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'a sale return has to say whether the goods go back on the shelf'
      then 'PASS' else 'FAIL' end
    || ': 10. a sale return that does not say whether the goods are resellable is refused '
    || '(got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_outcome := public.record_stock_adjustment(jsonb_build_object(
      'product_id', v_product,
      'batch_id', v_batch,
      'qty', 5
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'a stock adjustment has to say which way it goes' then 'PASS' else 'FAIL' end
    || ': 10. an adjustment that does not say which way it goes is refused (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_outcome := public.record_stock_adjustment(jsonb_build_object(
      'product_id', v_product,
      'adjustment_type', 'sideways',
      'qty', 5
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'a stock adjustment has to say which way it goes' then 'PASS' else 'FAIL' end
    || ': 10. and one that says something the column cannot hold (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- ==================================================== 11. another pharmacy
  perform set_config('request.jwt.claims', json_build_object('sub', v_other_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_other_owner::text, true);

  v_msg := null;
  begin
    v_outcome := public.record_stock_adjustment(jsonb_build_object(
      'product_id', v_product,
      'adjustment_type', 'increase',
      'qty', 5
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that product is not in this pharmacy' then 'PASS' else 'FAIL' end
    || ': 11. another pharmacy cannot adjust this one''s stock (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_outcome := public.record_sale_return(jsonb_build_object(
      'sale_id', v_sale.id,
      'restock', true,
      'items', jsonb_build_array(jsonb_build_object('qty', 1))
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that sale is not in this pharmacy' then 'PASS' else 'FAIL' end
    || ': 11. nor return against its sale (got ' || coalesce(v_msg, 'NULL') || ')');

  -- ==================================================== 12. the owner is held to it too
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_msg := null;
  begin
    v_outcome := public.record_purchase_return(jsonb_build_object(
      'purchase_id', v_purchase,
      'items', '[]'::jsonb
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'a purchase return needs at least one line' then 'PASS' else 'FAIL' end
    || ': 12. the OWNER''s own write is held to the same shape - a return with no lines is not a '
    || 'return because he is writing it (got ' || coalesce(v_msg, 'NULL') || ')');

  select count(*) into v_rows from public.purchase_returns r where r.pharmacy_id = v_pharmacy;
  v_log := array_append(v_log, case when v_rows = 2 then 'PASS' else 'FAIL' end
    || ': 12. and it wrote nothing (got ' || v_rows || ' returns, the two that were allowed)');

  -- ================================================================ summary
  v_log := array_append(v_log, case
    when (select count(*) from unnest(v_log) l
           where coalesce(l, '') not like 'PASS%'
             and coalesce(l, '') not like 'FAIL%') = 0
      then 'PASS' else 'FAIL' end
    || ': 12. every logged line is a PASS or a FAIL (nothing skipped, nothing truncated)');

  v_log := array_append(v_log, 'SUMMARY: '
    || (select count(*) from unnest(v_log) l where l like 'PASS%') || ' PASS / '
    || (select count(*) from unnest(v_log) l where l like 'FAIL%') || ' FAIL of '
    || (select count(*) from unnest(v_log) l
         where l like 'PASS%' or l like 'FAIL%') || ' assertions');

  raise exception E'PHASE6.5C RETURNS TEST\n%', array_to_string(v_log, chr(10));
end $$;
