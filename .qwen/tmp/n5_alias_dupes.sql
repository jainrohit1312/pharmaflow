-- Open item N-5, Phase 6 chunk 1 (2026-09-19). READ-ONLY probe.
--
-- The migration that follows turns `product_aliases`' unique key into one where
-- a NULL supplier is a value rather than a distinct-per-row non-value. A unique
-- index cannot be created over data that already violates it, so this asks first:
-- does any (pharmacy_id, supplier_id, normalized_name) group hold more than one
-- row? A NULL supplier groups with itself here, which is exactly the collision
-- the new index would refuse.
select
  (select count(*) from public.product_aliases) as alias_rows,
  (select count(*) from public.product_aliases a where a.supplier_id is null)
    as unscoped_rows,
  (select count(*) from (
     select 1
       from public.product_aliases b
      group by b.pharmacy_id, b.supplier_id, b.normalized_name
     having count(*) > 1
   ) collisions) as colliding_keys;
