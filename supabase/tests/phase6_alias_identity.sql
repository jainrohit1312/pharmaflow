-- Phase 6 alias identity - functional test for migration
-- 20260919000030_phase6_alias_identity, which closes open item N-5.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase6_alias_identity.sql
--
-- HOW TO READ THE RESULT
--   Every line is "PASS: ..." or "FAIL: ...", and the last line is
--   "SUMMARY: n PASS / n FAIL". A non-zero exit code is expected and means the
--   script ran to completion: it ends by raising, so the whole DO block (one
--   statement, one transaction) rolls back and no ZZTEST pharmacy, supplier,
--   product or alias survives.
--
-- WHAT IT PROVES
--   1.  The index itself: unique, non-partial, over exactly
--       (pharmacy_id, supplier_id, normalized_name) in that order, and
--       NULLS NOT DISTINCT - which is the whole of the change, and the one
--       property that cannot be inferred from the app's behaviour.
--   2.  The write the app actually makes converges. `ProductsRepository.addAlias`
--       upserts at `on_conflict=pharmacy_id,supplier_id,normalized_name`; the
--       statement below is that statement (every column in the DO UPDATE, the way
--       PostgREST emits it), run as `authenticated` so RLS is live. Before this
--       migration the second NULL-supplier upsert inserted a *second row* - that
--       is the assertion that fails on the old index, and it is why the two
--       printed forms are asserted to normalize to one key first.
--   3.  The pharmacy-wide case re-points rather than duplicates: one row, and it
--       points at the product chosen the second time.
--   4.  The supplier-scoped case still behaves as it did (parity, not regression).
--   5.  What must *not* converge, does not: a supplier-scoped alias and a
--       pharmacy-wide alias for one printed text coexist (the fact
--       phase5_match_products.sql asserts), a second, different text with no
--       supplier adds a row, and one text under two different suppliers is two
--       rows.
--   6.  The key is per tenant: the other pharmacy may hold the same
--       (no supplier, text) pair, and the impersonated caller reads only its own.
--   7.  Nothing else moves: no product, no batch and no purchase row is written
--       by any of it beyond this test's own fixtures.
--
-- WHY IT IMPERSONATES
--   The index is DDL and needs no identity, but the *upsert path* is the thing
--   the app uses, and that runs under RLS as `authenticated`. The fixtures are
--   written as postgres (which owns the tables, is not subject to RLS, and is the
--   only way to create a second tenant inside a transaction), and the write
--   assertions run as the user, exactly as phase5_learn_product_aliases.sql does.

do $$
declare
  v_log       text[] := array[]::text[];
  v_pass      int;
  v_fail      int;
  v_pharmacy  uuid;
  v_other     uuid;
  v_user      uuid;
  v_product   uuid;
  v_product2  uuid;
  v_supplier  uuid;
  v_supplier2 uuid;
  v_norm      text;
  v_norm2     text;
  v_n         int;
  v_before    int;
  v_after     int;
  v_pointed   uuid;
  v_raw       text;
  v_indexdef  text;
  v_indisuniq boolean;
  v_indnulls  boolean;
  v_indpred   boolean;
  v_products_before  int;
  v_products_after   int;
  v_batches_before   int;
  v_batches_after    int;
  v_purchases_before int;
  v_purchases_after  int;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE6 ALIAS TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user
    from public.profiles
   where pharmacy_id = v_pharmacy
   order by created_at
   limit 1;
  if v_user is null then
    raise exception 'PHASE6 ALIAS TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- The two printed forms this test writes. They are *not* the same text - one
  -- has a hyphen and one does not, one is uppercase and one is not - which is what
  -- makes the convergence below a statement about the normalized key rather than
  -- about Postgres string equality. Asserted equal in section 2 before anything
  -- depends on it: a fixture that quietly normalizes differently would make this
  -- whole file pass while testing nothing.
  v_norm  := public.normalize_product_name('DOLO-650 TAB');
  v_norm2 := public.normalize_product_name('ZETAMAC 500 TAB');

  -- ------------------------------------------------------- 1. the index itself
  select i.indisunique, i.indnullsnotdistinct, i.indpred is null,
         pg_get_indexdef(i.indexrelid)
    into v_indisuniq, v_indnulls, v_indpred, v_indexdef
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
    join pg_index i on i.indexrelid = c.oid
   where ns.nspname = 'public'
     and c.relname = 'product_aliases_pharmacy_supplier_normalized_key';

  v_log := array_append(
    v_log,
    case when v_indisuniq then 'PASS' else 'FAIL' end
      || ': 1. the alias key exists and is unique (got '
      || coalesce(v_indisuniq::text, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_indnulls then 'PASS' else 'FAIL' end
      || ': 1. it is NULLS NOT DISTINCT, so a NULL supplier is a value (got '
      || coalesce(v_indnulls::text, 'null') || ') - the whole of N-5'
  );

  v_log := array_append(
    v_log,
    case when v_indpred then 'PASS' else 'FAIL' end
      || ': 1. it is non-partial, which ON CONFLICT inference requires (got '
      || coalesce(v_indpred::text, 'null') || ')'
  );

  -- Exactly the three columns, in the order PostgREST names them. An index over
  -- the right columns in the wrong order is not the target the app upserts at.
  select count(*) into v_n
    from pg_index i
   where i.indexrelid = to_regclass('public.product_aliases_pharmacy_supplier_normalized_key')
     and i.indnatts = 3
     and i.indkey[0] = (
       select a.attnum from pg_attribute a
        where a.attrelid = 'public.product_aliases'::regclass and a.attname = 'pharmacy_id'
     )
     and i.indkey[1] = (
       select a.attnum from pg_attribute a
        where a.attrelid = 'public.product_aliases'::regclass and a.attname = 'supplier_id'
     )
     and i.indkey[2] = (
       select a.attnum from pg_attribute a
        where a.attrelid = 'public.product_aliases'::regclass and a.attname = 'normalized_name'
     );

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 1. its columns are (pharmacy_id, supplier_id, normalized_name) in that order (matched '
      || v_n || ')'
  );

  -- The old index is gone rather than shadowed: one unique index over three
  -- columns is the whole set on this table.
  select count(*) into v_n
    from pg_index i
   where i.indrelid = 'public.product_aliases'::regclass
     and i.indisunique
     and i.indnatts = 3;

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 1. the old NULLS-DISTINCT index did not survive beside it (three-column unique indexes: '
      || v_n || ') - ' || coalesce(v_indexdef, 'no index definition')
  );

  -- ------------------------------------------------------------------- fixtures
  -- Counted *before* the fixtures, so "nothing else moved" is about the test's own
  -- work rather than about its own rows.
  select count(*) into v_products_before from public.products;
  select count(*) into v_batches_before from public.product_batches;
  select count(*) into v_purchases_before from public.purchases;

  -- A whole second tenant, because "the key is per pharmacy" cannot be proven with
  -- one tenant's rows in the database.
  insert into public.pharmacies (name)
  values ('ZZTEST alias identity other pharmacy')
  returning id into v_other;

  insert into public.suppliers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST alias identity supplier A') returning id into v_supplier;
  insert into public.suppliers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST alias identity supplier B') returning id into v_supplier2;

  insert into public.products (pharmacy_id, name, pack_size)
  values (v_pharmacy, 'ZZTEST alias identity 650', '10s') returning id into v_product;
  insert into public.products (pharmacy_id, name, pack_size)
  values (v_pharmacy, 'ZZTEST alias identity 500', '10s') returning id into v_product2;

  -- ------------------------------------------------------------------ as the user
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- ------------------------------------------- 2. the pharmacy-wide upsert (N-5)
  -- The fixture check first: if these two forms ever stop normalizing to one key,
  -- every assertion below would pass while proving nothing.
  v_log := array_append(
    v_log,
    case when v_norm = public.normalize_product_name('dolo-650   tab')
      then 'PASS' else 'FAIL' end
      || ': 2. the two printed forms are one normalized key (''DOLO-650 TAB'' -> '''
      || v_norm || ''', ''dolo-650   tab'' -> '''
      || public.normalize_product_name('dolo-650   tab') || ''')'
  );

  -- The statement `addAlias` makes, with no supplier named. The first one inserts.
  insert into public.product_aliases (
    pharmacy_id, product_id, raw_name, normalized_name, supplier_id
  )
  values (v_pharmacy, v_product, 'DOLO-650 TAB', v_norm, null)
  on conflict (pharmacy_id, supplier_id, normalized_name)
  do update set
    pharmacy_id = excluded.pharmacy_id,
    product_id = excluded.product_id,
    raw_name = excluded.raw_name,
    normalized_name = excluded.normalized_name,
    supplier_id = excluded.supplier_id;

  select count(*) into v_n
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.supplier_id is null
     and a.normalized_name = v_norm;

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 2. a text added with no supplier is one pharmacy-wide row (found ' || v_n || ')'
  );

  -- The same text, printed slightly differently, for a different product. On the
  -- old index this inserted a second row and reported success; it is the assertion
  -- this migration exists for.
  insert into public.product_aliases (
    pharmacy_id, product_id, raw_name, normalized_name, supplier_id
  )
  values (
    v_pharmacy, v_product2, 'dolo-650   tab',
    public.normalize_product_name('dolo-650   tab'), null
  )
  on conflict (pharmacy_id, supplier_id, normalized_name)
  do update set
    pharmacy_id = excluded.pharmacy_id,
    product_id = excluded.product_id,
    raw_name = excluded.raw_name,
    normalized_name = excluded.normalized_name,
    supplier_id = excluded.supplier_id;

  select count(*) into v_n
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.supplier_id is null
     and a.normalized_name = v_norm;

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 2. re-adding the same text with no supplier converges instead of duplicating (found '
      || v_n || ', wanted 1 - the old index left 2)'
  );

  select a.product_id, a.raw_name into v_pointed, v_raw
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.supplier_id is null
     and a.normalized_name = v_norm;

  v_log := array_append(
    v_log,
    case when v_pointed = v_product2 then 'PASS' else 'FAIL' end
      || ': 3. the surviving row re-points at the product chosen the second time'
  );

  v_log := array_append(
    v_log,
    case when v_raw = 'dolo-650   tab' then 'PASS' else 'FAIL' end
      || ': 3. and it carries the printed text as last added (got '
      || coalesce(v_raw, 'null') || ')'
  );

  -- --------------------------------------------- 4. the supplier-scoped upsert
  -- Parity: this converged before the change and must still converge.
  insert into public.product_aliases (
    pharmacy_id, product_id, raw_name, normalized_name, supplier_id
  )
  values (v_pharmacy, v_product, 'ZETAMAC 500 TAB', v_norm2, v_supplier)
  on conflict (pharmacy_id, supplier_id, normalized_name)
  do update set
    pharmacy_id = excluded.pharmacy_id,
    product_id = excluded.product_id,
    raw_name = excluded.raw_name,
    normalized_name = excluded.normalized_name,
    supplier_id = excluded.supplier_id;

  insert into public.product_aliases (
    pharmacy_id, product_id, raw_name, normalized_name, supplier_id
  )
  values (v_pharmacy, v_product2, 'ZETAMAC 500 TAB', v_norm2, v_supplier)
  on conflict (pharmacy_id, supplier_id, normalized_name)
  do update set
    pharmacy_id = excluded.pharmacy_id,
    product_id = excluded.product_id,
    raw_name = excluded.raw_name,
    normalized_name = excluded.normalized_name,
    supplier_id = excluded.supplier_id;

  select count(*) into v_n
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.supplier_id = v_supplier
     and a.normalized_name = v_norm2;

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 4. a supplier-scoped alias still converges to one row (found ' || v_n || ')'
  );

  select a.product_id into v_pointed
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.supplier_id = v_supplier
     and a.normalized_name = v_norm2;

  v_log := array_append(
    v_log,
    case when v_pointed = v_product2 then 'PASS' else 'FAIL' end
      || ': 4. and it re-points at the product chosen the second time'
  );

  -- ---------------------------------------- 5. what must NOT converge, does not
  -- One printed text, two scopes: the supplier-scoped row and the pharmacy-wide
  -- row coexist. This is the fact phase5_match_products.sql asserts, and the
  -- migration must not have taken it away.
  insert into public.product_aliases (
    pharmacy_id, product_id, raw_name, normalized_name, supplier_id
  )
  values (v_pharmacy, v_product, 'DOLO-650 TAB', v_norm, v_supplier);

  select count(*) into v_n
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.normalized_name = v_norm;

  v_log := array_append(
    v_log,
    case when v_n = 2 then 'PASS' else 'FAIL' end
      || ': 5. a supplier-scoped alias and a pharmacy-wide alias for one text still coexist (found '
      || v_n || ', wanted 2)'
  );

  -- A different text with no supplier adds a row rather than converging into one.
  -- Counted as a delta, so this assertion does not depend on what section 2 left
  -- behind - which is how the first draft of this file managed to assert nothing.
  select count(*) into v_before
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy and a.supplier_id is null;

  insert into public.product_aliases (
    pharmacy_id, product_id, raw_name, normalized_name, supplier_id
  )
  values (
    v_pharmacy, v_product, 'AMOXICILLIN 500 CAP',
    public.normalize_product_name('AMOXICILLIN 500 CAP'), null
  );

  select count(*) into v_after
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy and a.supplier_id is null;

  v_log := array_append(
    v_log,
    case when v_after = v_before + 1 then 'PASS' else 'FAIL' end
      || ': 5. a second, different text with no supplier adds a row ('
      || v_before || ' -> ' || v_after || ', wanted +1)'
  );

  -- One text under two different suppliers is two rows.
  insert into public.product_aliases (
    pharmacy_id, product_id, raw_name, normalized_name, supplier_id
  )
  values (v_pharmacy, v_product, 'ZETAMAC 500 TAB', v_norm2, v_supplier2);

  select count(*) into v_n
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.normalized_name = v_norm2;

  v_log := array_append(
    v_log,
    case when v_n = 2 then 'PASS' else 'FAIL' end
      || ': 5. one text under two suppliers is two rows (found ' || v_n
      || ', wanted 2)'
  );

  -- ------------------------------------------------------- 6. the key is per tenant
  -- The other pharmacy may hold the same pair - the key includes pharmacy_id.
  execute 'reset role';

  insert into public.product_aliases (
    pharmacy_id, product_id, raw_name, normalized_name, supplier_id
  )
  values (v_other, v_product, 'DOLO-650 TAB', v_norm, null);

  select count(*) into v_n
    from public.product_aliases a
   where a.normalized_name = v_norm
     and a.supplier_id is null;

  v_log := array_append(
    v_log,
    case when v_n = 2 then 'PASS' else 'FAIL' end
      || ': 6. the same unscoped text exists in both pharmacies as separate rows (found '
      || v_n || ', wanted 2)'
  );

  -- And the caller reads only its own, which is the RLS policy and the key doing
  -- their separate jobs.
  execute 'set local role authenticated';

  select count(*) into v_n
    from public.product_aliases a
   where a.normalized_name = v_norm
     and a.supplier_id is null;

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 6. the signed-in caller sees only its own tenant''s row (found ' || v_n
      || ', wanted 1)'
  );

  -- --------------------------------------------------------- 7. nothing else moved
  execute 'reset role';

  select count(*) into v_products_after from public.products;
  select count(*) into v_batches_after from public.product_batches;
  select count(*) into v_purchases_after from public.purchases;

  v_log := array_append(
    v_log,
    case when v_products_after = v_products_before + 2 then 'PASS' else 'FAIL' end
      || ': 7. the only products that appeared are this test''s two fixtures ('
      || v_products_before || ' -> ' || v_products_after || ')'
  );

  v_log := array_append(
    v_log,
    case when v_batches_after = v_batches_before then 'PASS' else 'FAIL' end
      || ': 7. no batch was written ('
      || v_batches_before || ' -> ' || v_batches_after || ')'
  );

  v_log := array_append(
    v_log,
    case when v_purchases_after = v_purchases_before then 'PASS' else 'FAIL' end
      || ': 7. no purchase was written ('
      || v_purchases_before || ' -> ' || v_purchases_after || ')'
  );

  select count(*) into v_pass from unnest(v_log) l where l like 'PASS%';
  select count(*) into v_fail from unnest(v_log) l where l like 'FAIL%';
  v_log := array_append(
    v_log,
    'SUMMARY: ' || v_pass || ' PASS / ' || v_fail || ' FAIL of '
      || (array_length(v_log, 1) + 1) || ' assertions'
  );

  raise exception E'PHASE6 ALIAS IDENTITY TEST\n%', array_to_string(v_log, chr(10));
end $$;
