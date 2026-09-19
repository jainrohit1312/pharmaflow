-- Phase 5 embedding backfill - functional test for migration
-- 20260919000025_phase5_embedding_backfill.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase5_embedding_backfill.sql
--
-- HOW TO READ THE RESULT
--   Every line is "PASS: ..." or "FAIL: ...", and the last line is
--   "SUMMARY: n PASS / n FAIL". A non-zero exit code is expected and means the
--   script ran to completion: it ends by raising, so the whole DO block (one
--   statement, one transaction) rolls back and no ZZTEST pharmacy, supplier,
--   product or embedding survives.
--
-- WHY IT IMPERSONATES
--   Both functions are SECURITY DEFINER, so RLS is NOT applied to their own
--   statements - the only way to prove they scope by hand is to call them as
--   `authenticated` with a JWT set, the way phase4_report_summary.sql and
--   phase5_match_products.sql do, and to put a second tenant's product in reach.
--   The fixtures themselves are written as `postgres`, which owns the tables and
--   is not subject to RLS.
--
-- WHAT IT PROVES
--   1.  The read: only this pharmacy's un-embedded rows, the text built by
--       product_embedding_text() (D-037), the limit honoured *after* the
--       un-embeddable rows are filtered out rather than handing back a short
--       batch, and a row with nothing to embed counted separately.
--   2.  The write: 768 numbers land as a vector; a wrong width, a value that is
--       not a uuid, a non-object entry and another tenant's product are all
--       skipped with a reason instead of raising.
--   3.  Tenant isolation both ways: another tenant's product cannot be written
--       through this function, and its row is untouched afterwards.
--   4.  **Resumability**: after a write the rows are no longer offered and
--       `remaining` has dropped by exactly what was written - `NULL` is the
--       marker, so a second run continues.
--   5.  **The chain works**: a vector this pair wrote makes the *vector leg of a
--       real `match_products` call* fire, with no model involved anywhere.
--   6.  Nothing else moves: no product, no batch, no purchase row appears.
--   7.  Both functions' own contract: SECURITY DEFINER, the read STABLE and the
--       write VOLATILE, search_path pinned, no pharmacy argument, EXECUTE for
--       `authenticated` and not for `anon`.

do $$
declare
  v_log        text[] := array[]::text[];
  v_pass       int;
  v_fail       int;
  v_pharmacy   uuid;
  v_user       uuid;
  v_other      uuid;
  v_p_embed    uuid;
  v_p_plain    uuid;
  v_p_notext   uuid;
  v_p_other    uuid;
  v_result     jsonb;
  v_again      jsonb;
  v_items      jsonb;
  v_n          int;
  v_remaining_before bigint;
  v_remaining_after  bigint;
  v_emb        text;
  v_emb_close  text;
  v_emb_far    text;
  v_query      text;
  v_similarity numeric;
  v_products_before int;
  v_products_after  int;
  v_batches_before  int;
  v_batches_after   int;
  v_purchases_before int;
  v_purchases_after  int;
  v_prosecdef  boolean;
  v_provolatile char;
  v_proconfig  text[];
  v_identity   text;
begin
  -- The vectors below are cast and compared with pgvector's types and operators,
  -- which live in `extensions`. The platform's own connection usually has it in
  -- the path; this makes the test independent of how it was launched.
  perform set_config('search_path', 'public, extensions', true);

  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE5 BACKFILL TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user
    from public.profiles
   where pharmacy_id = v_pharmacy
   order by created_at
   limit 1;
  if v_user is null then
    raise exception 'PHASE5 BACKFILL TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------- fixtures
  insert into public.pharmacies (name)
  values ('ZZTEST backfill other pharmacy')
  returning id into v_other;

  insert into public.products (pharmacy_id, name, generic_name, pack_size)
  values (v_pharmacy, 'ZZTEST Backfill 500', 'Paracetamol', '10s')
  returning id into v_p_embed;
  insert into public.products (pharmacy_id, name, generic_name, pack_size)
  values (v_pharmacy, 'ZZTEST Backfill 650', 'Paracetamol', '10s')
  returning id into v_p_plain;
  -- A product with nothing to embed: no name, no generic name, no pack size. It
  -- must never be offered, or the operator's loop would spin on it for ever.
  insert into public.products (pharmacy_id, name)
  values (v_pharmacy, ' ')
  returning id into v_p_notext;
  insert into public.products (pharmacy_id, name, pack_size)
  values (v_other, 'ZZTEST Backfill 500', '10s')
  returning id into v_p_other;

  -- Synthetic vectors, the same trick phase5_match_products.sql uses: cosine
  -- against a unit query vector on the first axis is then exact and known.
  --   v_emb_close  [1, 0.2, 0, …]  -> 0.9806  (a real match)
  --   v_emb_far    [0, 1, 0, …]    -> 0.0     (nothing like it)
  select '[' || array_to_string(
      array_agg(case when g = 1 then 1.0 when g = 2 then 0.2 else 0 end order by g), ',') || ']'
    into v_emb_close from generate_series(1, 768) g;
  select '[' || array_to_string(
      array_agg(case when g = 2 then 1 else 0 end order by g), ',') || ']'
    into v_emb_far from generate_series(1, 768) g;
  select '[' || array_to_string(
      array_agg(case when g = 1 then 1 else 0 end order by g), ',') || ']'
    into v_query from generate_series(1, 768) g;

  -- ------------------------------------------------------------------ as the user
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  select count(*) into v_products_before from public.products where pharmacy_id = v_pharmacy;
  select count(*) into v_batches_before from public.product_batches where pharmacy_id = v_pharmacy;
  select count(*) into v_purchases_before from public.purchases where pharmacy_id = v_pharmacy;

  -- ---------------------------------------------------------------- 1. the read
  -- The pharmacy under test may hold hundreds of rows that are also un-embedded
  -- (that is what a not-yet-backfilled catalogue looks like), so every assertion
  -- here is either about a ZZTEST row by id or about a *relative* number.
  v_result := public.products_to_embed(100);

  v_log := array_append(
    v_log,
    case when v_result ? 'items' and v_result ? 'remaining' and v_result ? 'unembeddable'
      then 'PASS' else 'FAIL' end
      || ': 1. the read answers with the batch, what is left, and what can never be done'
  );

  v_log := array_append(
    v_log,
    case when (v_result->>'unembeddable')::int >= 1 then 'PASS' else 'FAIL' end
      || ': 1. the product with nothing to embed is counted apart, not offered (got '
      || coalesce(v_result->>'unembeddable', 'null') || ')'
  );

  v_remaining_before := (v_result->>'remaining')::bigint;
  v_log := array_append(
    v_log,
    case when v_remaining_before >= 2 then 'PASS' else 'FAIL' end
      || ': 1. the two fixtures are in the work list (remaining '
      || v_remaining_before || ')'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->'items') item
   where item->>'product_id' = v_p_notext::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 1. it is not in the batch either (found ' || v_n || ')'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->'items') item
   where item->>'product_id' = v_p_other::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 1. another tenant''s un-embedded product is not offered to us (found ' || v_n || ')'
  );

  select item->>'text' into v_emb
    from jsonb_array_elements(v_result->'items') item
   where item->>'product_id' = v_p_embed::text;
  v_log := array_append(
    v_log,
    case when v_emb = public.product_embedding_text('ZZTEST Backfill 500', 'Paracetamol', '10s')
      then 'PASS' else 'FAIL' end
      || ': 1. the text is the convention''s, not something the caller composed (got '
      || coalesce(v_emb, 'null') || ')'
  );

  -- The limit is honoured after the un-embeddable rows are dropped, so a batch of
  -- one is one *embeddable* row and the loop never comes back short for no reason.
  v_result := public.products_to_embed(1);
  v_again := public.products_to_embed(1);
  v_log := array_append(
    v_log,
    case when jsonb_array_length(v_result->'items') = 1
      then 'PASS' else 'FAIL' end
      || ': 1. a limit of one is one embeddable row (got '
      || jsonb_array_length(v_result->'items') || ')'
  );

  v_items := v_result->'items';
  v_log := array_append(
    v_log,
    case when (v_items->0->>'product_id') = (v_again->'items'->0->>'product_id')
      then 'PASS' else 'FAIL' end
      || ': 1. and the same row twice, so a resumed run is deterministic rather than arbitrary'
  );

  -- --------------------------------------------------------------- 2. the write
  -- The wrong width first: 3 numbers instead of 768.
  v_result := public.set_product_embeddings(jsonb_build_array(
    jsonb_build_object('product_id', v_p_embed::text, 'embedding', '[1,2,3]'::jsonb)
  ));
  v_log := array_append(
    v_log,
    case when (v_result->>'written')::int = 0
          and jsonb_array_length(v_result->'skipped') = 1
      then 'PASS' else 'FAIL' end
      || ': 2. an embedding of the wrong width is skipped, not stored (written '
      || coalesce(v_result->>'written', 'null') || ')'
  );

  select count(*) into v_n
    from public.products p
   where p.id = v_p_embed and p.embedding is null;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 2. and the row is untouched, so it stays in the work list'
  );

  v_result := public.set_product_embeddings(jsonb_build_array(
    jsonb_build_object('product_id', 'zzqq-not-a-uuid', 'embedding', v_emb_close::jsonb),
    to_jsonb('not an item'::text),
    jsonb_build_object('product_id', v_p_other::text, 'embedding', v_emb_close::jsonb)
  ));
  v_log := array_append(
    v_log,
    case when (v_result->>'written')::int = 0
          and jsonb_array_length(v_result->'skipped') = 3
      then 'PASS' else 'FAIL' end
      || ': 2. a malformed id, a non-item and a foreign product are all skipped with a reason (got '
      || jsonb_array_length(v_result->'skipped') || ' of 3)'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->'skipped') skip
   where skip->>'reason' = 'that product is not in this catalogue';
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 2. the foreign product is refused as such (found ' || v_n || ')'
  );

  -- The real write.
  v_result := public.set_product_embeddings(jsonb_build_array(
    jsonb_build_object('product_id', v_p_embed::text, 'embedding', v_emb_close::jsonb),
    jsonb_build_object('product_id', v_p_plain::text, 'embedding', v_emb_far::jsonb)
  ));

  v_log := array_append(
    v_log,
    case when (v_result->>'written')::int = 2
          and jsonb_array_length(v_result->'skipped') = 0
      then 'PASS' else 'FAIL' end
      || ': 2. a well-formed batch is written whole (written '
      || coalesce(v_result->>'written', 'null') || ')'
  );

  v_remaining_after := (v_result->>'remaining')::bigint;
  v_log := array_append(
    v_log,
    case when v_remaining_after = v_remaining_before - 2 then 'PASS' else 'FAIL' end
      || ': 4. and the work list shrank by exactly what was written ('
      || v_remaining_before || ' -> ' || v_remaining_after || ')'
  );

  select extensions.vector_dims(p.embedding) into v_n
    from public.products p where p.id = v_p_embed;
  v_log := array_append(
    v_log,
    case when v_n = 768 then 'PASS' else 'FAIL' end
      || ': 2. the column holds a 768-dimension vector (got ' || coalesce(v_n::text, 'null') || ')'
  );

  select round((1 - (p.embedding <=> v_query::extensions.vector))::numeric, 4)
    into v_similarity
    from public.products p
   where p.id = v_p_embed;
  v_log := array_append(
    v_log,
    case when v_similarity = 0.9806 then 'PASS' else 'FAIL' end
      || ': 2. and it is the value that was sent, not a neighbour (cosine '
      || coalesce(v_similarity::text, 'null') || ')'
  );

  -- --------------------------------------------------------- 4. it resumes
  v_result := public.products_to_embed(100);
  select count(*) into v_n
    from jsonb_array_elements(v_result->'items') item
   where item->>'product_id' in (v_p_embed::text, v_p_plain::text);
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 4. a second run does not offer what is already embedded (found ' || v_n || ')'
  );

  -- ------------------------------------ 5. the vector leg fires on what this pair wrote
  -- Nothing here calls the model: the query embedding is synthetic, and the point
  -- is that the whole chain composes - a vector written by `set_product_embeddings`
  -- is a candidate the matcher's vector leg can find.
  v_result := public.match_products(jsonb_build_array(
    jsonb_build_object(
      -- C1's own junk string, measured at 0.000 trigram similarity: whatever comes
      -- back is the vector leg's work, and nothing else.
      'raw_name', 'ZZQQ nonsense 9999',
      'query_embedding', v_query::jsonb
    )
  ));

  select count(*) into v_n
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_p_embed::text and c->>'reason' = 'vector';
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 5. the match''s vector leg finds the row this pair embedded (found ' || v_n || ')'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_p_plain::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 5. and not the row whose vector points elsewhere (found ' || v_n || ')'
  );

  -- The payload still carries no embedding: the vector is compared, never sent
  -- (D-027).
  v_log := array_append(
    v_log,
    case when v_result::text not like '%embedding%' then 'PASS' else 'FAIL' end
      || ': 5. and the match payload still carries no embedding column'
  );

  -- ----------------------------------------------------- 6. nothing else moved
  select count(*) into v_products_after from public.products where pharmacy_id = v_pharmacy;
  select count(*) into v_batches_after from public.product_batches where pharmacy_id = v_pharmacy;
  select count(*) into v_purchases_after from public.purchases where pharmacy_id = v_pharmacy;

  v_log := array_append(
    v_log,
    case when v_products_after = v_products_before then 'PASS' else 'FAIL' end
      || ': 6. the backfill creates no product (before ' || v_products_before
      || ', after ' || v_products_after || ')'
  );

  v_log := array_append(
    v_log,
    case when v_batches_after = v_batches_before then 'PASS' else 'FAIL' end
      || ': 6. the backfill moves no stock - no batch row appears (before '
      || v_batches_before || ', after ' || v_batches_after || ')'
  );

  v_log := array_append(
    v_log,
    case when v_purchases_after = v_purchases_before then 'PASS' else 'FAIL' end
      || ': 6. the backfill writes no purchase document (before ' || v_purchases_before
      || ', after ' || v_purchases_after || ')'
  );

  execute 'reset role';

  -- ------------------------------------------------- 3. tenant isolation, as postgres
  -- Read after dropping the impersonation on purpose: RLS hides the other tenant's
  -- row from `authenticated`, so the only way to prove it was left alone is to look
  -- as the owner - which is also the point, because the function writes without RLS
  -- and has to scope by hand.
  select count(*) into v_n
    from public.products p
   where p.id = v_p_other and p.embedding is null;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 3. another tenant''s row is still un-embedded after we aimed at it (rows with NULL: '
      || v_n || ')'
  );

  -- --------------------------------------------- 7. both functions' own contract
  select p.prosecdef, p.provolatile, p.proconfig
    into v_prosecdef, v_provolatile, v_proconfig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'products_to_embed';

  v_log := array_append(
    v_log,
    case when v_prosecdef then 'PASS' else 'FAIL' end
      || ': 7. products_to_embed is SECURITY DEFINER, so it scopes by hand'
  );

  v_log := array_append(
    v_log,
    case when v_provolatile = 's' then 'PASS' else 'FAIL' end
      || ': 7. the read is STABLE - it cannot write (got '
      || coalesce(v_provolatile::text, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1 from unnest(coalesce(v_proconfig, array[]::text[])) c
       where c like 'search_path=%' and c like '%public%'
    ) then 'PASS' else 'FAIL' end
      || ': 7. its search_path is pinned (got ' || coalesce(v_proconfig::text, 'null') || ')'
  );

  select p.prosecdef, p.provolatile, p.proconfig
    into v_prosecdef, v_provolatile, v_proconfig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'set_product_embeddings';

  v_log := array_append(
    v_log,
    case when v_prosecdef then 'PASS' else 'FAIL' end
      || ': 7. set_product_embeddings is SECURITY DEFINER, so it scopes by hand'
  );

  v_log := array_append(
    v_log,
    case when v_provolatile = 'v' then 'PASS' else 'FAIL' end
      || ': 7. the write is VOLATILE (got ' || coalesce(v_provolatile::text, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1 from unnest(coalesce(v_proconfig, array[]::text[])) c
       where c like 'search_path=%' and c like '%public%'
    ) then 'PASS' else 'FAIL' end
      || ': 7. and its search_path is pinned too (got ' || coalesce(v_proconfig::text, 'null') || ')'
  );

  select pg_get_function_identity_arguments(p.oid) into v_identity
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'products_to_embed';
  v_log := array_append(
    v_log,
    case when v_identity not like '%pharmacy%' then 'PASS' else 'FAIL' end
      || ': 7. the read takes no pharmacy - it comes from the caller (' || coalesce(v_identity, 'missing') || ')'
  );

  select pg_get_function_identity_arguments(p.oid) into v_identity
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'set_product_embeddings';
  v_log := array_append(
    v_log,
    case when v_identity not like '%pharmacy%' then 'PASS' else 'FAIL' end
      || ': 7. nor does the write (' || coalesce(v_identity, 'missing') || ')'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('authenticated', 'public.products_to_embed(int)', 'EXECUTE')
          and has_function_privilege('authenticated', 'public.set_product_embeddings(jsonb)', 'EXECUTE')
      then 'PASS' else 'FAIL' end
      || ': 7. authenticated may read the work list and write embeddings'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('anon', 'public.products_to_embed(int)', 'EXECUTE')
          or has_function_privilege('anon', 'public.set_product_embeddings(jsonb)', 'EXECUTE')
      then 'FAIL' else 'PASS' end
      || ': 7. anon may do neither'
  );

  select count(*) into v_pass from unnest(v_log) l where l like 'PASS%';
  select count(*) into v_fail from unnest(v_log) l where l like 'FAIL%';
  v_log := array_append(
    v_log,
    'SUMMARY: ' || v_pass || ' PASS / ' || v_fail || ' FAIL of '
      || (array_length(v_log, 1) + 1) || ' assertions'
  );

  raise exception E'PHASE5 EMBEDDING BACKFILL TEST\n%', array_to_string(v_log, chr(10));
end $$;
