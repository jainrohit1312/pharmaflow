-- Phase 6.5c chunk 3 - functional test for migration 20260921000044 (purchases behind the
-- owner's approval: a pending GRN, and the writes the tables no longer take).
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase6_5c_purchases.sql
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
--   The whole point of the chunk is WHO may write a purchase, so this file switches identity
--   repeatedly: fixtures are written as the owner of the database, then the session becomes
--   `authenticated` and the JWT claims are re-pointed at the owner, at a **cashier** (who may only
--   ask) and at a **second pharmacy's owner** (whose writes must not reach this pharmacy's
--   documents). RLS applies to this file's own SELECTs after that, which is how the read policies
--   are asserted rather than assumed.
--
-- WHAT IT PROVES
--   1.  The shape: `purchases` and `purchase_items` take no INSERT/UPDATE/DELETE from
--       `authenticated` any more while still being readable, the three purchase action types have
--       executors, and the mechanism's internals are not callable by a session.
--   2.  A staff receipt is written as `pending_approval` with its batches and its lines - and
--       NOTHING posts: no stock, no supplier payable, no `stock_posted_at`.
--   3.  The ask says what approving it would do, and it is REFRESHED rather than stacked when the
--       same document is saved again.
--   4.  Approving it posts exactly what a direct write posted: the same batch quantities, the same
--       landed cost, the same ledger entry - because it is the same status transition.
--   5.  The owner's own write is not gated, and it answers his staff's ask rather than leaving it
--       in his queue.
--   6.  A refusal soft-deletes a document the ask created, and restores one it did not.
--   7.  A cancellation is a question, not an edit: the document does not move until the answer,
--       and a cancelled document's other questions close with it.
--   8.  The refusals that keep the owner's list honest: an ask has to name a document this build
--       can act on, and the write path refuses a document that does not add up or is already
--       received.
--   9.  A request whose document has moved on is refused rather than applied.
--   10. Nothing that worked before broke: the owner's direct write, the read path and the
--       Phase 2 sweep index are all still there.

do $$
declare
  v_log            text[] := array[]::text[];
  v_outcome        text;
  v_pharmacy       uuid;
  v_owner          uuid;
  v_cashier        uuid := '00000000-0000-0000-0000-000000000045';
  v_other_pharmacy uuid;
  v_other_owner    uuid := '00000000-0000-0000-0000-000000000046';
  v_supplier       uuid;
  v_other_supplier uuid;
  v_product        uuid;
  v_product2       uuid;
  v_doc            public.purchases;
  v_doc2           public.purchases;
  v_staged         public.purchases;
  v_request        public.approval_requests;
  v_request2       public.approval_requests;
  v_msg            text;
  v_rows           int;
  v_qty            int;
  v_cost           numeric(14,4);
  v_amount         numeric(14,2);
  v_allowed        boolean;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE6.5C PURCHASES TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_owner
    from public.profiles
   where pharmacy_id = v_pharmacy and role = 'owner'
   order by created_at
   limit 1;
  if v_owner is null then
    raise exception 'PHASE6.5C PURCHASES TEST ABORTED: no owner profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------ fixtures
  insert into auth.users (id, email)
  values (v_cashier, 'zztest-44-cashier@example.invalid')
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_cashier, 'ZZTEST 44 cashier', 'cashier', v_pharmacy)
  on conflict (id) do update
    set role = excluded.role, pharmacy_id = excluded.pharmacy_id;

  insert into public.pharmacies (id, name)
  values (gen_random_uuid(), 'ZZTEST 44 other pharmacy')
  returning id into v_other_pharmacy;

  insert into auth.users (id, email)
  values (v_other_owner, 'zztest-44-other-owner@example.invalid')
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_other_owner, 'ZZTEST 44 other owner', 'owner', v_other_pharmacy)
  on conflict (id) do update
    set role = excluded.role, pharmacy_id = excluded.pharmacy_id;

  insert into public.suppliers (pharmacy_id, name, state)
  values (v_pharmacy, 'ZZTEST 44 Distributors', 'Maharashtra')
  returning id into v_supplier;

  insert into public.suppliers (pharmacy_id, name)
  values (v_other_pharmacy, 'ZZTEST 44 other supplier')
  returning id into v_other_supplier;

  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 44 twelve percent', 12)
  returning id into v_product;

  insert into public.products (pharmacy_id, name, gst_percent)
  values (v_pharmacy, 'ZZTEST 44 five percent', 5)
  returning id into v_product2;

  -- ------------------------------------------------- behave as the pharmacy
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);
  execute 'set local role authenticated';

  -- ==================================================== 1. the shape the design rests on
  v_log := array_append(v_log, case
    when 'pending_approval'::public.purchase_status::text = 'pending_approval' then 'PASS' else 'FAIL' end
    || ': 1. purchase_status carries pending_approval');

  select has_table_privilege('authenticated', 'public.purchases', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated cannot INSERT a purchase (expected false, got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.purchases', 'UPDATE') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated cannot UPDATE a purchase (expected false, got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.purchases', 'DELETE') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated cannot DELETE a purchase (expected false, got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.purchase_items', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated cannot INSERT a purchase line (expected false, got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.purchase_items', 'UPDATE') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated cannot UPDATE a purchase line (expected false, got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.purchase_items', 'DELETE') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated cannot DELETE a purchase line (expected false, got ' || v_allowed || ')');

  -- The reads are untouched: a purchase list and a document still load normally.
  select has_table_privilege('authenticated', 'public.purchases', 'SELECT') into v_allowed;
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. and it can still READ a purchase (expected true, got ' || v_allowed || ')');

  v_log := array_append(v_log, case
    when public.approval_has_executor('purchase') then 'PASS' else 'FAIL' end
    || ': 1. approval_has_executor() answers yes for purchase');

  v_log := array_append(v_log, case
    when public.approval_has_executor('purchase_edit') then 'PASS' else 'FAIL' end
    || ': 1. and for purchase_edit');

  v_log := array_append(v_log, case
    when public.approval_has_executor('purchase_delete') then 'PASS' else 'FAIL' end
    || ': 1. and for purchase_delete');

  v_log := array_append(v_log, case
    when not public.approval_has_executor('expense_create') then 'PASS' else 'FAIL' end
    || ': 1. and never for an action type D-085 retired (expense_create)');

  select has_function_privilege('anon', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_purchase';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. anon cannot execute save_purchase (expected false, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_purchase';
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated can execute save_purchase (expected true, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'approval_pending_purchase_type';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. the mechanism''s internals are not callable by a session (approval_pending_purchase_type, got '
    || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'purchase_restore_document';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... and not purchase_restore_document either (got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'approval_close_purchase_asks';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... and not approval_close_purchase_asks (got ' || v_allowed || ')');

  select count(*) into v_rows
    from pg_indexes
   where schemaname = 'public'
     and indexname = 'purchases_pharmacy_id_pending_stock_idx';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 1. the received-but-unposted sweep index is untouched (got ' || v_rows || ')');

  -- ==================================================== 2. a staff GRN is a pending document
  v_staged := public.save_purchase(jsonb_build_object(
    'status', 'received',
    'supplier_id', v_supplier,
    'invoice_no', 'ZZTEST-44-A',
    'invoice_date', current_date,
    'notes', 'first pass',
    'sub_total', 2000,
    'discount_total', 0,
    'tax_total', 240,
    'grand_total', 2240,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product, 'product_name_raw', 'ZZTEST 44 twelve percent',
        'batch_no', 'ZZTEST-44-A1', 'expiry_date', current_date + 365,
        'qty', 10, 'free_qty', 2, 'purchase_rate', 100, 'mrp', 150, 'selling_rate', 140,
        'discount_percent', 0, 'gst_percent', 12,
        'cgst_amount', 60, 'sgst_amount', 60, 'igst_amount', 0,
        'tax_amount', 120, 'total_amount', 1120
      ),
      jsonb_build_object(
        'product_id', v_product2, 'product_name_raw', 'ZZTEST 44 five percent',
        'batch_no', 'ZZTEST-44-A2', 'expiry_date', current_date + 400,
        'qty', 10, 'free_qty', 0, 'purchase_rate', 100, 'mrp', 130, 'selling_rate', 125,
        'discount_percent', 0, 'gst_percent', 5,
        'cgst_amount', 30, 'sgst_amount', 30, 'igst_amount', 0,
        'tax_amount', 60, 'total_amount', 1060
      )
    )
  ));

  v_log := array_append(v_log, case
    when v_staged.status = 'pending_approval'::public.purchase_status then 'PASS' else 'FAIL' end
    || ': 2. a cashier''s receipt is written as a PENDING document (got ' || v_staged.status || ')');

  v_log := array_append(v_log, case
    when v_staged.grand_total = 2240.00 then 'PASS' else 'FAIL' end
    || ': 2. and it carries the figures the invoice was saved with (got '
    || v_staged.grand_total || ')');

  v_log := array_append(v_log, case
    when v_staged.stock_posted_at is null then 'PASS' else 'FAIL' end
    || ': 2. nothing was posted (stock_posted_at is null)');

  select count(*) into v_rows
    from public.product_batches b
   where b.pharmacy_id = v_pharmacy
     and b.batch_no in ('ZZTEST-44-A1', 'ZZTEST-44-A2');
  v_log := array_append(v_log, case when v_rows = 2 then 'PASS' else 'FAIL' end
    || ': 2. its batches exist, because the lines have to point at something before the status '
    || 'can move (got ' || v_rows || ' of 2)');

  select count(*) into v_rows
    from public.product_batches b
   where b.pharmacy_id = v_pharmacy
     and b.batch_no in ('ZZTEST-44-A1', 'ZZTEST-44-A2')
     and b.qty = 0;
  v_log := array_append(v_log, case when v_rows = 2 then 'PASS' else 'FAIL' end
    || ': 2. and they hold NO stock (got ' || v_rows || ' of 2 at zero)');

  select count(*) into v_rows
    from public.purchase_items i
   where i.purchase_id = v_staged.id
     and i.batch_id is not null;
  v_log := array_append(v_log, case when v_rows = 2 then 'PASS' else 'FAIL' end
    || ': 2. its lines point at those batches (got ' || v_rows || ' of 2)');

  select coalesce(sum(i.total_amount), 0) into v_amount
    from public.purchase_items i
   where i.purchase_id = v_staged.id;
  v_log := array_append(v_log, case when v_amount = 2180.00 then 'PASS' else 'FAIL' end
    || ': 2. the lines were stored as the invoice had them (got ' || v_amount || ')');

  select count(*) into v_rows
    from public.ledger_entries l
   where l.reference_type = 'purchase'
     and l.reference_id = v_staged.id;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 2. and NO supplier payable was posted (got ' || v_rows || ' ledger entries)');

  select count(*) into v_rows
    from public.approval_requests a
   where a.target_id = v_staged.id
     and a.action_type = 'purchase'
     and a.status = 'pending';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 2. the owner has one ask about it (got ' || v_rows || ')');

  select * into v_request
    from public.approval_requests a
   where a.target_id = v_staged.id and a.status = 'pending';

  v_log := array_append(v_log, case
    when v_request.requested_by = v_cashier
     and v_request.target_table = 'purchases'
     and v_request.decided_by is null then 'PASS' else 'FAIL' end
    || ': 2. raised by the cashier, against the document, undecided');

  v_log := array_append(v_log, case
    when v_request.payload ->> 'resume_status' = 'received' then 'PASS' else 'FAIL' end
    || ': 2. and it says what approving it would do (got '
    || coalesce(v_request.payload ->> 'resume_status', 'NULL') || ')');

  v_log := array_append(v_log, case
    when v_request.payload -> 'undo' = 'null'::jsonb then 'PASS' else 'FAIL' end
    || ': 2. with nothing to put back, because the ask is what created the document');

  v_log := array_append(v_log, case
    when v_request.title like 'Purchase ZZTEST-44-A from %' then 'PASS' else 'FAIL' end
    || ': 2. its title names the invoice and the supplier (got ' || v_request.title || ')');

  -- The owner sees it. (Read as the owner, so RLS has to let him.)
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  select count(*) into v_rows
    from public.approval_requests a
   where a.target_id = v_staged.id and a.status = 'pending';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 2. it is in the owner''s queue (got ' || v_rows || ' of 1 visible to him)');

  -- ==================================================== 3. one ask, refreshed
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_doc := public.save_purchase(jsonb_build_object(
    'purchase_id', v_staged.id,
    'status', 'received',
    'supplier_id', v_supplier,
    'invoice_no', 'ZZTEST-44-A',
    'invoice_date', current_date,
    'notes', 'second pass',
    'sub_total', 1060,
    'discount_total', 0,
    'tax_total', 60,
    'grand_total', 1120,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product2, 'product_name_raw', 'ZZTEST 44 five percent',
        'batch_no', 'ZZTEST-44-A2', 'expiry_date', current_date + 400,
        'qty', 10, 'free_qty', 0, 'purchase_rate', 100, 'mrp', 130, 'selling_rate', 125,
        'discount_percent', 0, 'gst_percent', 5,
        'cgst_amount', 30, 'sgst_amount', 30, 'igst_amount', 0,
        'tax_amount', 60, 'total_amount', 1060
      )
    )
  ));

  select count(*) into v_rows
    from public.approval_requests a
   where a.target_id = v_doc.id and a.status = 'pending';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 3. saving the same document again REFRESHES the ask instead of stacking a second '
    || '(got ' || v_rows || ' pending)');

  select * into v_request
    from public.approval_requests a
   where a.target_id = v_doc.id and a.status = 'pending';

  v_log := array_append(v_log, case
    when v_request.id = v_request.id and v_request.title like 'Purchase ZZTEST-44-A%'
     and v_request.payload ->> 'resume_status' = 'received' then 'PASS' else 'FAIL' end
    || ': 3. and the refreshed ask still says what approving it would do');

  select count(*) into v_rows
    from public.purchase_items i
   where i.purchase_id = v_doc.id;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 3. the document''s lines were replaced, not merged (got ' || v_rows || ' of 1)');

  -- Two lines naming one batch would make the upsert touch one row twice; refused, with a reason.
  v_msg := null;
  begin
    v_doc2 := public.save_purchase(jsonb_build_object(
      'purchase_id', v_doc.id,
      'status', 'received',
      'supplier_id', v_supplier,
      'invoice_no', 'ZZTEST-44-A',
      'invoice_date', current_date,
      'sub_total', 1060, 'tax_total', 60, 'grand_total', 1120,
      'items', jsonb_build_array(
        jsonb_build_object(
          'product_id', v_product2, 'batch_no', 'ZZTEST-44-A2',
          'expiry_date', current_date + 400, 'qty', 5, 'purchase_rate', 100, 'mrp', 130,
          'total_amount', 530
        ),
        jsonb_build_object(
          'product_id', v_product2, 'batch_no', 'ZZTEST-44-A2',
          'expiry_date', current_date + 400, 'qty', 5, 'purchase_rate', 100, 'mrp', 130,
          'total_amount', 530
        )
      )
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'the same batch of one product appears twice - combine the lines or give them different batch numbers'
      then 'PASS' else 'FAIL' end
    || ': 3. two lines naming one batch are refused before the upsert can reach Postgres (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- ==================================================== 4. approving posts the write
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_request := public.decide_approval(v_request.id, true, 'OK');

  v_log := array_append(v_log, case
    when v_request.status = 'approved'::public.approval_status
     and v_request.decided_by = v_owner
     and v_request.decided_at is not null then 'PASS' else 'FAIL' end
    || ': 4. the owner''s approval is recorded with who gave it and when');

  select * into v_doc
    from public.purchases p
   where p.id = v_doc.id;
  v_log := array_append(v_log, case
    when v_doc.status = 'received'::public.purchase_status then 'PASS' else 'FAIL' end
    || ': 4. approving the ask gives the document the status it was saved with (got '
    || v_doc.status || ')');

  v_log := array_append(v_log, case
    when v_doc.stock_posted_at is not null then 'PASS' else 'FAIL' end
    || ': 4. and the receipt posted (stock_posted_at is set)');

  select b.qty, b.landed_cost_per_unit into v_qty, v_cost
    from public.product_batches b
   where b.pharmacy_id = v_pharmacy
     and b.batch_no = 'ZZTEST-44-A2';
  v_log := array_append(v_log, case when v_qty = 10 then 'PASS' else 'FAIL' end
    || ': 4. the stock arrived, exactly as a direct write moved it (got ' || v_qty || ' of 10)');

  v_log := array_append(v_log, case when v_cost = 100.0000 then 'PASS' else 'FAIL' end
    || ': 4. and its landed cost is the moving average the trigger computes (got '
    || coalesce(v_cost::text, 'NULL') || ')');

  select count(*) into v_rows
    from public.ledger_entries l
   where l.reference_type = 'purchase'
     and l.reference_id = v_doc.id
     and l.credit = 1120.00;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 4. the supplier payable was posted for the document''s own figure (got '
    || v_rows || ')');

  -- The batch the first (superseded) pass created holds nothing: its line is gone.
  select b.qty into v_qty
    from public.product_batches b
   where b.pharmacy_id = v_pharmacy
     and b.batch_no = 'ZZTEST-44-A1';
  v_log := array_append(v_log, case when coalesce(v_qty, 0) = 0 then 'PASS' else 'FAIL' end
    || ': 4. the batch a superseded line had created holds no stock (got '
    || coalesce(v_qty::text, 'NULL') || ')');

  select count(*) into v_rows
    from public.approval_requests a
   where a.target_id = v_doc.id and a.status = 'pending';
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 4. and nothing about that document is left waiting (got ' || v_rows || ')');

  -- ==================================================== 5. the owner is not gated
  v_doc2 := public.save_purchase(jsonb_build_object(
    'status', 'received',
    'supplier_id', v_supplier,
    'invoice_no', 'ZZTEST-44-B',
    'invoice_date', current_date,
    'sub_total', 500,
    'discount_total', 0,
    'tax_total', 60,
    'grand_total', 560,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product, 'product_name_raw', 'ZZTEST 44 twelve percent',
        'batch_no', 'ZZTEST-44-B1', 'expiry_date', current_date + 365,
        'qty', 5, 'free_qty', 0, 'purchase_rate', 100, 'mrp', 150, 'selling_rate', 140,
        'discount_percent', 0, 'gst_percent', 12,
        'cgst_amount', 30, 'sgst_amount', 30, 'igst_amount', 0,
        'tax_amount', 60, 'total_amount', 560
      )
    )
  ));

  v_log := array_append(v_log, case
    when v_doc2.status = 'received'::public.purchase_status
     and v_doc2.stock_posted_at is not null then 'PASS' else 'FAIL' end
    || ': 5. the owner''s own receipt posts straight away, exactly as it did before (got '
    || v_doc2.status || ')');

  select count(*) into v_rows
    from public.approval_requests a
   where a.target_id = v_doc2.id;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 5. and raises no ask at all (got ' || v_rows || ')');

  select b.qty into v_qty
    from public.product_batches b
   where b.pharmacy_id = v_pharmacy and b.batch_no = 'ZZTEST-44-B1';
  v_log := array_append(v_log, case when v_qty = 5 then 'PASS' else 'FAIL' end
    || ': 5. with the stock it moved (got ' || v_qty || ' of 5)');

  -- ==================================================== 6. a refusal soft-deletes a creation
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_staged := public.save_purchase(jsonb_build_object(
    'status', 'draft',
    'supplier_id', v_supplier,
    'invoice_no', 'ZZTEST-44-C',
    'invoice_date', current_date,
    'sub_total', 500,
    'tax_total', 60,
    'grand_total', 560,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product, 'batch_no', 'ZZTEST-44-C1',
        'expiry_date', current_date + 365, 'qty', 5, 'purchase_rate', 100, 'mrp', 150,
        'discount_percent', 0, 'gst_percent', 12,
        'cgst_amount', 30, 'sgst_amount', 30, 'igst_amount', 0,
        'tax_amount', 60, 'total_amount', 560
      )
    )
  ));

  select * into v_request
    from public.approval_requests a
   where a.target_id = v_staged.id and a.status = 'pending';

  v_log := array_append(v_log, case
    when v_request.payload ->> 'resume_status' = 'draft' then 'PASS' else 'FAIL' end
    || ': 6. a draft a member of staff saves is staged too, and the ask says so');

  v_log := array_append(v_log, case
    when v_staged.status = 'pending_approval'::public.purchase_status then 'PASS' else 'FAIL' end
    || ': 6. ... and the document waits rather than existing as a draft (got '
    || v_staged.status || ')');

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_request := public.decide_approval(v_request.id, false, 'not now');

  v_log := array_append(v_log, case
    when v_request.status = 'rejected'::public.approval_status then 'PASS' else 'FAIL' end
    || ': 6. the owner''s refusal is recorded as a refusal');

  select * into v_staged
    from public.purchases p
   where p.id = v_staged.id;

  v_log := array_append(v_log, case
    when v_staged.status = 'cancelled'::public.purchase_status then 'PASS' else 'FAIL' end
    || ': 6. refusing a document its own ask created soft-deletes it (got '
    || v_staged.status || ')');

  v_log := array_append(v_log, case
    when v_staged.invoice_no = 'ZZTEST-44-C' then 'PASS' else 'FAIL' end
    || ': 6. the row stays, with the number it was given (got ' || v_staged.invoice_no || ')');

  select count(*) into v_rows
    from public.ledger_entries l
   where l.reference_type = 'purchase' and l.reference_id = v_staged.id;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 6. and nothing was ever posted for it (got ' || v_rows || ' ledger entries)');

  -- ==================================================== 7. an edit is staged, with its pre-image
  -- The owner makes a document of his own: no ask, and the status he asked for.
  v_doc := public.save_purchase(jsonb_build_object(
    'status', 'ordered',
    'supplier_id', v_supplier,
    'invoice_no', 'ZZTEST-44-D',
    'invoice_date', current_date,
    'notes', 'as ordered',
    'sub_total', 1000,
    'tax_total', 120,
    'grand_total', 1120,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product, 'batch_no', 'ZZTEST-44-D1',
        'expiry_date', current_date + 365, 'qty', 10, 'purchase_rate', 100, 'mrp', 150,
        'discount_percent', 0, 'gst_percent', 12,
        'cgst_amount', 60, 'sgst_amount', 60, 'igst_amount', 0,
        'tax_amount', 120, 'total_amount', 1120
      )
    )
  ));

  v_log := array_append(v_log, case
    when v_doc.status = 'ordered'::public.purchase_status then 'PASS' else 'FAIL' end
    || ': 7. the owner can save a document straight as ordered (got ' || v_doc.status || ')');

  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_staged := public.save_purchase(jsonb_build_object(
    'purchase_id', v_doc.id,
    'status', 'received',
    'supplier_id', v_supplier,
    'invoice_no', 'ZZTEST-44-D',
    'invoice_date', current_date,
    'notes', 'goods actually came',
    'sub_total', 1500,
    'tax_total', 180,
    'grand_total', 1680,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product, 'batch_no', 'ZZTEST-44-D1',
        'expiry_date', current_date + 365, 'qty', 15, 'purchase_rate', 100, 'mrp', 150,
        'discount_percent', 0, 'gst_percent', 12,
        'cgst_amount', 90, 'sgst_amount', 90, 'igst_amount', 0,
        'tax_amount', 180, 'total_amount', 1680
      )
    )
  ));

  select * into v_request
    from public.approval_requests a
   where a.target_id = v_doc.id and a.status = 'pending';

  v_log := array_append(v_log, case
    when v_request.action_type = 'purchase_edit'::public.approval_action_type then 'PASS' else 'FAIL' end
    || ': 7. changing a document that already existed asks as a purchase_edit (got '
    || v_request.action_type || ')');

  v_log := array_append(v_log, case
    when v_request.summary like '%replaces the document as it stands%' then 'PASS' else 'FAIL' end
    || ': 7. and the ask says it replaces the document (got ' || v_request.summary || ')');

  -- The staged document is written NOW: that is what makes it a pending GRN rather than a
  -- promise - the owner reads the document itself, not a copy of it.
  select count(*) into v_rows
    from public.purchase_items i
   where i.purchase_id = v_doc.id;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 7. and the document itself holds the edit while it waits (got ' || v_rows || ' line)');

  select count(*) into v_rows
    from public.product_batches b
   where b.pharmacy_id = v_pharmacy and b.batch_no = 'ZZTEST-44-D1' and b.qty = 15;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 7. while nothing moved for it - the batch a staged save touches holds no stock');

  -- ==================================================== 8. approving an edit lands the edit
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_request := public.decide_approval(v_request.id, true);

  select * into v_doc
    from public.purchases p
   where p.id = v_doc.id;

  v_log := array_append(v_log, case
    when v_doc.status = 'received'::public.purchase_status
     and v_doc.grand_total = 1680.00
     and v_doc.notes = 'goods actually came' then 'PASS' else 'FAIL' end
    || ': 8. approving the edit gives the document the status and the figures it was saved with (got '
    || v_doc.status || ', ' || v_doc.grand_total || ', ' || coalesce(v_doc.notes, 'NULL') || ')');

  select b.qty into v_qty
    from public.product_batches b
   where b.pharmacy_id = v_pharmacy and b.batch_no = 'ZZTEST-44-D1';
  v_log := array_append(v_log, case when v_qty = 15 then 'PASS' else 'FAIL' end
    || ': 8. and posts the goods: the batch now holds the edited quantity (got ' || v_qty || ')');

  -- ==================================================== 9. a refusal restores the document
  v_doc := public.save_purchase(jsonb_build_object(
    'status', 'ordered',
    'supplier_id', v_supplier,
    'invoice_no', 'ZZTEST-44-E',
    'invoice_date', current_date,
    'notes', 'as ordered',
    'sub_total', 1000,
    'tax_total', 120,
    'grand_total', 1120,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product, 'batch_no', 'ZZTEST-44-E1',
        'expiry_date', current_date + 365, 'qty', 10, 'purchase_rate', 100, 'mrp', 150,
        'gst_percent', 12, 'tax_amount', 120, 'total_amount', 1120
      )
    )
  ));

  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_staged := public.save_purchase(jsonb_build_object(
    'purchase_id', v_doc.id,
    'status', 'received',
    'supplier_id', v_supplier,
    'invoice_no', 'ZZTEST-44-E',
    'invoice_date', current_date,
    'notes', 'a change the owner will refuse',
    'sub_total', 2000,
    'tax_total', 240,
    'grand_total', 2240,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product, 'batch_no', 'ZZTEST-44-E1',
        'expiry_date', current_date + 365, 'qty', 20, 'purchase_rate', 100, 'mrp', 150,
        'gst_percent', 12, 'tax_amount', 240, 'total_amount', 2240
      ),
      jsonb_build_object(
        'product_id', v_product2, 'batch_no', 'ZZTEST-44-E2',
        'expiry_date', current_date + 365, 'qty', 1, 'purchase_rate', 100, 'mrp', 130,
        'gst_percent', 5, 'tax_amount', 5, 'total_amount', 105
      )
    )
  ));

  select * into v_request
    from public.approval_requests a
   where a.target_id = v_doc.id and a.status = 'pending';

  v_log := array_append(v_log, case
    when v_request.payload -> 'undo' <> 'null'::jsonb
     and v_request.payload -> 'undo' -> 'header' ->> 'status' = 'ordered' then 'PASS' else 'FAIL' end
    || ': 9. an edit carries the pre-image it would put back (got '
    || coalesce(v_request.payload -> 'undo' -> 'header' ->> 'status', 'NULL') || ')');

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_request := public.decide_approval(v_request.id, false, 'wrong invoice');

  select * into v_doc
    from public.purchases p
   where p.id = v_doc.id;

  v_log := array_append(v_log, case
    when v_doc.status = 'ordered'::public.purchase_status then 'PASS' else 'FAIL' end
    || ': 9. refusing an edit puts the document back to the status it had (got '
    || v_doc.status || ')');

  v_log := array_append(v_log, case
    when v_doc.notes = 'as ordered' and v_doc.grand_total = 1120.00 then 'PASS' else 'FAIL' end
    || ': 9. with its own figures (got ' || coalesce(v_doc.notes, 'NULL') || ', '
    || v_doc.grand_total || ')');

  select count(*) into v_rows
    from public.purchase_items i
   where i.purchase_id = v_doc.id;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 9. and its own lines (got ' || v_rows || ' of 1)');

  select count(*) into v_rows
    from public.ledger_entries l
   where l.reference_type = 'purchase' and l.reference_id = v_doc.id;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 9. and nothing posted, because the document never became received (got '
    || v_rows || ')');

  -- ==================================================== 10. a cancellation is a question
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_doc2 := public.save_purchase(jsonb_build_object(
    'purchase_id', v_doc.id,
    'status', 'cancelled'
  ));

  v_log := array_append(v_log, case
    when v_doc2.status = 'ordered'::public.purchase_status then 'PASS' else 'FAIL' end
    || ': 10. asking to cancel does NOT move the document (got ' || v_doc2.status || ')');

  select * into v_request
    from public.approval_requests a
   where a.target_id = v_doc.id
     and a.action_type = 'purchase_delete'
     and a.status = 'pending';

  v_log := array_append(v_log, case
    when v_request.id is not null then 'PASS' else 'FAIL' end
    || ': 10. it raises a cancellation ask of its own');

  v_log := array_append(v_log, case
    when v_request.payload ->> 'from_status' = 'ordered' then 'PASS' else 'FAIL' end
    || ': 10. naming the status it would cancel from (got '
    || coalesce(v_request.payload ->> 'from_status', 'NULL') || ')');

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_request := public.decide_approval(v_request.id, true);

  select * into v_doc
    from public.purchases p
   where p.id = v_doc.id;
  v_log := array_append(v_log, case
    when v_doc.status = 'cancelled'::public.purchase_status then 'PASS' else 'FAIL' end
    || ': 10. approving it cancels the document (got ' || v_doc.status || ')');

  select count(*) into v_rows
    from public.approval_requests a
   where a.target_id = v_doc.id and a.status = 'pending';
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 10. and nothing about it is left waiting (got ' || v_rows || ')');

  -- ==================================================== 11. cancelling closes the other questions
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_staged := public.save_purchase(jsonb_build_object(
    'status', 'draft',
    'supplier_id', v_supplier,
    'invoice_no', 'ZZTEST-44-F',
    'invoice_date', current_date,
    'sub_total', 500,
    'tax_total', 60,
    'grand_total', 560,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product, 'batch_no', 'ZZTEST-44-F1',
        'expiry_date', current_date + 365, 'qty', 5, 'purchase_rate', 100, 'mrp', 150,
        'gst_percent', 12, 'tax_amount', 60, 'total_amount', 560
      )
    )
  ));

  select * into v_request
    from public.approval_requests a
   where a.target_id = v_staged.id and a.status = 'pending';

  perform public.save_purchase(jsonb_build_object(
    'purchase_id', v_staged.id,
    'status', 'cancelled'
  ));

  select count(*) into v_rows
    from public.approval_requests a
   where a.target_id = v_staged.id and a.status = 'pending';
  v_log := array_append(v_log, case when v_rows = 2 then 'PASS' else 'FAIL' end
    || ': 11. a staged document asked to cancel has two live questions - save it, or drop it '
    || '(got ' || v_rows || ')');

  select * into v_request2
    from public.approval_requests a
   where a.target_id = v_staged.id
     and a.action_type = 'purchase_delete'
     and a.status = 'pending';

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_request2 := public.decide_approval(v_request2.id, true);

  select * into v_request
    from public.approval_requests a
   where a.id = v_request.id;
  v_log := array_append(v_log, case
    when v_request.status = 'rejected'::public.approval_status
     and v_request.decided_by = v_owner
     and v_request.decision_note like '%cancelled%' then 'PASS' else 'FAIL' end
    || ': 11. cancelling the document closes its other question as refused, with a note saying why (got '
    || v_request.status || ')');

  select count(*) into v_rows
    from public.approval_requests a
   where a.target_id = v_staged.id and a.status = 'pending';
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 11. so the owner''s list holds no question about a document that no longer exists (got '
    || v_rows || ')');

  -- ==================================================== 12. the owner's own write answers his staff
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_staged := public.save_purchase(jsonb_build_object(
    'status', 'draft',
    'supplier_id', v_supplier,
    'invoice_no', 'ZZTEST-44-G',
    'invoice_date', current_date,
    'sub_total', 500,
    'tax_total', 60,
    'grand_total', 560,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product, 'batch_no', 'ZZTEST-44-G1',
        'expiry_date', current_date + 365, 'qty', 5, 'purchase_rate', 100, 'mrp', 150,
        'gst_percent', 12, 'tax_amount', 60, 'total_amount', 560
      )
    )
  ));

  select * into v_request
    from public.approval_requests a
   where a.target_id = v_staged.id and a.status = 'pending';

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_doc := public.save_purchase(jsonb_build_object(
    'purchase_id', v_staged.id,
    'status', 'received',
    'supplier_id', v_supplier,
    'invoice_no', 'ZZTEST-44-G',
    'invoice_date', current_date,
    'sub_total', 500,
    'tax_total', 60,
    'grand_total', 560,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product, 'batch_no', 'ZZTEST-44-G1',
        'expiry_date', current_date + 365, 'qty', 5, 'purchase_rate', 100, 'mrp', 150,
        'gst_percent', 12, 'tax_amount', 60, 'total_amount', 560
      )
    )
  ));

  v_log := array_append(v_log, case
    when v_doc.status = 'received'::public.purchase_status then 'PASS' else 'FAIL' end
    || ': 12. the owner can finish a document his staff staged (got ' || v_doc.status || ')');

  select * into v_request
    from public.approval_requests a
   where a.id = v_request.id;
  v_log := array_append(v_log, case
    when v_request.status = 'rejected'::public.approval_status
     and v_request.decided_by = v_owner then 'PASS' else 'FAIL' end
    || ': 12. and doing it himself answers the ask rather than leaving it in his queue (got '
    || v_request.status || ')');

  -- ==================================================== 13. an ask has to name something real
  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'purchase',
      p_title => 'ZZTEST 44 purchase of an ordered document',
      p_payload => jsonb_build_object('resume_status', 'received'),
      p_target_table => 'purchases',
      p_target_id => v_doc.id
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that purchase is not waiting for approval - only a document saved as pending can be asked about'
      then 'PASS' else 'FAIL' end
    || ': 13. a content ask about a document that is not staged is refused (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'purchase_delete',
      p_title => 'ZZTEST 44 cancel an ordered document',
      p_target_table => 'purchases',
      p_target_id => v_doc.id
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg is null then 'PASS' else 'FAIL' end
    || ': 13. while cancelling a received document is still askable, as it always was');

  perform set_config('request.jwt.claims', json_build_object('sub', v_other_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_other_owner::text, true);

  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'purchase_delete',
      p_title => 'ZZTEST 44 the other pharmacy asking about this document',
      p_target_table => 'purchases',
      p_target_id => v_doc.id
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that purchase is not in this pharmacy' then 'PASS' else 'FAIL' end
    || ': 13. another pharmacy cannot ask about this one''s document (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_doc2 := public.save_purchase(jsonb_build_object(
      'purchase_id', v_doc.id, 'status', 'cancelled'
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that purchase is not in this pharmacy' then 'PASS' else 'FAIL' end
    || ': 13. and cannot write it either (got ' || coalesce(v_msg, 'NULL') || ')');

  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'purchase',
      p_title => 'ZZTEST 44 no target at all',
      p_payload => jsonb_build_object('resume_status', 'draft')
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'an approval for a purchase has to name the purchase document it is about'
      then 'PASS' else 'FAIL' end
    || ': 13. an ask naming no document is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  -- ==================================================== 14. the write path's own refusals
  v_msg := null;
  begin
    v_doc2 := public.save_purchase(jsonb_build_object(
      'status', 'draft',
      'supplier_id', v_other_supplier,
      'invoice_no', 'ZZTEST-44-X',
      'invoice_date', current_date,
      'sub_total', 100, 'tax_total', 12, 'grand_total', 112,
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product, 'qty', 1, 'purchase_rate', 100, 'mrp', 150,
        'gst_percent', 12, 'tax_amount', 12, 'total_amount', 112
      ))
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that supplier is not in this pharmacy' then 'PASS' else 'FAIL' end
    || ': 14. a supplier outside the pharmacy is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_doc2 := public.save_purchase(jsonb_build_object(
      'status', 'draft',
      'supplier_id', v_supplier,
      'invoice_no', 'ZZTEST-44-X',
      'invoice_date', current_date,
      'sub_total', 0, 'tax_total', 0, 'grand_total', 0,
      'items', '[]'::jsonb
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'a purchase needs at least one line' then 'PASS' else 'FAIL' end
    || ': 14. a document with no lines is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_doc2 := public.save_purchase(jsonb_build_object(
      'status', 'received',
      'supplier_id', v_supplier,
      'invoice_no', 'ZZTEST-44-X',
      'invoice_date', current_date,
      'sub_total', 100, 'tax_total', 12, 'grand_total', 112,
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product, 'batch_no', 'ZZTEST-44-X1',
        'qty', 1, 'purchase_rate', 100, 'mrp', 150,
        'gst_percent', 12, 'tax_amount', 12, 'total_amount', 112
      ))
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'line 1 needs an expiry date before the goods can be booked in'
      then 'PASS' else 'FAIL' end
    || ': 14. a receipt line with no expiry is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_doc2 := public.save_purchase(jsonb_build_object(
      'status', 'received',
      'supplier_id', v_supplier,
      'invoice_no', 'ZZTEST-44-X',
      'invoice_date', current_date,
      'sub_total', 100, 'tax_total', 12, 'grand_total', 112,
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product, 'expiry_date', current_date + 365,
        'qty', 1, 'purchase_rate', 100, 'mrp', 150,
        'gst_percent', 12, 'tax_amount', 12, 'total_amount', 112
      ))
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'line 1 needs a batch number before the goods can be booked in'
      then 'PASS' else 'FAIL' end
    || ': 14. and one with no batch number (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_doc2 := public.save_purchase(jsonb_build_object(
      'status', 'draft',
      'supplier_id', v_supplier,
      'invoice_no', 'ZZTEST-44-X',
      'invoice_date', current_date,
      'sub_total', 100, 'tax_total', 12, 'grand_total', 100,
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product, 'qty', 1, 'purchase_rate', 100, 'mrp', 150,
        'gst_percent', 12, 'tax_amount', 12, 'total_amount', 112
      ))
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like 'the document''s grand total (100.00) is not its taxable value plus its tax%'
      then 'PASS' else 'FAIL' end
    || ': 14. a document whose money does not add up is refused - the ledger will post that figure '
    || '(got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_doc2 := public.save_purchase(jsonb_build_object(
      'status', 'draft',
      'supplier_id', v_supplier,
      'invoice_no', 'ZZTEST-44-X',
      'invoice_date', current_date,
      'sub_total', 0, 'tax_total', 0, 'grand_total', 0,
      'items', jsonb_build_array(jsonb_build_object(
        'qty', 1, 'purchase_rate', 100, 'mrp', 150,
        'gst_percent', 12, 'tax_amount', 0, 'total_amount', 0
      ))
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'line 1 needs a product' then 'PASS' else 'FAIL' end
    || ': 14. a line with no product is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_doc2 := public.save_purchase(jsonb_build_object(
      'status', 'draft',
      'supplier_id', v_supplier,
      'invoice_no', 'ZZTEST-44-X',
      'invoice_date', current_date,
      'sub_total', 0, 'tax_total', 0, 'grand_total', 0,
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', v_product, 'qty', 0, 'purchase_rate', 100, 'mrp', 150,
        'gst_percent', 12, 'tax_amount', 0, 'total_amount', 0
      ))
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'line 1 needs a quantity greater than zero' then 'PASS' else 'FAIL' end
    || ': 14. and one with no quantity (got ' || coalesce(v_msg, 'NULL') || ')');

  -- A received document is not editable, and that is now the server's rule rather than a hidden
  -- button: its lines produced the stock and the ledger entry.
  v_msg := null;
  begin
    v_doc2 := public.save_purchase(jsonb_build_object(
      'purchase_id', v_doc.id,
      'status', 'draft',
      'supplier_id', v_supplier,
      'invoice_no', 'ZZTEST-44-G',
      'invoice_date', current_date,
      'sub_total', 500, 'tax_total', 60, 'grand_total', 560,
      'items', jsonb_build_array(
        jsonb_build_object(
          'product_id', v_product, 'batch_no', 'ZZTEST-44-G1',
          'expiry_date', current_date + 365, 'qty', 99, 'purchase_rate', 100, 'mrp', 150,
          'gst_percent', 12, 'tax_amount', 60, 'total_amount', 560
        )
      )
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'this purchase is received already, and its stock is booked in: correct it with a purchase return or a stock adjustment instead'
      then 'PASS' else 'FAIL' end
    || ': 14. editing a received document is refused, in the sentence the client used to raise '
    || '(got ' || coalesce(v_msg, 'NULL') || ')');

  -- ==================================================== 15. a stale ask is refused, not applied
  v_staged := public.save_purchase(jsonb_build_object(
    'status', 'draft',
    'supplier_id', v_supplier,
    'invoice_no', 'ZZTEST-44-H',
    'invoice_date', current_date,
    'sub_total', 500,
    'tax_total', 60,
    'grand_total', 560,
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_id', v_product, 'batch_no', 'ZZTEST-44-H1',
        'expiry_date', current_date + 365, 'qty', 5, 'purchase_rate', 100, 'mrp', 150,
        'gst_percent', 12, 'tax_amount', 60, 'total_amount', 560
      )
    )
  ));

  select * into v_request
    from public.approval_requests a
   where a.target_id = v_staged.id and a.status = 'pending';

  -- Simulate the race: the document moves on between the ask and the answer, out of band.
  execute 'reset role';
  update public.purchases p
     set status = 'ordered'::public.purchase_status
   where p.id = v_staged.id;
  execute 'set local role authenticated';

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_msg := null;
  begin
    v_request2 := public.decide_approval(v_request.id, true);
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like 'that purchase has moved on since this was asked (%now) - it is no longer waiting for this answer'
      then 'PASS' else 'FAIL' end
    || ': 15. an ask whose document has moved on is refused rather than applied (got '
    || coalesce(v_msg, 'NULL') || ')');

  select count(*) into v_rows
    from public.approval_requests a
   where a.id = v_request.id and a.status = 'pending';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 15. and the refusal did not record a decision either (got ' || v_rows
    || ' still pending)');

  -- ================================================================ summary
  v_log := array_append(v_log, case
    when (select count(*) from unnest(v_log) l
           where coalesce(l, '') not like 'PASS%'
             and coalesce(l, '') not like 'FAIL%') = 0
      then 'PASS' else 'FAIL' end
    || ': 16. every logged line is a PASS or a FAIL (nothing skipped, nothing truncated)');

  v_log := array_append(v_log, 'SUMMARY: '
    || (select count(*) from unnest(v_log) l where l like 'PASS%') || ' PASS / '
    || (select count(*) from unnest(v_log) l where l like 'FAIL%') || ' FAIL of '
    || (select count(*) from unnest(v_log) l
         where l like 'PASS%' or l like 'FAIL%') || ' assertions');

  raise exception E'PHASE6.5C PURCHASES TEST\n%', array_to_string(v_log, chr(10));
end $$;
