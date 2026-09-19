-- Phase 5 product matching - functional test for migration
-- 20260919000023_phase5_product_matching.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase5_match_products.sql
--
-- HOW TO READ THE RESULT
--   Every line is "PASS: ..." or "FAIL: ...". A non-zero exit code is expected and
--   means the script ran to completion. It ends by raising, so the whole DO block
--   (one statement, one transaction) rolls back: no ZZTEST product, alias,
--   embedding or second tenant survives.
--
-- WHY IT IMPERSONATES
--   Row level security is about the *caller's* identity, and match_products is
--   SECURITY DEFINER - which means RLS is NOT applied to its own queries. The
--   only way to prove that is to call it as `authenticated` with a JWT set, the
--   way phase4_report_summary.sql and phase5_ai_notifications.sql do, and to put a
--   second tenant's identically-named product with a *perfect* embedding in reach.
--   The fixtures themselves are written as `postgres`, which owns the tables, is
--   not subject to RLS, and is the only way to create that second tenant inside a
--   transaction.
--
-- WHAT IT PROVES
--   1.  product_embedding_text: the catalogue-text convention, at its edges.
--   2.  The alias leg - an exact hit is a certainty (score 1.0, reason 'alias') -
--       and the precedence rules around it: a supplier's own alias beats the
--       pharmacy-wide one, and an alias learned for one supplier does NOT answer
--       the same printed text on another supplier's bill.
--   3.  The trigram leg, including the `Dolo650Tab15s` case that needs the
--       reversed word_similarity, and the measured margin against its sibling
--       `Dolo 500` - which is why the vector leg has to be able to outrank it.
--   4.  The vector leg: cosine ranking, the similarity floor, and that an
--       un-embedded row simply does not participate.
--   5.  Tenant isolation against a second tenant whose product is named
--       identically and embedded identically to the query.
--   6.  What the result may not contain: the embedding column, and any row from
--       another pharmacy.
--   7.  The untrusted-input rules: a blank line keeps its place with no
--       candidates, a malformed supplier id is "no supplier", a malformed
--       embedding is "no vector leg", and neither fails the bill.
--   8.  The function's own contract: SECURITY DEFINER, STABLE (it cannot write),
--       search_path pinned, no pharmacy argument, and EXECUTE for `authenticated`
--       but not for `anon`.

do $$
declare
  v_log       text[] := array[]::text[];
  v_pharmacy  uuid;
  v_user      uuid;
  v_other     uuid := gen_random_uuid();
  v_supplier  uuid;
  v_supplier2 uuid;
  v_p650      uuid;
  v_p500      uuid;
  v_pamox     uuid;
  v_pcet      uuid;
  v_poff      uuid;
  v_portho    uuid;
  v_otherp    uuid;
  v_alias_scoped  uuid;
  v_alias_global  uuid;
  v_q         jsonb;
  v_result    jsonb;
  v_text      text;
  v_num       numeric;
  v_num2      numeric;
  v_n         int;
  v_emb_q     text;
  v_emb_amox  text;
  v_emb_cet   text;
  v_emb_ortho text;
  v_prosecdef boolean;
  v_provolatile char;
  v_proconfig  text[];
  v_identity   text;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE5 MATCH TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user
    from public.profiles
   where pharmacy_id = v_pharmacy
   order by created_at
   limit 1;
  if v_user is null then
    raise exception 'PHASE5 MATCH TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- ---------------------------------------------------------------- 1. the convention
  -- No fixtures needed: this is a pure text function.
  v_text := public.product_embedding_text('Dolo 650', 'Paracetamol', '15s');
  v_log := array_append(
    v_log,
    case when v_text = 'Dolo 650 Paracetamol 15s' then 'PASS' else 'FAIL' end
      || ': 1. the catalogue text joins name, generic name and pack (got '
      || coalesce(v_text, 'null') || ')'
  );

  v_text := public.product_embedding_text('  Dolo   650 ', null, '');
  v_log := array_append(
    v_log,
    case when v_text = 'Dolo 650' then 'PASS' else 'FAIL' end
      || ': 1. missing parts are omitted and whitespace collapses (got '
      || coalesce(v_text, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when public.product_embedding_text(null, null, null) is null
      then 'PASS' else 'FAIL' end
      || ': 1. a row with nothing to embed yields null, not an empty string'
  );

  v_log := array_append(
    v_log,
    case when public.product_embedding_text('Cetirizine 10mg', 'Cetirizine', '10s')
      = 'Cetirizine 10mg Cetirizine 10s'
      then 'PASS' else 'FAIL' end
      || ': 1. the convention is positional, not de-duplicated (name then generic then pack)'
  );

  -- ------------------------------------------------------------------- fixtures
  insert into public.pharmacies (name)
  values ('ZZTEST match other pharmacy')
  returning id into v_other;

  insert into public.suppliers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST match supplier A') returning id into v_supplier;
  insert into public.suppliers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST match supplier B') returning id into v_supplier2;

  insert into public.products (pharmacy_id, name, generic_name, pack_size)
  values (v_pharmacy, 'Dolo 650', 'Paracetamol', '15s') returning id into v_p650;
  insert into public.products (pharmacy_id, name, generic_name, pack_size)
  values (v_pharmacy, 'Dolo 500', 'Paracetamol', '15s') returning id into v_p500;
  insert into public.products (pharmacy_id, name, generic_name, pack_size)
  values (v_pharmacy, 'Amoxyclav 625', 'Amoxicillin + Clavulanic acid', '10s')
  returning id into v_pamox;
  insert into public.products (pharmacy_id, name, pack_size)
  values (v_pharmacy, 'Cetirizine 10mg', '10s') returning id into v_pcet;

  -- A deactivated product with the *exact* name the trigram leg would otherwise
  -- score 1.0: if the is_active filter is ever dropped, this one wins the query
  -- `Dolo 650` and the assertion below catches it.
  insert into public.products (pharmacy_id, name, pack_size, is_active)
  values (v_pharmacy, 'Dolo 650', '15s', false) returning id into v_poff;

  -- The other tenant's product: the same name as v_p650 and the *closest
  -- possible* embedding to the query vector, so any missing pharmacy filter
  -- promotes it to first place.
  insert into public.products (pharmacy_id, name, generic_name, pack_size)
  values (v_other, 'Dolo 650', 'Paracetamol', '15s') returning id into v_otherp;

  -- Synthetic embeddings. Cosine similarity against the query vector (a unit
  -- vector on the first axis) is therefore exact and known:
  --   v_pamox   [1, 0.05, 0, ...]  -> 0.9987   (the one the vector leg should pick)
  --   v_pcet    [1, 1, 0, ...]     -> 0.7071   (just above the 0.7 floor)
  --   v_portho  [1, 1, 1, 0, ...]  -> 0.5774   (below the floor: never a candidate)
  select '[' || array_to_string(
      array_agg(case when g = 1 then 1 else 0 end order by g), ',') || ']'
    into v_emb_q from generate_series(1, 768) g;
  select '[' || array_to_string(
      array_agg(case when g = 1 then 1.0 when g = 2 then 0.05 else 0 end order by g), ',') || ']'
    into v_emb_amox from generate_series(1, 768) g;
  select '[' || array_to_string(
      array_agg(case when g <= 2 then 1 else 0 end order by g), ',') || ']'
    into v_emb_cet from generate_series(1, 768) g;
  select '[' || array_to_string(
      array_agg(case when g <= 3 then 1 else 0 end order by g), ',') || ']'
    into v_emb_ortho from generate_series(1, 768) g;

  insert into public.products (pharmacy_id, name, pack_size)
  values (v_pharmacy, 'ZZTEST orthogonal product', '1s') returning id into v_portho;

  update public.products set embedding = v_emb_amox::extensions.vector where id = v_pamox;
  update public.products set embedding = v_emb_cet::extensions.vector where id = v_pcet;
  update public.products set embedding = v_emb_ortho::extensions.vector where id = v_portho;
  update public.products set embedding = v_emb_q::extensions.vector where id = v_otherp;

  -- The aliases under test. 'DOLO-650 TAB' is the printed text on supplier A's
  -- bills, and the pharmacy also knows the text from an unnamed source.
  insert into public.product_aliases (pharmacy_id, raw_name, normalized_name, product_id, supplier_id)
  values (
    v_pharmacy, 'DOLO-650 TAB', public.normalize_product_name('DOLO-650 TAB'), v_p650, v_supplier
  ) returning id into v_alias_scoped;

  insert into public.product_aliases (pharmacy_id, raw_name, normalized_name, product_id, supplier_id)
  values (
    v_pharmacy, 'DOLO-650 TAB', public.normalize_product_name('DOLO-650 TAB'), v_p500, null
  ) returning id into v_alias_global;

  -- Both rows exist for one printed text. They *can*, because supplier_id is
  -- nullable and Postgres treats NULLs as distinct in a unique index - which is
  -- the fact behind open item N-5: the same text written twice with no supplier
  -- is two rows rather than one update.
  v_log := array_append(
    v_log,
    case when v_alias_scoped <> v_alias_global then 'PASS' else 'FAIL' end
      || ': 2. a supplier-scoped alias and a pharmacy-wide alias for one text coexist (the N-5 fact)'
  );

  -- ------------------------------------------------------------------ as the user
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- ---------------------------------------------------------------- 2. the alias leg
  -- The alias probes use the *printed* text the alias was learned from, not the
  -- run-together form the trigram leg reads: normalize_product_name('Dolo650Tab15s')
  -- is 'dolo650tab15s' while the alias was recorded as 'dolo 650 tab', and only an
  -- exact normalized match is a certainty.
  v_q := jsonb_build_array(
    jsonb_build_object('raw_name', 'Dolo-650 Tab', 'supplier_id', v_supplier::text)
  );
  v_result := public.match_products(v_q);

  select count(*) into v_n
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_p650::text and c->>'reason' = 'alias';
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 2. an exact normalized alias for this supplier resolves the text (found '
      || v_n || ')'
  );

  v_num := (v_result->0->'candidates'->0->>'score')::numeric;
  v_log := array_append(
    v_log,
    case when v_num = 1.0 then 'PASS' else 'FAIL' end
      || ': 2. an alias hit scores as a certainty, not a similarity (got '
      || coalesce(v_num::text, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_result->0->'candidates'->0->>'product_id' = v_p650::text
          and (v_result->0->'candidates'->0->'evidence'->>'supplier_scoped')::boolean
      then 'PASS' else 'FAIL' end
      || ': 2. the supplier''s own alias outranks the pharmacy-wide one for the same text'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_p500::text and c->>'reason' = 'alias';
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 2. the pharmacy-wide alias for the same text is still offered, second (found '
      || v_n || ')'
  );

  -- The same printed text on a different supplier's bill. Supplier A's alias is
  -- not evidence about supplier B, so the pharmacy-wide alias is the best answer
  -- and the other product must not be reported as an alias hit at all.
  v_q := jsonb_build_array(
    jsonb_build_object('raw_name', 'Dolo-650 Tab', 'supplier_id', v_supplier2::text)
  );
  v_result := public.match_products(v_q);

  v_log := array_append(
    v_log,
    case when v_result->0->'candidates'->0->>'product_id' = v_p500::text
          and v_result->0->'candidates'->0->>'reason' = 'alias'
      then 'PASS' else 'FAIL' end
      || ': 2. another supplier''s bill falls back to the pharmacy-wide alias (got '
      || coalesce(v_result->0->'candidates'->0->>'reason', 'nothing') || ')'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_p650::text and c->>'reason' = 'alias';
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 2. a supplier-scoped alias does NOT answer another supplier''s identical text (found '
      || v_n || ')'
  );

  -- With no supplier at all (the reader could not name one), only the
  -- pharmacy-wide alias applies - and it still answers.
  v_q := jsonb_build_array(jsonb_build_object('raw_name', 'DOLO-650 TAB'));
  v_result := public.match_products(v_q);
  v_log := array_append(
    v_log,
    case when v_result->0->'candidates'->0->>'product_id' = v_p500::text
      then 'PASS' else 'FAIL' end
      || ': 2. an unknown supplier still resolves the pharmacy-wide alias'
  );

  -- -------------------------------------------------------------- 3. the trigram leg
  v_q := jsonb_build_array(jsonb_build_object('raw_name', 'Dolo650Tab15s'));
  v_result := public.match_products(v_q);

  select c->>'reason' into v_text
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_p650::text;
  v_log := array_append(
    v_log,
    case when v_text = 'trigram' then 'PASS' else 'FAIL' end
      || ': 3. Dolo650Tab15s is read as an unspaced catalogue name (reason ' ||
      coalesce(v_text, 'nothing') || ')'
  );

  v_num := (select (c->'evidence'->>'similarity')::numeric
              from jsonb_array_elements(v_result->0->'candidates') c
             where c->>'product_id' = v_p650::text);
  v_num2 := (select (c->'evidence'->>'similarity')::numeric
               from jsonb_array_elements(v_result->0->'candidates') c
              where c->>'product_id' = v_p500::text);
  v_log := array_append(
    v_log,
    case when v_num >= 0.35 then 'PASS' else 'FAIL' end
      || ': 3. the trigram score clears the 0.35 threshold (Dolo 650 measured '
      || coalesce(v_num::text, 'absent') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_num > v_num2 then 'PASS' else 'FAIL' end
      || ': 3. the right sibling is ranked above the wrong one by trigram alone, '
      || 'but only just (Dolo 650 ' || coalesce(v_num::text, 'absent') || ' vs Dolo 500 '
      || coalesce(v_num2::text, 'absent') || ' - this thin margin is why the vector leg exists)'
  );

  v_q := jsonb_build_array(jsonb_build_object('raw_name', 'ZZQQ nonsense 9999'));
  v_result := public.match_products(v_q);
  v_n := jsonb_array_length(v_result->0->'candidates');
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 3. text that resembles nothing yields no candidates at all (found ' || v_n || ')'
  );

  -- The deactivated namesake: exact name match, and it must still not be offered.
  v_q := jsonb_build_array(jsonb_build_object('raw_name', 'Dolo 650'));
  v_result := public.match_products(v_q);
  select count(*) into v_n
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_poff::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 3. a deactivated product is never suggested, even on an exact name match (found '
      || v_n || ')'
  );
  select count(*) into v_n
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_p650::text;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 3. the active namesake is offered for the same text (found ' || v_n || ')'
  );

  -- --------------------------------------------------------------- 4. the vector leg
  -- An abbreviation no trigram can read, answered only by the embedding.
  v_q := jsonb_build_array(
    jsonb_build_object('raw_name', 'DX-9900', 'query_embedding', v_emb_q::jsonb)
  );
  v_result := public.match_products(v_q);

  v_log := array_append(
    v_log,
    case when v_result->0->'candidates'->0->>'product_id' = v_pamox::text
          and v_result->0->'candidates'->0->>'reason' = 'vector'
      then 'PASS' else 'FAIL' end
      || ': 4. an abbreviation trigram cannot read is found by the vector leg (top reason '
      || coalesce(v_result->0->'candidates'->0->>'reason', 'nothing') || ')'
  );

  v_num := (v_result->0->'candidates'->0->>'score')::numeric;
  v_log := array_append(
    v_log,
    case when v_num > 0.99 then 'PASS' else 'FAIL' end
      || ': 4. the nearest vector ranks first at its cosine similarity (got '
      || coalesce(v_num::text, 'null') || ')'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_pcet::text and c->>'reason' = 'vector';
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 4. a candidate just above the 0.7 floor is offered behind it (found ' || v_n || ')'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_portho::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 4. a vector below the 0.7 floor is not a suggestion at all (found ' || v_n || ')'
  );

  -- ---------------------------------------------------- 5. isolation and payload
  select count(*) into v_n
    from jsonb_array_elements(v_result->0->'candidates') c
   where c->>'product_id' = v_otherp::text;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 5. another pharmacy''s identically named, identically embedded product is invisible (found '
      || v_n || ')'
  );

  v_log := array_append(
    v_log,
    case when jsonb_path_exists(v_result, '$.**.embedding') then 'FAIL' else 'PASS' end
      || ': 5. no candidate carries the embedding column (D-027)'
  );

  select count(*) into v_n
    from jsonb_object_keys(v_result->0->'candidates'->0) k
   where k in ('product_id', 'name', 'generic_name', 'pack_size', 'is_active',
               'score', 'reason', 'evidence');
  v_log := array_append(
    v_log,
    case when v_n = 8 then 'PASS' else 'FAIL' end
      || ': 5. a candidate carries exactly the eight named fields (found ' || v_n || ')'
  );

  -- ------------------------------------------------------- 6. untrusted input
  v_q := jsonb_build_array(
    jsonb_build_object('raw_name', '   '),
    jsonb_build_object('raw_name', 'Dolo650Tab15s', 'supplier_id', 'not-a-uuid'),
    jsonb_build_object('raw_name', 'Dolo650Tab15s', 'query_embedding', 'not-an-array'),
    jsonb_build_object(
      'raw_name', 'Dolo650Tab15s',
      'query_embedding', (select jsonb_agg(0.5) from generate_series(1, 769))
    )
  );
  v_result := public.match_products(v_q);

  v_log := array_append(
    v_log,
    case when jsonb_array_length(v_result) = 4 then 'PASS' else 'FAIL' end
      || ': 6. a blank line keeps its place rather than disappearing (entries '
      || jsonb_array_length(v_result) || ')'
  );

  v_log := array_append(
    v_log,
    case when jsonb_array_length(v_result->0->'candidates') = 0
      then 'PASS' else 'FAIL' end
      || ': 6. a blank line yields no candidates rather than an error'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result) e
    cross join lateral jsonb_array_elements(e->'candidates') c
   where c->>'reason' = 'vector';
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 6. a malformed embedding is read as "no vector leg", not as an error (vector hits '
      || v_n || ')'
  );

  select count(*) into v_n
    from jsonb_array_elements(v_result->1->'candidates') c
   where c->>'product_id' = v_p650::text;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 6. a malformed supplier id is read as "no supplier" and still matches (found '
      || v_n || ')'
  );

  -- Order is part of the contract: the caller lines the answer up with the bill.
  v_q := jsonb_build_array(
    jsonb_build_object('raw_name', 'Dolo650Tab15s'),
    jsonb_build_object('raw_name', 'AMOXYCLAV 625 10S')
  );
  v_result := public.match_products(v_q);
  v_log := array_append(
    v_log,
    case when v_result->0->>'raw_name' = 'Dolo650Tab15s'
          and v_result->1->>'raw_name' = 'AMOXYCLAV 625 10S'
          and v_result->1->'candidates'->0->>'product_id' = v_pamox::text
      then 'PASS' else 'FAIL' end
      || ': 6. the answer keeps the order it was asked in, and a plain name matches its product'
  );

  -- ------------------------------------------------------------ 7. the limit
  v_q := jsonb_build_array(jsonb_build_object('raw_name', 'Dolo650Tab15s'));
  v_n := jsonb_array_length(public.match_products(v_q, 1)->0->'candidates');
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 7. p_limit bounds the candidate list (1 asked, ' || v_n || ' returned)'
  );

  v_n := jsonb_array_length(public.match_products(v_q, 0)->0->'candidates');
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 7. a nonsensical p_limit is clamped rather than obeyed (0 asked, '
      || v_n || ' returned)'
  );

  v_result := public.match_products('[]'::jsonb);
  v_log := array_append(
    v_log,
    case when v_result = '[]'::jsonb then 'PASS' else 'FAIL' end
      || ': 7. an empty query list answers with an empty list'
  );

  select jsonb_array_length(public.match_products('"not an array"'::jsonb)) into v_n;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 7. a non-array argument answers with an empty list rather than raising ('
      || v_n || ')'
  );

  v_n := jsonb_array_length(public.match_products(v_q)->0->'candidates');
  v_log := array_append(
    v_log,
    case when v_n > 1 then 'PASS' else 'FAIL' end
      || ': 7. the default limit offers more than one candidate for an ambiguous text ('
      || v_n || ')'
  );

  execute 'reset role';

  -- ------------------------------------------------- 8. the function's own contract
  select p.prosecdef, p.provolatile, p.proconfig
    into v_prosecdef, v_provolatile, v_proconfig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'match_products';

  v_log := array_append(
    v_log,
    case when v_prosecdef then 'PASS' else 'FAIL' end
      || ': 8. match_products is SECURITY DEFINER, so its own queries bypass RLS and must scope by hand'
  );

  v_log := array_append(
    v_log,
    case when v_provolatile = 's' then 'PASS' else 'FAIL' end
      || ': 8. match_products is STABLE - a matcher cannot move stock (got '
      || coalesce(v_provolatile::text, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1
        from unnest(coalesce(v_proconfig, array[]::text[])) c
       where c like 'search_path=%'
         and c like '%public%'
         and c like '%extensions%'
    ) then 'PASS' else 'FAIL' end
      || ': 8. search_path is pinned (public + extensions, for the vector operators), '
      || 'not inherited from the caller (got ' || coalesce(v_proconfig::text, 'null') || ')'
  );

  select pg_get_function_identity_arguments(p.oid) into v_identity
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'match_products';
  v_log := array_append(
    v_log,
    case when v_identity not like '%pharmacy%' then 'PASS' else 'FAIL' end
      || ': 8. the pharmacy is not an argument - it comes from the caller (signature: '
      || coalesce(v_identity, 'missing') || ')'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('authenticated', 'public.match_products(jsonb,int)', 'EXECUTE')
      then 'PASS' else 'FAIL' end
      || ': 8. authenticated may execute the match'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('anon', 'public.match_products(jsonb,int)', 'EXECUTE')
      then 'FAIL' else 'PASS' end
      || ': 8. anon may not execute the match'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('authenticated', 'public.product_embedding_text(text,text,text)', 'EXECUTE')
      then 'PASS' else 'FAIL' end
      || ': 8. authenticated may call the convention function'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('anon', 'public.product_embedding_text(text,text,text)', 'EXECUTE')
      then 'FAIL' else 'PASS' end
      || ': 8. anon may not call the convention function'
  );

  raise exception E'PHASE5 MATCH PRODUCTS TEST\n%', array_to_string(v_log, chr(10));
end $$;
