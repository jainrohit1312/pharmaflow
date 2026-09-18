-- Migration: 20260918000013_views | Purpose: read-only reporting views (per-product stock rollup, batch expiry status)
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace view.
--
-- Both views are created with security_invoker = true, so the caller's RLS
-- applies to the underlying tables (products / product_batches). They are
-- therefore safe to expose to `authenticated` without widening tenant access.
-- This depends on migration 0009's indexes and on the product_batches RLS
-- policies from migration 0012.

-- ---------------------------------------------------------------------------
-- 1. product_stock - one row per product with on-hand quantity and valuation.
--    Only batches with qty > 0 contribute (zero/negative rows are treated as
--    fully consumed and are excluded from valuation).
-- ---------------------------------------------------------------------------
create or replace view public.product_stock
with (security_invoker = true) as
select
  p.id                as product_id,
  p.pharmacy_id,
  p.name,
  p.generic_name,
  p.brand,
  p.min_stock_level,
  coalesce(sum(b.qty), 0)::int                              as total_qty,
  coalesce(sum(b.qty * b.purchase_rate), 0)::numeric(14,2)  as stock_value_at_cost,
  coalesce(sum(b.qty * b.mrp), 0)::numeric(14,2)            as stock_value_at_mrp
from public.products p
left join public.product_batches b
  on b.product_id = p.id
 and b.qty > 0
group by
  p.id,
  p.pharmacy_id,
  p.name,
  p.generic_name,
  p.brand,
  p.min_stock_level;

-- ---------------------------------------------------------------------------
-- 2. batch_status - every product_batches column plus a bucketed expiry flag.
--    Buckets are evaluated most-urgent-first so an already-expired batch can
--    never be reported as merely 'critical'/'warning'.
-- ---------------------------------------------------------------------------
create or replace view public.batch_status
with (security_invoker = true) as
select
  b.*,
  case
    when b.expiry_date < current_date                then 'expired'
    when b.expiry_date <= current_date + 30          then 'critical'
    when b.expiry_date <= current_date + 90          then 'warning'
    else 'safe'
  end as expiry_status
from public.product_batches b;

-- ---------------------------------------------------------------------------
-- 3. Grants - authenticated only; anon has no tenant identity.
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant select on public.product_stock to authenticated';
  execute 'grant select on public.batch_status to authenticated';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
