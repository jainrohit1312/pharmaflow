-- Phase 5 alias learning - functional test for migration
-- 20260919000024_phase5_alias_learning.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase5_learn_product_aliases.sql
--
-- HOW TO READ THE RESULT
--   Every line is "PASS: ..." or "FAIL: ...", and the last line is
--   "SUMMARY: n PASS / n FAIL". A non-zero exit code is expected and means the
--   script ran to completion: it ends by raising, so the whole DO block (one
--   statement, one transaction) rolls back and no ZZTEST pharmacy, supplier,
--   product or alias survives.
--
-- WHY IT IMPERSONATES
--   `learn_product_aliases` is SECURITY DEFINER, so RLS is NOT applied to its
--   own statements - the only way to prove it scopes by hand is to call it as
--   `authenticated` with a JWT set, the way phase4_report_summary.sql and
--   phase5_match_products.sql do, and to put a second tenant's product and a
--   second tenant's supplier in reach. The fixtures themselves are written as
--   `postgres`, which owns the tables, is not subject to RLS, and is the only
--   way to create that second tenant inside a transaction.
--
-- WHAT IT PROVES
--   1.  The write itself: the printed text trimmed, the normalized form derived
--       server-side, the row scoped to the supplier and pointed at the product
--       the human chose, and the numbers in the return envelope.
--   2.  Re-learning converges: the same text for the same supplier re-points the
--       one row instead of adding a second.
--   3.  The NULL-supplier case converges too, which the unique index could not do
--       on its own when this file was written (open item N-5, closed by migration
--       20260919000030): the same text with no supplier stays one row and
--       re-points. The function's own update-then-insert is what converges it, and
--       it stays after 00030 - redundant now, still correct.
--   4.  Every untrusted input is skipped with a reason rather than raising: a
--       non-object entry, blank text, punctuation-only text, no product chosen, a
--       malformed product id, a product belonging to another tenant, a supplier
--       belonging to another tenant (read as "no supplier"), and a body that is
--       not an array at all.
--   5.  End to end through `match_products`: a learned alias answers the alias leg
--       at 1.0 for the supplier it was learned from, does NOT answer another
--       supplier's bill, and does once the same text is learned with no supplier
--       - D-036's rule, proven through this migration's write.
--   6.  Nothing else moves: no product, no batch, no purchase row appears.
--   7.  The function's own contract: SECURITY DEFINER, VOLATILE (it writes),
--       search_path pinned, no pharmacy argument, and EXECUTE for `authenticated`
--       but not for `anon`.

do $$
declare
  v_log       text[] := array[]::text[];
  v_pass      int;
  v_fail      int;
  v_pharmacy  uuid;
  v_user      uuid;
  v_other     uuid;
  v_supplier  uuid;
  v_supplier2 uuid;
  v_sup_other uuid;
  v_product   uuid;
  v_product2  uuid;
  v_p_other   uuid;
  v_pointed   uuid;
  v_result    jsonb;
  v_n         int;
  v_row       public.product_aliases%rowtype;
  v_products_before int;
  v_products_after  int;
  v_batches_before  int;
  v_batches_after   int;
  v_purchases_before int;
  v_purchases_after  int;
  v_prosecdef boolean;
  v_provolatile char;
  v_proconfig  text[];
  v_identity   text;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE5 ALIAS TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user
    from public.profiles
   where pharmacy_id = v_pharmacy
   order by created_at
   limit 1;
  if v_user is null then
    raise exception 'PHASE5 ALIAS TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------- fixtures
  -- A whole second tenant, because "a product that is not in this catalogue" and
  -- "a supplier that is not ours" are the two checks that cannot be proven with
  -- only one tenant's rows in the database.
  insert into public.pharmacies (name)
  values ('ZZTEST alias other pharmacy')
  returning id into v_other;

  insert into public.suppliers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST alias supplier A') returning id into v_supplier;
  insert into public.suppliers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST alias supplier B') returning id into v_supplier2;
  insert into public.suppliers (pharmacy_id, name)
  values (v_other, 'ZZTEST alias supplier foreign') returning id into v_sup_other;

  insert into public.products (pharmacy_id, name, pack_size)
  values (v_pharmacy, 'ZZTEST Zetamac 500', '10s') returning id into v_product;
  insert into public.products (pharmacy_id, name, pack_size)
  values (v_pharmacy, 'ZZTEST Zetamac 650', '10s') returning id into v_product2;
  insert into public.products (pharmacy_id, name, pack_size)
  values (v_other, 'ZZTEST Zetamac 500', '10s') returning id into v_p_other;

  -- ------------------------------------------------------------------ as the user
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- ------------------------------------------------------------- 1. the write
  -- The text arrives as a screen holds it: padded, and with the inner spacing the
  -- bill printed. `normalize_product_name('DOLO-650   TAB')` is 'dolo650 tab'
  -- (measured on this database: the punctuation is dropped, the space is kept),
  -- and the point of the assertion is that the *database* derived it - a client
  -- that sent its own idea of "normalized" would write an alias the alias leg
  -- could never match.
  v_result := public.learn_product_aliases(jsonb_build_array(
    jsonb_build_object(
      'raw_name', '  DOLO-650   TAB  ',
      'product_id', v_product::text,
      'supplier_id', v_supplier::text
    )
  ));

  v_log := array_append(
    v_log,
    case when (v_result->>'learned')::int = 1 then 'PASS' else 'FAIL' end
      || ': 1. one confirmed line is learned (got '
      || coalesce(v_result->>'learned', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_result ? 'learned' and v_result ? 'skipped'
      then 'PASS' else 'FAIL' end
      || ': 1. the envelope carries exactly what it says it does (learned, skipped)'
  );

  v_log := array_append(
    v_log,
    case when jsonb_array_length(coalesce(v_result->'skipped', '[]'::jsonb)) = 0
      then 'PASS' else 'FAIL' end
      || ': 1. a line this good is skipped for nothing (got '
      || coalesce(v_result->'skipped', 'null')::text || ')'
  );

  select * into v_row
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.normalized_name = 'dolo650 tab';

  v_log := array_append(
    v_log,
    case when v_row.id is not null then 'PASS' else 'FAIL' end
      || ': 1. the alias is in the table'
  );

  v_log := array_append(
    v_log,
    case when v_row.raw_name = 'DOLO-650   TAB' then 'PASS' else 'FAIL' end
      || ': 1. raw_name is the printed text, trimmed but otherwise untouched (got '
      || coalesce(v_row.raw_name, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_row.normalized_name = 'dolo650 tab' then 'PASS' else 'FAIL' end
      || ': 1. normalized_name was derived by the database, not sent by the client (got '
      || coalesce(v_row.normalized_name, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_row.product_id = v_product then 'PASS' else 'FAIL' end
      || ': 1. the alias points at the product the human chose'
  );

  v_log := array_append(
    v_log,
    case when v_row.supplier_id = v_supplier then 'PASS' else 'FAIL' end
      || ': 1. the alias is scoped to the supplier the bill named (got '
      || coalesce(v_row.supplier_id::text, 'null') || ')'
  );

  -- ------------------------------------------------- 2. re-learning converges
  -- The same bill text arrives again, and this time the human chooses a different
  -- product. That is the whole point of the unique key: the mapping is corrected,
  -- not duplicated.
  v_result := public.learn_product_aliases(jsonb_build_array(
    jsonb_build_object(
      'raw_name', 'DOLO-650   TAB',
      'product_id', v_product2::text,
      'supplier_id', v_supplier::text
    )
  ));

  select count(*) into v_n
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.normalized_name = 'dolo650 tab';

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 2. re-learning the same text for the same supplier is still one row (found '
      || v_n || ')'
  );

  select a.product_id into v_pointed
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.normalized_name = 'dolo650 tab';

  v_log := array_append(
    v_log,
    case when v_pointed = v_product2 then 'PASS' else 'FAIL' end
      || ': 2. and it now points at the product chosen the second time'
  );

  -- ------------------------------------ 3. the pharmacy-wide case (open item N-5)
  -- supplier_id NULL. The unique index could not converge these rows when this was
  -- written - Postgres treats NULLs as distinct - so the function updates first and
  -- inserts only when there was nothing to update. Migration 00030 closes N-5 by
  -- rebuilding the index NULLS NOT DISTINCT; the function is deliberately not
  -- replaced, and its branch is what this section still exercises.
  v_result := public.learn_product_aliases(jsonb_build_array(
    jsonb_build_object(
      'raw_name', 'ZETAMAC 500 TAB',
      'product_id', v_product::text,
      'supplier_id', null
    )
  ));

  select count(*) into v_n
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.normalized_name = 'zetamac 500 tab'
     and a.supplier_id is null;

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 3. a text learned with no supplier is one pharmacy-wide row (found '
      || v_n || ')'
  );

  v_result := public.learn_product_aliases(jsonb_build_array(
    jsonb_build_object(
      'raw_name', 'ZETAMAC 500 TAB',
      'product_id', v_product2::text,
      'supplier_id', null
    )
  ));

  select count(*) into v_n
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.normalized_name = 'zetamac 500 tab';

  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 3. learning it with no supplier a second time is still one row, not two (found '
      || v_n || ') - the N-5 trap this branch sidesteps, which 00030 closed'
  );

  select a.product_id into v_pointed
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.normalized_name = 'zetamac 500 tab';

  v_log := array_append(
    v_log,
    case when v_pointed = v_product2 and (v_result->>'learned')::int = 1
      then 'PASS' else 'FAIL' end
      || ': 3. and the second write re-points it, reporting the work as done'
  );

  -- -------------------------------------------------------- 4. untrusted input
  -- Everything here arrives from a screen. A bill that cannot teach is not a
  -- failure - the purchase it came from is already saved - so each one is skipped
  -- with a reason and the rest of the batch is still learned.
  select count(*) into v_products_before
    from public.products where pharmacy_id = v_pharmacy;
  select count(*) into v_batches_before
    from public.product_batches where pharmacy_id = v_pharmacy;
  select count(*) into v_purchases_before
    from public.purchases where pharmacy_id = v_pharmacy;

  v_result := public.learn_product_aliases(jsonb_build_array(
    jsonb_build_object('raw_name', '   ', 'product_id', v_product::text),
    jsonb_build_object('raw_name', '---', 'product_id', v_product::text),
    jsonb_build_object('raw_name', 'ZZQQ nothing chosen', 'product_id', null),
    jsonb_build_object(
      'raw_name', 'ZZQQ foreign product', 'product_id', v_p_other::text
    ),
    jsonb_build_object(
      'raw_name', 'ZZQQ foreign supplier',
      'product_id', v_product::text,
      'supplier_id', v_sup_other::text
    ),
    to_jsonb('not a line'::text),
    jsonb_build_object(
      'raw_name', 'zzqq-not-a-uuid',
      'product_id', 'zzqq-not-a-uuid',
      'supplier_id', 'zzqq-not-a-uuid'
    )
  ));

  v_log := array_append(
    v_log,
    case when (v_result->>'learned')::int = 1 then 'PASS' else 'FAIL' end
      || ': 4. only the one legitimate line in a batch of seven is learned (got '
      || coalesce(v_result->>'learned', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when jsonb_array_length(v_result->'skipped') = 6 then 'PASS' else 'FAIL' end
      || ': 4. the other six are skipped, not raised (skipped '
      || jsonb_array_length(v_result->'skipped') || ' of 7)'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->'skipped') s
   where s->>'reason' = 'the printed text has nothing to match on';
  v_log := array_append(
    v_log,
    case when v_n = 2 then 'PASS' else 'FAIL' end
      || ': 4. blank text and punctuation-only text are refused by the normalizer (found '
      || v_n || ' of 2)'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->'skipped') s
   where s->>'reason' = 'no product was chosen for it';
  v_log := array_append(
    v_log,
    case when v_n = 2 then 'PASS' else 'FAIL' end
      || ': 4. no product chosen, and a product id that is not a uuid, are one refusal: an id the app did not choose (found '
      || v_n || ' of 2)'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->'skipped') s
   where s->>'reason' = 'that product is not in this catalogue';
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 4. another tenant''s product id is refused as such (found ' || v_n || ')'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->'skipped') s
   where s->>'reason' = 'not a line';
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 4. an entry that is not an object is skipped rather than raising (found '
      || v_n || ')'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->'skipped') s
   where s->>'reason' is null;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 4. every skip carries a reason a person could read (unnamed: ' || v_n || ')'
  );

  -- The cross-tenant product must leave no row behind at all: the alias table
  -- would otherwise hold a mapping to a product this pharmacy cannot read.
  select count(*) into v_n
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.raw_name = 'ZZQQ foreign product';
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 4. no alias was written for the foreign product (found ' || v_n || ')'
  );

  -- A supplier that is not ours is read as "no supplier": the alias is still worth
  -- having, it is just pharmacy-wide rather than scoped to a stranger.
  select count(*) into v_n
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.raw_name = 'ZZQQ foreign supplier'
     and a.supplier_id is null;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 4. a foreign supplier id is read as "no supplier", and the alias is still learned (found '
      || v_n || ')'
  );

  -- A malformed uuid must never reach a cast, and must leave no row behind.
  select count(*) into v_n
    from public.product_aliases a
   where a.pharmacy_id = v_pharmacy
     and a.raw_name = 'zzqq-not-a-uuid';
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 4. a value that is not a uuid never reaches a cast (rows written: ' || v_n || ')'
  );

  -- A body that is not an array (or is absent) is an answer, not an exception: the
  -- app has already saved the purchase by the time it learns.
  v_result := public.learn_product_aliases('{"raw_name":"DOLO-650 TAB"}'::jsonb);
  v_log := array_append(
    v_log,
    case when (v_result->>'learned')::int = 0
          and jsonb_array_length(v_result->'skipped') = 0
      then 'PASS' else 'FAIL' end
      || ': 4. a body that is not an array learns nothing and says so (got '
      || v_result::text || ')'
  );

  v_result := public.learn_product_aliases(null);
  v_log := array_append(
    v_log,
    case when (v_result->>'learned')::int = 0 then 'PASS' else 'FAIL' end
      || ': 4. a null body is an empty batch, not an error (got '
      || v_result::text || ')'
  );

  -- --------------------------------------- 5. end to end through the alias leg
  -- The product's own name here is deliberately nothing like the printed text, so
  -- the trigram leg cannot find it and any candidate at all is the alias leg's
  -- work. This is D-036's supplier rule, proven through this migration's write.
  v_result := public.match_products(jsonb_build_array(
    jsonb_build_object('raw_name', 'DRL500TAB', 'supplier_id', v_supplier::text)
  ));

  select count(*) into v_n
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_product2::text and c->>'reason' = 'alias';
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 5. before any learning, that text answers no alias (found ' || v_n || ')'
  );

  v_result := public.learn_product_aliases(jsonb_build_array(
    jsonb_build_object(
      'raw_name', 'DRL500TAB',
      'product_id', v_product2::text,
      'supplier_id', v_supplier::text
    )
  ));
  v_log := array_append(
    v_log,
    case when (v_result->>'learned')::int = 1 then 'PASS' else 'FAIL' end
      || ': 5. the bill''s supplier-scoped alias is learned'
  );

  v_result := public.match_products(jsonb_build_array(
    jsonb_build_object('raw_name', 'DRL500TAB', 'supplier_id', v_supplier::text)
  ));
  v_log := array_append(
    v_log,
    case when v_result->0->'candidates'->0->>'product_id' = v_product2::text
          and v_result->0->'candidates'->0->>'reason' = 'alias'
      then 'PASS' else 'FAIL' end
      || ': 5. the supplier''s own bill now resolves on the alias leg (got '
      || coalesce(v_result->0->'candidates'->0->>'reason', 'nothing') || ')'
  );

  v_log := array_append(
    v_log,
    case when (v_result->0->'candidates'->0->>'score')::numeric = 1.0 then 'PASS' else 'FAIL' end
      || ': 5. and it scores as a certainty, not a similarity (got '
      || coalesce(v_result->0->'candidates'->0->>'score', 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when (v_result->0->'candidates'->0->'evidence'->>'supplier_scoped')::boolean
      then 'PASS' else 'FAIL' end
      || ': 5. the answer says the hit came from this supplier''s own alias'
  );

  -- Another distributor's bill. The alias was learned from supplier A, so it is
  -- not evidence about supplier B: two suppliers abbreviate differently.
  v_result := public.match_products(jsonb_build_array(
    jsonb_build_object('raw_name', 'DRL500TAB', 'supplier_id', v_supplier2::text)
  ));

  select count(*) into v_n
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_product2::text and c->>'reason' = 'alias';
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 5. another supplier''s bill is NOT answered by it (alias hits found ' || v_n || ')'
  );

  -- The same text learned with no supplier. This is the row that crosses
  -- suppliers, which is what a pharmacy-wide alias is for.
  v_result := public.learn_product_aliases(jsonb_build_array(
    jsonb_build_object(
      'raw_name', 'DRL500TAB',
      'product_id', v_product2::text,
      'supplier_id', null
    )
  ));

  v_result := public.match_products(jsonb_build_array(
    jsonb_build_object('raw_name', 'DRL500TAB', 'supplier_id', v_supplier2::text)
  ));
  v_log := array_append(
    v_log,
    case when v_result->0->'candidates'->0->>'product_id' = v_product2::text
          and v_result->0->'candidates'->0->>'reason' = 'alias'
          and (v_result->0->'candidates'->0->'evidence'->>'supplier_scoped')::boolean = false
      then 'PASS' else 'FAIL' end
      || ': 5. a pharmacy-wide alias for the same text does answer it, and says so (got '
      || coalesce(v_result->0->'candidates'->0->>'reason', 'nothing') || ')'
  );

  -- --------------------------------------------------- 6. nothing else moved
  select count(*) into v_products_after
    from public.products where pharmacy_id = v_pharmacy;
  select count(*) into v_batches_after
    from public.product_batches where pharmacy_id = v_pharmacy;
  select count(*) into v_purchases_after
    from public.purchases where pharmacy_id = v_pharmacy;

  v_log := array_append(
    v_log,
    case when v_products_after = v_products_before then 'PASS' else 'FAIL' end
      || ': 6. learning creates no product (before ' || v_products_before
      || ', after ' || v_products_after || ')'
  );

  v_log := array_append(
    v_log,
    case when v_batches_after = v_batches_before then 'PASS' else 'FAIL' end
      || ': 6. learning moves no stock - no batch row appears (before ' || v_batches_before
      || ', after ' || v_batches_after || ')'
  );

  v_log := array_append(
    v_log,
    case when v_purchases_after = v_purchases_before then 'PASS' else 'FAIL' end
      || ': 6. learning writes no purchase document (before ' || v_purchases_before
      || ', after ' || v_purchases_after || ')'
  );

  execute 'reset role';

  -- --------------------------------------------- 7. the function's own contract
  select p.prosecdef, p.provolatile, p.proconfig
    into v_prosecdef, v_provolatile, v_proconfig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'learn_product_aliases';

  v_log := array_append(
    v_log,
    case when v_prosecdef then 'PASS' else 'FAIL' end
      || ': 7. learn_product_aliases is SECURITY DEFINER, so its own writes bypass RLS and must scope by hand'
  );

  v_log := array_append(
    v_log,
    case when v_provolatile = 'v' then 'PASS' else 'FAIL' end
      || ': 7. it is VOLATILE - it writes, and saying otherwise is a lie the planner may act on (got '
      || coalesce(v_provolatile::text, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1
        from unnest(coalesce(v_proconfig, array[]::text[])) c
       where c like 'search_path=%'
         and c like '%public%'
    ) then 'PASS' else 'FAIL' end
      || ': 7. search_path is pinned, not inherited from the caller (got '
      || coalesce(v_proconfig::text, 'null') || ')'
  );

  select pg_get_function_identity_arguments(p.oid) into v_identity
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'learn_product_aliases';

  v_log := array_append(
    v_log,
    case when v_identity not like '%pharmacy%' then 'PASS' else 'FAIL' end
      || ': 7. the pharmacy is not an argument - it comes from the caller (signature: '
      || coalesce(v_identity, 'missing') || ')'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('authenticated', 'public.learn_product_aliases(jsonb)', 'EXECUTE')
      then 'PASS' else 'FAIL' end
      || ': 7. authenticated may learn'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('anon', 'public.learn_product_aliases(jsonb)', 'EXECUTE')
      then 'FAIL' else 'PASS' end
      || ': 7. anon may not learn'
  );

  -- Nothing this function wrote belongs to the other tenant.
  select count(*) into v_n from public.product_aliases a where a.pharmacy_id = v_other;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 7. nothing was written for the other tenant (rows: ' || v_n || ')'
  );

  select count(*) into v_pass from unnest(v_log) l where l like 'PASS%';
  select count(*) into v_fail from unnest(v_log) l where l like 'FAIL%';
  v_log := array_append(
    v_log,
    'SUMMARY: ' || v_pass || ' PASS / ' || v_fail || ' FAIL of '
      || (array_length(v_log, 1) + 1) || ' assertions'
  );

  raise exception E'PHASE5 LEARN PRODUCT ALIASES TEST\n%', array_to_string(v_log, chr(10));
end $$;
