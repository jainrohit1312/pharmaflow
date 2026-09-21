-- Phase 6.5c chunk 5 - functional test for migration 20260921000046 (the product master, the
-- customer/patient master and the expense notification).
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase6_5c_master_data.sql
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
--   the JWT claims are re-pointed at the owner (who is not gated), at a **cashier**, at a
--   **pharmacist** (gated like a cashier since D-085) and at a second pharmacy's owner.
--
-- WHAT IT PROVES
--   1.  The shape: `products`, `product_batches` and `product_aliases` take no INSERT, UPDATE or
--       DELETE from `authenticated` any more and are still readable; `expenses` KEEPS its writes
--       (D-085 gates nothing there); the four master-data action types have executors and the
--       three retired expense types never will; and the mechanism's internals are not executable.
--   2.  A staff product create, edit, deletion, restore or alias act is a REQUEST: nothing is
--       written, and the owner has one ask carrying the whole document.
--   3.  The action type is DERIVED from the document, not named by the caller - so deactivating a
--       product is a `product_delete` ask however it was submitted.
--   4.  The same submit twice is one ask, not two.
--   5.  Approving writes exactly what the direct write wrote, through the same door: the product
--       appears, the edited column changes and the others do not, the alias lands on the N-5 key.
--   6.  The owner's own write is not gated, is the same RPC, and is held to the SAME shape check -
--       so a document a staff ask would be refused for is refused for him too.
--   7.  The customer master: the owner edits it directly, a cashier AND a pharmacist may only ask
--       (D-085 supersedes migration 00038's owner-or-pharmacist rule), and the ask is one question
--       refreshed rather than two stacked.
--   8.  A recorded expense TELLS the owner in-app and queues the delivery log of every channel it
--       can address - and queues none for a channel it cannot, because that would be a claim to
--       have tried. Both halves are asserted with FIXTURE values: the email leg was the channel the
--       account could not be addressed on until chunk 6 put an address on the profile (00048), and
--       migration 00048 backfilled it from auth.users.email, so a fixture that read the environment
--       would pass locally and fail on the hosted project.
--   9.  The enum's own comment says which action types are retired, so the type cannot read as
--       "a chunk is coming" for the three that will never have one.

do $$
declare
  v_log            text[] := array[]::text[];
  v_pharmacy       uuid;
  v_owner          uuid;
  v_owner_phone    text;
  v_cashier        uuid := '00000000-0000-0000-0000-000000000059';
  v_pharmacist     uuid := '00000000-0000-0000-0000-00000000005a';
  v_other_pharmacy uuid;
  v_other_owner    uuid := '00000000-0000-0000-0000-00000000005b';
  v_supplier       uuid;
  v_other_supplier uuid;
  v_product        uuid;
  v_product2       uuid;
  v_other_product  uuid;
  v_alias_id       uuid;
  v_patient        public.customers;
  v_nophone        public.customers;
  v_other_patient  public.customers;
  v_request        public.approval_requests;
  v_request2       public.approval_requests;
  v_decided        public.approval_requests;
  v_out            jsonb;
  v_out2           jsonb;
  v_row            public.products;
  v_row2           public.products;
  v_pat_row        public.customers;
  v_rows           int;
  v_count          int;
  v_expect         int;
  v_allowed        boolean;
  v_msg            text;
  v_comment        text;
  v_payload        jsonb;
  v_key            text;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE6.5C MASTER DATA TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id, phone into v_owner, v_owner_phone
    from public.profiles
   where pharmacy_id = v_pharmacy and role = 'owner'
   order by created_at
   limit 1;
  if v_owner is null then
    raise exception 'PHASE6.5C MASTER DATA TEST ABORTED: no owner profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------ fixtures
  -- `handle_new_user()` creates the profile row when the auth user is inserted, with only the
  -- name in the signup metadata - so the phone and the full name have to be SET here rather than
  -- passed to the insert, or the row would keep the trigger's nulls.
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_cashier, 'zztest-59-cashier@example.invalid', '{"full_name":"ZZTEST 59 cashier"}'::jsonb)
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_cashier, 'ZZTEST 59 cashier', 'cashier', v_pharmacy)
  on conflict (id) do update
    set full_name = excluded.full_name,
        role = excluded.role,
        pharmacy_id = excluded.pharmacy_id;

  insert into auth.users (id, email, raw_user_meta_data)
  values (v_pharmacist, 'zztest-59-pharmacist@example.invalid', '{"full_name":"ZZTEST 59 pharmacist"}'::jsonb)
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_pharmacist, 'ZZTEST 59 pharmacist', 'pharmacist', v_pharmacy)
  on conflict (id) do update
    set full_name = excluded.full_name,
        role = excluded.role,
        pharmacy_id = excluded.pharmacy_id;

  insert into public.pharmacies (id, name)
  values (gen_random_uuid(), 'ZZTEST 59 other pharmacy')
  returning id into v_other_pharmacy;

  insert into auth.users (id, email) values (v_other_owner, 'zztest-59-other@example.invalid')
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_other_owner, 'ZZTEST 59 other owner', 'owner', v_other_pharmacy)
  on conflict (id) do update
    set full_name = excluded.full_name,
        role = excluded.role,
        pharmacy_id = excluded.pharmacy_id;

  insert into public.suppliers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST 59 Distributors')
  returning id into v_supplier;

  insert into public.suppliers (pharmacy_id, name)
  values (v_other_pharmacy, 'ZZTEST 59 other supplier')
  returning id into v_other_supplier;

  insert into public.products (pharmacy_id, name, schedule_type, min_stock_level, category)
  values (v_pharmacy, 'ZZTEST 59 paracetamol', 'OTC', 10, 'Analgesic')
  returning id into v_product;

  insert into public.products (pharmacy_id, name, schedule_type)
  values (v_pharmacy, 'ZZTEST 59 cetirizine', 'H1')
  returning id into v_product2;

  insert into public.products (pharmacy_id, name)
  values (v_other_pharmacy, 'ZZTEST 59 other tablet')
  returning id into v_other_product;

  insert into public.customers (pharmacy_id, name, phone)
  values (v_pharmacy, 'ZZTEST 59 patient', '9876500059')
  returning * into v_patient;

  -- A party with NO number on file, because "a patient must end an edit with a contact number" can
  -- only be exercised on one who has none - the rule reads the row's own phone as the fallback.
  insert into public.customers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST 59 no contact patient')
  returning * into v_nophone;

  insert into public.customers (pharmacy_id, name, phone)
  values (v_other_pharmacy, 'ZZTEST 59 other patient', '9876500058')
  returning * into v_other_patient;

  -- ------------------------------------------------- behave as the pharmacy
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);
  execute 'set local role authenticated';

  -- The patient CODE is minted by save_patient(), not by inserting the row, so the master is taken
  -- through its own registration path once - and the call is made here rather than in the
  -- fixtures because the tenant comes from get_my_pharmacy_id(), which resolves auth.uid().
  -- Registering a patient is free for every role, which is what makes this a fixture and not a
  -- gated act.
  perform public.save_patient(p_patient_id => v_patient.id, p_name => 'ZZTEST 59 patient');

  select * into v_patient from public.customers c where c.id = v_patient.id;

  -- ==================================================== 1. the shape
  select has_table_privilege('authenticated', 'public.products', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated cannot INSERT a product (expected false, got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.products', 'UPDATE') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor UPDATE one (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.products', 'DELETE') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor DELETE one (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.product_batches', 'UPDATE') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor UPDATE a batch, which is the stock hole D-083 recorded (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.product_batches', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor INSERT one (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.product_aliases', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor INSERT an alias (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.product_aliases', 'DELETE') into v_allowed;
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... nor DELETE one (got ' || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.products', 'SELECT') into v_allowed;
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. while every one of the three is still readable (expected true, got ' || v_allowed || ')');

  -- D-085: an expense is NOT gated, so it keeps the writes the owner never asked to approve.
  select has_table_privilege('authenticated', 'public.expenses', 'INSERT') into v_allowed;
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. and an expense still takes a session write - D-085 gates none of them (expected true, got '
    || v_allowed || ')');

  select has_table_privilege('authenticated', 'public.expenses', 'UPDATE') into v_allowed;
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. ... including an edit and a deletion (got ' || v_allowed || ')');

  v_log := array_append(v_log, case
    when public.approval_has_executor('product_create') then 'PASS' else 'FAIL' end
    || ': 1. approval_has_executor() answers yes for product_create');

  v_log := array_append(v_log, case
    when public.approval_has_executor('product_edit') then 'PASS' else 'FAIL' end
    || ': 1. and for product_edit');

  v_log := array_append(v_log, case
    when public.approval_has_executor('product_delete') then 'PASS' else 'FAIL' end
    || ': 1. and for product_delete');

  v_log := array_append(v_log, case
    when public.approval_has_executor('customer_edit') then 'PASS' else 'FAIL' end
    || ': 1. and for customer_edit');

  -- The example of "an action type this build cannot execute" used to be `product_create`; this
  -- chunk built it, so the example moves to the three types D-085 RETIRED - which will never have
  -- an executor, so the assertion stops moving. The RULE asserted is unchanged.
  v_log := array_append(v_log, case
    when not public.approval_has_executor('expense_create')
     and not public.approval_has_executor('expense_edit')
     and not public.approval_has_executor('expense_delete') then 'PASS' else 'FAIL' end
    || ': 1. and never for the three expense types D-085 retired');

  -- The example of "an action type this build cannot execute" is the retired trio above, and it
  -- stays there. This pair is the other half of the rule: chunk 5d built `sale_cancel` and
  -- `sale_edit`, so from that chunk on **no declared action type is left without a chunk** - every
  -- value in the enum is either implemented or retired, which is what the type's own comment says.
  v_log := array_append(v_log, case
    when public.approval_has_executor('sale_cancel')
     and public.approval_has_executor('sale_edit') then 'PASS' else 'FAIL' end
    || ': 1. and yes for the two sale acts chunk 5d built, so no declared type is left without one');

  -- The ask for a retired type is refused in words, naming it.
  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'expense_create',
      p_title => 'ZZTEST 59 an expense the owner never asked to approve'
    );
  exception when feature_not_supported then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'the approval for expense_create is not available yet' then 'PASS' else 'FAIL' end
    || ': 1. a request naming a retired type is refused, named (got ' || coalesce(v_msg, 'NULL') || ')');

  select has_function_privilege('anon', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_product';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. anon cannot execute save_product (expected false, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'save_product';
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. authenticated can (expected true, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'master_apply_decision';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. while the applier is not reachable by a session (expected false, got ' || v_allowed || ')');

  select has_function_privilege('authenticated', p.oid, 'EXECUTE') into v_allowed
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'notify_owner_of_expense';
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. nor the expense trigger function (expected false, got ' || v_allowed || ')');

  -- The enum's own comment, so the retired types cannot read as "a chunk is coming".
  select obj_description('public.approval_action_type'::regtype, 'pg_type') into v_comment;
  v_log := array_append(v_log, case
    when v_comment like '%RETIRED%' and v_comment like '%expense_create%'
      then 'PASS' else 'FAIL' end
    || ': 1. the enum comment says the expense action types are retired');

  v_log := array_append(v_log, case
    when v_comment like '%sale_cancel%' and v_comment like '%IMPLEMENTED%'
      then 'PASS' else 'FAIL' end
    || ': 1. and names what is implemented and what is still declared');

  -- ============================================ 2. a cashier''s new product is a REQUEST
  v_key := 'zztest-59-create-' || gen_random_uuid()::text;
  v_payload := jsonb_build_object(
    'name', 'ZZTEST 59 azithromycin',
    'generic_name', 'Azithromycin',
    'category', 'Antibiotic',
    'schedule_type', 'H1',
    'min_stock_level', 4,
    'barcode', 'ZZTEST59BAR',
    'is_active', true,
    'idempotency_key', v_key
  );

  v_out := public.save_product(v_payload);

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'staged' then 'PASS' else 'FAIL' end
    || ': 2. a cashier''s new product comes back staged (got ' || (v_out ->> 'outcome') || ')');

  v_log := array_append(v_log, case when v_out ->> 'document' is null then 'PASS' else 'FAIL' end
    || ': 2. with no document, because there is none to answer with');

  v_log := array_append(v_log, case
    when (v_out ->> 'request_id')::uuid is not null then 'PASS' else 'FAIL' end
    || ': 2. and the id of the ask it raised');

  select count(*) into v_rows from public.products p
   where p.pharmacy_id = v_pharmacy and p.name = 'ZZTEST 59 azithromycin';
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 2. and NOTHING was written (expected 0 products, got ' || v_rows || ')');

  select * into v_request from public.approval_requests a where a.id = (v_out ->> 'request_id')::uuid;

  v_log := array_append(v_log, case
    when v_request.action_type = 'product_create'::public.approval_action_type then 'PASS' else 'FAIL' end
    || ': 2. the ask is a product_create');

  v_log := array_append(v_log, case
    when v_request.title = 'New product: ZZTEST 59 azithromycin' then 'PASS' else 'FAIL' end
    || ': 2. titled so the owner knows what he is being asked (got ' || v_request.title || ')');

  v_log := array_append(v_log, case
    when v_request.summary like '%Antibiotic%' then 'PASS' else 'FAIL' end
    || ': 2. and summarised from the document itself');

  v_log := array_append(v_log, case
    when v_request.payload ->> 'schedule_type' = 'H1'
     and v_request.payload ->> 'barcode' = 'ZZTEST59BAR' then 'PASS' else 'FAIL' end
    || ': 2. carrying the whole document, not a reference to one');

  v_log := array_append(v_log, case
    when v_request.target_table = 'products' and v_request.target_id is null then 'PASS' else 'FAIL' end
    || ': 2. aimed at the products table, with no row to aim at yet');

  v_log := array_append(v_log, case
    when v_request.requested_by = v_cashier then 'PASS' else 'FAIL' end
    || ': 2. and it records who asked');

  -- The same submit twice is one ask, not two - the key is what makes a double tap harmless.
  v_out2 := public.save_product(v_payload);

  select count(*) into v_rows from public.approval_requests a
   where a.pharmacy_id = v_pharmacy
     and a.action_type = 'product_create'::public.approval_action_type
     and a.idempotency_key = v_key;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 2. the same submit twice is one ask (expected 1, got ' || v_rows || ')');

  v_log := array_append(v_log, case
    when (v_out2 ->> 'request_id')::uuid = v_request.id then 'PASS' else 'FAIL' end
    || ': 2. and the second call answers with the first ask''s id');

  -- ================================ 3. the owner''s own write is not gated, and is the same door
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_out := public.save_product(jsonb_build_object(
    'name', 'ZZTEST 59 owner tablet', 'schedule_type', 'OTC', 'min_stock_level', 2
  ));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'recorded' then 'PASS' else 'FAIL' end
    || ': 3. the owner''s own product is recorded, not asked about (got ' || (v_out ->> 'outcome') || ')');

  v_log := array_append(v_log, case
    when (v_out #>> '{document,name}') = 'ZZTEST 59 owner tablet' then 'PASS' else 'FAIL' end
    || ': 3. and he is answered with the row he wrote');

  v_log := array_append(v_log, case
    when (v_out #>> '{document,pharmacy_id}') = v_pharmacy::text then 'PASS' else 'FAIL' end
    || ': 3. scoped to his own pharmacy');

  select count(*) into v_rows from public.products p
   where p.pharmacy_id = v_pharmacy and p.name = 'ZZTEST 59 owner tablet';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 3. and the row exists (expected 1, got ' || v_rows || ')');

  -- ========================================= 4. approving writes what the direct write wrote
  v_decided := public.decide_approval(
    p_id => v_request.id,
    p_approve => true,
    p_note => 'ZZTEST 59 allowed'
  );

  v_log := array_append(v_log, case
    when v_decided.status = 'approved'::public.approval_status then 'PASS' else 'FAIL' end
    || ': 4. the owner approves the new-product ask');

  select * into v_row from public.products p
   where p.pharmacy_id = v_pharmacy and p.name = 'ZZTEST 59 azithromycin';

  v_log := array_append(v_log, case when v_row.id is not null then 'PASS' else 'FAIL' end
    || ': 4. and the product now exists, written by the approval');

  v_log := array_append(v_log, case
    when v_row.schedule_type = 'H1'::public.schedule_type
     and v_row.gst_percent is null then 'PASS' else 'FAIL' end
    || ': 4. with the document''s own columns, and nothing invented (slab left unrecorded)');

  v_log := array_append(v_log, case
    when v_row.barcode = 'ZZTEST59BAR' and v_row.min_stock_level = 4 then 'PASS' else 'FAIL' end
    || ': 4. including the barcode and the reorder level the ask carried');

  v_log := array_append(v_log, case
    when v_row.is_active then 'PASS' else 'FAIL' end
    || ': 4. and it starts active, as the document said');

  -- ===================================================================== 5. an edit
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_out := public.save_product(jsonb_build_object(
    'product_id', v_product, 'name', 'ZZTEST 59 paracetamol renamed', 'rack_location', 'R-59'
  ));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'staged' then 'PASS' else 'FAIL' end
    || ': 5. a cashier''s product edit is a request (got ' || (v_out ->> 'outcome') || ')');

  select * into v_row from public.products p where p.id = v_product;
  v_log := array_append(v_log, case
    when v_row.name = 'ZZTEST 59 paracetamol' and v_row.rack_location is null then 'PASS' else 'FAIL' end
    || ': 5. and the product is untouched (name ' || v_row.name || ')');

  select * into v_request from public.approval_requests a
   where a.id = (v_out ->> 'request_id')::uuid;
  v_log := array_append(v_log, case
    when v_request.action_type = 'product_edit'::public.approval_action_type then 'PASS' else 'FAIL' end
    || ': 5. the ask is a product_edit');

  v_log := array_append(v_log, case
    when v_request.summary = 'Changes: name, rack_location' then 'PASS' else 'FAIL' end
    || ': 5. its summary names the columns the document changes (got ' || v_request.summary || ')');

  -- A second edit of the same product REFRESHES that one question instead of stacking a second.
  v_out := public.save_product(jsonb_build_object(
    'product_id', v_product, 'name', 'ZZTEST 59 paracetamol v2'
  ));

  select count(*) into v_rows from public.approval_requests a
   where a.pharmacy_id = v_pharmacy
     and a.target_id = v_product
     and a.status = 'pending'::public.approval_status;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 5. a second edit of the same product refreshes the one undecided ask (expected 1, got '
    || v_rows || ')');

  select * into v_request2 from public.approval_requests a
   where a.id = (v_out ->> 'request_id')::uuid;
  v_log := array_append(v_log, case
    when v_request2.id = v_request.id and v_request2.payload ->> 'name' = 'ZZTEST 59 paracetamol v2'
      then 'PASS' else 'FAIL' end
    || ': 5. keeping its identity and taking the newer document');

  -- The owner''s own edit is the same door and the same shape.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_out := public.save_product(jsonb_build_object(
    'product_id', v_product, 'name', 'ZZTEST 59 paracetamol edited', 'rack_location', 'R-59'
  ));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'recorded' then 'PASS' else 'FAIL' end
    || ': 5. the owner''s own edit lands directly (got ' || (v_out ->> 'outcome') || ')');

  select * into v_row from public.products p where p.id = v_product;
  v_log := array_append(v_log, case
    when v_row.name = 'ZZTEST 59 paracetamol edited' and v_row.rack_location = 'R-59'
      then 'PASS' else 'FAIL' end
    || ': 5. and the two columns the document named are changed');

  v_log := array_append(v_log, case
    when v_row.category = 'Analgesic' and v_row.min_stock_level = 10 then 'PASS' else 'FAIL' end
    || ': 5. while a column it did not name keeps its value');

  -- ============================================== 6. a deletion is the soft delete
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_out := public.save_product(jsonb_build_object('product_id', v_product2, 'is_active', false));

  select * into v_request from public.approval_requests a
   where a.id = (v_out ->> 'request_id')::uuid;

  v_log := array_append(v_log, case
    when v_request.action_type = 'product_delete'::public.approval_action_type then 'PASS' else 'FAIL' end
    || ': 6. deactivating a product is a product_delete ask, derived not named by the caller');

  v_log := array_append(v_log, case
    when v_request.title = 'Delete product: ZZTEST 59 cetirizine' then 'PASS' else 'FAIL' end
    || ': 6. titled as the deletion it is (got ' || v_request.title || ')');

  select * into v_row2 from public.products p where p.id = v_product2;
  v_log := array_append(v_log, case when v_row2.is_active then 'PASS' else 'FAIL' end
    || ': 6. and the product is still active until he answers');

  -- The owner deactivates his own, which is the soft delete: the row stays.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_out := public.save_product(jsonb_build_object('product_id', v_product2, 'is_active', false));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'recorded' then 'PASS' else 'FAIL' end
    || ': 6. the owner''s own deletion lands directly (got ' || (v_out ->> 'outcome') || ')');

  select * into v_row2 from public.products p where p.id = v_product2;
  v_log := array_append(v_log, case when not v_row2.is_active then 'PASS' else 'FAIL' end
    || ': 6. leaving the row in place with is_active false');

  select count(*) into v_rows from public.products p where p.id = v_product2;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 6. so the products list can still show what happened (the row is still there)');

  -- And a restore is a product_edit, because it edits is_active back to true.
  v_out := public.save_product(jsonb_build_object('product_id', v_product2, 'is_active', true));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'recorded' then 'PASS' else 'FAIL' end
    || ': 6. and putting it back is an edit, not a deletion (got ' || (v_out ->> 'outcome') || ')');

  select * into v_row2 from public.products p where p.id = v_product2;
  v_log := array_append(v_log, case when v_row2.is_active then 'PASS' else 'FAIL' end
    || ': 6. the product is active again');

  -- ================================================================ 7. aliases
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_out := public.save_product(jsonb_build_object(
    'product_id', v_product,
    'alias', jsonb_build_object('raw_name', 'ZZTEST 59 pcm 500', 'supplier_id', v_supplier)
  ));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'staged' then 'PASS' else 'FAIL' end
    || ': 7. a cashier''s alias is a request (got ' || (v_out ->> 'outcome') || ')');

  select count(*) into v_rows from public.product_aliases a
   where a.pharmacy_id = v_pharmacy and a.normalized_name = 'zztest 59 pcm 500';
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 7. and no alias is recorded (expected 0, got ' || v_rows || ')');

  select * into v_request from public.approval_requests a where a.id = (v_out ->> 'request_id')::uuid;
  v_log := array_append(v_log, case
    when v_request.action_type = 'product_edit'::public.approval_action_type
     and v_request.target_table = 'product_aliases' and v_request.target_id is null
      then 'PASS' else 'FAIL' end
    || ': 7. the ask is a product_edit aimed at the alias table, not at the product''s own row');

  v_log := array_append(v_log, case
    when v_request.summary like '%ZZTEST 59 pcm 500%' then 'PASS' else 'FAIL' end
    || ': 7. and it names the invoice text the owner would be recording');

  -- The owner records it directly, on the N-5 key.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_out := public.save_product(jsonb_build_object(
    'product_id', v_product,
    'alias', jsonb_build_object('raw_name', 'ZZTEST 59 pcm 500', 'supplier_id', v_supplier)
  ));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'recorded' then 'PASS' else 'FAIL' end
    || ': 7. the owner''s own alias lands directly (got ' || (v_out ->> 'outcome') || ')');

  v_alias_id := (v_out #>> '{document,id}')::uuid;

  v_log := array_append(v_log, case
    when (v_out #>> '{document,normalized_name}') = 'zztest 59 pcm 500' then 'PASS' else 'FAIL' end
    || ': 7. normalized by the database''s own function, not by the client');

  -- The same printed text again RE-POINTS instead of duplicating (N-5''s NULLS NOT DISTINCT key).
  v_out := public.save_product(jsonb_build_object(
    'product_id', v_product2,
    'alias', jsonb_build_object('raw_name', 'ZZTEST 59 pcm 500', 'supplier_id', v_supplier)
  ));

  select count(*) into v_rows from public.product_aliases a
   where a.pharmacy_id = v_pharmacy and a.normalized_name = 'zztest 59 pcm 500';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 7. re-adding the same text converges on one row (expected 1, got ' || v_rows || ')');

  v_log := array_append(v_log, case
    when (v_out #>> '{document,product_id}') = v_product2::text then 'PASS' else 'FAIL' end
    || ': 7. and re-points it at the product the owner just named');

  -- A cashier removing it is a request; the owner removing it is not.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_out := public.save_product(jsonb_build_object('product_id', v_product2, 'remove_alias_id', v_alias_id));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'staged' then 'PASS' else 'FAIL' end
    || ': 7. a cashier''s alias removal is a request too (got ' || (v_out ->> 'outcome') || ')');

  select * into v_request from public.approval_requests a where a.id = (v_out ->> 'request_id')::uuid;
  v_log := array_append(v_log, case
    when v_request.target_id = v_alias_id and v_request.summary like '%ZZTEST 59 pcm 500%'
      then 'PASS' else 'FAIL' end
    || ': 7. aimed at that alias, and the summary names the text that would go');

  select count(*) into v_rows from public.product_aliases a where a.id = v_alias_id;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 7. and the alias is still recorded');

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  v_out := public.save_product(jsonb_build_object('product_id', v_product2, 'remove_alias_id', v_alias_id));

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'recorded' then 'PASS' else 'FAIL' end
    || ': 7. the owner''s own removal lands directly (got ' || (v_out ->> 'outcome') || ')');

  select count(*) into v_rows from public.product_aliases a where a.id = v_alias_id;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 7. and the alias row is gone (expected 0, got ' || v_rows || ')');

  -- ======================================================== 8. the customer master
  v_out := public.update_patient(
    p_patient_id => v_patient.id,
    p_name => 'ZZTEST 59 patient one',
    p_mobile => '9876500059',
    p_age_years => 41,
    p_sex => 'female',
    p_notes => 'ZZTEST 59 edited by the owner'
  );

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'recorded' then 'PASS' else 'FAIL' end
    || ': 8. the owner may edit a patient master, and is answered with the row (got '
    || (v_out ->> 'outcome') || ')');

  v_log := array_append(v_log, case
    when (v_out #>> '{document,age_years}') = '41' then 'PASS' else 'FAIL' end
    || ': 8. the edit landed');

  select * into v_pat_row from public.customers c where c.id = v_patient.id;
  v_log := array_append(v_log, case
    when v_pat_row.patient_code is not null then 'PASS' else 'FAIL' end
    || ': 8. an edit leaves the patient code alone (identity belongs to the counter)');

  -- A CASHIER may only ask now.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_out := public.update_patient(
    p_patient_id => v_patient.id,
    p_name => 'ZZTEST 59 cashier rename',
    p_mobile => '9876500059'
  );

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'staged' then 'PASS' else 'FAIL' end
    || ': 8. a cashier''s patient edit is a request, not a refusal and not a write (got '
    || (v_out ->> 'outcome') || ')');

  select * into v_pat_row from public.customers c where c.id = v_patient.id;
  v_log := array_append(v_log, case
    when v_pat_row.name = 'ZZTEST 59 patient one' then 'PASS' else 'FAIL' end
    || ': 8. and the master is NOT rewritten (name ' || v_pat_row.name || ')');

  select * into v_request from public.approval_requests a where a.id = (v_out ->> 'request_id')::uuid;
  v_log := array_append(v_log, case
    when v_request.action_type = 'customer_edit'::public.approval_action_type
     and v_request.target_table = 'customers' and v_request.target_id = v_patient.id
      then 'PASS' else 'FAIL' end
    || ': 8. the ask is a customer_edit aimed at that patient');

  v_log := array_append(v_log, case
    when v_request.payload ->> 'name' = 'ZZTEST 59 cashier rename'
     and v_request.payload ->> 'mobile' = '9876500059' then 'PASS' else 'FAIL' end
    || ': 8. carrying the fields as the function''s own arguments');

  -- A PHARMACIST is gated exactly like a cashier now: D-085 supersedes 00038''s rule.
  perform set_config('request.jwt.claims', json_build_object('sub', v_pharmacist::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_pharmacist::text, true);

  v_out := public.update_patient(
    p_patient_id => v_patient.id,
    p_name => 'ZZTEST 59 pharmacist rename',
    p_mobile => '9876500059'
  );

  v_log := array_append(v_log, case when (v_out ->> 'outcome') = 'staged' then 'PASS' else 'FAIL' end
    || ': 8. a PHARMACIST may no longer edit a master directly - the owner''s policy won (got '
    || (v_out ->> 'outcome') || ')');

  select * into v_pat_row from public.customers c where c.id = v_patient.id;
  v_log := array_append(v_log, case
    when v_pat_row.name = 'ZZTEST 59 patient one' then 'PASS' else 'FAIL' end
    || ': 8. and the master still is not rewritten');

  -- The owner answers it, and the master takes the document''s values.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  -- Counted as the OWNER, because that is who may read an ask he was not the one to raise: the
  -- SELECT policy is `the owner, or the person who asked`.
  select count(*) into v_rows from public.approval_requests a
   where a.pharmacy_id = v_pharmacy
     and a.action_type = 'customer_edit'::public.approval_action_type
     and a.target_id = v_patient.id
     and a.status = 'pending'::public.approval_status;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 8. and the pharmacist''s ask refreshed the cashier''s rather than stacking (expected 1, got '
    || v_rows || ')');

  v_decided := public.decide_approval(p_id => v_request.id, p_approve => true);

  v_log := array_append(v_log, case
    when v_decided.status = 'approved'::public.approval_status then 'PASS' else 'FAIL' end
    || ': 8. the owner approves the customer-edit ask');

  select * into v_pat_row from public.customers c where c.id = v_patient.id;
  v_log := array_append(v_log, case
    when v_pat_row.name = 'ZZTEST 59 pharmacist rename' then 'PASS' else 'FAIL' end
    || ': 8. and the master now reads what the approved document said (got ' || v_pat_row.name || ')');

  -- ================================ 9. the shape check holds both roles, and the owner too
  v_msg := null;
  begin
    v_out := public.save_product(jsonb_build_object('product_id', v_product));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that product edit changes nothing' then 'PASS' else 'FAIL' end
    || ': 9. an edit that changes nothing is refused, in words (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.save_product(jsonb_build_object(
      'product_id', v_product,
      'category', 'Analgesic',
      'alias', jsonb_build_object('raw_name', 'ZZTEST 59 mixed')
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like 'an alias is its own document%' then 'PASS' else 'FAIL' end
    || ': 9. a payload mixing a field change with an alias act is refused (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.save_product(jsonb_build_object(
      'product_id', v_product,
      'alias', jsonb_build_object('raw_name', 'ZZTEST 59 cross', 'supplier_id', v_other_supplier)
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that supplier is not in this pharmacy' then 'PASS' else 'FAIL' end
    || ': 9. an alias scoped to another pharmacy''s supplier is refused (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.save_product(jsonb_build_object('product_id', v_other_product, 'category', 'X'));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that product is not in this pharmacy' then 'PASS' else 'FAIL' end
    || ': 9. another pharmacy''s product is refused (got ' || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.save_product(jsonb_build_object(
      'product_id', v_product, 'min_stock_level', 'five'
    ));
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg like 'a reorder level has to be%' then 'PASS' else 'FAIL' end
    || ': 9. a reorder level that is not a whole number is a sentence, not a cast error (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_out := public.update_patient(
      p_patient_id => v_other_patient.id, p_name => 'ZZTEST 59 cross patient'
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that patient is not in this pharmacy' then 'PASS' else 'FAIL' end
    || ': 9. another pharmacy''s patient is refused by the writer (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- And the same document is refused on the ASK path, by the one shared check - so no ask about
  -- another tenant''s patient can ever reach the owner''s list either.
  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'customer_edit',
      p_title => 'ZZTEST 59 an ask about another pharmacy''s patient',
      p_payload => jsonb_build_object('customer_id', v_other_patient.id, 'name', 'ZZTEST 59 cross')
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that customer is not in this pharmacy' then 'PASS' else 'FAIL' end
    || ': 9. and by the shared check on the ask path, in the checker''s own words (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- A patient with no number on file must END an edit with one: the rule reads the row''s own phone
  -- as the fallback, so it can only be exercised on a party that has none.
  v_msg := null;
  begin
    v_out := public.update_patient(
      p_patient_id => v_nophone.id,
      p_name => 'ZZTEST 59 still no contact'
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'a patient needs a mobile number, or a guardian''s for a child or dependant'
      then 'PASS' else 'FAIL' end
    || ': 9. an edit that would leave the patient unreachable is refused by the shared check (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'customer_edit',
      p_title => 'ZZTEST 59 an ask that would leave the patient unreachable',
      p_payload => jsonb_build_object('customer_id', v_nophone.id, 'name', 'ZZTEST 59 still no contact')
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'a patient needs a mobile number, or a guardian''s for a child or dependant'
      then 'PASS' else 'FAIL' end
    || ': 9. and the same ask is refused before it reaches his list (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- The same rules hold for a staff ASK, not only for the owner''s own write: nothing that
  -- answering could not carry out may reach his list.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'product_edit',
      p_title => 'ZZTEST 59 an ask that changes nothing',
      p_payload => jsonb_build_object('product_id', v_product)
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'that product edit changes nothing' then 'PASS' else 'FAIL' end
    || ': 9. and an ASK for the same nothing is refused before it reaches his list (got '
    || coalesce(v_msg, 'NULL') || ')');

  v_msg := null;
  begin
    v_request := public.request_approval(
      p_action_type => 'product_delete',
      p_title => 'ZZTEST 59 a deletion that does not delete',
      p_payload => jsonb_build_object('product_id', v_product, 'is_active', true)
    );
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  v_log := array_append(v_log, case
    when v_msg = 'a product deletion has to say the product stops being active'
      then 'PASS' else 'FAIL' end
    || ': 9. and a deletion ask that does not deactivate is refused (got '
    || coalesce(v_msg, 'NULL') || ')');

  -- ============================================ 10. the expense notification
  -- The fixture gives the owner a number so the WhatsApp leg is deterministic, and takes his ADDRESS
  -- away for the same reason - then reverses both to pin the other half of the rule: a channel with
  -- no destination is not queued at all. It is set as the OWNER, because `profiles_update_self` is
  -- what permits it - nobody else may rewrite his row - and read straight back, so a fixture that
  -- quietly did nothing is a FAIL here rather than a puzzling count three assertions later.
  --
  -- The address is a fixture value because migration 20260922000048 BACKFILLED `profiles.email`
  -- from `auth.users.email`: on the hosted project the owner''s profile already carries his real
  -- address, so an assertion about the email leg that read the environment would pass locally and
  -- fail there. This block writes the state it asserts, both ways.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  update public.profiles p
     set phone = '9000000059',
         email = null
   where p.id = v_owner;

  select p.phone into v_owner_phone from public.profiles p where p.id = v_owner;

  v_log := array_append(v_log, case when v_owner_phone = '9000000059' then 'PASS' else 'FAIL' end
    || ': 10. the fixture put a number on the owner''s profile (got '
    || coalesce(v_owner_phone, 'NULL') || ')');

  -- The expense itself is recorded by the CASHIER, because who recorded it is what the
  -- notification has to name.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  insert into public.expenses (pharmacy_id, category, amount, expense_date, payment_mode, notes)
  values (v_pharmacy, 'ZZTEST 59 tea', 1250, current_date, 'cash', 'ZZTEST 59 recorded by staff');

  -- The notification is the OWNER''s row, so it is invisible to the cashier under the
  -- notifications SELECT policy (user_id = auth.uid()). Read it as him.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  select count(*) into v_count from public.notifications n
   where n.user_id = v_owner
     and n.type = 'expense'
     and n.message like '%ZZTEST 59 tea%';
  v_log := array_append(v_log, case when v_count = 1 then 'PASS' else 'FAIL' end
    || ': 10. recording an expense puts ONE notification in the owner''s inbox (expected 1, got '
    || v_count || ')');

  select count(*) into v_rows from public.notifications n
   where n.user_id = v_owner
     and n.type = 'expense'
     and n.message like '%ZZTEST 59 cashier%'
     and n.message like '%1250.00%'
     and n.title = 'Expense recorded'
     and n.channel = 'in_app';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 10. and it names who recorded it, what it cost and which act it was');

  -- The delivery log, which is the half a dispatcher settles later.
  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy
     and l.channel = 'whatsapp'
     and l.destination = v_owner_phone
     and l.status = 'queued'
     and l.body like '%ZZTEST 59 tea%';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 10. the WhatsApp leg is queued to the number his profile carries (expected 1, got '
    || v_rows || ')');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy
     and l.channel = 'in_app'
     and l.status = 'queued'
     and l.body like '%ZZTEST 59 tea%';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 10. alongside the in-app delivery log the row points at (expected 1, got ' || v_rows || ')');

  -- A channel the account cannot be addressed on is not queued: that would record an attempt that
  -- could never happen. The fixture left his profile with no address above, so this is the email
  -- leg's absence - and the block below gives him one, which is that same rule's other half.
  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.channel = 'email' and l.body like '%ZZTEST 59 tea%';
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 10. and no email row, because the profile carries no address for him (expected 0, got '
    || v_rows || ')');

  -- Take his number away and give him an address: the in-app row still lands, the WhatsApp row does
  -- not, and the EMAIL leg is the one that now is - which is the positive half of the rule the
  -- assertion above pins negatively, and the leg chunk 6 added.
  update public.profiles p
     set phone = null,
         email = 'zztest-59-owner@example.invalid'
   where p.id = v_owner;

  insert into public.expenses (pharmacy_id, category, amount, expense_date, payment_mode)
  values (v_pharmacy, 'ZZTEST 59 no number', 40, current_date, 'cash');

  select count(*) into v_count from public.notifications n
   where n.user_id = v_owner and n.type = 'expense' and n.message like '%ZZTEST 59 no number%';
  v_log := array_append(v_log, case when v_count = 1 then 'PASS' else 'FAIL' end
    || ': 10. a second expense still reaches the inbox with no number on file (expected 1, got '
    || v_count || ')');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.channel = 'whatsapp'
     and l.body like '%ZZTEST 59 no number%';
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 10. and no WhatsApp row is claimed for a destination that does not exist (expected 0, got '
    || v_rows || ')');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy
     and l.channel = 'email'
     and l.destination = 'zztest-59-owner@example.invalid'
     and l.subject = 'Expense recorded'
     and l.status = 'queued'
     and l.body like '%ZZTEST 59 no number%';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 10. while the email leg IS queued to the address it now carries, subject and all (expected 1, got '
    || v_rows || ')');

  -- An edit and a deletion tell him too: the other two acts D-085 retired.
  update public.expenses e
     set amount = 60
   where e.pharmacy_id = v_pharmacy and e.category = 'ZZTEST 59 no number';

  select count(*) into v_rows from public.notifications n
   where n.user_id = v_owner and n.type = 'expense' and n.title = 'Expense changed'
     and n.message like '%ZZTEST 59 no number%';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 10. an expense EDIT tells him too (expected 1, got ' || v_rows || ')');

  delete from public.expenses e
   where e.pharmacy_id = v_pharmacy and e.category = 'ZZTEST 59 no number';

  select count(*) into v_rows from public.notifications n
   where n.user_id = v_owner and n.type = 'expense' and n.title = 'Expense deleted'
     and n.message like '%ZZTEST 59 no number%';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 10. and so does a deletion (expected 1, got ' || v_rows || ')');

  -- Another pharmacy''s expense is that pharmacy''s owner''s business, not this one''s.
  perform set_config('request.jwt.claims', json_build_object('sub', v_other_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_other_owner::text, true);

  insert into public.expenses (pharmacy_id, category, amount, expense_date, payment_mode)
  values (v_other_pharmacy, 'ZZTEST 59 their tea', 10, current_date, 'cash');

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  select count(*) into v_rows from public.notifications n
   where n.user_id = v_owner and n.message like '%ZZTEST 59 their tea%';
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 10. and the other pharmacy''s expense does not reach this owner (expected 0, got '
    || v_rows || ')');

  -- An expense is still free: no ask was raised for any of them.
  select count(*) into v_rows from public.approval_requests a
   where a.pharmacy_id = v_pharmacy
     and a.action_type in (
       'expense_create'::public.approval_action_type,
       'expense_edit'::public.approval_action_type,
       'expense_delete'::public.approval_action_type
     );
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 10. and recording one raised no approval request at all (expected 0, got ' || v_rows || ')');

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

  raise exception E'PHASE6.5C MASTER DATA TEST\n%', array_to_string(v_log, chr(10));
end $$;
