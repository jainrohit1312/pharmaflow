-- Migration: 20260921000046_phase6_5c_approval_master_data | Purpose: put the product master, the
-- customer/patient master and the expense notification behind the owner's rail (chunk 5).
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create-or-replace functions, a guarded drop-and-create for the one function whose
-- return type changes, guarded revoke/grant, drop-trigger-if-exists.
--
-- The owner's policy this chunk completes (D-085, 2026-09-21)
-- ----------------------------------------------------------
-- "Any modification and deletion from staff" needs his approval; "only sale bill is allowed without
-- approval". Asked the two questions the last chunk left, he settled:
--
--   * **Expenses are NOT gated** - *"expenses donot need approvals only notification, email,
--     whatsapp notification"*. Recording one stays free for every role, and he is TOLD instead
--     (section 8). `expense_create` / `expense_edit` / `expense_delete` are RETIRED: they stay
--     declared in the enum, because a value cannot be dropped, and section 9 says in the type's own
--     comment that no chunk is coming for them.
--   * **`sale_edit` and `sale_cancel` ARE gated** - *"sale edit/ sale cancle need approval from
--     owner"*. Neither act exists yet (nothing writes `sales.status = 'cancelled'`, and there is no
--     sale-edit screen), so what a cancellation does to already-posted stock and money is a design
--     question put back to him rather than guessed at here. See the enum's comment in section 9.
--
-- Why the product master and the customer master are REQUESTED, not STAGED as a pending row
-- ---------------------------------------------------------------------------------------------
-- This module now has two shapes and the brief named both. A purchase is STAGED (`pending_approval`)
-- because it has a *life* - it is drafted, ordered, received - and because the posting trigger waits
-- on a status a screen can show. A return is REQUESTED because it is a single event with no status
-- to wait in. The product and customer masters are REQUESTED, and the reason is sharper than "they
-- look like a return":
--
--   * **A new product cannot be staged at all.** Nothing can reference a product that does not
--     exist, so there is no document to wait as; the row either exists or it does not, and "exists
--     but unapproved" is not a state anything in this schema can express. This is the brief's own
--     case ("a brand-new product is closer to a return").
--   * **An edit of a product that has history has no status to wait in either.** A staged edit would
--     have to write the new values onto the live row - making the change real before the owner
--     answered - or keep a second copy of the row somewhere, which is a second source of truth for
--     one product. There is no `pending_approval` for a product, and inventing one would put a
--     half-edited row in front of the counter. Requesting the whole document instead means a refusal
--     is a no-op: nothing was written, so there is nothing to put back - which is *better* than the
--     purchase's pre-image restore, not a compromise on it.
--   * `is_active` is the soft delete (D-083's answer) and it is one boolean on that same row, so a
--     deletion is the same shape as an edit.
--
-- So one shape, four action types, and no third mechanism. What the owner reads is the document the
-- payload carries, and what approving does is run the very write the staff used to run.
--
-- `save_product()` is ONE door to three tables
-- --------------------------------------------
-- The client writes `products`, `product_batches` and `product_aliases` straight through PostgREST
-- today, so section 7 revokes all three in this same migration - the rule chunk 3 set, never before
-- the request path. `save_product()` is the replacement door, and it is ONE function for the whole
-- master because that is how the form and the detail screen already behave: a create, an edit, a
-- deletion, a restore and both alias acts are all "change one product's master record", and the
-- action type is DERIVED from the payload rather than chosen by the caller (`product_create` with no
-- `product_id`, `product_delete` when it deactivates an active product, `product_edit` otherwise).
-- Deriving it server-side is what stops a client naming a gentler type for a harsher act.
--
-- `product_batches` gets the revoke and NO door, on purpose
-- --------------------------------------------------------
-- Nothing in the application writes `product_batches`: the Flutter repository reads it (a batch's
-- remaining quantity) and never writes it, the GRN writes it through `save_purchase()`, and the
-- opening-stock import through its own RPC - both SECURITY DEFINER, both unaffected by a revoke. The
-- hole D-083 recorded is therefore a pure session hole: a holder of a token could move a batch's
-- `qty` by hand, which is a stock adjustment in disguise and is exactly what `stock_adjustment` was
-- gated for. Closing it needs no request path because there is no screen to re-route, and that is
-- stated here rather than left as an unexplained revoke.
--
-- The customer master: which rule won, and what is NOT gated
-- ---------------------------------------------------------
-- `update_patient()` (migration 00038, D-076) refused anyone but the owner or a PHARMACIST. D-085
-- supersedes that half of it: **the owner's policy won, so a pharmacist is gated exactly like a
-- cashier**. The action type ABSORBS the rule rather than sitting beside it - there is one door,
-- `update_patient()`, and it writes for the owner and raises a `customer_edit` request for anybody
-- else. The return type changes from the row to the same `{outcome, document, request_id}` envelope
-- the other gated writes answer with, because there IS no row to answer with for staff; the function
-- is dropped and recreated for that reason, and it has no Dart caller (the app registers patients
-- through `save_patient()` and never edits a master), so nothing else moves.
--
-- **What is deliberately NOT gated, and why.** `customers` has table-level UPDATE revoked, with
-- exactly eight columns granted back for the customers form (name, phone, email, address, gstin,
-- opening_balance, loyalty_points, is_active - migration 00038, deliberately, so "no existing screen
-- changes behaviour"). This chunk does not revoke those eight. The brief says the customers form is
-- not this phase's to change, and the revoke rule is that a revoke ships WITH its request path - so
-- revoking columns a committed Phase 1 screen writes, with no replacement for that screen in this
-- migration, would leave staff unable to edit a customer at all. The gap that leaves is named rather
-- than hidden: **a session can still set a customer's `is_active` (a soft delete) and
-- `opening_balance` (money) through the customers form.** Both are the kind of act the owner's
-- sentence covers, so the customers form is a later chunk's to gate, together with its screen - and
-- `customer_edit` is already the action type it will raise.
--
-- The expense notification (chunk 6's first half)
-- -----------------------------------------------
-- A recorded expense TELLS the owner instead of asking him: an in-app notification in his own inbox
-- through `queue_notification()` (migration 00028), opened by a TRIGGER on `expenses` rather than by
-- a call in the app's write path, because the rule is "every expense tells him" and a screen can be
-- bypassed by a session. A trigger also covers an edit and a deletion - the other two acts D-085
-- retired from the enum - which no app path performs today but a session still can.
--
-- The delivery-log half is queued for the channels the account can actually be addressed on. Email
-- and WhatsApp are the same seam the in-app row is (one `queue_notification` call), and they wait on
-- N-1's credentials for a *dispatch*; what this migration does NOT do is write a log row for a
-- channel with no destination, because that would record an attempt that could never happen. The
-- owner's WhatsApp number is on his profile, so that leg is queued; his email address is nowhere in
-- this schema yet, so that leg is not, and the note is in section 8.

-- ---------------------------------------------------------------------------
-- 1. document_payload_problem() - replaced: the master-data shapes
-- A new product, a product edit or alias act, a product deletion and a customer
-- edit ask for a document that does not exist yet, so the payload IS the
-- document and the check is what makes answering it possible. The whole body
-- travels again because applied migrations are never edited; sections 1 bis
-- (declarations, the master-data branches, the function's own comment) are the
-- only additions.
-- ---------------------------------------------------------------------------
create or replace function public.document_payload_problem(
  p_action_type public.approval_action_type,
  p_payload jsonb,
  p_pharmacy_id uuid
) returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_items jsonb;
  v_customer public.customers;
  v_key_name text;
begin
  if p_action_type = 'purchase_return'::public.approval_action_type then
    if nullif(p_payload ->> 'purchase_id', '') is null then
      return 'a purchase return has to name the purchase it returns to';
    end if;

    if not exists (
      select 1 from public.purchases p
       where p.id = (p_payload ->> 'purchase_id')::uuid
         and p.pharmacy_id = p_pharmacy_id
    ) then
      return 'that purchase is not in this pharmacy';
    end if;

    v_items := coalesce(p_payload -> 'items', '[]'::jsonb);

    if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
      return 'a purchase return needs at least one line';
    end if;

    if exists (
      select 1 from jsonb_array_elements(v_items) i
       where coalesce((i ->> 'qty')::int, 0) <= 0
          or nullif(i ->> 'batch_id', '') is null
    ) then
      return 'every line of a purchase return needs a batch and a quantity greater than zero';
    end if;

    return null;
  end if;

  if p_action_type = 'sale_return'::public.approval_action_type then
    if nullif(p_payload ->> 'sale_id', '') is null then
      return 'a sale return has to name the sale it returns';
    end if;

    if not exists (
      select 1 from public.sales s
       where s.id = (p_payload ->> 'sale_id')::uuid
         and s.pharmacy_id = p_pharmacy_id
    ) then
      return 'that sale is not in this pharmacy';
    end if;

    v_items := coalesce(p_payload -> 'items', '[]'::jsonb);

    if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
      return 'a sale return needs at least one line';
    end if;

    if exists (
      select 1 from jsonb_array_elements(v_items) i
       where coalesce((i ->> 'qty')::int, 0) <= 0
    ) then
      return 'every line of a sale return needs a quantity greater than zero';
    end if;

    -- Restocking is a yes or a no, never an absence: `stock_restore_on_sale_return()` reads a
    -- missing `restock` as false, which would silently write off goods the operator meant to put
    -- back on the shelf.
    if p_payload ->> 'restock' is null
       or lower(btrim(p_payload ->> 'restock')) not in ('true', 'false') then
      return 'a sale return has to say whether the goods go back on the shelf';
    end if;

    return null;
  end if;

  if p_action_type = 'stock_adjustment'::public.approval_action_type then
    if nullif(p_payload ->> 'product_id', '') is null then
      return 'a stock adjustment has to name the product it corrects';
    end if;

    if not exists (
      select 1 from public.products pr
       where pr.id = (p_payload ->> 'product_id')::uuid
         and pr.pharmacy_id = p_pharmacy_id
    ) then
      return 'that product is not in this pharmacy';
    end if;

    if coalesce((p_payload ->> 'qty')::int, 0) <= 0 then
      return 'a stock adjustment needs a quantity greater than zero';
    end if;

    if lower(btrim(coalesce(p_payload ->> 'adjustment_type', ''))) not in ('increase', 'decrease') then
      return 'a stock adjustment has to say which way it goes';
    end if;

    if nullif(p_payload ->> 'batch_id', '') is not null
       and not exists (
         select 1 from public.product_batches b
          where b.id = (p_payload ->> 'batch_id')::uuid
            and b.pharmacy_id = p_pharmacy_id
       ) then
      return 'that batch is not in this pharmacy';
    end if;

    return null;
  end if;

  -- -------------------------------------------------------------------------
  -- The master data: the product document and the customer master. Same rule as
  -- the contra documents - the payload IS the document - so an ask whose answer
  -- could not be carried out never reaches the owner, and the owner's own write
  -- is held to exactly the same shape.
  -- -------------------------------------------------------------------------
  if p_action_type = 'product_create'::public.approval_action_type then
    if nullif(btrim(coalesce(p_payload ->> 'name', '')), '') is null then
      return 'a new product needs a name';
    end if;

    if p_payload ? 'schedule_type'
       and btrim(p_payload ->> 'schedule_type') not in (
         select label::text
           from unnest(enum_range(null::public.schedule_type)) as label
       ) then
      return 'that drug schedule is not one this pharmacy records';
    end if;

    -- The reorder level is an int the writer casts, so it is checked here: a bad value has to be a
    -- sentence the operator can act on, not a cast error while the owner is reading his list.
    if p_payload ? 'min_stock_level'
       and btrim(p_payload ->> 'min_stock_level') !~ '^[0-9]+$' then
      return 'a reorder level has to be a whole number of units, zero or more';
    end if;

    if p_payload ? 'is_active'
       and lower(btrim(p_payload ->> 'is_active')) not in ('true', 'false') then
      return 'a new product has to say whether it starts active';
    end if;

    return null;
  end if;

  if p_action_type = 'product_edit'::public.approval_action_type then
    if nullif(p_payload ->> 'product_id', '') is null then
      return 'a product edit has to name the product it edits';
    end if;

    if not exists (
      select 1 from public.products pr
       where pr.id = (p_payload ->> 'product_id')::uuid
         and pr.pharmacy_id = p_pharmacy_id
    ) then
      return 'that product is not in this pharmacy';
    end if;

    if p_payload ? 'name' and nullif(btrim(coalesce(p_payload ->> 'name', '')), '') is null then
      return 'a product cannot be left without a name';
    end if;

    if p_payload ? 'schedule_type'
       and btrim(p_payload ->> 'schedule_type') not in (
         select label::text
           from unnest(enum_range(null::public.schedule_type)) as label
       ) then
      return 'that drug schedule is not one this pharmacy records';
    end if;

    if p_payload ? 'min_stock_level'
       and btrim(p_payload ->> 'min_stock_level') !~ '^[0-9]+$' then
      return 'a reorder level has to be a whole number of units, zero or more';
    end if;

    if p_payload ? 'is_active'
       and lower(btrim(p_payload ->> 'is_active')) not in ('true', 'false') then
      return 'a product has to say whether it is active';
    end if;

    -- One document per ask, and only one: either the product's own fields or ONE alias act. A
    -- payload mixing them would describe two documents under one approval, and the writer applies
    -- whichever the shape names - so the mixture is refused here rather than half-applied later.
    if p_payload ? 'remove_alias_id' or p_payload ? 'alias' then
      if p_payload ?| array['name', 'generic_name', 'brand', 'manufacturer', 'hsn_code', 'category',
                            'schedule_type', 'pack_size', 'unit', 'min_stock_level', 'rack_location',
                            'barcode'] then
        return 'an alias is its own document: send either the product''s fields or the alias, not both';
      end if;

      if p_payload ? 'remove_alias_id' then
        if nullif(p_payload ->> 'remove_alias_id', '') is null then
          return 'a product edit that removes an alias has to name the alias';
        end if;

        if not exists (
          select 1 from public.product_aliases a
           where a.id = (p_payload ->> 'remove_alias_id')::uuid
             and a.pharmacy_id = p_pharmacy_id
             and a.product_id = (p_payload ->> 'product_id')::uuid
        ) then
          return 'that alias is not recorded on this product in this pharmacy';
        end if;

        return null;
      end if;

      if jsonb_typeof(p_payload -> 'alias') <> 'object' then
        return 'an alias has to be an object carrying the invoice text';
      end if;

      if nullif(btrim(coalesce(p_payload #>> '{alias,raw_name}', '')), '') is null then
        return 'an alias needs the invoice text it is recorded against';
      end if;

      -- The same rule addAlias() states in Flutter, enforced where it counts: a text with nothing
      -- a letter or a digit in it normalizes to the empty string and would match everything.
      if nullif(public.normalize_product_name(p_payload #>> '{alias,raw_name}'), '') is null then
        return 'that alias needs at least one letter or digit';
      end if;

      if nullif(p_payload #>> '{alias,supplier_id}', '') is not null
         and not exists (
           select 1 from public.suppliers s
            where s.id = (p_payload #>> '{alias,supplier_id}')::uuid
              and s.pharmacy_id = p_pharmacy_id
         ) then
        return 'that supplier is not in this pharmacy';
      end if;

      return null;
    end if;

    -- Otherwise it is the product's own fields, and something has to be changing.
    if not (p_payload ?| array['name', 'generic_name', 'brand', 'manufacturer', 'hsn_code',
                                 'category', 'schedule_type', 'pack_size', 'unit',
                                 'min_stock_level', 'rack_location', 'barcode', 'is_active']) then
      return 'that product edit changes nothing';
    end if;

    return null;
  end if;

  if p_action_type = 'product_delete'::public.approval_action_type then
    if nullif(p_payload ->> 'product_id', '') is null then
      return 'deleting a product has to name it';
    end if;

    if not exists (
      select 1 from public.products pr
       where pr.id = (p_payload ->> 'product_id')::uuid
         and pr.pharmacy_id = p_pharmacy_id
    ) then
      return 'that product is not in this pharmacy';
    end if;

    -- A deletion IS a deactivation (D-083's soft delete), so the document has to say so.
    if lower(btrim(coalesce(p_payload ->> 'is_active', ''))) <> 'false' then
      return 'a product deletion has to say the product stops being active';
    end if;

    return null;
  end if;

  if p_action_type = 'customer_edit'::public.approval_action_type then
    if nullif(p_payload ->> 'customer_id', '') is null then
      return 'a customer edit has to name the customer it edits';
    end if;

    select * into v_customer
      from public.customers c
     where c.id = (p_payload ->> 'customer_id')::uuid
       and c.pharmacy_id = p_pharmacy_id;

    if not found then
      return 'that customer is not in this pharmacy';
    end if;

    if nullif(btrim(coalesce(p_payload ->> 'name', '')), '') is null then
      return 'a customer edit has to keep a name';
    end if;

    if nullif(p_payload ->> 'mobile', '') is not null
       and public.normalize_indian_mobile(p_payload ->> 'mobile') is null then
      return 'that mobile number is not a valid Indian mobile (10 digits, starting 6-9)';
    end if;

    if nullif(p_payload ->> 'guardian_phone', '') is not null
       and public.normalize_indian_mobile(p_payload ->> 'guardian_phone') is null then
      return 'that guardian mobile number is not a valid Indian mobile (10 digits, starting 6-9)';
    end if;

    if nullif(p_payload ->> 'sex', '') is not null
       and lower(btrim(p_payload ->> 'sex')) not in ('male', 'female', 'other') then
      return 'sex must be male, female or other';
    end if;

    -- The two ages and the date of birth are the values the executor casts, checked here for the
    -- same reason the reorder level is: a bad one has to be a sentence, not a cast error.
    foreach v_key_name in array array['age_years', 'age_months'] loop
      if nullif(btrim(coalesce(p_payload ->> v_key_name, '')), '') is not null
         and btrim(p_payload ->> v_key_name) !~ '^[0-9]+$' then
        return 'a patient''s age has to be a whole number of years and of months';
      end if;
    end loop;

    if nullif(p_payload ->> 'date_of_birth', '') is not null then
      if btrim(p_payload ->> 'date_of_birth') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        return 'that date of birth is not a date';
      end if;

      if (p_payload ->> 'date_of_birth')::date > current_date then
        return 'a date of birth cannot be in the future';
      end if;
    end if;

    -- The contact rule migration 00038 set, restated so an ask that answering would refuse never
    -- reaches the owner's list: a patient has to end an edit with a number, their own or a
    -- guardian's, because the next pharmacy sale refuses to bill a patient without one.
    if coalesce(
         public.normalize_indian_mobile(p_payload ->> 'mobile'),
         public.normalize_indian_mobile(p_payload ->> 'guardian_phone'),
         v_customer.phone
       ) is null then
      return 'a patient needs a mobile number, or a guardian''s for a child or dependant';
    end if;

    return null;
  end if;

  -- An action type this describes nothing about: the caller owns its validation, as it does for a
  -- purchase document and a discount.
  return null;
end;
$$;

comment on function public.document_payload_problem(public.approval_action_type, jsonb, uuid) is
  'Why a payload could not produce a document, or NULL when it could: the contra documents (purchase returns, sale returns, stock adjustments) and the master-data documents (a new product, a product edit or alias act, a product deletion, a customer edit). One definition, used by request_approval() so an ask that answering could not carry out never reaches the owner''s list, and by each writer - the three record_*() functions, save_product() and update_patient() - so the owner''s own write is held to exactly the same shape.';



-- ---------------------------------------------------------------------------
-- 2. approval_has_executor() - the four action types this chunk makes real
-- Two consequences in one list: the four master-data acts become executable, and
-- the three expense action types D-085 RETIRED stay absent for ever.
-- ---------------------------------------------------------------------------
create or replace function public.approval_has_executor(p_action_type public.approval_action_type)
returns boolean
language sql
immutable
as $$
  -- One entry per action type whose chunk has landed. Chunk 1 built the discount, chunk 3 the
  -- purchase document, chunk 4 the three contra documents, this chunk the four master-data acts.
  -- `expense_create`, `expense_edit` and `expense_delete` are RETIRED by D-085 and are absent from
  -- this list on purpose, so a request naming one is refused in words rather than sitting in the
  -- owner's list waiting for an executor that is never coming.
  select p_action_type in (
    'discount_above_limit'::public.approval_action_type,
    'purchase'::public.approval_action_type,
    'purchase_edit'::public.approval_action_type,
    'purchase_delete'::public.approval_action_type,
    'purchase_return'::public.approval_action_type,
    'sale_return'::public.approval_action_type,
    'stock_adjustment'::public.approval_action_type,
    'product_create'::public.approval_action_type,
    'product_edit'::public.approval_action_type,
    'product_delete'::public.approval_action_type,
    'customer_edit'::public.approval_action_type
  );
$$;

comment on function public.approval_has_executor(public.approval_action_type) is
  'Whether this build can actually carry an action type out. request_approval() refuses an action type this returns false for, so the owner''s list can never hold a request that approving would not act on.';



-- ---------------------------------------------------------------------------
-- 3. request_approval() - replaced: a master-data ask has to carry a document
-- The master-data family joins the contra documents at the one shape check, and
-- the "refresh rather than stack" list grows the three action types whose asks
-- are revisions of one document. The whole body travels again; nothing else in
-- it changes.
-- ---------------------------------------------------------------------------
create or replace function public.request_approval(
  p_action_type public.approval_action_type,
  p_title text,
  p_summary text default null,
  p_payload jsonb default '{}'::jsonb,
  p_target_table text default null,
  p_target_id uuid default null,
  p_idempotency_key text default null
) returns public.approval_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_key      text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_row      public.approval_requests;
  v_purchase public.purchases;
  v_problem  text;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  if nullif(btrim(coalesce(p_title, '')), '') is null then
    raise exception 'an approval request needs a title the owner can read'
      using errcode = 'check_violation';
  end if;

  if not public.approval_has_executor(p_action_type) then
    -- Named, not silent: the phase that owns this action type will add it, and until then the ask
    -- is refused instead of sitting in a list where approving it would do nothing.
    raise exception 'the approval for % is not available yet', p_action_type
      using errcode = 'feature_not_supported';
  end if;

  if p_action_type = 'discount_above_limit'::public.approval_action_type then
    -- The ask has to carry the figure and the bill it is taken off, because those are what the
    -- owner reads AND what `checkout_sale()` matches the bill against afterwards.
    if coalesce((p_payload ->> 'discount_amount')::numeric, 0) <= 0
       or coalesce((p_payload ->> 'bill_gross')::numeric, 0) <= 0 then
      raise exception 'a discount request needs the discount and the bill it is taken off'
        using errcode = 'check_violation';
    end if;

    -- And it has to be a discount the counter could NOT just give: an ask for something within the
    -- 10% spends the owner's attention on a figure that needs no permission.
    if (p_payload ->> 'discount_amount')::numeric <= (p_payload ->> 'bill_gross')::numeric * 0.10 then
      raise exception 'that discount is within the 10%% the counter may give, so no approval is needed'
        using errcode = 'check_violation';
    end if;
  end if;

  if p_action_type in (
    'purchase'::public.approval_action_type,
    'purchase_edit'::public.approval_action_type,
    'purchase_delete'::public.approval_action_type
  ) then
    if p_target_id is null or coalesce(btrim(p_target_table), '') <> 'purchases' then
      raise exception 'an approval for a purchase has to name the purchase document it is about'
        using errcode = 'check_violation';
    end if;

    select * into v_purchase
      from public.purchases p
     where p.id = p_target_id
       and p.pharmacy_id = v_pharmacy;

    if not found then
      raise exception 'that purchase is not in this pharmacy'
        using errcode = 'check_violation';
    end if;

    if p_action_type in (
      'purchase'::public.approval_action_type,
      'purchase_edit'::public.approval_action_type
    ) then
      -- A content ask names a document that is WAITING: `pending_approval` is the row's own state,
      -- so the owner reads the document itself and approving it is one status change.
      if v_purchase.status <> 'pending_approval'::public.purchase_status then
        raise exception 'that purchase is not waiting for approval - only a document saved as pending can be asked about'
          using errcode = 'check_violation';
      end if;

      -- And it has to say what approving it would DO. Without this the owner could answer a
      -- question whose answer had nowhere to go.
      if coalesce(p_payload ->> 'resume_status', '') not in ('draft', 'ordered', 'received') then
        raise exception 'a purchase request has to say which status approving it would give the document'
          using errcode = 'check_violation';
      end if;
    else
      -- A cancellation is only ever asked about a document that still exists to cancel.
      if v_purchase.status = 'cancelled'::public.purchase_status then
        raise exception 'that purchase is cancelled already'
          using errcode = 'check_violation';
      end if;
    end if;
  end if;

  -- -------------------------------------------------------------------------
  -- The contra documents: the payload IS the document, so it has to be one the
  -- executor can write. One shared check (see `document_payload_problem`), so
  -- the ask and the write cannot disagree about what a sound document is.
  -- -------------------------------------------------------------------------
  if p_action_type in (
    'purchase_return'::public.approval_action_type,
    'sale_return'::public.approval_action_type,
    'stock_adjustment'::public.approval_action_type
  ) then
    v_problem := public.document_payload_problem(p_action_type, p_payload, v_pharmacy);

    if v_problem is not null then
      raise exception '%', v_problem
        using errcode = 'check_violation';
    end if;
  end if;

  -- -------------------------------------------------------------------------
  -- The master data: the product master and the customer master. The payload IS
  -- the document here too (nothing is written until he answers), so the same one
  -- shape check holds the ask - and the writer calls it as well, so the owner's
  -- own edit is not a different document.
  -- -------------------------------------------------------------------------
  if p_action_type in (
    'product_create'::public.approval_action_type,
    'product_edit'::public.approval_action_type,
    'product_delete'::public.approval_action_type,
    'customer_edit'::public.approval_action_type
  ) then
    v_problem := public.document_payload_problem(p_action_type, p_payload, v_pharmacy);

    if v_problem is not null then
      raise exception '%', v_problem
        using errcode = 'check_violation';
    end if;
  end if;

  if v_key is not null then
    select * into v_row
      from public.approval_requests a
     where a.pharmacy_id = v_pharmacy
       and a.idempotency_key = v_key;

    if found then
      return v_row;
    end if;
  end if;

  -- One undecided ask per document, refreshed rather than stacked: it is the case where the same
  -- person keeps refining ONE question about ONE row. A purchase qualifies because its payload is a
  -- single status while the document itself is the staged row; a product or customer master edit
  -- qualifies because the client sends the whole form, so the later ask REPLACES the earlier one
  -- instead of losing a change from it. A return has no row yet and a second return against the same
  -- sale is a different document, so those never converge - and an alias act carries no product
  -- target at all, so it is a question of its own rather than a revision of the product's.
  if p_action_type in (
    'purchase'::public.approval_action_type,
    'purchase_edit'::public.approval_action_type,
    'purchase_delete'::public.approval_action_type,
    'product_edit'::public.approval_action_type,
    'product_delete'::public.approval_action_type,
    'customer_edit'::public.approval_action_type
  ) then
    select * into v_row
      from public.approval_requests a
     where a.pharmacy_id = v_pharmacy
       and a.action_type = p_action_type
       and a.target_id = p_target_id
       and a.status = 'pending'::public.approval_status
     for update;

    if found then
      update public.approval_requests a
         set title   = btrim(p_title),
             summary = nullif(btrim(coalesce(p_summary, '')), ''),
             payload = coalesce(p_payload, '{}'::jsonb)
       where a.id = v_row.id
      returning * into v_row;

      return v_row;
    end if;
  end if;

  insert into public.approval_requests (
    pharmacy_id, action_type, title, summary, payload,
    target_table, target_id, requested_by, idempotency_key
  ) values (
    v_pharmacy,
    p_action_type,
    btrim(p_title),
    nullif(btrim(coalesce(p_summary, '')), ''),
    coalesce(p_payload, '{}'::jsonb),
    p_target_table,
    p_target_id,
    auth.uid(),
    v_key
  )
  returning * into v_row;

  return v_row;
end;
$$;

comment on function public.request_approval(public.approval_action_type, text, text, jsonb, text, uuid, text) is
  'Raises one approval request. Any authorised member of the pharmacy may ask; only the owner may decide (decide_approval). Refuses an action type this build cannot execute, refuses a discount the counter may simply give, refuses a request whose payload could not be carried out, and refreshes an undecided ask about the same document instead of stacking a second one. Idempotent on p_idempotency_key.';



-- ---------------------------------------------------------------------------
-- 4. save_product() - the ONE door to the product master
--
--    A create, an edit, a soft delete, a restore and both alias acts, for both roles, because the
--    three tables stop taking writes from a session in section 7. The action type is DERIVED from
--    the payload rather than named by the caller, so a client cannot ask for a gentler action type
--    than the change it is asking for; the phrase the owner's screen shows is built HERE, from the
--    row's own values, so his queue cannot describe one product while the write produces another.
--
--    The figures are not recomputed anywhere: a product's columns ARE its master record. The one
--    thing this function will not do is change `pharmacy_id` (never in the whitelist) or write a
--    column the form does not own (`gst_percent`, `embedding` and the three timestamps are not in
--    it), so the write is exactly the write the client used to make.
-- ---------------------------------------------------------------------------
create or replace function public.save_product(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy     uuid := public.get_my_pharmacy_id();
  v_role         public.app_role := public.get_my_role();
  v_product_id   uuid := nullif(p_payload ->> 'product_id', '')::uuid;
  v_product      public.products;
  v_alias_raw    text := nullif(btrim(coalesce(p_payload #>> '{alias,raw_name}', '')), '');
  v_supplier_id  uuid := nullif(p_payload #>> '{alias,supplier_id}', '')::uuid;
  v_remove_alias uuid := nullif(p_payload ->> 'remove_alias_id', '')::uuid;
  v_key          text := nullif(btrim(coalesce(p_payload ->> 'idempotency_key', '')), '');
  v_action       public.approval_action_type;
  v_target_table text;
  v_target_id    uuid;
  v_problem      text;
  v_title        text;
  v_summary      text;
  v_document     jsonb;
  v_alias        public.product_aliases;
  v_existing     public.product_aliases;
  v_other        public.products;
  v_norm         text;
  v_changed      text[] := array[]::text[];
  v_field        text;
  v_fields       text[] := array[
    'name', 'generic_name', 'brand', 'manufacturer', 'hsn_code', 'category', 'schedule_type',
    'pack_size', 'unit', 'min_stock_level', 'rack_location', 'barcode', 'is_active'
  ];
  v_request      public.approval_requests;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  if v_product_id is not null then
    select * into v_product
      from public.products pr
     where pr.id = v_product_id
       and pr.pharmacy_id = v_pharmacy;

    if not found then
      raise exception 'that product is not in this pharmacy'
        using errcode = 'check_violation';
    end if;
  end if;

  -- Which of the four acts this payload IS. Derived, not taken from the caller.
  if v_product_id is null then
    v_action := 'product_create'::public.approval_action_type;
    v_target_table := 'products';
  elsif v_remove_alias is not null then
    v_action := 'product_edit'::public.approval_action_type;
    v_target_table := 'product_aliases';
    v_target_id := v_remove_alias;
  elsif v_alias_raw is not null then
    v_action := 'product_edit'::public.approval_action_type;
    v_target_table := 'product_aliases';
  elsif p_payload ? 'is_active'
        and lower(btrim(p_payload ->> 'is_active')) = 'false'
        and v_product.is_active then
    -- Deactivating a product that is in use is the soft DELETE (D-083's answer), and it is its own
    -- action type: a payload that only flips the switch is a deletion, whatever screen sent it.
    v_action := 'product_delete'::public.approval_action_type;
    v_target_table := 'products';
    v_target_id := v_product_id;
  else
    v_action := 'product_edit'::public.approval_action_type;
    v_target_table := 'products';
    v_target_id := v_product_id;
  end if;

  -- The one shape check, called from HERE for both roles, as the contra documents call it: the
  -- owner's own write is not a different document from the one a cashier asked about.
  v_problem := public.document_payload_problem(v_action, p_payload, v_pharmacy);

  if v_problem is not null then
    raise exception '%', v_problem
      using errcode = 'check_violation';
  end if;

  -- ------------------------------------------------------------------ the wording
  if v_action = 'product_create'::public.approval_action_type then
    v_title := 'New product: ' || btrim(p_payload ->> 'name');
    v_summary := 'Added to the catalogue'
      || case when nullif(btrim(coalesce(p_payload ->> 'category', '')), '') is null
              then '' else ' · ' || btrim(p_payload ->> 'category') end
      || case when nullif(btrim(coalesce(p_payload ->> 'schedule_type', '')), '') is null
              then '' else ' · schedule ' || btrim(p_payload ->> 'schedule_type') end;

  elsif v_remove_alias is not null then
    -- Read before the write, so the sentence names the text that is actually going.
    select * into v_existing
      from public.product_aliases a
     where a.id = v_remove_alias
       and a.pharmacy_id = v_pharmacy;

    v_title := 'Remove alias from ' || v_product.name;
    v_summary := 'The invoice text "'
      || coalesce(nullif(btrim(coalesce(v_existing.raw_name, '')), ''), '?')
      || '" stops matching this product';

  elsif v_alias_raw is not null then
    v_norm := public.normalize_product_name(v_alias_raw);

    select * into v_existing
      from public.product_aliases a
     where a.pharmacy_id = v_pharmacy
       and a.normalized_name = v_norm
       and a.supplier_id is not distinct from v_supplier_id;

    if found then
      select * into v_other from public.products pr where pr.id = v_existing.product_id;
    end if;

    v_title := 'Alias for ' || v_product.name;
    v_summary := 'Invoice text "' || v_alias_raw || '"'
      || case when v_existing.id is not null and v_existing.product_id <> v_product.id
              then ' · RE-POINTS an alias that currently means '
                   || coalesce(v_other.name, 'another product')
              else '' end;

  else
    foreach v_field in array v_fields loop
      if p_payload ? v_field then
        v_changed := array_append(v_changed, v_field);
      end if;
    end loop;

    if v_action = 'product_delete'::public.approval_action_type then
      v_title := 'Delete product: ' || v_product.name;
      v_summary := 'Soft delete: the row stays, it stops appearing in the bill'
        || case when coalesce(array_length(v_changed, 1), 0) > 1
                then ' · and the same document changes ' || array_to_string(v_changed, ', ')
                else '' end;
    elsif coalesce(array_length(v_changed, 1), 0) = 1 and v_changed[1] = 'is_active' then
      v_title := 'Restore product: ' || v_product.name;
      v_summary := 'Puts the product back in the bill';
    else
      v_title := 'Edit product: ' || v_product.name;
      v_summary := 'Changes: ' || array_to_string(v_changed, ', ');
    end if;
  end if;

  -- ------------------------------------------------------------------ the write
  if v_role = 'owner'::public.app_role then
    if v_action = 'product_create'::public.approval_action_type then
      insert into public.products (
        pharmacy_id, name, generic_name, brand, manufacturer, hsn_code, category,
        schedule_type, pack_size, unit, min_stock_level, rack_location, barcode, is_active
      ) values (
        v_pharmacy,
        btrim(p_payload ->> 'name'),
        nullif(btrim(coalesce(p_payload ->> 'generic_name', '')), ''),
        nullif(btrim(coalesce(p_payload ->> 'brand', '')), ''),
        nullif(btrim(coalesce(p_payload ->> 'manufacturer', '')), ''),
        nullif(btrim(coalesce(p_payload ->> 'hsn_code', '')), ''),
        nullif(btrim(coalesce(p_payload ->> 'category', '')), ''),
        coalesce(nullif(btrim(coalesce(p_payload ->> 'schedule_type', '')), ''),
                 'OTC')::public.schedule_type,
        nullif(btrim(coalesce(p_payload ->> 'pack_size', '')), ''),
        nullif(btrim(coalesce(p_payload ->> 'unit', '')), ''),
        coalesce((p_payload ->> 'min_stock_level')::int, 0),
        nullif(btrim(coalesce(p_payload ->> 'rack_location', '')), ''),
        nullif(btrim(coalesce(p_payload ->> 'barcode', '')), ''),
        coalesce((p_payload ->> 'is_active')::boolean, true)
      )
      returning * into v_product;

      v_document := to_jsonb(v_product);

    elsif v_remove_alias is not null then
      delete from public.product_aliases a
       where a.id = v_remove_alias
         and a.pharmacy_id = v_pharmacy
      returning * into v_alias;

      if not found then
        raise exception 'that alias is not in this pharmacy'
          using errcode = 'check_violation';
      end if;

      v_document := to_jsonb(v_alias);

    elsif v_alias_raw is not null then
      insert into public.product_aliases (
        pharmacy_id, product_id, raw_name, normalized_name, supplier_id
      ) values (
        v_pharmacy, v_product.id, v_alias_raw, v_norm, v_supplier_id
      )
      on conflict (pharmacy_id, supplier_id, normalized_name) do update
        set product_id = excluded.product_id,
            raw_name   = excluded.raw_name
      returning * into v_alias;

      v_document := to_jsonb(v_alias);

    else
      -- A partial update, and a CASE rather than a rebuilt statement: a column the payload does not
      -- name keeps its value, and the cast in a branch only runs when that branch is taken - which
      -- is why the shape check above validates the three non-text casts.
      update public.products pr set
        name = case when p_payload ? 'name'
                    then btrim(p_payload ->> 'name') else pr.name end,
        generic_name = case when p_payload ? 'generic_name'
                            then nullif(btrim(coalesce(p_payload ->> 'generic_name', '')), '')
                            else pr.generic_name end,
        brand = case when p_payload ? 'brand'
                     then nullif(btrim(coalesce(p_payload ->> 'brand', '')), '')
                     else pr.brand end,
        manufacturer = case when p_payload ? 'manufacturer'
                            then nullif(btrim(coalesce(p_payload ->> 'manufacturer', '')), '')
                            else pr.manufacturer end,
        hsn_code = case when p_payload ? 'hsn_code'
                        then nullif(btrim(coalesce(p_payload ->> 'hsn_code', '')), '')
                        else pr.hsn_code end,
        category = case when p_payload ? 'category'
                        then nullif(btrim(coalesce(p_payload ->> 'category', '')), '')
                        else pr.category end,
        schedule_type = case when p_payload ? 'schedule_type'
                             then (p_payload ->> 'schedule_type')::public.schedule_type
                             else pr.schedule_type end,
        pack_size = case when p_payload ? 'pack_size'
                         then nullif(btrim(coalesce(p_payload ->> 'pack_size', '')), '')
                         else pr.pack_size end,
        unit = case when p_payload ? 'unit'
                    then nullif(btrim(coalesce(p_payload ->> 'unit', '')), '')
                    else pr.unit end,
        min_stock_level = case when p_payload ? 'min_stock_level'
                               then (p_payload ->> 'min_stock_level')::int
                               else pr.min_stock_level end,
        rack_location = case when p_payload ? 'rack_location'
                             then nullif(btrim(coalesce(p_payload ->> 'rack_location', '')), '')
                             else pr.rack_location end,
        barcode = case when p_payload ? 'barcode'
                       then nullif(btrim(coalesce(p_payload ->> 'barcode', '')), '')
                       else pr.barcode end,
        is_active = case when p_payload ? 'is_active'
                         then (p_payload ->> 'is_active')::boolean
                         else pr.is_active end
       where pr.id = v_product.id
         and pr.pharmacy_id = v_pharmacy
      returning * into v_product;

      v_document := to_jsonb(v_product);
    end if;

    return jsonb_build_object(
      'outcome', 'recorded',
      'document', v_document,
      'request_id', null
    );
  end if;

  v_request := public.request_approval(
    p_action_type => v_action,
    p_title => v_title,
    p_summary => v_summary,
    p_payload => p_payload,
    p_target_table => v_target_table,
    p_target_id => v_target_id,
    p_idempotency_key => v_key
  );

  return jsonb_build_object(
    'outcome', 'staged',
    'document', null,
    'request_id', v_request.id
  );
end;
$$;

comment on function public.save_product(jsonb) is
  'The one door to the product master: creates, edits, soft-deletes and restores a product and records or removes an alias, for the owner and for staff alike. The action type is derived from the payload (product_create with no product_id, product_delete when it deactivates an active product, product_edit otherwise), so a client cannot name a gentler act than the change it asks for. Anybody but the owner gets {"outcome":"staged"} and one approval request carrying the document; the owner gets {"outcome":"recorded"} and the row he wrote. `authenticated` has no INSERT, UPDATE or DELETE on products, product_batches or product_aliases.';

-- ---------------------------------------------------------------------------
-- 5. update_patient() - re-expressed: the owner's policy absorbed the pharmacist half
--
--    Migration 00038 gated this door to "the owner or a pharmacist". D-085 supersedes that: a
--    pharmacist is gated like a cashier now, so the action type ABSORBS the rule instead of sitting
--    beside it - one door, `update_patient()`, which writes for the owner and raises a
--    `customer_edit` request for everybody else.
--
--    Its return type changes from the row to the same {outcome, document, request_id} envelope every
--    other gated write answers with, because there IS no row to answer with for staff - and a
--    `create or replace` cannot change a return type, so the function is dropped first. Nothing in
--    Flutter calls it (the app registers patients through save_patient() and never edits a master),
--    so the only callers that move are this repository's SQL tests, which are re-expressed.
--
--    Everything 00038 decided about WHAT an edit may do is unchanged: no patient_code, none of the
--    financial columns the customers form owns, no moving a patient between pharmacies, and a
--    patient must end the call with a contact number.
-- ---------------------------------------------------------------------------
drop function if exists public.update_patient(
  uuid, text, text, text, text, date, integer, integer, text, text, text
);

create or replace function public.update_patient(
  p_patient_id uuid,
  p_name text,
  p_mobile text default null,
  p_guardian_phone text default null,
  p_address text default null,
  p_date_of_birth date default null,
  p_age_years int default null,
  p_age_months int default null,
  p_sex text default null,
  p_guardian_name text default null,
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy  uuid := public.get_my_pharmacy_id();
  v_role      public.app_role := public.get_my_role();
  v_patient   public.customers;
  v_name      text := btrim(coalesce(p_name, ''));
  v_mobile    text := public.normalize_indian_mobile(p_mobile);
  v_guardian  text := public.normalize_indian_mobile(p_guardian_phone);
  v_sex       text := nullif(lower(btrim(coalesce(p_sex, ''))), '');
  v_contact   text;
  v_payload   jsonb;
  v_problem   text;
  v_request   public.approval_requests;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_patient
    from public.customers c
   where c.id = p_patient_id
     and c.pharmacy_id = v_pharmacy
   for update;

  if not found then
    raise exception 'that patient is not in this pharmacy'
      using errcode = 'check_violation';
  end if;

  if v_name = '' then
    raise exception 'a patient needs a name'
      using errcode = 'check_violation';
  end if;

  if p_mobile is not null and btrim(p_mobile) <> '' and v_mobile is null then
    raise exception 'that mobile number is not a valid Indian mobile (10 digits, starting 6-9)'
      using errcode = 'check_violation';
  end if;

  if p_guardian_phone is not null and btrim(p_guardian_phone) <> '' and v_guardian is null then
    raise exception 'that guardian mobile number is not a valid Indian mobile (10 digits, starting 6-9)'
      using errcode = 'check_violation';
  end if;

  v_contact := coalesce(v_mobile, v_guardian, v_patient.phone);

  if v_contact is null then
    raise exception 'a patient needs a mobile number, or a guardian''s for a child or dependant'
      using errcode = 'check_violation';
  end if;

  if v_sex is not null and v_sex not in ('male', 'female', 'other') then
    raise exception 'sex must be male, female or other'
      using errcode = 'check_violation';
  end if;

  if p_date_of_birth is not null and p_date_of_birth > current_date then
    raise exception 'a date of birth cannot be in the future'
      using errcode = 'check_violation';
  end if;

  -- The document that travels, and that the owner's screen reads. The keys are this function's own
  -- arguments, so the executor hands them straight back and the two cannot drift.
  v_payload := jsonb_build_object(
    'customer_id',   v_patient.id,
    'name',          v_name,
    'mobile',        v_mobile,
    'guardian_phone', v_guardian,
    'address',       nullif(btrim(coalesce(p_address, '')), ''),
    'date_of_birth', p_date_of_birth,
    'age_years',     p_age_years,
    'age_months',    p_age_months,
    'sex',           v_sex,
    'guardian_name', nullif(btrim(coalesce(p_guardian_name, '')), ''),
    'notes',         nullif(btrim(coalesce(p_notes, '')), '')
  );

  -- The one shape check, called from the writer too: the owner's own edit is the same document.
  v_problem := public.document_payload_problem('customer_edit', v_payload, v_pharmacy);

  if v_problem is not null then
    raise exception '%', v_problem
      using errcode = 'check_violation';
  end if;

  if v_role = 'owner'::public.app_role then
    update public.customers c
       set name           = v_name,
           phone          = v_contact,
           address        = nullif(btrim(coalesce(p_address, '')), ''),
           date_of_birth  = p_date_of_birth,
           age_years      = p_age_years,
           age_months     = p_age_months,
           sex            = v_sex,
           guardian_name  = nullif(btrim(coalesce(p_guardian_name, '')), ''),
           guardian_phone = v_guardian,
           notes          = nullif(btrim(coalesce(p_notes, '')), '')
     where c.id = v_patient.id
    returning * into v_patient;

    return jsonb_build_object(
      'outcome', 'recorded',
      'document', to_jsonb(v_patient),
      'request_id', null
    );
  end if;

  v_request := public.request_approval(
    p_action_type => 'customer_edit',
    p_title => 'Patient master edit: ' || v_name,
    p_summary => 'The demographics and contact details of a registered patient'
      || case when nullif(btrim(coalesce(v_patient.patient_code, '')), '') is null
              then '' else ' · ' || v_patient.patient_code end,
    p_payload => v_payload,
    p_target_table => 'customers',
    p_target_id => v_patient.id
  );

  return jsonb_build_object(
    'outcome', 'staged',
    'document', null,
    'request_id', v_request.id
  );
end;
$$;

comment on function public.update_patient(uuid, text, text, text, text, date, integer, integer, text, text, text) is
  'Edits an existing patient master, for the owner directly and for anybody else as one customer_edit approval request that writes nothing until he answers (D-085 supersedes 00038''s owner-or-pharmacist rule: a pharmacist is gated like a cashier now). Refuses to leave the patient without a contact number; never changes patient_code, the financial columns the customers form owns, or the pharmacy. Answers {"outcome": "recorded"|"staged", "document", "request_id"} like every other gated write.';

-- ---------------------------------------------------------------------------
-- 6. The applier, and the one dispatch
-- ---------------------------------------------------------------------------

-- Carries out the owner's answer to a master-data request.
--
-- Approving runs the very write the client used to run, through the same door, which is why no
-- screen and no trigger has to change: `save_product()` derives the same action type from the same
-- payload and, seeing the owner, writes it. Refusing writes NOTHING AT ALL - not a pre-image
-- restore, not a status change - because nothing was written when the ask was raised. That is the
-- other half of why these are REQUESTED rather than staged: there is no half-document to put back.
create or replace function public.master_apply_decision(
  p_action_type public.approval_action_type,
  p_payload jsonb,
  p_approve boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not p_approve then
    return;
  end if;

  if p_action_type in (
    'product_create'::public.approval_action_type,
    'product_edit'::public.approval_action_type,
    'product_delete'::public.approval_action_type
  ) then
    -- One call for all three: `save_product()` is the door, and it re-derives the action type from
    -- the document it is handed - the same derivation that raised the ask.
    perform public.save_product(p_payload);
    return;
  end if;

  if p_action_type = 'customer_edit'::public.approval_action_type then
    perform public.update_patient(
      p_patient_id     => (p_payload ->> 'customer_id')::uuid,
      p_name           => p_payload ->> 'name',
      p_mobile         => p_payload ->> 'mobile',
      p_guardian_phone => p_payload ->> 'guardian_phone',
      p_address        => p_payload ->> 'address',
      p_date_of_birth  => nullif(p_payload ->> 'date_of_birth', '')::date,
      p_age_years      => nullif(p_payload ->> 'age_years', '')::int,
      p_age_months     => nullif(p_payload ->> 'age_months', '')::int,
      p_sex            => p_payload ->> 'sex',
      p_guardian_name  => p_payload ->> 'guardian_name',
      p_notes          => p_payload ->> 'notes'
    );
    return;
  end if;

  raise exception 'this build cannot carry out a %', p_action_type
    using errcode = 'feature_not_supported';
end;
$$;

comment on function public.master_apply_decision(public.approval_action_type, jsonb, boolean) is
  'Carries out the owner''s answer to a product or customer-master request: approving runs the document the payload carries through the very door the owner''s own write uses (save_product() or update_patient()), so the write is identical; refusing writes nothing, because nothing was written. Internal - called by approval_execute(), not executable by a session.';

-- ---------------------------------------------------------------------------
-- 6b. approval_execute() - replaced: the master-data family joins the dispatch
-- One shape for the decision path: the family is routed to its own applier, and
-- an action type with no writer is still refused rather than stamped approved.
-- ---------------------------------------------------------------------------
create or replace function public.approval_execute(
  p_action_type public.approval_action_type,
  p_target_id uuid,
  p_payload jsonb,
  p_approve boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_action_type in (
    'purchase'::public.approval_action_type,
    'purchase_edit'::public.approval_action_type,
    'purchase_delete'::public.approval_action_type
  ) then
    perform public.purchase_apply_decision(
      p_purchase_id => p_target_id,
      p_action_type => p_action_type,
      p_payload => p_payload,
      p_approve => p_approve
    );

    return;
  end if;

  if p_action_type in (
    'purchase_return'::public.approval_action_type,
    'sale_return'::public.approval_action_type,
    'stock_adjustment'::public.approval_action_type
  ) then
    perform public.document_apply_decision(
      p_action_type => p_action_type,
      p_payload => p_payload,
      p_approve => p_approve
    );

    return;
  end if;

  if p_action_type in (
    'product_create'::public.approval_action_type,
    'product_edit'::public.approval_action_type,
    'product_delete'::public.approval_action_type,
    'customer_edit'::public.approval_action_type
  ) then
    perform public.master_apply_decision(
      p_action_type => p_action_type,
      p_payload => p_payload,
      p_approve => p_approve
    );

    return;
  end if;

  if p_action_type = 'discount_above_limit'::public.approval_action_type then
    -- The sale IS the execution: it quotes the request as its authority (D-071), and there is
    -- nothing for the owner's answer to write.
    return;
  end if;

  raise exception 'this build cannot carry out a %', p_action_type
    using errcode = 'feature_not_supported';
end;
$$;

comment on function public.approval_execute(public.approval_action_type, uuid, jsonb, boolean) is
  'The single dispatch decide_approval() calls: a purchase is carried out against its staged row, a return or a stock adjustment against the document its payload carries, a product or customer master act against the document its payload carries, and the discount needs nothing because the sale is its execution. An action type with no writer is refused rather than recorded as approved. Internal - not executable by a session.';



-- ---------------------------------------------------------------------------
-- 7. The revokes - the same migration as the request path, never before it
--
--    Three tables carried the standard tenant-wide four-policy template from 00012 and the
--    table-level grants Supabase gives every public table, so any member of the pharmacy could
--    rewrite the catalogue - or move a batch's quantity, which is a stock adjustment in disguise -
--    straight through PostgREST. They stop taking writes from `authenticated` and are reachable only
--    through `save_product()`.
--
--    `product_batches` is revoked and gets NO request path, deliberately: no screen in this
--    application writes it (a GRN writes it through save_purchase(), the opening stock through its
--    own import RPC, a return and an adjustment through theirs - all SECURITY DEFINER), so there is
--    nothing to re-route. The revoke closes a session hole; it does not take a door away.
--
--    The revoke is per-role, so it covers the owner too: his own product is written by the same RPC,
--    which does exactly what his direct write did and asks him nothing. His AUTHORITY is what is
--    gated, never his route.
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'revoke insert, update, delete on public.products from authenticated';
  execute 'revoke insert, update, delete on public.product_batches from authenticated';
  execute 'revoke insert, update, delete on public.product_aliases from authenticated';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to revoke.
    null;
end $$;

comment on table public.products is
  'Catalogue master. Stock lives in product_batches, not here. Written ONLY by save_product(): `authenticated` has no INSERT, UPDATE or DELETE here. For anybody but the owner that function writes nothing and raises a product_create / product_edit / product_delete approval request carrying the document, which decide_approval() then writes. The read policies are unchanged.';
comment on table public.product_batches is
  'Stock-on-hand per product+batch; qty is the running balance maintained by the stock triggers. `authenticated` has NO INSERT, UPDATE or DELETE here since chunk 5: every legitimate writer is a SECURITY DEFINER function (save_purchase(), the opening-stock import, the return and adjustment doors), and the stock triggers those fire run with their rights. Before that revoke a session could move a batch''s qty by hand, which is a stock adjustment in disguise - the act stock_adjustment was gated for.';
comment on table public.product_aliases is
  'Learned mappings from supplier invoice text to catalogue products, used to auto-match on purchase import. `authenticated` has no INSERT, UPDATE or DELETE here: a manual alias is recorded or removed through save_product() (a product_edit request for anybody but the owner), and the automatic learning runs inside learn_product_aliases(), which is SECURITY DEFINER and writes its own rows.';

-- ---------------------------------------------------------------------------
-- 8. The expense notification - he is TOLD, not asked (D-085)
--
--    A TRIGGER rather than a call in the app's write path, because the rule is "every expense tells
--    him" and a screen can be bypassed by a session holding a token. It fires on INSERT, UPDATE and
--    DELETE - the three acts D-085 retired from the enum - because those are the three a session can
--    still perform on this table, and an unannounced edit or deletion of an expense is exactly what
--    the notification exists to surface.
--
--    There is no request path and no revoke here on purpose: `expenses` keeps its INSERT, UPDATE and
--    DELETE grants, and recording one stays free for every role, the way the sale bill does.
-- ---------------------------------------------------------------------------
create or replace function public.notify_owner_of_expense()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := coalesce(new.pharmacy_id, old.pharmacy_id);
  v_owner    public.profiles;
  v_actor    text;
  v_title    text;
  v_body     text;
begin
  -- The tenant of the row that moved, and only when it is the caller's own. This is not decoration:
  -- queue_notification() raises when its caller has no pharmacy, so a fixture written by a
  -- superuser (no auth.uid()) would fail the INSERT rather than skip the notification - and a
  -- notification that cannot say who recorded the expense is not the control he asked for.
  if v_pharmacy is null or v_pharmacy is distinct from public.get_my_pharmacy_id() then
    return null;
  end if;

  select * into v_owner
    from public.profiles p
   where p.pharmacy_id = v_pharmacy
     and p.role = 'owner'::public.app_role
     and p.is_active
   order by p.created_at, p.id
   limit 1;

  if not found then
    return null;
  end if;

  select nullif(btrim(coalesce(p.full_name, '')), '')
    into v_actor
    from public.profiles p
   where p.id = auth.uid();

  v_actor := coalesce(v_actor, 'A member of staff');

  if TG_OP = 'INSERT' then
    v_title := 'Expense recorded';
    v_body := v_actor || ' recorded an expense of '
      || to_char(coalesce(new.amount, 0), 'FM9999999990.00') || ' under "'
      || coalesce(new.category, '?') || '" on '
      || to_char(coalesce(new.expense_date, current_date), 'DD Mon YYYY') || '.';
  elsif TG_OP = 'UPDATE' then
    v_title := 'Expense changed';
    v_body := v_actor || ' changed an expense to '
      || to_char(coalesce(new.amount, 0), 'FM9999999990.00') || ' under "'
      || coalesce(new.category, '?') || '" on '
      || to_char(coalesce(new.expense_date, current_date), 'DD Mon YYYY') || '.';
  else
    v_title := 'Expense deleted';
    v_body := v_actor || ' deleted an expense of '
      || to_char(coalesce(old.amount, 0), 'FM9999999990.00') || ' under "'
      || coalesce(old.category, '?') || '" recorded on '
      || to_char(coalesce(old.expense_date, current_date), 'DD Mon YYYY') || '.';
  end if;

  -- The in-app row - the one he reads today - and the delivery log it points at, in ONE transaction
  -- through the rail Phase 5 built (D-024/D-029). `notify_user_id` is what puts it in HIS inbox; the
  -- recipient is him and not a party, because an expense has no counterparty.
  perform public.queue_notification(jsonb_build_object(
    'channel',        'in_app',
    'recipient_type', 'user',
    'recipient_id',   v_owner.id,
    'notify_user_id', v_owner.id,
    'type',           'expense',
    'title',          v_title,
    'body',           v_body
  ));

  -- WhatsApp is the channel he named that this schema can actually address. Email is NOT queued, and
  -- not because it is unimportant: `profiles` carries a phone but no address for him and
  -- `pharmacies.email` is the outlet's, so an email log row would claim an attempt to reach somebody
  -- at nowhere. The leg is one jsonb_build_object away the day the account carries an address; the
  -- credential it also needs is N-1's, and send-notification already answers `skipped` naming it.
  if nullif(btrim(coalesce(v_owner.phone, '')), '') is not null then
    perform public.queue_notification(jsonb_build_object(
      'channel',        'whatsapp',
      'recipient_type', 'user',
      'recipient_id',   v_owner.id,
      'destination',    v_owner.phone,
      'title',          v_title,
      'body',           v_body
    ));
  end if;

  return null;
end;
$$;

comment on function public.notify_owner_of_expense() is
  'Tells the owner that an expense was recorded, changed or deleted, instead of asking his permission for it (D-085). Queues the in-app row into his own inbox and a WhatsApp delivery-log row when his profile carries a number; the dispatch half is send-notification''s, and the queue is the seam. Fires on INSERT, UPDATE and DELETE - the three acts D-085 retired from the enum, and the three a session can still perform on this table. Internal trigger function, not executable by a session.';

drop trigger if exists notify_owner_of_expense on public.expenses;
create trigger notify_owner_of_expense
  after insert or update or delete on public.expenses
  for each row execute function public.notify_owner_of_expense();

comment on table public.expenses is
  'Recorded expenses. NOT gated (D-085): `authenticated` keeps INSERT, UPDATE and DELETE here, recording one stays free for every role, and there is no approval request path. Every write instead TELLS the owner, through the notify_owner_of_expense trigger.';

-- ---------------------------------------------------------------------------
-- 9. What the enum now means - the retired types said out loud
--
--    D-085 retires three action types. An enum value cannot be dropped, so they stay declared; what
--    must not happen is the type reading as "a chunk is coming" for three actions that will never
--    have one. That reading is exactly what `approval_has_executor()` prevents one row at a time,
--    and the type's own comment is where it is prevented for the schema.
-- ---------------------------------------------------------------------------
comment on type public.approval_action_type is
  'The owner''s list of actions that need his approval (2026-09-21). IMPLEMENTED: discount_above_limit (chunk 1); purchase, purchase_edit, purchase_delete (chunk 3); purchase_return, sale_return, stock_adjustment (chunk 4); product_create, product_edit, product_delete, customer_edit (chunk 5) - `approval_has_executor()` answers true for exactly these. STILL DECLARED, NOT YET IMPLEMENTED: sale_edit and sale_cancel, whose acts do not exist in this application yet (nothing writes sales.status = ''cancelled'', and there is no sale-edit screen), so what a cancellation does to already-posted stock and money is a question the owner has been asked rather than guessed at. RETIRED - never to be implemented: expense_create, expense_edit and expense_delete, because the owner settled that recording an expense needs no approval and wants a NOTIFICATION instead (D-085). `approval_has_executor()` answers false for them for ever and a request naming one is refused in words.';

-- ---------------------------------------------------------------------------
-- 10. Grants - the same idiom 00018 settled for this family
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.save_product(jsonb) to authenticated';
  execute 'revoke execute on function public.save_product(jsonb) from anon, public';

  execute 'grant execute on function public.update_patient(uuid, text, text, text, text, date, integer, integer, text, text, text) to authenticated';
  execute 'revoke execute on function public.update_patient(uuid, text, text, text, text, date, integer, integer, text, text, text) from anon, public';

  execute 'grant execute on function public.approval_has_executor(public.approval_action_type) to authenticated';
  execute 'revoke execute on function public.approval_has_executor(public.approval_action_type) from anon, public';

  execute 'grant execute on function public.request_approval(public.approval_action_type, text, text, jsonb, text, uuid, text) to authenticated';
  execute 'revoke execute on function public.request_approval(public.approval_action_type, text, text, jsonb, text, uuid, text) from anon, public';

  -- Internal: the master-data applier, the dispatch, the one shape check and the trigger. Reachable
  -- from decide_approval() and from the triggers themselves, which is the only place they mean
  -- anything.
  execute 'revoke execute on function public.master_apply_decision(public.approval_action_type, jsonb, boolean) from anon, authenticated, public';
  execute 'revoke execute on function public.approval_execute(public.approval_action_type, uuid, jsonb, boolean) from anon, authenticated, public';
  execute 'revoke execute on function public.document_payload_problem(public.approval_action_type, jsonb, uuid) from anon, authenticated, public';
  execute 'revoke execute on function public.notify_owner_of_expense() from anon, authenticated, public';
exception
  when undefined_object then
    -- Role or function missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
