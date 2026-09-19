-- Migration: 20260918000015_phase2_extras | Purpose: enable the Phase-2 automation layer (purchase stock posting, supplier ledger, stock adjustments, purchase-return stock) plus the indexes the Phase 1/2 read paths need
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: add column if not exists / create or replace function /
--             drop trigger if exists / create index if not exists.
--
-- Why this file exists instead of uncommenting migration 00010
-- -----------------------------------------------------------
-- The automation functions were shipped commented out in
-- 20260918000010_triggers.sql with TODO(phase-2) markers at lines 150, 200,
-- 266, 298 and 340. That migration is already applied to the hosted project,
-- and `supabase db push` only applies versions missing from
-- supabase_migrations.schema_migrations - editing an applied file would leave
-- the repository looking enabled while the database stayed inert. Enabling
-- them is therefore a new migration, exactly as MASTER_PLAN.md:85-87 puts it:
-- "Enabling them is a migration, not a rewrite".
--
-- Mapping back to the commented originals:
--   ledger_auto_entry_purchase()  -> activated here verbatim (00010 line 150)
--   stock_update_on_purchase()    -> REPLACED by two status-gated functions
--                                    (00010 line 266). The shipped version was
--                                    `after insert on purchase_items` with no
--                                    status test, so writing a draft purchase
--                                    order's lines would have inflated batch
--                                    stock before any goods arrived. It also
--                                    ignored free_qty, which is physical stock
--                                    on a pharmacy supplier invoice.
--   ledger_auto_entry_sale()      -> still Phase 3 (00010 line 200)
--   stock_update_on_sale()        -> still Phase 3 (00010 line 298)
--   write_audit_log()             -> still unused (00010 line 340); Phase 2's
--                                    audit trail is the stock_adjustments table
--
-- Contract this migration establishes
-- ----------------------------------
--   * A purchase document reaches 'received' exactly once as far as stock is
--     concerned: draft and ordered lines never move stock, and a status flip
--     back out of 'received' never reverses it (see stock_posted_at below).
--   * product_batches.qty is the single running balance. Batch rows must exist
--     before a received line references them - purchase_items.batch_id is the
--     join key, as 00010's own dependency note at line 268 says - and the GRN
--     UI creates them with qty = 0 so the increments below are the only write.
--   * Quantity received = qty + free_qty, because scheme/free goods are
--     physical stock that will be dispensed.
--   * Outbound corrections do not go through status changes: they go through
--     purchase returns (stock decremented) or stock adjustments (either
--     direction, with a reason).

-- ---------------------------------------------------------------------------
-- 1. Stock-posting marker + the partial index Phase 2 reads
--
--    The marker is what makes stock posting idempotent. It is stamped by the
--    same trigger that applies the lines, and it is deliberately never
--    cleared, so re-entering 'received' cannot post a second time.
-- ---------------------------------------------------------------------------
alter table public.purchases
  add column if not exists stock_posted_at timestamptz;

comment on column public.purchases.stock_posted_at is
  'Stamped once when this document''s lines were applied to product_batches. NULL means received-but-not-yet-posted. One-way by design: stock is never reversed by a status change.';

-- Supports the "received but not yet posted" sweep behind the Phase 2
-- dashboard. Partial, so it stays small regardless of purchase volume.
create index if not exists purchases_pharmacy_id_pending_stock_idx
  on public.purchases (pharmacy_id)
  where status = 'received' and stock_posted_at is null;

-- ---------------------------------------------------------------------------
-- 2. ledger_auto_entry_purchase()
--    Verbatim from 00010 line 150 (uncommented only): posts the supplier
--    payable when a purchase becomes 'received'. Its own exists() guard already
--    makes it idempotent, so it needs no other change.
-- ---------------------------------------------------------------------------
create or replace function public.ledger_auto_entry_purchase()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Only post once the document is finalised; drafts must stay out of the ledger.
  if new.status is distinct from 'received' then
    return new;
  end if;

  -- Idempotency guard: one ledger row per purchase document.
  if exists (
    select 1 from public.ledger_entries
    where reference_type = 'purchase' and reference_id = new.id
  ) then
    return new;
  end if;

  insert into public.ledger_entries (
    pharmacy_id, entry_date, party_type, supplier_id,
    reference_type, reference_id, description, debit, credit, created_by
  ) values (
    new.pharmacy_id,
    coalesce(new.invoice_date, current_date),
    'supplier',
    new.supplier_id,
    'purchase',
    new.id,
    'Purchase ' || coalesce(new.invoice_no, new.id::text),
    0,
    coalesce(new.grand_total, 0),
    new.created_by
  );

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. stock_apply_purchase()
--    Document-level posting: applies every line of a purchase to stock, once,
--    at the moment the document becomes 'received'. This is the primary path -
--    the GRN screen writes its lines while the document is still draft/ordered,
--    then sets the status.
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
  update public.product_batches b
     set qty = b.qty + v.delta,
         updated_at = now()
    from (
      select
        i.batch_id,
        sum(coalesce(i.qty, 0) + coalesce(i.free_qty, 0))::int as delta
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
-- 4. stock_apply_purchase_item()
--    Line-level posting for the opposite write order: a line added to a
--    document that is ALREADY received (a missed line, or a document created
--    directly as received by a future quick-GRN path).
--
--    Exactly one of functions 3 and 4 owns any given line, which is what keeps
--    stock from double-counting: a line that exists before the status change is
--    invisible to this branch (its document was not received yet), and a line
--    written afterwards is invisible to function 3 (the marker is already set).
-- ---------------------------------------------------------------------------
create or replace function public.stock_apply_purchase_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_received boolean;
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

  -- Deviation from shipped stock_update_on_purchase(): adds free_qty
  -- because scheme goods are physical stock. See DECISIONS.md D-011.
  update public.product_batches b
     set qty = b.qty + (coalesce(new.qty, 0) + coalesce(new.free_qty, 0)),
         updated_at = now()
   where b.id = new.batch_id
     and b.pharmacy_id = new.pharmacy_id;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. stock_apply_adjustment()
--    Applies a stock_adjustments row to its batch in the same transaction, so
--    the audit row and the quantity can never disagree. qty is always positive
--    and adjustment_type carries the direction (00008 line 8).
-- ---------------------------------------------------------------------------
create or replace function public.stock_apply_adjustment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer;
begin
  -- A product-level adjustment carries no batch, so there is no balance to
  -- move: product_batches.qty is the only stock there is. It stays recorded.
  if new.batch_id is null then
    return new;
  end if;

  -- The trailing OR makes a decrease that would drive the batch negative match
  -- no row at all, which the row_count check below turns into a hard error -
  -- the same guard style as stock_update_on_sale() in 00010.
  update public.product_batches b
     set qty = b.qty + case
                         when new.adjustment_type = 'increase' then new.qty
                         else -new.qty
                       end,
         updated_at = now()
   where b.id = new.batch_id
     and b.pharmacy_id = new.pharmacy_id
     and (new.adjustment_type = 'increase' or b.qty >= new.qty);

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    raise exception 'stock adjustment % would take batch % below zero',
      new.id, new.batch_id
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. stock_update_on_purchase_return()
--    Returns remove stock immediately. Named after the shipped
--    stock_update_on_sale() it mirrors; purchase_return_items has no free_qty
--    column, so the decrement is qty only.
-- ---------------------------------------------------------------------------
create or replace function public.stock_update_on_purchase_return()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer;
begin
  if new.batch_id is null then
    return new;
  end if;

  update public.product_batches b
     set qty = b.qty - coalesce(new.qty, 0),
         updated_at = now()
   where b.id = new.batch_id
     and b.pharmacy_id = new.pharmacy_id
     and b.qty >= coalesce(new.qty, 0);

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    raise exception 'insufficient stock in batch % for purchase return item %',
      new.batch_id, new.id
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Attach the triggers
--    All five are idempotent via drop trigger if exists. The two purchase
--    triggers sit on the same event and fire in name order
--    (trg_ledger_auto_entry_purchase, then trg_stock_apply_purchase); they
--    touch different tables and share no state, so the order is immaterial.
-- ---------------------------------------------------------------------------
drop trigger if exists trg_ledger_auto_entry_purchase on public.purchases;
create trigger trg_ledger_auto_entry_purchase
  after insert or update of status on public.purchases
  for each row execute function public.ledger_auto_entry_purchase();

drop trigger if exists trg_stock_apply_purchase on public.purchases;
create trigger trg_stock_apply_purchase
  after insert or update of status on public.purchases
  for each row execute function public.stock_apply_purchase();

drop trigger if exists trg_stock_apply_purchase_item on public.purchase_items;
create trigger trg_stock_apply_purchase_item
  after insert on public.purchase_items
  for each row execute function public.stock_apply_purchase_item();

drop trigger if exists trg_stock_apply_adjustment on public.stock_adjustments;
create trigger trg_stock_apply_adjustment
  after insert on public.stock_adjustments
  for each row execute function public.stock_apply_adjustment();

drop trigger if exists trg_stock_update_on_purchase_return on public.purchase_return_items;
create trigger trg_stock_update_on_purchase_return
  after insert on public.purchase_return_items
  for each row execute function public.stock_update_on_purchase_return();

-- ---------------------------------------------------------------------------
-- 8. Indexes the Phase 1/2 read paths need
-- ---------------------------------------------------------------------------

-- Phase 1 product search asks for `name ilike %x% or generic_name ilike %x% or
-- barcode ilike %x%`. Migration 00009 only indexes (pharmacy_id, lower(name))
-- and a partial barcode index, so the generic_name branch was a sequential
-- scan. Trigram indexes serve infix ilike on both text columns. pg_trgm is
-- already installed (migration 0001) and already used by product_aliases.
create index if not exists products_name_trgm_idx
  on public.products using gin (name gin_trgm_ops);

create index if not exists products_generic_name_trgm_idx
  on public.products using gin (generic_name gin_trgm_ops);

-- Alias write path. product_aliases carried only plain indexes (00009), so the
-- alias tab could not upsert at all: PostgREST's `on_conflict` target needs a
-- unique index over real columns. supplier_id stays nullable on purpose: a row
-- with no supplier is a pharmacy-wide alias, not one tied to a distributor.
--
-- The sentence that stood here claimed NULL-supplier rows "never conflict", and
-- called that the right behaviour. They do not conflict under NULLS DISTINCT -
-- which was the bug rather than the intent: it made the second manual alias for
-- one printed text a duplicate row instead of an update, while
-- `ProductsRepository.addAlias` documented the opposite. Migration 00030
-- rebuilds this index NULLS NOT DISTINCT and closes it (open item N-5). The
-- statement below is left exactly as applied, and points forward the way 00010
-- points at 00015 (D-013).
create unique index if not exists product_aliases_pharmacy_supplier_normalized_key
  on public.product_aliases (pharmacy_id, supplier_id, normalized_name);
