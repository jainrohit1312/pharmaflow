-- Migration: 20260919000025_phase5_embedding_backfill | Purpose: the read and
-- write half of embedding the catalogue - the two statements the operator's
-- backfill loop is built from.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace function + guarded grants.
--
-- What this migration is
-- ----------------------
-- Two functions and their grants. Nothing else: no table, no column, no trigger.
-- `products.embedding` and its HNSW index already exist (migration 00022, D-027),
-- and `product_embedding_text()` - the ONE catalogue-text convention - already
-- exists (migration 00023, D-037). This is the pair that moves real vectors into
-- that column:
--
--   products_to_embed(...)      what is still to do, as one batch
--   set_product_embeddings(...)  the write, as one batch
--
-- Why two functions and not one
-- -----------------------------
-- Because the model call happens between them, and it happens in an Edge
-- Function: read a batch here, embed it there, write it back here. That split is
-- what makes the work **resumable** - the loop's state is the column itself
-- (`embedding is null`), so a second run continues rather than repeating - and it
-- is what lets the operator stop between any two batches. A single function that
-- called the model would put the network inside a transaction.
--
-- The work list, exactly
-- ----------------------
-- D-027 says `products.embedding is null` is the work list. Precisely: the
-- *embeddable* un-embedded rows - a row whose `product_embedding_text()` is NULL
-- (a product with no name, generic name or pack size, i.e. nothing to say about
-- it) is not offered, because embedding it is impossible and offering it would
-- make the loop spin for ever on a row that can never leave the list. Such rows
-- are counted separately so the tail is visible rather than silently missing:
-- `{ items, remaining, unembeddable }`.
--
-- Why the write is an RPC and not a PostgREST update
-- --------------------------------------------------
-- D-027 refused to depend on how PostgREST marshals a `vector`, and this is that
-- refusal being honoured: a `vector(768)` written through the REST API is a
-- behaviour nobody here can verify without a container. Through a function the
-- value is cast by the database, from the same text form the vector's own input
-- function accepts - `[0.1,0.2,…]` - which is the trick migration 00023 already
-- uses for its query embedding.
--
-- The tenant is never an argument (D-004/D-026). It comes from
-- get_my_pharmacy_id(), and because a SECURITY DEFINER function is not subject to
-- RLS, every read and write below carries `pharmacy_id = v_pharmacy` explicitly:
-- the write in particular, where a caller-supplied product id from another
-- catalogue must not be able to set a vector on a row this tenant cannot see.
--
-- Untrusted input, all of it
-- --------------------------
-- `set_product_embeddings` treats every entry as hostile: a non-object entry, a
-- product id that is not a uuid, an embedding that is not an array of exactly 768
-- numbers, and a product that is not in this catalogue are **skipped with a
-- reason** rather than raising. A batch that arrives half-formed is a batch that
-- wrote what it could, and the caller reads the `skipped` list.
--
-- What this migration does NOT do
-- -------------------------------
-- It does not touch `match_products`' `c_vector_min_similarity`. That constant is
-- provisional (migration 00023) and is re-tuned against the vectors this pair
-- produces, in a **separate** migration (D-013: an applied migration is never
-- edited in place) once there are real vectors to measure.
--
-- Verified by supabase/tests/phase5_embedding_backfill.sql (atomic,
-- self-rolling-back: the read's shape and scope, the write's cast and its
-- refusals, tenant isolation on both sides, resumability, and the vector leg of a
-- real `match_products` call firing on a row this pair wrote).

-- ---------------------------------------------------------------------------
-- 1. The work list
--
--    One batch, in a stable order, with the text the convention produces. The
--    text is returned rather than rebuilt by the caller on purpose: D-037 put the
--    convention in the database so the two sides of the match cannot drift, and a
--    backfill that composed its own string would be a third opinion.
-- ---------------------------------------------------------------------------
create or replace function public.products_to_embed(p_limit int default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  -- The ceiling is a payload guard, not a measurement: 20 is the batch size that
  -- was measured safe against the live model (D-041), and this only stops a
  -- caller asking for a thousand rows in one request.
  c_max_batch constant int := 100;

  v_pharmacy     uuid := public.get_my_pharmacy_id();
  v_limit        int := least(greatest(coalesce(p_limit, 20), 1), c_max_batch);
  v_items        jsonb;
  v_remaining    bigint;
  v_unembeddable bigint;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  with candidates as (
    select
      p.id,
      p.name,
      public.product_embedding_text(p.name, p.generic_name, p.pack_size) as text
    from public.products p
    where p.pharmacy_id = v_pharmacy
      and p.embedding is null
  ),
  batch as (
    -- The filter is inside the limit, not after it: taking 20 rows and then
    -- dropping the un-embeddable ones would quietly hand back a short batch and
    -- make the operator's loop look stuck.
    select c.id, c.name, c.text
    from candidates c
    where c.text is not null
    order by c.name, c.id
    limit v_limit
  )
  select
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object('product_id', b.id, 'text', b.text)
          order by b.name, b.id
        )
        from batch b
      ),
      '[]'::jsonb
    ),
    (select count(*) from candidates c where c.text is not null),
    (select count(*) from candidates c where c.text is null)
  into v_items, v_remaining, v_unembeddable;

  return jsonb_build_object(
    'items', v_items,
    'remaining', v_remaining,
    'unembeddable', v_unembeddable
  );
end;
$$;

comment on function public.products_to_embed(int) is
  'One batch of the caller pharmacy''s catalogue rows that still need an embedding, with the text product_embedding_text() produces (D-037), plus how many rows remain and how many can never be embedded. `products.embedding is null` is the work list (D-027), so a second run resumes rather than repeating; the pharmacy comes from get_my_pharmacy_id(), never an argument.';

-- ---------------------------------------------------------------------------
-- 2. The write
--
--    One batch, all or nothing per *row*, with the count that tells the operator
--    whether to run it again. `remaining` is computed after the writes, so the
--    next step is one number instead of another round trip.
-- ---------------------------------------------------------------------------
create or replace function public.set_product_embeddings(p_items jsonb)
returns jsonb
language plpgsql
volatile
security definer
-- `extensions` is in the list for pgvector's type, the same pair migration 00023
-- pins for its operators.
set search_path = public, extensions
as $$
declare
  -- The schema's hard constant (migration 00022, D-027). A vector of any other
  -- width is refused rather than stored: the model emits 3072 unless told
  -- otherwise, and a 3072-element vector in a vector(768) column is a comparison
  -- that can only fail.
  c_dimensions constant int := 768;

  c_uuid constant text :=
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

  v_pharmacy  uuid := public.get_my_pharmacy_id();
  v_entry     jsonb;
  v_product   uuid;
  v_embedding extensions.vector;
  v_written   int := 0;
  v_updated   int;
  v_skipped   jsonb := '[]'::jsonb;
  v_remaining bigint;
  v_unembeddable bigint;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    for v_entry in select value from jsonb_array_elements(p_items)
    loop
      if jsonb_typeof(v_entry) <> 'object' then
        v_skipped := v_skipped || jsonb_build_object(
          'product_id', null,
          'reason', 'not an item'
        );
        continue;
      end if;

      v_product := case
        when coalesce(v_entry->>'product_id', '') ~* c_uuid
          then (v_entry->>'product_id')::uuid
        else null
      end;

      -- The nested CASE is deliberate, the same way migration 00023's is:
      -- `jsonb_array_length` raises on a value that is not an array, so a flat
      -- AND would let the planner reach it.
      v_embedding := case
        when jsonb_typeof(v_entry->'embedding') = 'array' then
          case
            when jsonb_array_length(v_entry->'embedding') = c_dimensions
              then translate(v_entry->>'embedding', ' ', '')::extensions.vector
            else null
          end
        else null
      end;

      if v_product is null then
        v_skipped := v_skipped || jsonb_build_object(
          'product_id', v_entry->>'product_id',
          'reason', 'not a product id'
        );
        continue;
      end if;

      if v_embedding is null then
        v_skipped := v_skipped || jsonb_build_object(
          'product_id', v_product::text,
          'reason',
          'the embedding is not ' || c_dimensions || ' numbers'
        );
        continue;
      end if;

      -- Scoped, not merely keyed: a product id from another tenant's catalogue
      -- must not be writable from here even though the function owns the table.
      update public.products
         set embedding = v_embedding
       where id = v_product
         and pharmacy_id = v_pharmacy;

      get diagnostics v_updated = row_count;

      if v_updated = 0 then
        v_skipped := v_skipped || jsonb_build_object(
          'product_id', v_product::text,
          'reason', 'that product is not in this catalogue'
        );
      else
        v_written := v_written + 1;
      end if;
    end loop;
  end if;

  -- After the writes: what is left, so the operator's next step is one number.
  select
    count(*) filter (where t.text is not null),
    count(*) filter (where t.text is null)
  into v_remaining, v_unembeddable
  from (
    select public.product_embedding_text(p.name, p.generic_name, p.pack_size) as text
    from public.products p
    where p.pharmacy_id = v_pharmacy
      and p.embedding is null
  ) t;

  return jsonb_build_object(
    'written', v_written,
    'remaining', v_remaining,
    'unembeddable', v_unembeddable,
    'skipped', v_skipped
  );
end;
$$;

comment on function public.set_product_embeddings(jsonb) is
  'Writes one batch of catalogue embeddings, casting each value with the database''s own vector input rather than trusting PostgREST to marshal a vector (D-027). Every row is scoped to get_my_pharmacy_id(); an entry that is not an object, a product id that is not a uuid, an embedding that is not 768 numbers, and a product that is not in this catalogue are skipped with a reason instead of raising. Returns the write count, what is left to do, and the skips.';

-- ---------------------------------------------------------------------------
-- 3. Grants
--    authenticated only: anon has no RLS identity and no catalogue. `revoke ...
--    from anon, public` is not redundant with the absence of a grant - Supabase
--    grants EXECUTE to anon and authenticated directly, so removing the PUBLIC
--    grant leaves their own in place (D-017's lesson, migration 00018).
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.products_to_embed(int) to authenticated';
  execute 'revoke execute on function public.products_to_embed(int) from anon, public';

  execute 'grant execute on function public.set_product_embeddings(jsonb) to authenticated';
  execute 'revoke execute on function public.set_product_embeddings(jsonb) from anon, public';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
