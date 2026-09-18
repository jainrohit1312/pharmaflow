-- Migration: 20260918000016_landed_cost | Purpose: value scheme/free stock correctly - a per-batch landed cost
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: add column if not exists / update ... where is null /
--             create or replace view / create or replace function.
--
-- Why
-- ---
-- D-011 counts scheme (free) goods as physical stock, so quantity received is
-- qty + free_qty. Valuing every unit at purchase_rate would then overstate stock
-- value on any receipt carrying a scheme line: 10 paid at 100 plus 2 free is
-- 1000 of cost sitting behind 12 units, not 1200. That overstatement flows into
-- P&L, GST filing, audits and dead-stock decisions, so the cost of a unit is
-- stored per batch as the landed cost:
--
--     landed_cost_per_unit = paid_amount / units_received
--                          = (purchase_rate * paid_qty) / (paid_qty + free_qty)
--
-- Scope
-- -----
--   * quantity and cost basis live on product_batches, so a batch is the unit
--     of valuation (see DECISIONS.md D-012);
--   * landed cost is written by the same trigger that increments qty, which is
--     what keeps quantity and cost from ever disagreeing;
--   * outbound movements (purchase returns, stock adjustments) change quantity
--     only. The remaining units keep the basis the batch was received at, which
--     is the correct treatment for a write-off or a return.
--
-- Note on migration 20260918000015
-- --------------------------------
-- This migration REPLACES two functions created there, so the deployed copies
-- of stock_apply_purchase() and stock_apply_purchase_item() are the versions
-- below. 00015 is deliberately left untouched apart from comments: it is
-- already applied, and `supabase db push` does not re-run applied versions.

-- ---------------------------------------------------------------------------
-- 1. The column
-- ---------------------------------------------------------------------------
alter table public.product_batches
  add column if not exists landed_cost_per_unit numeric(12,4);

comment on column public.product_batches.landed_cost_per_unit is
  'Cost per unit actually paid for this batch, spread over the paid AND free units it contains. Written by the Phase 2 purchase triggers; NULL means "not yet costed", in which case product_stock falls back to purchase_rate.';

-- ---------------------------------------------------------------------------
-- 2. Backfill
--
--    Every batch that exists today was created without a scheme line, so its
--    purchase_rate IS its landed cost. Cheap and safe: product_batches is
--    still empty on the hosted project (nothing has been received yet), and
--    this keeps the column populated for any that were seeded by hand.
-- ---------------------------------------------------------------------------
update public.product_batches
   set landed_cost_per_unit = purchase_rate
 where landed_cost_per_unit is null;

-- ---------------------------------------------------------------------------
-- 3. Valuation uses the landed cost
--
--    Same shape, columns and column order as migration 20260918000013 -
--    create or replace view cannot change those. Only stock_value_at_cost
--    changes. The inner coalesce matters: without it a single batch whose
--    landed cost was never set would drop out of the sum entirely (qty * NULL
--    is NULL and sum ignores NULLs), silently understating the total instead
--    of falling back to the batch's purchase rate.
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
  coalesce(
    sum(b.qty * coalesce(b.landed_cost_per_unit, b.purchase_rate)),
    0
  )::numeric(14,2)                                          as stock_value_at_cost,
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

-- create or replace preserves the existing grants, but re-issuing them costs
-- nothing and keeps this migration correct if the view is ever dropped first.
do $$
begin
  execute 'grant select on public.product_stock to authenticated';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Document-level posting, now carrying the cost basis
--
--    Landed cost is a moving weighted average over the units the batch holds:
--
--      new_cost = (existing_units * existing_cost + amount_paid_here)
--                 / (existing_units + units_received_here)
--
--    On the first receipt into an empty batch this is exactly
--    purchase_rate * qty / (qty + free_qty). On a later receipt into the same
--    batch it averages rather than overwriting, because overwriting would
--    restate the cost of units that are already in stock (and possibly already
--    dispensed), which is precisely the kind of retroactive change an inventory
--    ledger must not make.
--
--    In the SET list, b.qty and b.landed_cost_per_unit are the pre-update
--    values, which is what the formula needs.
-- ---------------------------------------------------------------------------
create or replace function public.stock_apply_purchase()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Stock moves only when the document is received...
  if new.status is distinct from 'received' then
    return new;
  end if;

  -- ...and only once per document. The marker is set at the end of this
  -- function and never cleared, so a later status flip cannot post twice and
  -- cannot silently reverse what was posted.
  if new.stock_posted_at is not null then
    return new;
  end if;

  -- One increment per batch, aggregated so that a document referencing the
  -- same batch on two lines still produces a single deterministic delta
  -- (PostgreSQL picks arbitrarily among duplicate join matches otherwise).
  -- Lines that were never resolved to a batch contribute nothing, which is
  -- exactly why the GRN UI has to upsert the batch row first.
  --
  -- Deviation from shipped stock_update_on_purchase(): adds free_qty
  -- because scheme goods are physical stock. See DECISIONS.md D-011.
  --
  -- Landed cost is the moving weighted average over the units this batch holds
  -- (D-012), because a batch can be received more than once - the unique key is
  -- (pharmacy_id, product_id, batch_no) - and overwriting would restate the cost
  -- of units already in stock, possibly already dispensed:
  --
  --   new_cost = (old_qty * coalesce(old_cost, purchase_rate) + paid_here)
  --              / (old_qty + units_received_here)
  --
  -- On the first receipt into an empty batch old_qty is 0, so this reduces to
  --   purchase_rate * qty / (qty + free_qty)
  -- which is the single-receipt case: 10 paid at 100 plus 2 free gives 1000 of
  -- cost behind 12 units, i.e. 83.3333 per unit.
  update public.product_batches b
     set qty = b.qty + v.delta,
         landed_cost_per_unit = case
           when b.qty + v.delta > 0
           then (coalesce(b.landed_cost_per_unit, b.purchase_rate) * b.qty
                 + v.paid_cost) / (b.qty + v.delta)
           else coalesce(b.landed_cost_per_unit, b.purchase_rate)
         end,
         updated_at = now()
    from (
      select
        i.batch_id,
        sum(coalesce(i.qty, 0) + coalesce(i.free_qty, 0))::int as delta,
        sum(coalesce(i.qty, 0) * i.purchase_rate)::numeric(14,2) as paid_cost
      from public.purchase_items i
      where i.purchase_id = new.id
        and i.pharmacy_id = new.pharmacy_id
        and i.batch_id is not null
      group by i.batch_id
    ) v
   where b.id = v.batch_id
     and b.pharmacy_id = new.pharmacy_id;

  -- Stamp last. This UPDATE sets only stock_posted_at, so it does not re-fire
  -- this trigger (which is bound to `update of status`) and cannot recurse.
  update public.purchases
     set stock_posted_at = now()
   where id = new.id
     and stock_posted_at is null;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Line-level posting, same cost treatment for the opposite write order
--    (a line added to a document that is already received).
-- ---------------------------------------------------------------------------
create or replace function public.stock_apply_purchase_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_received boolean;
  v_delta       int;
begin
  if new.batch_id is null then
    return new;
  end if;

  select (p.status = 'received')
    into v_is_received
    from public.purchases p
   where p.id = new.purchase_id
     and p.pharmacy_id = new.pharmacy_id;

  if coalesce(v_is_received, false) is not true then
    return new;
  end if;

  v_delta := coalesce(new.qty, 0) + coalesce(new.free_qty, 0);

  -- Deviation from shipped stock_update_on_purchase(): adds free_qty
  -- because scheme goods are physical stock. See DECISIONS.md D-011.
  --
  -- Same moving weighted average as stock_apply_purchase() (D-012), for the
  -- opposite write order - a line added to a document that is already received:
  --
  --   new_cost = (old_qty * coalesce(old_cost, purchase_rate)
  --               + paid_qty_here * purchase_rate_here)
  --              / (old_qty + units_received_here)
  --
  -- Reducing to purchase_rate * qty / (qty + free_qty) when old_qty is 0.
  update public.product_batches b
     set qty = b.qty + v_delta,
         landed_cost_per_unit = case
           when b.qty + v_delta > 0
           then (coalesce(b.landed_cost_per_unit, b.purchase_rate) * b.qty
                 + coalesce(new.qty, 0) * new.purchase_rate)
                / (b.qty + v_delta)
           else coalesce(b.landed_cost_per_unit, b.purchase_rate)
         end,
         updated_at = now()
   where b.id = new.batch_id
     and b.pharmacy_id = new.pharmacy_id;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Not changed, on purpose
--
--    ledger_auto_entry_purchase() posts new.grand_total - what the invoice says
--    was PAYABLE - not a rate-derived figure, so it is already correct and
--    unaffected by the free-goods treatment above. Payments and the ledger
--    track cash; landed cost tracks inventory value.
--
--    stock_apply_adjustment() and stock_update_on_purchase_return() change
--    quantity only, leaving the batch's cost basis alone.
--
--    No trigger changes are needed: CREATE OR REPLACE FUNCTION keeps the
--    function OID, so the triggers attached in 00015 now call these bodies.
-- ---------------------------------------------------------------------------
