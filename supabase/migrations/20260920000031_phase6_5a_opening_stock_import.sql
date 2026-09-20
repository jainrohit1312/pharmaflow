-- Migration: 20260920000031_phase6_5a_opening_stock_import | Purpose: the one-time
-- Marg opening-stock import - the schema it writes, the two tables that audit it,
-- and the three functions the app calls.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: if-not-exists tables/columns/indexes, drop-policy-if-exists before
-- every policy, create-or-replace functions/views, guarded grants.
--
-- What this migration is, and what it deliberately is not
-- -------------------------------------------------------
-- It is the way 314 catalogue rows and their opening quantities enter a pharmacy
-- that has been running on Marg until now: one product, one batch, one audit row
-- each. Opening stock has **no tax event and no supplier**, so this file writes
-- no purchase, no purchase item, no ledger entry and no payment - it creates
-- products (only where missing) and batches, and nothing else. It touches no
-- billing RPC and no stock trigger: `checkout_sale` and the Phase 2/3 automation
-- are untouched, and a batch written here is an ordinary batch afterwards, FEFO
-- and all.
--
-- The one structural concession opening stock forces is that **unknown is not a
-- value**: 145 of the owner's rows have no expiry date and 138 have no batch
-- number, and the previous schema could not represent either honestly -
-- `product_batches.expiry_date` was NOT NULL (a placeholder date would have been
-- invented data) and a batch number had no way to say "the source had none". So
-- `expiry_date` becomes nullable and a batch carries `is_unknown_batch`. The
-- client renders the first as "unknown expiry"; the second is what tells a user
-- that a number was generated rather than printed on a box.
--
-- Tenant model: both new tables carry `pharmacy_id` and are reachable only by the
-- owner of that pharmacy (D-004). The write path is the RPC alone - neither table
-- has an INSERT/UPDATE/DELETE policy, so a client cannot fabricate an audit row
-- that claims a committed import it never made. The RPCs are SECURITY DEFINER and
-- re-derive the tenant from `get_my_pharmacy_id()`, never from a parameter.

-- ---------------------------------------------------------------------------
-- 1. products - the GST slab, which today has no home
--
--    GST is stored per document line (`purchase_items.gst_percent`,
--    `sale_items.gst_percent`), and nothing in the schema has ever said what a
--    *product's* slab is - the POS just defaults every line to 12%
--    (`defaultSaleGstPercent`). The owner's answer for this catalogue is one
--    common slab: 5%, split 2.5% CGST + 2.5% SGST.
--
--    Nullable, and **no default**, deliberately. `default 5.00` would be
--    metadata-only DDL in PG 11+, but every pre-existing row would then *read*
--    as 5.00 - including the lines already bought and sold at 12%. Nullable keeps
--    "nobody has said" distinguishable from "5%", which is the same rule the
--    business already applies to hospital shares (D-068: 0% is a value, not an
--    absence). The import writes 5.00 explicitly on the products it creates.
--
--    Nothing reads these columns yet, and that is expected: until the bill and
--    the POS read the product's slab, the tax on an invoice is unchanged. They
--    are the owner's stated slab, stored for the pass that will use it.
-- ---------------------------------------------------------------------------
alter table public.products
  add column if not exists gst_percent  numeric(5,2),
  add column if not exists cgst_percent numeric(5,2),
  add column if not exists sgst_percent numeric(5,2);

comment on column public.products.gst_percent is
  'The product''s total GST rate (e.g. 5.00). NULL means no slab has been recorded for this product yet - it is not a rate of zero. Written by the opening-stock import; nothing reads it until the bill and the POS do.';
comment on column public.products.cgst_percent is
  'Central GST share of gst_percent (half of it for an intra-state supply). NULL when no slab is recorded.';
comment on column public.products.sgst_percent is
  'State GST share of gst_percent. NULL when no slab is recorded.';

-- ---------------------------------------------------------------------------
-- 2. product_batches - an unknown expiry, and an unknown batch number
--
--    `expiry_date` was `not null` (migration 00004 line 66) and stays the
--    business default: the GRN reader requires an expiry and the FEFO/expiry
--    alerting both read it. Dropping NOT NULL makes NULL mean exactly one thing -
--    "the source did not say" - and the import never invents a date to satisfy a
--    constraint. A missing date cannot be reported as 'safe' by expiry_status
--    any more either; see section 3.
--
--    `batch_no` stays NOT NULL: the import generates a stable internal identity
--    for a blank one (`OPENING-<first 8 of the product uuid>`) rather than
--    storing an empty string, so the unique key (pharmacy_id, product_id,
--    batch_no) still says what it means. `is_unknown_batch` is what records that
--    the number was generated - the prefix is a convenience, not the contract.
-- ---------------------------------------------------------------------------
alter table public.product_batches
  add column if not exists is_unknown_batch boolean not null default false;

alter table public.product_batches
  alter column expiry_date drop not null;

comment on column public.product_batches.expiry_date is
  'Expiry as printed on the pack. NULL means the source did not record one (opening stock imported from Marg); it never means "no expiry".';
comment on column public.product_batches.is_unknown_batch is
  'True when this batch has no batch number of its own and carries a generated OPENING-<uuid8> identity instead.';

-- ---------------------------------------------------------------------------
-- 3. batch_status - replaced, not just extended
--
--    The view was written as `select b.*` (migration 00013), and Postgres
--    *expands* the star when the view is created - which is why the view has
--    never carried `landed_cost_per_unit` (added in 00016 and invisible here
--    ever since; that is open item D-021's whole point). Two consequences:
--
--      * a new column on product_batches does NOT appear in this view, so the
--        `is_unknown_batch` above reaches nothing until this view is replaced;
--      * `create or replace` cannot insert a column in the middle of a view's
--        list (`b.*` would put the new column before `expiry_status`, and
--        position 13 changing from text to boolean is refused), so the columns
--        are now named explicitly. That makes the frozen list visible instead of
--        implicit - a future column on the table still will not appear here
--        without an edit, and now that is obvious from reading it.
--
--    `when b.expiry_date is null then 'unknown'` is new, and it is a real
--    behaviour change rather than a cosmetic one: with NULL now possible, the
--    old CASE would have fallen through to `else 'safe'` - reporting a batch
--    whose expiry nobody knows as having more than 90 days of shelf life. Rows
--    with no expiry are excluded from the expiry dashboard's three buckets by
--    the filter its query builds from `expiringBuckets`, which is the honest
--    outcome. `expiryStatusFromDb` in the app maps anything it does not
--    recognise to `ExpiryStatus.safe` (see the ledger's own note in
--    `data/models/batch_status.dart`), so an 'unknown' row shows the safe badge
--    until the inventory screens learn the label - recorded as an open item, and
--    deliberately not fixed here because this chunk does not own those screens.
-- ---------------------------------------------------------------------------
create or replace view public.batch_status
with (security_invoker = true) as
select
  b.id,
  b.pharmacy_id,
  b.product_id,
  b.batch_no,
  b.mfg_date,
  b.expiry_date,
  b.qty,
  b.purchase_rate,
  b.mrp,
  b.selling_rate,
  b.created_at,
  b.updated_at,
  case
    when b.expiry_date is null                then 'unknown'
    when b.expiry_date < current_date         then 'expired'
    when b.expiry_date <= current_date + 30   then 'critical'
    when b.expiry_date <= current_date + 90   then 'warning'
    else 'safe'
  end as expiry_status,
  b.is_unknown_batch
from public.product_batches b;

-- ---------------------------------------------------------------------------
-- 4. import_jobs - one row per committed import, and the idempotency key
--
--    `unique (pharmacy_id, content_fingerprint)` is the whole of the "re-upload
--    the same file is a no-op" rule: the second upload conflicts on the key and
--    is answered with the first job's id instead of writing a second set of
--    batches. Because the insert happens inside the committing transaction, two
--    concurrent identical uploads serialise on that key - the second blocks
--    until the first commits, finds the conflict, and returns the first job.
--
--    `status` carries four values, of which **this migration's own path writes
--    exactly two**: 'pending' for the row as inserted, 'committed' when it
--    lands. 'failed' and 'rolled_back' are in the vocabulary for a future
--    partial-failure path and are unreachable here - a refused import raises and
--    takes its own job row down with it, so nothing survives to be marked. The
--    constraint documents the vocabulary rather than claiming it is all used.
--
--    `actor_id` follows the audit convention already in the schema
--    (`audit_logs.user_id`, `stock_adjustments.created_by`): a nullable FK to
--    profiles with `on delete set null`, so removing a colleague does not delete
--    the record of what they imported. The RPC refuses to run without an actor,
--    so in practice it is always populated.
-- ---------------------------------------------------------------------------
create table if not exists public.import_jobs (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references public.pharmacies(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  source_filename text not null,
  source_format text not null default 'csv'
    check (source_format in ('csv', 'xlsx')),
  content_fingerprint text not null,
  row_count int not null default 0,
  total_qty int not null default 0,
  total_cost numeric(14,2) not null default 0,
  status text not null default 'pending'
    check (status in ('pending', 'committed', 'failed', 'rolled_back')),
  error_message text,
  committed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint import_jobs_pharmacy_fingerprint_key
    unique (pharmacy_id, content_fingerprint)
);

comment on table public.import_jobs is
  'One row per opening-stock import: what was uploaded, when it committed, and the fingerprint that makes a second upload of the same content a no-op. Written by commit_opening_stock_import() only.';
comment on column public.import_jobs.content_fingerprint is
  'sha256 over the canonical rows (item name normalized, batch/expiry trimmed and lowered, rates at 2dp), sorted, so the same content in a different order or under a different filename is one job.';
comment on column public.import_jobs.status is
  'pending while the import is being written, committed when it lands. The other two values are reserved for a partial-failure path that does not exist: a refused import raises and rolls its own row back.';

-- ---------------------------------------------------------------------------
-- 5. import_job_rows - the audit trail, one row per source line
--
--    `product_id` / `batch_id` are nullable because the row exists on both sides
--    of the write, and both are `on delete set null` so the trail outlives the
--    objects it names (a deleted batch must not erase the record that it was
--    imported, which is the question an audit asks).
-- ---------------------------------------------------------------------------
create table if not exists public.import_job_rows (
  id uuid primary key default gen_random_uuid(),
  import_job_id uuid not null references public.import_jobs(id) on delete cascade,
  row_number int not null,
  raw_item_name text not null,
  raw_batch_no text,
  raw_expiry text,
  qty int not null,
  purchase_rate numeric(12,2) not null,
  mrp numeric(12,2) not null,
  product_id uuid references public.products(id) on delete set null,
  batch_id uuid references public.product_batches(id) on delete set null,
  action text not null check (action in ('created', 'matched', 'error')),
  error_note text,
  constraint import_job_rows_job_row_key unique (import_job_id, row_number)
);

comment on table public.import_job_rows is
  'The source line as read, kept beside what it wrote: raw_item_name/raw_batch_no/raw_expiry are the file''s own text, and product_id/batch_id are what the import made of it. This is what the audit CSV is rendered from. The unique key below is also the index both readers (the join from get_import_job and the row_number lookup) use, so no second index is added for it.';

-- ---------------------------------------------------------------------------
-- 6. RLS - owner-only reads, and no write policy at all
--
--    The two tables are written exclusively by the SECURITY DEFINER RPC, which
--    runs as the owner and bypasses RLS. Granting INSERT/UPDATE to
--    `authenticated` would let a client write an import_jobs row claiming
--    `status = 'committed'` without importing anything, which is exactly the
--    audit record the owner would later trust - so there is deliberately no
--    write policy here, the same reasoning `notification_logs` uses for having
--    no delete policy.
--
--    import_job_rows is scoped through its job: it carries no pharmacy_id, and
--    the EXISTS clause is evaluated as the caller, so import_jobs' own select
--    policy applies inside it too.
-- ---------------------------------------------------------------------------
alter table public.import_jobs      enable row level security;
alter table public.import_job_rows  enable row level security;

drop policy if exists import_jobs_owner_select on public.import_jobs;
create policy import_jobs_owner_select on public.import_jobs
  for select using (
    pharmacy_id = public.get_my_pharmacy_id()
    and public.get_my_role() = 'owner'
  );

drop policy if exists import_job_rows_owner_select on public.import_job_rows;
create policy import_job_rows_owner_select on public.import_job_rows
  for select using (
    public.get_my_role() = 'owner'
    and exists (
      select 1
        from public.import_jobs j
       where j.id = import_job_rows.import_job_id
         and j.pharmacy_id = public.get_my_pharmacy_id()
    )
  );

-- ---------------------------------------------------------------------------
-- 7. opening_stock_classify() - the one reader of the source rows
--
--    Both the preview and the commit go through this function, which is the
--    point: a preview that classified differently from the commit would be worse
--    than no preview, and the matching rule (the existing
--    `normalize_product_name()`, which the alias matcher already uses) exists in
--    exactly one place.
--
--    It parses defensively rather than casting: a JSON `qty` of "14.5" or "" or
--    "-3" has to come back as a row-numbered sentence, not as a 22P02 from a
--    `::int` cast four frames down. Every field is read with `->>` and validated
--    with a regex *before* any cast, so the only numbers it ever casts are
--    numbers it has already accepted. It validates the whole file rather than
--    stopping at the first bad row, because an owner fixing a CSV wants the
--    whole list.
--
--    Outcomes per row: 'new' (no catalogue product normalizes the same),
--    'matched' (exactly one does), 'ambiguous' (more than one does - BLOCKED,
--    never auto-picked; two products of the same brand and different strength
--    must not be merged), 'error' (a field the import cannot accept).
--
--    A duplicate *name* within the file is an error too, and that one is a
--    property of opening stock rather than of the file format: the import
--    writes exactly one batch per product, so two rows naming one product would
--    either double its stock in two batches or silently drop a row. Refusing is
--    the honest outcome, and the note names both row numbers.
--
--    Returns {summary, rows, fingerprint}. The fingerprint is NULL when any row
--    failed, since there is no canonical content to name yet.
-- ---------------------------------------------------------------------------
create or replace function public.opening_stock_classify(
  p_pharmacy_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rows           jsonb := coalesce(p_rows, '[]'::jsonb);
  v_rec            record;
  v_number         int;
  v_name_raw       text;
  v_name           text;
  v_norm           text;
  v_batch_raw      text;
  v_expiry_raw     text;
  v_expiry         date;
  v_qty_txt        text;
  v_qty            int;
  v_rate_txt       text;
  v_rate           numeric(12,2);
  v_mrp_txt        text;
  v_mrp            numeric(12,2);
  v_note           text;
  v_matches        uuid[];
  v_match_names    text[];
  v_product_id     uuid;
  v_outcome        text;
  v_rows_out       jsonb := '[]'::jsonb;
  v_lines          text[] := array[]::text[];
  v_seen           jsonb := '{}'::jsonb;
  v_seen_row       int;
  v_row_count      int := 0;
  v_total_qty      bigint := 0;
  v_total_cost     numeric(14,2) := 0;
  v_new_count      int := 0;
  v_matched_count  int := 0;
  v_ambiguous      int := 0;
  v_zero_qty       int := 0;
  v_unknown_batch  int := 0;
  v_unknown_expiry int := 0;
  v_expired        int := 0;
  v_errors         int := 0;
  v_fingerprint    text;
begin
  for v_rec in
    select e.payload, e.rownum
      from jsonb_array_elements(v_rows) with ordinality as e(payload, rownum)
  loop
    v_number := v_rec.rownum::int;
    v_note := null;
    v_outcome := null;
    v_product_id := null;
    v_matches := null;
    v_match_names := null;
    v_qty := null;
    v_rate := null;
    v_mrp := null;
    v_expiry := null;

    v_name_raw   := coalesce(v_rec.payload ->> 'item_name', '');
    v_batch_raw  := trim(coalesce(v_rec.payload ->> 'batch_no', ''));
    v_expiry_raw := trim(coalesce(v_rec.payload ->> 'expiry_date', ''));
    v_qty_txt    := trim(coalesce(v_rec.payload ->> 'qty', ''));
    v_rate_txt   := trim(coalesce(v_rec.payload ->> 'purchase_rate', ''));
    v_mrp_txt    := trim(coalesce(v_rec.payload ->> 'mrp', ''));
    v_name       := trim(both ' ' from v_name_raw);

    -- ---- the item name: the only field that must not be blank
    if v_name = '' then
      v_note := 'item_name is blank';
    end if;

    -- ---- qty: a whole, non-negative number. Zero is valid (the owner has 53
    --      of them: a product that exists in the catalogue and holds no stock).
    if v_note is null then
      if v_qty_txt = '' then
        v_note := 'qty is missing';
      elsif v_qty_txt !~ '^[0-9]+$' then
        if v_qty_txt ~ '^-' then
          v_note := format('qty "%s" is negative', v_qty_txt);
        else
          v_note := format('qty "%s" is not a whole number', v_qty_txt);
        end if;
      elsif length(v_qty_txt) > 9 then
        v_note := format('qty "%s" is out of range', v_qty_txt);
      else
        v_qty := v_qty_txt::int;
      end if;
    end if;

    -- ---- purchase_rate and mrp: at most two decimals, which is what the
    --      columns hold. Zero cost is valid (the owner's PANTOP row) - it is a
    --      rate of zero, not a missing one, and only a missing one is refused.
    if v_note is null then
      if v_rate_txt = '' then
        v_note := 'purchase_rate is missing';
      elsif v_rate_txt !~ '^[0-9]+(\.[0-9]{1,2})?$' then
        if v_rate_txt ~ '^-' then
          v_note := format('purchase_rate "%s" is negative', v_rate_txt);
        else
          v_note := format(
            'purchase_rate "%s" is not a number with at most two decimals',
            v_rate_txt
          );
        end if;
      else
        v_rate := v_rate_txt::numeric(12,2);
      end if;
    end if;

    if v_note is null then
      if v_mrp_txt = '' then
        v_note := 'mrp is missing';
      elsif v_mrp_txt !~ '^[0-9]+(\.[0-9]{1,2})?$' then
        if v_mrp_txt ~ '^-' then
          v_note := format('mrp "%s" is negative', v_mrp_txt);
        else
          v_note := format(
            'mrp "%s" is not a number with at most two decimals',
            v_mrp_txt
          );
        end if;
      else
        v_mrp := v_mrp_txt::numeric(12,2);
      end if;
    end if;

    -- ---- expiry: absent is valid and means unknown; present but unreadable is
    --      refused rather than dropped, because silently discarding a date the
    --      owner wrote would hide a broken column in their export.
    if v_note is null and v_expiry_raw <> '' then
      if v_expiry_raw !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_note := format('expiry_date "%s" is not YYYY-MM-DD', v_expiry_raw);
      else
        begin
          v_expiry := v_expiry_raw::date;
        exception
          when others then
            v_note := format('expiry_date "%s" is not a real date', v_expiry_raw);
        end;
      end if;
    end if;

    -- ---- matching, and the one-batch-per-product rule
    if v_note is null then
      v_norm := public.normalize_product_name(v_name);

      v_seen_row := nullif(v_seen ->> v_norm, '')::int;
      if v_seen_row is not null then
        v_note := format(
          'this product name is already row %s - opening stock writes one batch per product',
          v_seen_row
        );
        v_outcome := 'error';
      else
        v_seen := v_seen || jsonb_build_object(v_norm, v_number);

        select array_agg(p.id order by p.created_at, p.id),
               array_agg(p.name order by p.created_at, p.id)
          into v_matches, v_match_names
          from public.products p
         where p.pharmacy_id = p_pharmacy_id
           and public.normalize_product_name(p.name) = v_norm;

        if coalesce(array_length(v_matches, 1), 0) = 0 then
          v_outcome := 'new';
        elsif array_length(v_matches, 1) = 1 then
          v_outcome := 'matched';
          v_product_id := v_matches[1];
        else
          v_outcome := 'ambiguous';
          v_note := format(
            '%s catalogue products share this name - resolve it in the catalogue first',
            array_length(v_matches, 1)
          );
        end if;
      end if;
    end if;

    if v_outcome = 'error' or (v_outcome is null and v_note is not null) then
      v_outcome := 'error';
    end if;

    v_row_count := v_row_count + 1;

    if v_outcome = 'error' then
      v_errors := v_errors + 1;
    else
      v_total_qty := v_total_qty + v_qty;
      v_total_cost := v_total_cost + (v_qty * v_rate);

      if v_outcome = 'new' then
        v_new_count := v_new_count + 1;
      elsif v_outcome = 'matched' then
        v_matched_count := v_matched_count + 1;
      else
        v_ambiguous := v_ambiguous + 1;
      end if;

      if v_qty = 0 then
        v_zero_qty := v_zero_qty + 1;
      end if;
      if v_batch_raw = '' then
        v_unknown_batch := v_unknown_batch + 1;
      end if;
      if v_expiry_raw = '' then
        v_unknown_expiry := v_unknown_expiry + 1;
      elsif v_expiry < current_date then
        v_expired := v_expired + 1;
      end if;

      -- The canonical line the fingerprint is taken over. The name is
      -- normalized, the batch number and the raw expiry are lowercased,
      -- trimmed and compared as text (leading zeros are the point of the
      -- column), and the money is formatted at the precision the columns
      -- store, so a re-export that differs only in whitespace, case or
      -- `27.5` vs `27.50` is the same content.
      v_lines := v_lines || (
        v_norm || '|'
        || lower(v_batch_raw) || '|'
        || lower(v_expiry_raw) || '|'
        || v_qty::text || '|'
        || to_char(v_rate, 'FM999999990.00') || '|'
        || to_char(v_mrp, 'FM999999990.00')
      );
    end if;

    v_rows_out := v_rows_out || jsonb_build_object(
      'row_number', v_number,
      'raw_item_name', v_name_raw,
      'item_name', v_name,
      'normalized_name', v_norm,
      'raw_batch_no', v_batch_raw,
      'raw_expiry', v_expiry_raw,
      'qty', v_qty,
      'purchase_rate', v_rate,
      'mrp', v_mrp,
      'expiry_date', v_expiry,
      'is_unknown_batch', (v_batch_raw = ''),
      'is_expired', case
                      when v_expiry is null then false
                      else v_expiry < current_date
                    end,
      'outcome', v_outcome,
      'product_id', v_product_id,
      'product_names', to_jsonb(v_match_names),
      'error_note', v_note
    );
  end loop;

  if v_errors = 0 and v_row_count > 0 then
    select encode(digest(string_agg(line, E'\n' order by line), 'sha256'), 'hex')
      into v_fingerprint
      from unnest(v_lines) as line;
  end if;

  return jsonb_build_object(
    'fingerprint', v_fingerprint,
    'summary', jsonb_build_object(
      'row_count', v_row_count,
      'total_qty', v_total_qty,
      'total_cost', v_total_cost,
      'new_product_count', v_new_count,
      'matched_product_count', v_matched_count,
      'ambiguous_row_count', v_ambiguous,
      'zero_qty_row_count', v_zero_qty,
      'unknown_batch_row_count', v_unknown_batch,
      'unknown_expiry_row_count', v_unknown_expiry,
      'expired_row_count', v_expired,
      'error_row_count', v_errors
    ),
    'rows', v_rows_out
  );
end;
$$;

comment on function public.opening_stock_classify(uuid, jsonb) is
  'Validates, normalizes and classifies opening-stock rows for one pharmacy. Shared by preview_opening_stock() and commit_opening_stock_import() so a preview can never classify differently from the commit. Internal: no role is granted EXECUTE.';

-- ---------------------------------------------------------------------------
-- 8. preview_opening_stock() - what the screen shows before anything is written
--
--    Read-only, and the only function here a client calls before committing. It
--    also answers "has this exact content already been imported?", which is what
--    lets the screen say so before the owner presses the button rather than
--    after - the idempotency rule is only useful if the person re-uploading the
--    same file can see it was already done.
-- ---------------------------------------------------------------------------
create or replace function public.preview_opening_stock(p_rows jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_classify jsonb;
  v_existing jsonb;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  -- Owner-only, and enforced here rather than by RLS: this function is SECURITY
  -- DEFINER, so RLS does not apply inside it. The import is a one-time,
  -- whole-catalogue write, so it is the owner's action and nobody else's.
  if public.get_my_role() is distinct from 'owner' then
    raise exception 'only the owner of this pharmacy may import opening stock'
      using errcode = 'insufficient_privilege';
  end if;

  v_classify := public.opening_stock_classify(v_pharmacy, p_rows);

  if v_classify ->> 'fingerprint' is not null then
    select jsonb_build_object(
             'job_id', j.id,
             'row_count', j.row_count,
             'status', j.status,
             'committed_at', j.committed_at
           )
      into v_existing
      from public.import_jobs j
     where j.pharmacy_id = v_pharmacy
       and j.content_fingerprint = v_classify ->> 'fingerprint';
  end if;

  return v_classify || jsonb_build_object('existing_job', v_existing);
end;
$$;

comment on function public.preview_opening_stock(jsonb) is
  'Validates opening-stock rows and answers with the summary, the per-row classification and the id of an already-committed job with identical content. Writes nothing.';

-- ---------------------------------------------------------------------------
-- 9. commit_opening_stock_import() - the import itself, all or nothing
--
--    Re-classifies the rows rather than trusting a preview: the payload is the
--    rows, not a verdict, and the catalogue can have moved between the two
--    calls. Any refused row raises before the first write, so a bad file changes
--    nothing - which is also why a refusal names *every* bad row and its line
--    number in one message instead of failing on the first.
--
--    The job row is inserted before the loop with `on conflict do nothing`, and
--    that statement is the concurrency control: a second identical upload blocks
--    on the unique key until this transaction ends, then finds the conflict and
--    is answered with the committed job instead of writing anything. Nothing
--    claims success before the commit - the answer is built from rows this
--    transaction wrote, and the function is still inside it.
-- ---------------------------------------------------------------------------
create or replace function public.commit_opening_stock_import(
  p_rows jsonb,
  p_filename text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy    uuid := public.get_my_pharmacy_id();
  v_actor       uuid := auth.uid();
  v_filename    text := nullif(trim(coalesce(p_filename, '')), '');
  v_classify    jsonb;
  v_summary     jsonb;
  v_fingerprint text;
  v_job_id      uuid;
  v_existing    public.import_jobs;
  v_row         jsonb;
  v_notes       text;
  v_bad_total   int;
  v_notes_shown int;
  v_product_id  uuid;
  v_batch_id    uuid;
  v_batch_no    text;
  v_created     int := 0;
  v_matched     int := 0;
  v_batches     int := 0;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  if v_actor is null then
    raise exception 'an import needs a signed-in actor'
      using errcode = 'insufficient_privilege';
  end if;

  if public.get_my_role() is distinct from 'owner' then
    raise exception 'only the owner of this pharmacy may import opening stock'
      using errcode = 'insufficient_privilege';
  end if;

  if v_filename is null then
    raise exception 'an import needs the source file name'
      using errcode = 'check_violation';
  end if;

  v_classify := public.opening_stock_classify(v_pharmacy, p_rows);
  v_summary := v_classify -> 'summary';
  v_fingerprint := v_classify ->> 'fingerprint';

  if (v_summary ->> 'row_count')::int = 0 then
    raise exception 'the import has no rows'
      using errcode = 'check_violation';
  end if;

  -- An ambiguous row blocks exactly as a bad one does, and for a stronger
  -- reason: its name matches more than one catalogue product, and the only safe
  -- answer is the owner's. Creating a product here instead would leave the
  -- catalogue with two rows for one medicine, so this is where rule 7's "do not
  -- auto-pick" is enforced rather than trusted. Both kinds are refused in one
  -- message listing every affected line, because an owner fixing a CSV needs the
  -- whole list - capped, because a systematically broken file could otherwise
  -- produce three hundred lines of the same complaint.
  v_bad_total := (v_summary ->> 'error_row_count')::int
               + (v_summary ->> 'ambiguous_row_count')::int;

  if v_bad_total > 0 then
    select string_agg(t.note, E'\n' order by t.num), count(*)
      into v_notes, v_notes_shown
      from (
        select (e.value ->> 'row_number')::int as num,
               format(
                 'row %s: %s',
                 e.value ->> 'row_number',
                 coalesce(
                   nullif(e.value ->> 'error_note', ''),
                   'this row cannot be imported'
                 )
               ) as note
          from jsonb_array_elements(v_classify -> 'rows') as e(value)
         where e.value ->> 'outcome' in ('error', 'ambiguous')
         order by 1
         limit 25
      ) t;

    if v_bad_total > v_notes_shown then
      v_notes := v_notes
              || E'\n'
              || format('...and %s more', v_bad_total - v_notes_shown);
    end if;

    raise exception
      E'the opening stock import was refused - % row(s) cannot be imported:\n%',
      v_bad_total, v_notes
      using errcode = 'check_violation';
  end if;

  -- Idempotency. Not "select then insert": the insert is what arbitrates a
  -- concurrent identical upload, and the unique key is the arbiter.
  insert into public.import_jobs (
    pharmacy_id,
    actor_id,
    source_filename,
    source_format,
    content_fingerprint,
    row_count,
    total_qty,
    total_cost,
    status
  )
  values (
    v_pharmacy,
    v_actor,
    v_filename,
    'csv',
    v_fingerprint,
    (v_summary ->> 'row_count')::int,
    (v_summary ->> 'total_qty')::int,
    (v_summary ->> 'total_cost')::numeric(14,2),
    'pending'
  )
  on conflict (pharmacy_id, content_fingerprint) do nothing
  returning id into v_job_id;

  if v_job_id is null then
    select *
      into v_existing
      from public.import_jobs j
     where j.pharmacy_id = v_pharmacy
       and j.content_fingerprint = v_fingerprint;

    if v_existing.id is null then
      raise exception 'the import could not be recorded - try again'
        using errcode = 'check_violation';
    end if;

    return jsonb_build_object(
      'committed', true,
      'idempotent', true,
      'job_id', v_existing.id,
      'product_count',
        (select count(distinct r.product_id)
           from public.import_job_rows r
          where r.import_job_id = v_existing.id),
      'products_created', 0,
      'products_matched',
        (select count(*)
           from public.import_job_rows r
          where r.import_job_id = v_existing.id
            and r.action = 'matched'),
      'batch_count',
        (select count(*)
           from public.import_job_rows r
          where r.import_job_id = v_existing.id),
      'qty_total', v_existing.total_qty,
      'cost_total', v_existing.total_cost
    );
  end if;

  for v_row in select e.value from jsonb_array_elements(v_classify -> 'rows') as e(value)
  loop
    v_product_id := nullif(v_row ->> 'product_id', '')::uuid;
    if v_product_id is null then
      -- A product the catalogue does not have yet, created with the name and
      -- the owner's slab and nothing else: generic_name, hsn_code, manufacturer
      -- and schedule_type are the owner's to fill in later, and schedule_type
      -- keeps its own 'OTC' default.
      insert into public.products (
        pharmacy_id, name, gst_percent, cgst_percent, sgst_percent
      )
      values (
        v_pharmacy, v_row ->> 'item_name', 5.00, 2.50, 2.50
      )
      returning id into v_product_id;

      v_created := v_created + 1;
    else
      v_matched := v_matched + 1;
    end if;

    -- A blank batch number gets a stable internal identity rather than an empty
    -- string, so the (pharmacy, product, batch_no) key keeps meaning what it
    -- says and the row can be referred to.
    v_batch_no := coalesce(
      nullif(v_row ->> 'raw_batch_no', ''),
      'OPENING-' || left(v_product_id::text, 8)
    );

    if exists (
      select 1
        from public.product_batches b
       where b.pharmacy_id = v_pharmacy
         and b.product_id = v_product_id
         and b.batch_no = v_batch_no
    ) then
      raise exception
        'row %: batch % already exists for this product - opening stock writes a batch once',
        (v_row ->> 'row_number')::int, v_batch_no
        using errcode = 'unique_violation';
    end if;

    -- landed_cost_per_unit = purchase_rate: there is no freight and no free
    -- quantity on opening stock, which is the case D-012's formula collapses to
    -- (paid_amount / units_received). Leaving it NULL would also work for the
    -- valuation view, which falls back to purchase_rate - but writing it says
    -- the cost was considered rather than forgotten.
    insert into public.product_batches (
      pharmacy_id,
      product_id,
      batch_no,
      expiry_date,
      qty,
      purchase_rate,
      mrp,
      landed_cost_per_unit,
      is_unknown_batch
    )
    values (
      v_pharmacy,
      v_product_id,
      v_batch_no,
      nullif(v_row ->> 'expiry_date', '')::date,
      (v_row ->> 'qty')::int,
      (v_row ->> 'purchase_rate')::numeric(12,2),
      (v_row ->> 'mrp')::numeric(12,2),
      (v_row ->> 'purchase_rate')::numeric(12,2),
      (v_row ->> 'is_unknown_batch')::boolean
    )
    returning id into v_batch_id;

    insert into public.import_job_rows (
      import_job_id,
      row_number,
      raw_item_name,
      raw_batch_no,
      raw_expiry,
      qty,
      purchase_rate,
      mrp,
      product_id,
      batch_id,
      action
    )
    values (
      v_job_id,
      (v_row ->> 'row_number')::int,
      coalesce(v_row ->> 'raw_item_name', ''),
      nullif(v_row ->> 'raw_batch_no', ''),
      nullif(v_row ->> 'raw_expiry', ''),
      (v_row ->> 'qty')::int,
      (v_row ->> 'purchase_rate')::numeric(12,2),
      (v_row ->> 'mrp')::numeric(12,2),
      v_product_id,
      v_batch_id,
      case when (v_row ->> 'outcome') = 'matched' then 'matched' else 'created' end
    );

    v_batches := v_batches + 1;
  end loop;

  update public.import_jobs
     set status = 'committed',
         committed_at = now()
   where id = v_job_id;

  return jsonb_build_object(
    'committed', true,
    'idempotent', false,
    'job_id', v_job_id,
    'product_count', v_created + v_matched,
    'products_created', v_created,
    'products_matched', v_matched,
    'batch_count', v_batches,
    'qty_total', (v_summary ->> 'total_qty')::int,
    'cost_total', (v_summary ->> 'total_cost')::numeric
  );
end;
$$;

comment on function public.commit_opening_stock_import(jsonb, text) is
  'Writes one batch per row (and a product where the catalogue has none) for the owner of the caller''s pharmacy, plus the import_jobs/import_job_rows audit trail. Refuses the whole file on any bad row, and answers with the existing job when identical content has already been committed.';

-- ---------------------------------------------------------------------------
-- 10. get_import_job() - reading an import back, for the audit view and its CSV
--
--    Returns the job and its rows with the names they wrote (product name, batch
--    number, expiry), because the audit CSV is rendered from this and a trail of
--    bare uuids would not be readable. Scoped by tenant and owner like the rest.
-- ---------------------------------------------------------------------------
create or replace function public.get_import_job(p_job_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_job      public.import_jobs;
  v_rows     jsonb;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  if public.get_my_role() is distinct from 'owner' then
    raise exception 'only the owner of this pharmacy may read an import job'
      using errcode = 'insufficient_privilege';
  end if;

  select *
    into v_job
    from public.import_jobs j
   where j.id = p_job_id
     and j.pharmacy_id = v_pharmacy;

  if v_job.id is null then
    raise exception 'that import job is not in this pharmacy'
      using errcode = 'no_data_found';
  end if;

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'row_number', r.row_number,
               'raw_item_name', r.raw_item_name,
               'raw_batch_no', r.raw_batch_no,
               'raw_expiry', r.raw_expiry,
               'qty', r.qty,
               'purchase_rate', r.purchase_rate,
               'mrp', r.mrp,
               'product_id', r.product_id,
               'product_name', p.name,
               'batch_id', r.batch_id,
               'batch_no', b.batch_no,
               'expiry_date', b.expiry_date,
               'action', r.action,
               'error_note', r.error_note
             )
             order by r.row_number
           ),
           '[]'::jsonb
         )
    into v_rows
    from public.import_job_rows r
    left join public.products p        on p.id = r.product_id
    left join public.product_batches b on b.id = r.batch_id
   where r.import_job_id = v_job.id;

  return jsonb_build_object(
    'job', jsonb_build_object(
      'job_id', v_job.id,
      'source_filename', v_job.source_filename,
      'source_format', v_job.source_format,
      'content_fingerprint', v_job.content_fingerprint,
      'row_count', v_job.row_count,
      'total_qty', v_job.total_qty,
      'total_cost', v_job.total_cost,
      'status', v_job.status,
      'error_message', v_job.error_message,
      'committed_at', v_job.committed_at,
      'created_at', v_job.created_at,
      'actor_id', v_job.actor_id
    ),
    'rows', v_rows
  );
end;
$$;

comment on function public.get_import_job(uuid) is
  'One import job with its rows, as written - what the success screen and its audit CSV read.';

-- ---------------------------------------------------------------------------
-- 11. Execution grants
--
--     `revoke ... from anon, public` is not redundant with the absence of a
--     grant: Postgres grants EXECUTE to PUBLIC on a new function, and Supabase
--     grants directly to anon and authenticated, so a revoke aimed only at
--     PUBLIC leaves anon's own grant in place (migration 00018's finding).
--
--     opening_stock_classify() gets no grant at all: it is the shared reader of
--     the payload, reachable only from the two functions that gate on the owner
--     and the tenant first. Its callers are SECURITY DEFINER, so they keep
--     EXECUTE on it while no role has it.
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.preview_opening_stock(jsonb) to authenticated';
  execute 'revoke execute on function public.preview_opening_stock(jsonb) from anon, public';

  execute 'grant execute on function public.commit_opening_stock_import(jsonb, text) to authenticated';
  execute 'revoke execute on function public.commit_opening_stock_import(jsonb, text) from anon, public';

  execute 'grant execute on function public.get_import_job(uuid) to authenticated';
  execute 'revoke execute on function public.get_import_job(uuid) from anon, public';

  execute 'revoke execute on function public.opening_stock_classify(uuid, jsonb) from anon, authenticated, public';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
