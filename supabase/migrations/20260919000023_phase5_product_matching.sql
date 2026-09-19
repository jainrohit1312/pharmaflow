-- Migration: 20260919000023_phase5_product_matching | Purpose: the smart product
-- match - a supplier bill's invoice text resolved against the pharmacy's own
-- catalogue, ranked server-side.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace function + guarded grants.
--
-- What this migration is
-- ----------------------
-- Two functions and their grants. Nothing else: no table, no column, no trigger,
-- and nothing that moves stock (a matched line is still a line the human saves,
-- and stock still moves only through the goods receipt - D-011/D-013).
--
--   product_embedding_text(...)  the catalogue-text convention, in one place
--   match_products(...)          the ranking, as one round trip for a whole bill
--
-- Why an RPC and not PostgREST queries
-- ------------------------------------
-- The same reason report_summary() is one (D-025): PostgREST cannot express
-- `greatest(similarity(...))`, cannot order by a vector distance operator, and
-- cannot union three candidate sets with a per-product preference between them.
-- Every one of those would otherwise become "fetch a page of rows and rank them
-- in Dart", which is bounded by max_rows (1000) - so a catalogue past that bound
-- would silently rank only part of itself, and a matcher that quietly stops
-- seeing products is worse than one that is slow.
--
-- One call per bill rather than one per line: a twenty-line bill is one round
-- trip, and the three legs are evaluated against the same catalogue snapshot, so
-- two lines of one invoice cannot be ranked against two different catalogues.
--
-- The pharmacy is never an argument (D-004/D-026). It comes from
-- get_my_pharmacy_id() inside the function, so a crafted parameter cannot read
-- another tenant's catalogue - and because a SECURITY DEFINER function runs as
-- its owner, RLS is NOT applied to its queries, which is exactly why every query
-- below carries `pharmacy_id = v_pharmacy` explicitly. Dropping that filter would
-- not be a missing defence in depth; it would be a cross-tenant read.
--
-- The three legs, and why they are ranked the way they are
-- -------------------------------------------------------
--   1. ALIAS    an exact hit on normalize_product_name(raw_name) in
--               product_aliases. A human confirmed this text means this product,
--               so it is a certainty rather than a similarity, and it scores 1.0.
--   2. TRIGRAM  pg_trgm similarity, which is what reads `Dolo650Tab15s` as
--               `Dolo 650`. The score is the best of three comparisons, and the
--               third is not optional - measured on this database, the obvious
--               `similarity(name, raw_name)` scores 0.278 for exactly that pair
--               (below pg_trgm's own 0.3 default), while the reversed
--               `word_similarity(name, raw_name)` scores 0.455. The threshold is
--               therefore 0.35 and not the default.
--   3. VECTOR   cosine distance over products.embedding (D-027). This is the leg
--               that separates sibling SKUs: `Dolo650Tab15s` scores about the
--               same by trigram against `Dolo 650` and against `Dolo 500`, so
--               trigram alone cannot choose between them. It only answers when
--               the caller supplies a query embedding, and only for rows whose
--               embedding the backfill has already written (NULL marks un-embedded
--               rows, D-027), so its absence is normal and never an error.
--
-- Ranking is by SCORE, and the leg is attribution
-- -----------------------------------------------
-- A candidate's score is its best score across the legs and `reason` says which
-- leg produced it. The leg is only a TIEBREAK, and it is an ordered tiebreak -
-- 0 supplier-scoped alias, 1 pharmacy-wide alias, 2 trigram, 3 vector - so at
-- equal scores the certainty wins over the estimate, and a supplier's own alias
-- wins over the pharmacy-wide one. Ranked by the leg instead of the score, a
-- 0.45 trigram hit would always outrank a 0.95 vector hit, which is precisely
-- the case the vector leg exists for: the wrong sibling of a product is usually a
-- strong trigram hit too (measured here, `Dolo 650` scores 0.4545 against
-- `Dolo650Tab15s` and `Dolo 500` scores 0.4444 - a 0.01 margin, which is a coin
-- toss rather than a ranking). The alias's 1.0 keeps it ahead of everything,
-- which is the point of it.
--
-- Cost, stated rather than hidden: the trigram leg evaluates similarity per row
-- in the caller's catalogue, so its filter threshold cannot be the `%` operator's
-- and the products_name_trgm_idx/products_generic_name_trgm_idx GIN indexes do
-- not serve it. For a catalogue of a few thousand SKUs that is milliseconds; a
-- catalogue where it is not is a catalogue that wants a materialised search
-- column, which is a later decision, not a silent one.
--
-- Verified by supabase/tests/phase5_match_products.sql (atomic,
-- self-rolling-back, asserting the three legs, the precedence rules, tenant
-- isolation and what the result may not contain).

-- ---------------------------------------------------------------------------
-- 1. The catalogue-text convention
--
--    The embedding input text is a decision (D-027 names it as Chunk C's), and it
--    has to be ONE decision: the backfill embeds catalogue rows with this text,
--    and anything that ever re-embeds a row has to produce the same string, or
--    the two vectors are not comparable and the symptom is a matcher that ranks
--    at random. So it lives here, in the database, rather than in the Edge
--    Function that will call it - a convention two codebases agree on by
--    convention is a convention that drifts.
--
--    Shape: name, then generic name, then pack size, whitespace collapsed, empty
--    parts omitted, NULL for a row with nothing to embed. All three, because the
--    invoice text carries all three (`Dolo 650 Tab 15s`) and a vector built from
--    the bare name would be blind to the strength and the pack.
--
--    The QUERY side is deliberately not built by this function: the query text is
--    the invoice text as printed, which is the whole reason the vector leg copes
--    with a supplier's own abbreviations. This function is the catalogue side.
-- ---------------------------------------------------------------------------
create or replace function public.product_embedding_text(
  p_name text,
  p_generic_name text default null,
  p_pack_size text default null
)
returns text
language sql
immutable
as $$
  select nullif(
    regexp_replace(
      trim(
        both ' ' from
        concat_ws(
          ' ',
          nullif(trim(both ' ' from coalesce(p_name, '')), ''),
          nullif(trim(both ' ' from coalesce(p_generic_name, '')), ''),
          nullif(trim(both ' ' from coalesce(p_pack_size, '')), '')
        )
      ),
      '[[:space:]]+',
      ' ',
      'g'
    ),
    ''
  );
$$;

comment on function public.product_embedding_text(text, text, text) is
  'The one catalogue-text convention behind products.embedding (D-027): name, generic name and pack size, whitespace collapsed, empty parts omitted. The backfill embeds what this returns; the query side of the match embeds the invoice text as printed.';

-- ---------------------------------------------------------------------------
-- 2. The match
--
--    p_queries: a JSON array of
--      { "raw_name": "<invoice text>",
--        "supplier_id": "<uuid>" | null,
--        "query_embedding": [ <768 numbers> ] | null }
--    Returns a JSON array of { raw_name, candidates } in the order it was asked,
--    so a caller can line the answer up with the bill it sent - including for a
--    line that produced no candidates, which keeps its own empty entry rather
--    than disappearing.
--
--    Every parameter is treated as untrusted: a malformed supplier id is read as
--    "no supplier" and a malformed embedding as "no vector leg", because the one
--    thing a matcher may never do is fail a whole bill over one bad line.
-- ---------------------------------------------------------------------------
create or replace function public.match_products(
  p_queries jsonb,
  p_limit int default 5
)
returns jsonb
language plpgsql
stable
security definer
-- Pinned, not inherited: a SECURITY DEFINER function that resolves names through
-- whatever search_path the caller happened to have is a way to run someone else's
-- code as the owner. `extensions` is in the list because pgvector's distance
-- operators live there - a type can be written `extensions.vector`, an operator
-- cannot be qualified except through search_path - and it is the same pair the
-- platform itself uses (`extra_search_path = ["public", "extensions"]`). Nothing
-- an untrusted role can write to is added: `extensions` holds extension objects
-- and is owned by postgres.
set search_path = public, extensions
as $$
declare
  -- How similar the text has to look before trigram calls it a candidate.
  -- Measured, not copied: 0.35 keeps `Dolo650Tab15s` -> `Dolo 650` (0.455) and
  -- `AMOXYCLAV 625 10S` -> `Amoxyclav 625` (0.778) while refusing junk (0.000).
  -- pg_trgm's own 0.3 default would drop the first pair, which is the case this
  -- leg exists for.
  c_trigram_threshold constant real := 0.35;

  -- How close a vector has to be before it is a suggestion at all. PROVISIONAL:
  -- with no catalogue embedded yet (the backfill is the next chunk) this is a
  -- considered guess, not a measurement - text embeddings put unrelated short
  -- strings around 0.6-0.75 cosine and related ones above 0.85. Re-tune it
  -- against the live catalogue in the backfill chunk, and keep it high: a
  -- plausible-looking wrong suggestion teaches the user to ignore suggestions.
  c_vector_min_similarity constant real := 0.7;

  v_pharmacy   uuid := public.get_my_pharmacy_id();
  v_limit      int := least(greatest(coalesce(p_limit, 5), 1), 20);
  v_matches    jsonb := '[]'::jsonb;
  v_query      jsonb;
  v_candidates jsonb;
  v_raw        text;
  v_normalized text;
  v_supplier   uuid;
  v_query_vec  extensions.vector;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  if p_queries is null or jsonb_typeof(p_queries) <> 'array' then
    return '[]'::jsonb;
  end if;

  for v_query in select value from jsonb_array_elements(p_queries)
  loop
    if jsonb_typeof(v_query) <> 'object' then
      v_matches := v_matches || jsonb_build_object(
        'raw_name', null, 'candidates', '[]'::jsonb
      );
      continue;
    end if;

    v_raw := nullif(trim(both ' ' from coalesce(v_query->>'raw_name', '')), '');
    v_normalized := public.normalize_product_name(v_raw);

    -- A supplier id that is not a uuid is "no supplier", not an error: the
    -- caller may hold text from an invoice whose supplier the reader could not
    -- identify, and that is a normal bill rather than a malformed request.
    v_supplier := case
      when coalesce(v_query->>'supplier_id', '') ~*
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (v_query->>'supplier_id')::uuid
      else null
    end;

    -- A query embedding of the wrong width is "no vector leg" for the same
    -- reason. The nested CASE is deliberate: `jsonb_array_length` raises on a
    -- value that is not an array, and a flat AND would let the planner reach it.
    v_query_vec := case
      when jsonb_typeof(v_query->'query_embedding') = 'array' then
        case
          when jsonb_array_length(v_query->'query_embedding') = 768
            then translate(v_query->>'query_embedding', ' ', '')::extensions.vector
          else null
        end
      else null
    end;

    if v_raw is null or coalesce(v_normalized, '') = '' then
      v_matches := v_matches || jsonb_build_object(
        'raw_name', v_raw, 'candidates', '[]'::jsonb
      );
      continue;
    end if;

    with legs as (
      -- 1. The alias leg: a text a human already confirmed for this product.
      --
      --    Scoped to this supplier OR to no supplier. An alias learned for one
      --    distributor deliberately does NOT answer the same printed text on
      --    another distributor's bill: two suppliers abbreviate differently, and
      --    a mapping learned from one is not evidence about the other. What
      --    crosses suppliers is a pharmacy-wide (supplier-less) alias, which is
      --    what `supplier_id is null` means here.
      select
        a.product_id,
        1.0::real as score,
        'alias'::text as reason,
        jsonb_build_object(
          'alias_name', a.raw_name,
          'supplier_scoped', a.supplier_id is not null
        ) as evidence,
        case when a.supplier_id is not null then 0 else 1 end as leg_rank
      from public.product_aliases a
      join public.products p
        on p.id = a.product_id
       and p.pharmacy_id = a.pharmacy_id
      where a.pharmacy_id = v_pharmacy
        and a.normalized_name = v_normalized
        and p.is_active
        and (a.supplier_id is null or a.supplier_id = v_supplier)

      union all

      -- 2. The trigram leg. Three comparisons, best one wins: the invoice text
      --    against the name, against the generic name, and - the one that pays
      --    for itself - the reversed word_similarity, which is what reads a
      --    supplier's run-together `Dolo650Tab15s` as `Dolo 650`.
      select
        p.id,
        t.score,
        'trigram'::text,
        jsonb_build_object('similarity', round(t.score::numeric, 4)),
        2
      from public.products p
      cross join lateral (
        select greatest(
          similarity(p.name, v_raw),
          similarity(coalesce(p.generic_name, ''), v_raw),
          word_similarity(p.name, v_raw)
        )::real as score
      ) t
      where p.pharmacy_id = v_pharmacy
        and p.is_active
        and t.score >= c_trigram_threshold

      union all

      -- 3. The vector leg. Skipped for a row the backfill has not reached
      --    (`embedding is null`, D-027) and for a caller that supplied no
      --    embedding, so an un-backfilled catalogue simply has two legs.
      --
      --    The floor sits BEHIND the LIMIT on purpose. A `where 1 - distance >=
      --    floor` would have to be evaluated before any ordering, and the HNSW
      --    index that migration 00022 built for this leg can only serve an
      --    `order by distance limit n` - so the filter would quietly turn every
      --    match into a full scan that computes 768-float distances per row. The
      --    two are equivalent, because the floor is monotone in distance: a row
      --    under the floor is farther than every row over it, so it can only ever
      --    displace rows that the floor was going to remove anyway.
      (
        select near.id, near.score, near.reason, near.evidence, near.leg_rank
        from (
          select
            p.id,
            (1 - (p.embedding <=> v_query_vec))::real as score,
            'vector'::text as reason,
            jsonb_build_object(
              'distance', round((p.embedding <=> v_query_vec)::numeric, 4)
            ) as evidence,
            3 as leg_rank
          from public.products p
          where v_query_vec is not null
            and p.pharmacy_id = v_pharmacy
            and p.is_active
            and p.embedding is not null
          order by p.embedding <=> v_query_vec
          limit v_limit
        ) near
        where near.score >= c_vector_min_similarity
      )
    ),
    -- One row per product, keeping its strongest evidence. Ties go to the leg
    -- that is a certainty over the leg that is an estimate, and within the alias
    -- leg to the supplier's own alias over the pharmacy-wide one.
    best as (
      select distinct on (product_id)
        product_id,
        score,
        reason,
        evidence,
        leg_rank
      from legs
      order by product_id, score desc, leg_rank
    ),
    ranked as (
      select
        b.product_id,
        b.score,
        b.reason,
        b.evidence,
        b.leg_rank,
        p.name,
        p.generic_name,
        p.pack_size,
        p.is_active
      from best b
      join public.products p on p.id = b.product_id
      order by b.score desc, b.leg_rank, p.name
      limit v_limit
    )
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          -- Named columns, never `select *`: products carries the 768-float
          -- embedding, which no caller needs and which would be ~8 kB of numbers
          -- per candidate on the wire (D-027).
          'product_id', r.product_id,
          'name', r.name,
          'generic_name', r.generic_name,
          'pack_size', r.pack_size,
          'is_active', r.is_active,
          'score', round(r.score::numeric, 4),
          'reason', r.reason,
          'evidence', r.evidence
        )
        order by r.score desc, r.leg_rank, r.name
      ),
      '[]'::jsonb
    )
    into v_candidates
    from ranked r;

    v_matches := v_matches || jsonb_build_object(
      'raw_name', v_raw, 'candidates', v_candidates
    );
  end loop;

  return v_matches;
end;
$$;

comment on function public.match_products(jsonb, int) is
  'Ranks the caller pharmacy''s own catalogue against one or more invoice texts. Three legs - a human-confirmed alias (1.0), pg_trgm similarity, and cosine distance over products.embedding - ranked by score with the winning leg reported as `reason`. The pharmacy comes from get_my_pharmacy_id(), never from an argument (D-004/D-026); every query is explicitly pharmacy-scoped because a SECURITY DEFINER function is not subject to RLS.';

-- ---------------------------------------------------------------------------
-- 3. Grants
--    authenticated only: anon has no RLS identity and no catalogue to match
--    against. `revoke ... from anon, public` is not redundant with the absence of
--    a grant - Supabase grants EXECUTE to anon and authenticated directly, so
--    removing the PUBLIC grant leaves their own in place (D-017's lesson,
--    migration 00018).
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.product_embedding_text(text, text, text) to authenticated';
  execute 'revoke execute on function public.product_embedding_text(text, text, text) from anon, public';

  execute 'grant execute on function public.match_products(jsonb, int) to authenticated';
  execute 'revoke execute on function public.match_products(jsonb, int) from anon, public';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
