-- Migration: 20260921000047_phase6_5c_approval_sale_acts | Purpose: build the two sale acts the
-- owner's policy gates - cancelling a posted bill, and correcting a bill's printed identity - and
-- put them behind the same rail (Phase 6.5c chunk 5d).
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create-or-replace functions, guarded revoke/grant.
--
-- The owner's answer (2026-09-21), and what it settled
-- ---------------------------------------------------
-- Chunk 5 asked him one question, because building this gate means building the ACT first: nothing
-- in this application had ever written `sales.status = 'cancelled'`, and a posted bill has already
-- moved stock and posted a ledger entry, so "what does a cancel do to those two" was a design
-- question rather than a policy one.
--
--   * "**this data is only for testing, i will again update data from my current software when this
--     product is fully developed and bug free, so you have to take easy way out, and focus on
--     completing your task**" - so the cancellation is the CHEAP and honest of the two options: a
--     cancel is only for a bill **nothing has happened to**, and anything else is refused in words
--     that name the sale return the owner also approves. No reversal machinery is built, and the
--     migration comment below says exactly what a cancel does NOT do.
--   * "**Yes, narrow only**" - so `sale_edit` is the identity edit and nothing wider: the printed
--     patient name/mobile/address, the prescriber's name and the hospital's reference. The money and
--     the lines are refused by a WHITELIST, in words that name the act which can change them.
--
-- What "nothing has happened to it" means, in the schema's own facts
-- -----------------------------------------------------------------
-- The refusal is not a feeling, it is three queries, and each one is a thing that would be
-- contradicted by the status flip:
--
--   1. **a sale return names it** - the goods came back, so the bill is already corrected;
--   2. **a receipt has been applied to it SINCE it was raised** - a later `payment_allocations` row
--      whose payment is not the bill's own counter settlement, because money attached to a document
--      the flip stops counting is money nothing can explain;
--   3. **it is not settled** (`balance_due > 0`) - cancelling would leave a receivable standing with
--      nothing to attach it to.
--
-- The second one has a subtlety worth writing down, because the first draft of this migration got it
-- wrong: a bill paid at the counter DOES carry an allocation. `ledger_auto_entry_sale()` (migration
-- 00035) writes the payment, its ledger credit and its allocation to the sale **in the same
-- transaction as the sale**, with the payment's `reference_no` set to the bill's own invoice number -
-- so the counter's settlement is part of the bill's own posting, not a later act. Counting it would
-- have made every ordinary counter bill uncancellable and the whole act dead letter, which is not
-- what "take the easy way out" asks for. What the refusal is about is a receipt applied AFTERWARDS
-- (`allocate_payment()`, whose payments carry no such reference), and that is what it tests for.
--
-- One honest consequence of that reading: the second refusal is unreachable through this application
-- today, because `allocate_payment()` will not over-settle a settled bill (D-076) and a bill with
-- anything outstanding is already refused by the third. It is kept, and pinned by a test against a
-- directly-written fixture, because it describes a state a later migration could produce.
--
-- What a cancel does NOT do, stated where the owner reads it
-- ---------------------------------------------------------
-- The goods stay out of stock and the money the bill moved is not reversed: the sale's own ledger
-- entry stands, and the bill stops counting in every report and in every outstanding-bill expression
-- (which is what the `cancelled` value has always meant to them). That is a real trade, so it is not
-- hidden - the owner's queue shows it in the ask's own summary ("the goods stay out of stock and the
-- money it moved is not reversed · a correction that involves the goods is a sale return"), and the
-- refusal for anything else names the return path. Had he wanted the books to agree, this chunk
-- would have built the reversal instead; he chose this one knowing the data is test data and will be
-- re-imported.
--
-- Why the narrow edit is safe to gate
-- ----------------------------------
-- The five columns are SNAPSHOTS taken at checkout (`sales.patient_name` is "the patient as this
-- bill printed them"), so changing one rewrites the paper and never the master, the money or the
-- stock. Two rules come with the schema rather than with this chunk: 00035's
-- `sales_patient_identity_before_7a` constraint requires a pharmacy bill to carry the patient's name
-- AND number together or neither, so an edit that would leave one of the pair alone is refused here
-- rather than raising at the constraint; and an admission bill has to keep a hospital reference
-- (`sales_ipd_needs_reference`), so clearing it is refused in words too.

-- ---------------------------------------------------------------------------
-- 1. document_payload_problem() - replaced: the two sale acts
-- A cancellation and the narrow identity edit are held to the same one check as
-- every other document. The cancellation's refusals are the schema's own facts
-- (a return, an allocation, money still owed); the edit's is a whitelist, so a
-- money or line key is refused BY NAME in a sentence naming the sale return.
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
  v_sale public.sales;
  v_extra text;
  v_new_name text;
  v_new_mobile text;
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

  -- -------------------------------------------------------------------------
  -- The sale acts: cancelling a posted bill, and the narrow identity edit. Every
  -- refusal below names the act that CAN do the thing instead - a sale return -
  -- because a refusal that only says "no" leaves the person holding a bill they
  -- still have to correct.
  -- -------------------------------------------------------------------------
  if p_action_type = 'sale_cancel'::public.approval_action_type then
    if nullif(p_payload ->> 'sale_id', '') is null then
      return 'a cancellation has to name the bill it cancels';
    end if;

    select * into v_sale
      from public.sales s
     where s.id = (p_payload ->> 'sale_id')::uuid
       and s.pharmacy_id = p_pharmacy_id;

    if not found then
      return 'that bill is not in this pharmacy';
    end if;

    if v_sale.status = 'cancelled'::public.sale_status then
      return 'that bill is cancelled already';
    end if;

    -- "A bill nothing has happened to", defined by the schema's own facts: each of these three is
    -- something the status flip would either contradict or strand.
    if exists (select 1 from public.sale_returns r where r.sale_id = v_sale.id) then
      return 'that bill has a sale return against it, so the goods already came back: correct it with another return rather than cancelling it';
    end if;

    -- A receipt applied to the bill SINCE it was raised. The counter's own settlement is not that:
    -- ledger_auto_entry_sale() writes the payment, its ledger credit and its allocation in the
    -- SAME transaction as the sale, with the payment's reference_no set to the bill's own invoice
    -- number - so it is part of the bill's posting, not a later act, and counting it here would make
    -- every ordinary counter bill uncancellable. A receipt applied afterwards carries no such
    -- reference, and THAT is the one that would be left attached to a document nothing counts.
    if exists (
      select 1
        from public.payment_allocations pa
        join public.payments pm on pm.id = pa.payment_id
       where pa.sale_id = v_sale.id
         and pm.reference_no is distinct from v_sale.invoice_no
    ) then
      return 'a receipt has been applied to that bill since it was raised, so cancelling it would leave money attached to a document nothing counts: correct it with a sale return, which the owner also approves';
    end if;

    if v_sale.balance_due > 0 then
      return 'that bill is not settled, so cancelling it would leave money owed against a document nothing counts: correct it with a sale return, which the owner also approves';
    end if;

    return null;
  end if;

  if p_action_type = 'sale_edit'::public.approval_action_type then
    if nullif(p_payload ->> 'sale_id', '') is null then
      return 'an edit has to name the bill it edits';
    end if;

    select * into v_sale
      from public.sales s
     where s.id = (p_payload ->> 'sale_id')::uuid
       and s.pharmacy_id = p_pharmacy_id;

    if not found then
      return 'that bill is not in this pharmacy';
    end if;

    if v_sale.status = 'cancelled'::public.sale_status then
      return 'that bill is cancelled, so there is nothing left to edit on it';
    end if;

    if v_sale.sale_type = 'transfer'::public.sale_type then
      return 'a transfer carries no patient and no prescriber, so it has no printed identity to edit here';
    end if;

    -- The WHITELIST, and it is the whole of the narrow scope. A key that is not one of the five
    -- printed fields is refused by name, in a sentence that says which act can change it.
    select string_agg(k, ', ' order by k)
      into v_extra
      from jsonb_object_keys(coalesce(p_payload, '{}'::jsonb)) as k
     where k not in (
       'sale_id', 'patient_name', 'patient_mobile', 'patient_address',
       'doctor_name', 'hospital_reference', 'idempotency_key'
     );

    if v_extra is not null then
      return 'a posted bill''s ' || v_extra || ' is not editable here: correct the money or the lines with a sale return, which the owner also approves';
    end if;

    if not (p_payload ?| array[
      'patient_name', 'patient_mobile', 'patient_address', 'doctor_name', 'hospital_reference'
    ]) then
      return 'that bill edit changes nothing';
    end if;

    if p_payload ? 'patient_mobile'
       and nullif(btrim(coalesce(p_payload ->> 'patient_mobile', '')), '') is not null
       and public.normalize_indian_mobile(p_payload ->> 'patient_mobile') is null then
      return 'that mobile number is not a valid Indian mobile (10 digits, starting 6-9)';
    end if;

    v_new_name := case when p_payload ? 'patient_name'
                       then nullif(btrim(coalesce(p_payload ->> 'patient_name', '')), '')
                       else v_sale.patient_name end;
    v_new_mobile := case when p_payload ? 'patient_mobile'
                         then public.normalize_indian_mobile(p_payload ->> 'patient_mobile')
                         else v_sale.patient_mobile end;

    -- 00035's constraint, checked here rather than raised at the constraint: a pharmacy bill carries
    -- the patient's name AND number together, or neither.
    if v_sale.sale_type in ('counter'::public.sale_type, 'ipd_admission'::public.sale_type)
       and ((v_new_name is null) <> (v_new_mobile is null)) then
      return 'a pharmacy bill carries the patient''s name and number together, or neither: send both';
    end if;

    -- And an admission bill has to keep a reference - sales_ipd_needs_reference's own rule.
    if v_sale.sale_type = 'ipd_admission'::public.sale_type
       and p_payload ? 'hospital_reference'
       and nullif(btrim(coalesce(p_payload ->> 'hospital_reference', '')), '') is null then
      return 'an admission bill has to keep the hospital''s reference';
    end if;

    return null;
  end if;

  -- An action type this describes nothing about: the caller owns its validation, as it does for a
  -- purchase document and a discount.
  return null;
end;
$$;

comment on function public.document_payload_problem(public.approval_action_type, jsonb, uuid) is
  'Why a payload could not produce a document, or NULL when it could: the contra documents (purchase returns, sale returns, stock adjustments), the master-data documents (a new product, a product edit or alias act, a product deletion, a customer edit) and the two sale acts (a cancellation, which is only for a bill nothing has happened to, and the narrow identity edit, which is held to a whitelist of printed fields). One definition, used by request_approval() so an ask that answering could not carry out never reaches the owner''s list, and by each writer - the three record_*() functions, save_product(), update_patient(), cancel_sale() and save_sale_identity() - so the owner''s own write is held to exactly the same shape.';





-- ---------------------------------------------------------------------------
-- 2. approval_has_executor() - the last two action types
-- With these two the enum has no value left that is neither implemented nor
-- retired, which is what the type's own comment now says.
-- ---------------------------------------------------------------------------
create or replace function public.approval_has_executor(p_action_type public.approval_action_type)
returns boolean
language sql
immutable
as $$
  -- One entry per action type whose chunk has landed. Chunk 1 built the discount, chunk 3 the
  -- purchase document, chunk 4 the three contra documents, chunk 5 the four master-data acts and
  -- chunk 5d the two sale acts - so EVERY declared value is now either here or retired.
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
    'customer_edit'::public.approval_action_type,
    'sale_cancel'::public.approval_action_type,
    'sale_edit'::public.approval_action_type
  );
$$;

comment on function public.approval_has_executor(public.approval_action_type) is
  'Whether this build can actually carry an action type out. request_approval() refuses an action type this returns false for, so the owner''s list can never hold a request that approving would not act on.';





-- ---------------------------------------------------------------------------
-- 3. request_approval() - replaced: a sale act has to carry a document too
-- The sale acts join the one shape check, and the "refresh rather than stack"
-- list grows them: a cancellation and an edit are both revisions of one question
-- about one bill. The whole body travels again; nothing else in it changes.
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

  -- -------------------------------------------------------------------------
  -- The sale acts. Same rule once more: the payload IS the document, so an ask
  -- whose answer could not be carried out - a bill that has since been returned,
  -- settled or cancelled - never reaches the owner's list, and his own act is
  -- held to it as well.
  -- -------------------------------------------------------------------------
  if p_action_type in (
    'sale_cancel'::public.approval_action_type,
    'sale_edit'::public.approval_action_type
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
    'customer_edit'::public.approval_action_type,
    'sale_cancel'::public.approval_action_type,
    'sale_edit'::public.approval_action_type
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
-- 4. The two sale acts
--
--    Each is one RPC for both roles, because `sales` and `sale_items` stop taking writes from a
--    session in section 6: the owner's act is written and returned, anybody else's is raised as one
--    approval request and the envelope says so, exactly as `save_purchase()` and `save_product()`
--    behave. The shape each document has to have lives in `document_payload_problem()` - the ONE
--    check both the ask and the write call - so a refusal reaches the person who asked for it before
--    the owner ever sees the question.
-- ---------------------------------------------------------------------------

-- Cancels a posted bill: the status flips, and nothing else does.
create or replace function public.cancel_sale(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_role     public.app_role := public.get_my_role();
  v_sale_id  uuid := nullif(p_payload ->> 'sale_id', '')::uuid;
  v_key      text := nullif(btrim(coalesce(p_payload ->> 'idempotency_key', '')), '');
  v_problem  text;
  v_sale     public.sales;
  v_request  public.approval_requests;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  v_problem := public.document_payload_problem('sale_cancel', p_payload, v_pharmacy);

  if v_problem is not null then
    raise exception '%', v_problem
      using errcode = 'check_violation';
  end if;

  select * into v_sale
    from public.sales s
   where s.id = v_sale_id
     and s.pharmacy_id = v_pharmacy;

  if v_role = 'owner'::public.app_role then
    -- One statement, one column. A cancellation is not a reversal: see this migration's header for
    -- what it deliberately leaves standing, and for the three refusals that keep it honest.
    update public.sales s
       set status = 'cancelled'::public.sale_status
     where s.id = v_sale.id
    returning * into v_sale;

    -- A cancelled bill has nothing left to ask about, so any question still standing about it is
    -- closed rather than left in the owner's list waiting for an answer that can no longer change
    -- anything. Closed as REFUSED, because that is what it was: he did not allow it. The same rule
    -- chunk 3 applies to a cancelled purchase, and for the same reason - a decision he can never
    -- usefully take is a stuck row, not a question.
    update public.approval_requests a
       set status        = 'rejected'::public.approval_status,
           decided_by    = auth.uid(),
           decided_at    = now(),
           decision_note = 'the bill was cancelled, so this question no longer had an answer'
     where a.pharmacy_id = v_pharmacy
       and a.target_id = v_sale.id
       and a.target_table = 'sales'
       and a.status = 'pending'::public.approval_status;

    return jsonb_build_object(
      'outcome', 'recorded',
      'document', to_jsonb(v_sale),
      'request_id', null
    );
  end if;

  v_request := public.request_approval(
    p_action_type => 'sale_cancel',
    p_title => 'Cancel bill: ' || v_sale.invoice_no,
    p_summary => '₹' || to_char(v_sale.grand_total, 'FM9999999990.00')
      || ' · the goods stay out of stock and the money it moved is not reversed'
      || ' · a correction that involves the goods is a sale return, which you also approve',
    p_payload => p_payload,
    p_target_table => 'sales',
    p_target_id => v_sale.id,
    p_idempotency_key => v_key
  );

  return jsonb_build_object(
    'outcome', 'staged',
    'document', null,
    'request_id', v_request.id
  );
end;
$$;

comment on function public.cancel_sale(jsonb) is
  'Cancels a posted bill, or - for anybody but the owner - raises one sale_cancel approval request and writes nothing. Only for a bill NOTHING has happened to (no sale return, no allocation against it, nothing still owed), which the shared shape check enforces for the ask and for the owner''s own write alike. The status flip is the whole act: the goods are not returned and the bill''s ledger entry is not reversed - the ask says so in its own summary, and a correction involving goods is a sale return. Answers {"outcome", "document", "request_id"}.';

-- Corrects a posted bill's printed identity: who it was for and who prescribed it.
create or replace function public.save_sale_identity(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_role     public.app_role := public.get_my_role();
  v_sale_id  uuid := nullif(p_payload ->> 'sale_id', '')::uuid;
  v_key      text := nullif(btrim(coalesce(p_payload ->> 'idempotency_key', '')), '');
  v_problem  text;
  v_sale     public.sales;
  v_request  public.approval_requests;
  v_name     text;
  v_mobile   text;
  v_changed  text[] := array[]::text[];
  v_field    text;
  v_fields   text[] := array[
    'patient_name', 'patient_mobile', 'patient_address', 'doctor_name', 'hospital_reference'
  ];
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  v_problem := public.document_payload_problem('sale_edit', p_payload, v_pharmacy);

  if v_problem is not null then
    raise exception '%', v_problem
      using errcode = 'check_violation';
  end if;

  select * into v_sale
    from public.sales s
   where s.id = v_sale_id
     and s.pharmacy_id = v_pharmacy;

  if v_role = 'owner'::public.app_role then
    -- The pair 00035's constraint ties together, computed here so the UPDATE can never leave a name
    -- with no number: the shared check refused that state, and this is the write that obeys it.
    v_name := case when p_payload ? 'patient_name'
                   then nullif(btrim(coalesce(p_payload ->> 'patient_name', '')), '')
                   else v_sale.patient_name end;
    v_mobile := case when p_payload ? 'patient_mobile'
                     then public.normalize_indian_mobile(p_payload ->> 'patient_mobile')
                     else v_sale.patient_mobile end;

    update public.sales s set
      patient_name = v_name,
      patient_mobile = v_mobile,
      patient_address = case when p_payload ? 'patient_address'
                             then nullif(btrim(coalesce(p_payload ->> 'patient_address', '')), '')
                             else s.patient_address end,
      doctor_name = case when p_payload ? 'doctor_name'
                         then nullif(btrim(coalesce(p_payload ->> 'doctor_name', '')), '')
                         else s.doctor_name end,
      hospital_reference = case when p_payload ? 'hospital_reference'
                                then nullif(btrim(coalesce(p_payload ->> 'hospital_reference', '')), '')
                                else s.hospital_reference end
     where s.id = v_sale.id
    returning * into v_sale;

    return jsonb_build_object(
      'outcome', 'recorded',
      'document', to_jsonb(v_sale),
      'request_id', null
    );
  end if;

  foreach v_field in array v_fields loop
    if p_payload ? v_field then
      v_changed := array_append(v_changed, v_field);
    end if;
  end loop;

  v_request := public.request_approval(
    p_action_type => 'sale_edit',
    p_title => 'Edit bill: ' || v_sale.invoice_no,
    p_summary => 'Changes: ' || array_to_string(v_changed, ', ')
      || ' · the printed details only - the money, the lines and the stock are untouched',
    p_payload => p_payload,
    p_target_table => 'sales',
    p_target_id => v_sale.id,
    p_idempotency_key => v_key
  );

  return jsonb_build_object(
    'outcome', 'staged',
    'document', null,
    'request_id', v_request.id
  );
end;
$$;

comment on function public.save_sale_identity(jsonb) is
  'Corrects the printed identity of a posted bill - the patient name, mobile and address, the prescriber''s name and the hospital''s reference - or raises one sale_edit approval request for anybody but the owner. Changes no money column, no line and no stock: the payload is held to a WHITELIST by the shared shape check, which refuses any other key in words naming the sale return that can change it. Answers {"outcome", "document", "request_id"}.';

-- ---------------------------------------------------------------------------
-- 5. The applier, and the one dispatch
-- ---------------------------------------------------------------------------

-- Carries out the owner's answer to a sale act.
--
-- Approving runs the very write the client would have run, through the same door, so nothing about
-- the bill changes shape between the ask and the answer. Refusing writes NOTHING AT ALL - not a
-- status restore, not a re-read - because nothing was written when the ask was raised.
create or replace function public.sale_apply_decision(
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

  if p_action_type = 'sale_cancel'::public.approval_action_type then
    perform public.cancel_sale(p_payload);
    return;
  end if;

  if p_action_type = 'sale_edit'::public.approval_action_type then
    perform public.save_sale_identity(p_payload);
    return;
  end if;

  raise exception 'this build cannot carry out a %', p_action_type
    using errcode = 'feature_not_supported';
end;
$$;

comment on function public.sale_apply_decision(public.approval_action_type, jsonb, boolean) is
  'Carries out the owner''s answer to a sale act: approving runs the document the payload carries through the same door the owner''s own write uses (cancel_sale() or save_sale_identity()); refusing writes nothing, because nothing was written. The shared shape check is what re-runs, so an ask whose bill has moved on since it was raised is refused rather than applied. Internal - called by approval_execute(), not executable by a session.';

-- ---------------------------------------------------------------------------
-- 5b. approval_execute() - replaced: the sale acts join the dispatch
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

  if p_action_type in (
    'sale_cancel'::public.approval_action_type,
    'sale_edit'::public.approval_action_type
  ) then
    perform public.sale_apply_decision(
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
  'The single dispatch decide_approval() calls: a purchase is carried out against its staged row, a return, a stock adjustment, a product or customer master act, and a sale act against the document its payload carries, and the discount needs nothing because the sale is its execution. An action type with no writer is refused rather than recorded as approved. Internal - not executable by a session.';





-- ---------------------------------------------------------------------------
-- 6. The revokes - the same migration as the request path, never before it
--
--    `sales` and `sale_items` carried the standard tenant-wide four-policy template from 00012 and
--    the table-level grants Supabase gives every public table, so a session could rewrite a bill -
--    its money, its lines, or its status - straight through PostgREST. They are the LAST pair of
--    tables that still took writes directly, and they stop here.
--
--    Checked before revoking, because a revoke that breaks a live path is worse than the hole it
--    closes: every writer of these two tables in this repository is inside a SECURITY DEFINER
--    function - `checkout_sale()`, the four successive bodies of it in 00019, 00036, 00042 and 00043
--    being the only INSERTs - and no Dart file writes either table (they read `sales` for the list,
--    the filter and the receipt, and `sale_items` for a return and for the receipt's lines). A
--    revoke does not touch a DEFINER function's own rights, so the counter is unaffected.
--
--    The revoke is per-role, so it covers the owner too: his own cancellation is written by
--    `cancel_sale()`, which does exactly what his direct update did and asks him nothing. His
--    AUTHORITY is what is gated, never his route - and there is no route left that a role check
--    could be replaced with.
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'revoke insert, update, delete on public.sales from authenticated';
  execute 'revoke insert, update, delete on public.sale_items from authenticated';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to revoke.
    null;
end $$;

comment on table public.sales is
  'A bill. Written ONLY by checkout_sale() since Phase 6.5c chunk 5d: `authenticated` has no INSERT, UPDATE or DELETE here. The two later acts on a posted bill go through their own door - cancel_sale() for the status, save_sale_identity() for the printed identity - and for anybody but the owner each raises an approval request instead of writing. The read policies are unchanged.';
comment on table public.sale_items is
  'The lines of a bill. Written only by checkout_sale(), in one statement per sale, so a refusal takes the whole set with it. A posted line is never edited: a correction is a sale return, which the owner also approves.';

-- ---------------------------------------------------------------------------
-- 7. What the enum means now - every declared type is implemented or retired
--
--    With this chunk the enum has no "declared for completeness" value left: the two sale acts are
--    real, and the three expense types are RETIRED. The type's own comment has to say that, or it
--    reads as a promise the schema is not keeping in one direction or the other.
-- ---------------------------------------------------------------------------
comment on type public.approval_action_type is
  'The owner''s list of actions that need his approval (2026-09-21). EVERY DECLARED VALUE IS EITHER IMPLEMENTED OR RETIRED, and approval_has_executor() answers true for exactly the implemented ones: discount_above_limit (chunk 1); purchase, purchase_edit, purchase_delete (chunk 3); purchase_return, sale_return, stock_adjustment (chunk 4); product_create, product_edit, product_delete, customer_edit (chunk 5); sale_cancel and sale_edit (chunk 5d). RETIRED - never to be implemented: expense_create, expense_edit and expense_delete, because the owner settled that recording an expense needs no approval and wants a NOTIFICATION instead (D-085); approval_has_executor() answers false for them for ever and a request naming one is refused in words. sale_cancel is only for a bill nothing has happened to (no return against it, no receipt applied since it was raised, nothing still owed) and it is a STATUS FLIP and nothing else - the goods stay out of stock and the money is not reversed; sale_edit covers the printed identity only. The shared shape check, document_payload_problem(), holds both.';

-- ---------------------------------------------------------------------------
-- 8. Grants - the same idiom 00018 settled for this family
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.cancel_sale(jsonb) to authenticated';
  execute 'revoke execute on function public.cancel_sale(jsonb) from anon, public';

  execute 'grant execute on function public.save_sale_identity(jsonb) to authenticated';
  execute 'revoke execute on function public.save_sale_identity(jsonb) from anon, public';

  execute 'grant execute on function public.approval_has_executor(public.approval_action_type) to authenticated';
  execute 'revoke execute on function public.approval_has_executor(public.approval_action_type) from anon, public';

  execute 'grant execute on function public.request_approval(public.approval_action_type, text, text, jsonb, text, uuid, text) to authenticated';
  execute 'revoke execute on function public.request_approval(public.approval_action_type, text, text, jsonb, text, uuid, text) from anon, public';

  -- Internal: the sale applier, the dispatch and the one shape check. Reachable from
  -- decide_approval(), which is the only place they mean anything.
  execute 'revoke execute on function public.sale_apply_decision(public.approval_action_type, jsonb, boolean) from anon, authenticated, public';
  execute 'revoke execute on function public.approval_execute(public.approval_action_type, uuid, jsonb, boolean) from anon, authenticated, public';
  execute 'revoke execute on function public.document_payload_problem(public.approval_action_type, jsonb, uuid) from anon, authenticated, public';
exception
  when undefined_object then
    -- Role or function missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
