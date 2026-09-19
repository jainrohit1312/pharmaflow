-- Migration: 20260919000024_phase5_alias_learning | Purpose: the write half of the
-- smart match - record what a human confirmed on a bill the reader has read.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace function + guarded grants.
--
-- What this migration is
-- ----------------------
-- One function and its grant. Nothing else: no table, no column, no trigger, and
-- nothing that moves stock. The read half of the match is `match_products()`
-- (migration 00023); this is the half that makes the *second* bill from a
-- supplier cheap, because the first one taught the system what its abbreviations
-- mean.
--
-- Why learning is a write of its own rather than a field on the match
-- ------------------------------------------------------------------
-- A suggestion is a guess and an alias is a fact, and only one of the two is
-- worth remembering. `match_products()` suggests; a human then chooses; the choice
-- is what this function records. That is also why nothing here is called while the
-- screen is being filled in: the offer is made at read time and the fact is
-- recorded at save time (one call per bill), so a bill the user abandons teaches
-- the system nothing.
--
-- Why an alias is scoped to the supplier when one is known
-- --------------------------------------------------------
-- D-036's consequence, and the reason the alias leg accepts a row for *this*
-- supplier or a pharmacy-wide one: two distributors abbreviate differently, so a
-- mapping learned from one is not evidence about the other. A learned alias
-- therefore carries the supplier the bill named. A bill with no supplier (or a
-- supplier id that is not this pharmacy's) learns a pharmacy-wide alias instead -
-- which is the row that *does* cross suppliers, deliberately.
--
-- The tenant is never an argument (D-004/D-026). It comes from
-- get_my_pharmacy_id(), and because a SECURITY DEFINER function is not subject to
-- RLS, every read and write below carries `pharmacy_id = v_pharmacy` explicitly:
-- a product id from another catalogue must not become an alias to a row this
-- tenant cannot even see, and a supplier id from another tenant must not be
-- stored as if it were ours.
--
-- The NULL-supplier unique-key trap (open item N-5), sidestepped locally
-- --------------------------------------------------------------------
-- The unique index is (pharmacy_id, supplier_id, normalized_name) with a nullable
-- supplier_id and no NULLS NOT DISTINCT, so Postgres treats NULLs as distinct and
-- an `on conflict` can never converge a second pharmacy-wide row. N-5 records that
-- as the index's problem to fix; this function simply does not depend on it - a
-- phone-wide write updates the matching row if one exists and inserts only when it
-- does not, so learning the same text twice with no supplier is one row. The
-- index, `ProductsRepository.addAlias` and the manual path are untouched.
--
-- Untrusted input, all of it
-- --------------------------
-- Every entry arrives from a screen, so every entry is treated as hostile: a
-- non-object entry, a product id that is not a uuid, a product that is not in this
-- catalogue, a blank or punctuation-only text, and a supplier that is not ours are
-- all *skipped* with a reason rather than raising. A bill that cannot teach is not
-- a failure - the purchase it came from has already been saved.
--
-- Verified by supabase/tests/phase5_learn_product_aliases.sql (atomic,
-- self-rolling-back, asserting the write, the re-point, the NULL-supplier
-- convergence, tenant isolation, the untrusted-input rules, and the learned alias
-- answering the alias leg of a real match).

create or replace function public.learn_product_aliases(p_aliases jsonb)
returns jsonb
language plpgsql
-- VOLATILE, not STABLE: this one writes. Declaring it STABLE would be a lie the
-- planner is entitled to act on.
volatile
security definer
-- Pinned, not inherited: a SECURITY DEFINER function that resolves
-- `normalize_product_name` through whatever search_path the caller happened to
-- have is a way to run someone else's function as this owner.
set search_path = public
as $$
declare
  -- The shape a value has to have before it is cast to a uuid. A pattern rather
  -- than a try/catch: `'x'::uuid` raises, and one malformed id in a twenty-line
  -- bill must not cost the other nineteen their aliases.
  c_uuid constant text :=
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_entry    jsonb;
  v_raw      text;
  v_norm     text;
  v_product  uuid;
  v_supplier uuid;
  v_learned  int := 0;
  v_skipped  jsonb := '[]'::jsonb;
  v_updated  int;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  -- Not an array is "nothing to learn", not an error: the caller is an app that
  -- has just saved a purchase, and failing here would be a failure after the fact.
  if p_aliases is null or jsonb_typeof(p_aliases) <> 'array' then
    return jsonb_build_object('learned', 0, 'skipped', '[]'::jsonb);
  end if;

  for v_entry in select value from jsonb_array_elements(p_aliases)
  loop
    if jsonb_typeof(v_entry) <> 'object' then
      v_skipped := v_skipped || jsonb_build_object(
        'raw_name', null,
        'reason', 'not a line'
      );
      continue;
    end if;

    -- The printed text, trimmed. The *normalized* form is derived here rather
    -- than sent by the client: it is the same function the alias leg of
    -- match_products() compares against, so a client that computed it differently
    -- would write an alias nothing could ever find.
    v_raw := nullif(trim(both ' ' from coalesce(v_entry->>'raw_name', '')), '');
    v_norm := public.normalize_product_name(v_raw);

    v_product := case
      when coalesce(v_entry->>'product_id', '') ~* c_uuid
        then (v_entry->>'product_id')::uuid
      else null
    end;

    v_supplier := case
      when coalesce(v_entry->>'supplier_id', '') ~* c_uuid
        then (v_entry->>'supplier_id')::uuid
      else null
    end;

    if v_raw is null or coalesce(v_norm, '') = '' then
      -- `normalize_product_name` keeps only letters and digits, so punctuation
      -- alone normalizes to nothing and could never be matched back.
      v_skipped := v_skipped || jsonb_build_object(
        'raw_name', v_raw,
        'reason', 'the printed text has nothing to match on'
      );
      continue;
    end if;

    if v_product is null then
      v_skipped := v_skipped || jsonb_build_object(
        'raw_name', v_raw,
        'reason', 'no product was chosen for it'
      );
      continue;
    end if;

    -- The product has to be *this* pharmacy's. Without this check a caller could
    -- record an alias pointing at another tenant's product - a row it cannot read,
    -- in a table it owns, that its own match would then resolve to a product id it
    -- never sees.
    if not exists (
      select 1
        from public.products p
       where p.id = v_product
         and p.pharmacy_id = v_pharmacy
    ) then
      v_skipped := v_skipped || jsonb_build_object(
        'raw_name', v_raw,
        'reason', 'that product is not in this catalogue'
      );
      continue;
    end if;

    -- A supplier that is not ours is read as "no supplier" rather than refused:
    -- the alias is still worth learning, it is just not scoped to a distributor
    -- this pharmacy has never heard of.
    if v_supplier is not null and not exists (
      select 1
        from public.suppliers s
       where s.id = v_supplier
         and s.pharmacy_id = v_pharmacy
    ) then
      v_supplier := null;
    end if;

    if v_supplier is not null then
      -- One statement, and the unique index does the converging: re-learning a
      -- text that already exists for this supplier and this pharmacy *re-points*
      -- it at the product the human chose this time.
      insert into public.product_aliases (
        pharmacy_id, product_id, raw_name, normalized_name, supplier_id
      )
      values (v_pharmacy, v_product, v_raw, v_norm, v_supplier)
      on conflict (pharmacy_id, supplier_id, normalized_name)
      do update set
        product_id = excluded.product_id,
        raw_name = excluded.raw_name;
    else
      -- The pharmacy-wide case. `on conflict` cannot converge these rows at all
      -- (N-5: NULLs are distinct in the unique index), so the update is written
      -- out and the insert happens only when there was nothing to update.
      update public.product_aliases
         set product_id = v_product,
             raw_name = v_raw
       where pharmacy_id = v_pharmacy
         and supplier_id is null
         and normalized_name = v_norm;

      get diagnostics v_updated = row_count;

      if v_updated = 0 then
        insert into public.product_aliases (
          pharmacy_id, product_id, raw_name, normalized_name, supplier_id
        )
        values (v_pharmacy, v_product, v_raw, v_norm, null);
      end if;
    end if;

    v_learned := v_learned + 1;
  end loop;

  -- What the caller learns back. The client ignores it - learning is best effort
  -- and must never be able to fail a save - but a test and a handoff can assert it.
  return jsonb_build_object('learned', v_learned, 'skipped', v_skipped);
end;
$$;

comment on function public.learn_product_aliases(jsonb) is
  'Records the invoice-text-to-product mappings a human confirmed on a read bill (one call per bill, at save). The text is normalized by normalize_product_name() here rather than by the client, an alias carries the bill''s supplier when it names one, and a product or supplier that is not the caller''s own is skipped. The pharmacy comes from get_my_pharmacy_id(), never from an argument (D-004/D-026), and every statement is explicitly pharmacy-scoped because a SECURITY DEFINER function is not subject to RLS.';

-- ---------------------------------------------------------------------------
-- Grants. authenticated only: anon has no RLS identity, no catalogue, and
-- nothing it could legitimately teach. `revoke ... from anon, public` is not
-- redundant with the absence of a grant - Supabase grants EXECUTE to anon and
-- authenticated directly, so removing the PUBLIC grant leaves their own in place
-- (D-017's lesson, migration 00018).
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.learn_product_aliases(jsonb) to authenticated';
  execute 'revoke execute on function public.learn_product_aliases(jsonb) from anon, public';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
