-- Migration: 20260919000026_phase5_vector_floor | Purpose: the vector leg's
-- similarity floor, re-tuned against real vectors (D-036 marked it provisional).
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace function; no grant changes and nothing new.
--
-- What this migration is
-- ----------------------
-- `match_products()` exactly as migration 00023 defines it, with ONE constant
-- changed: `c_vector_min_similarity`, the score a candidate has to reach before
-- the vector leg offers it at all. It is a new migration rather than an edit of
-- 00023 for D-013's reason - 00023 is applied, and `supabase db push` applies only
-- versions the database has not seen, so editing it in place would leave the
-- database running the old constant while the repository looked changed.
--
-- Why it moved, and why to this number
-- ------------------------------------
-- 00023 called 0.7 a considered guess and said the backfill chunk would re-tune it
-- against real vectors. Chunk C3 produced those vectors and measured nine real
-- invoice texts against a real catalogue vector with the floor lowered, and the
-- guess was wrong in the direction that matters: `Dolo 500` and `Dolo 125` - two
-- strengths the pharmacy does not stock - both scored above it (0.7084, 0.7216)
-- and were offered as suggestions for a 'dolo 650' catalogue. The true match
-- (`Dolo650Tab15s`, the run-together spelling this leg exists for) scored 0.8280.
-- 0.78 is inside that window. The full table is beside the constant below and in
-- D-044.
--
-- What else this shows: junk text sits at 0.5364, so 00023's note that unrelated
-- short strings sit "around 0.6-0.75" was too high - a floor near 0.6 would have
-- offered the whole catalogue for every line. The trigram leg's 0.35 is untouched:
-- it was measured before it was written and nothing here contradicts it.
--
-- Verified by supabase/tests/phase5_match_products.sql (whose synthetic vectors
-- straddle whatever this constant is) and by the live probe recorded in D-044.

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

  -- How close a vector has to be before it is a suggestion at all. MEASURED, not
  -- guessed, on 2026-09-19 against the live catalogue (D-044): nine real invoice
  -- texts embedded by the live model and compared with the real catalogue vector,
  -- with this floor lowered to 0.01 so the RPC reported every distance.
  --
  --   'Dolo650Tab15s'  (the real product, run together)  0.8280   keep
  --   'Dolo 125'       (a different strength)            0.7216   refuse
  --   'Dolo 500'       (a different strength)            0.7084   refuse
  --   'Paracetamol 500mg' (same molecule, another brand) 0.6695   refuse
  --   'Amoxyclav 625 10s' (unrelated medicine)           0.5780   refuse
  --   'Cetirizine 10mg Tab' (unrelated medicine)         0.5546   refuse
  --   'ZZQQ nonsense 9999' (junk)                        0.5364   refuse
  --
  -- 0.78 sits inside the window the numbers leave open - above every wrong
  -- sibling (0.7216) and below the one true match (0.8280) - and it is high on
  -- purpose: a plausible-looking wrong suggestion teaches the user to ignore
  -- suggestions, while a missed one costs a tap. Note also what the bottom of
  -- that table says about the model: junk sits at 0.5364, so 00023's guess of
  -- "unrelated short strings around 0.6-0.75" was too high, and a floor anywhere
  -- near 0.6 would have offered the whole catalogue for every line.
  c_vector_min_similarity constant real := 0.78;

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
