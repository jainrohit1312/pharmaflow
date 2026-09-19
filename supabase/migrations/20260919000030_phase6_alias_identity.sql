-- 00030 - The alias key treats "no supplier" as a value
--
-- Open item N-5, closed in Phase 6. `product_aliases` is keyed
-- (pharmacy_id, supplier_id, normalized_name) and `supplier_id` is nullable: a
-- row with no supplier is a *pharmacy-wide* alias, one learned from a bill that
-- named no distributor.
--
-- Postgres treats NULLs as distinct in a unique index by default, so that key
-- did not mean what two places in this repository said it meant:
--
--   * migration 00015's comment claimed NULL-supplier rows "never conflict",
--     and called that "the right behaviour for manual aliases that are not tied
--     to one distributor";
--   * `ProductsRepository.addAlias`'s doc claimed that re-adding a text
--     "re-points the alias ... instead of failing, which is what the unique key
--     on (pharmacy_id, supplier_id, normalized_name) is for".
--
-- The first was true and the second was false: for a supplier-scoped alias the
-- upsert converged, and for a pharmacy-wide one the second manual add inserted a
-- *duplicate* row. Both cannot be true, which is what made this an open item
-- rather than a preference.
--
-- `NULLS NOT DISTINCT` (PostgreSQL 15+; this project is on 17) makes the second
-- claim true, so the two agree and the client needs no change: a pharmacy may
-- hold one alias per printed text per supplier *value*, and "no supplier" is a
-- value.
--
-- Why not the expression index. The other candidate was
-- `(pharmacy_id, coalesce(supplier_id, '<sentinel>'::uuid), normalized_name)`.
-- It enforces the same rule and PostgREST cannot use it: `on_conflict` is
-- matched to an index by *column names*, and an index over an expression is not
-- inferrable from those names, so `addAlias`'s upsert would have started failing
-- with "there is no unique or exclusion constraint matching the ON CONFLICT
-- specification". `NULLS NOT DISTINCT` keeps the index on the plain columns -
-- the docs describe inference as matching "exactly the conflict_target-specified
-- columns", with no exclusion for this option - so the upsert target still
-- resolves, and now the conflict it looks for is actually detected.
--
-- Why `learn_product_aliases` is untouched. Migration 00024's function carries
-- an explicit update-then-insert for the NULL-supplier case precisely because
-- `on conflict` could not converge those rows. That branch is now redundant, and
-- it stays: it is still correct, and replacing a deployed, tested function in
-- order to delete a branch that harms nothing is churn with a risk attached.
-- This note is what stops the old comment from reading as a live constraint.
--
-- Read-only probe first (2026-09-19, `.qwen/tmp/n5_alias_dupes.sql`): the
-- project held 0 alias rows and 0 colliding keys, so the index was built over an
-- empty table and nothing had to be de-duplicated. That is the only reason this
-- migration is pure DDL; on a populated table it would have needed a decision
-- about which row survives, which is not a thing an index swap should decide.
--
-- `NULLS NOT DISTINCT` is a property of the index and cannot be turned on for an
-- existing one, so the index is dropped and rebuilt. The table is empty and the
-- statement is a no-op on a re-run.
--
-- Verified by supabase/tests/phase6_alias_identity.sql (atomic,
-- self-rolling-back: the index's own flags, both upsert paths converging, the
-- supplier-scoped and pharmacy-wide rows still coexisting, two texts still two
-- rows, and tenant isolation).

drop index if exists public.product_aliases_pharmacy_supplier_normalized_key;

create unique index if not exists product_aliases_pharmacy_supplier_normalized_key
  on public.product_aliases (pharmacy_id, supplier_id, normalized_name)
  nulls not distinct;

comment on index public.product_aliases_pharmacy_supplier_normalized_key is
  'One row per (pharmacy, supplier, printed text), with a NULL supplier counting as a value so a pharmacy-wide alias converges instead of duplicating (N-5). The target PostgREST upserts at: on_conflict=pharmacy_id,supplier_id,normalized_name.';
