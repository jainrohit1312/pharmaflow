-- Migration: 20260922000049_phase6_5c_stale_asks | Purpose: one closure for the questions a
-- document's own changes have washed out, and the sale return that now performs it (chunk 6).
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create-or-replace functions, drop-function-if-exists, guarded grants, comments.
--
-- The question, and the answer this chunk chose
-- --------------------------------------------
-- A request whose document moved on between the ask and the answer is REFUSED, not applied - chunks
-- 3, 4, 5 and 5d all assert that - and it stays `pending`. So the owner's list can hold a question
-- he can never usefully answer: he taps Approve, the executor's own shape check refuses it, the
-- transaction rolls back, and the row is exactly where it was. Tapping again fails the same way.
--
-- Three answers were possible, and the brief named all three:
--
--   * **an expiry** (`expires_at` + a sweep) is impossible here, and not for want of design: a sweep
--     is a SCHEDULE, and this project has none anywhere - no `pg_cron`, no `pg_net`, no
--     `cron.schedule`, nothing in `supabase/config.toml`. Adding an expiry without a sweep would
--     leave a column nothing reads and a row that never leaves the list, which is the same stuck row
--     wearing a date.
--   * **leaving it, with the refusal as the answer** is honest about the write but leaves the module
--     disagreeing with itself: every chunk since 3 has acted on the rule that "a decision he can
--     never usefully take is a stuck row, not a question".
--   * **closing it when its document changes** is what chunk 3 built for a purchase
--     (`approval_close_purchase_asks()` when the owner writes the document himself) and what chunk
--     5d built for a cancelled bill (an inline update in `cancel_sale()`). **CHOSEN**, with the
--     machinery generalised rather than copied a third time.
--
-- One closure, not three
-- ----------------------
-- Section 1 turns those two implementations into ONE function, and sections 2 to 5 route every
-- caller through it. The purchase-specific function is DROPPED in section 6: two functions that
-- close the pending asks about a document are two mechanisms for one action.
--
-- Which asks a change washes out is knowledge that belongs at the DOOR that made the change, so the
-- generic function takes an optional action-type list and each caller names its own. That is what
-- keeps a sale return from closing an identity edit - the printed details of a bill are still
-- perfectly correctable after goods come back - while a cancelled bill closes both, because nothing
-- about it can be acted on again.
--
-- What this chunk does NOT close, and why
-- ---------------------------------------
-- A staff ask that the owner has simply SUPERSEDED - he edited the product himself, so his staff's
-- product edit is redundant - is left standing. It is not the case this policy is about: the ask can
-- still be acted on, and approving it applies a document he can read in full, so it is a no-op
-- rather than a lie. Closing it would be a behaviour change with no defect behind it. What the
-- policy IS about is the ask that can no longer be ANSWERED, and for the master data there is none:
-- `document_payload_problem()` refuses a product or customer document only for a reason the owner's
-- later write does not create (a blank name, a bad mobile, a product in another pharmacy).



-- ---------------------------------------------------------------------------
-- 1. approval_close_target_asks() - the ONE closure
-- Replaces `approval_close_purchase_asks()`, which becomes a set of arguments rather than a
-- function. Asks are closed as REFUSED rather than as anything else, because that is what the
-- document's own change means: he did not allow it, and he cannot now.
--
-- The decision columns are filled from `auth.uid()` and `now()`, which is what 00043's check
-- constraint requires of a decided row - a decided-but-anonymous row is the artefact that would
-- let an unapproved action look approved. That is also why this is the owner's own act (writing
-- or cancelling the document) rather than a background cleanup.
-- ---------------------------------------------------------------------------

create or replace function public.approval_close_target_asks(
  p_target_table text,
  p_target_id uuid,
  p_note text,
  p_action_types public.approval_action_type[] default null,
  p_except uuid default null
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_closed int;
begin
  update public.approval_requests a
     set status        = 'rejected'::public.approval_status,
         decided_by    = auth.uid(),
         decided_at    = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), '')
   where a.pharmacy_id = public.get_my_pharmacy_id()
     and a.target_table = p_target_table
     and a.target_id = p_target_id
     and a.status = 'pending'::public.approval_status
     and (p_action_types is null or a.action_type = any(p_action_types))
     and (p_except is null or a.id <> p_except);

  get diagnostics v_closed = row_count;

  return v_closed;
end;
$$;

comment on function public.approval_close_target_asks(text, uuid, text, public.approval_action_type[], uuid) is
  'Closes every undecided ask about one document, as the owner, with a note saying why - the ONE closure the whole module uses for a question its document has washed out. p_action_types narrows it to the asks this particular change invalidates (a cancelled bill closes both of its acts; a recorded sale return closes only the cancellation, because the printed identity is still correctable), and NULL means every ask about the document. p_except leaves out the decision being taken right now. Returns how many it closed. Internal - not executable by a session.';

comment on table public.approval_requests is
  'One thing the owner has been asked to allow: a purchase, a return, a deletion, a master-data edit, an above-cap discount, a sale act. Written only by request_approval() and changed only by decide_approval() - there is no INSERT or UPDATE policy, so nothing holding a session can forge one or decide its own request. LIFECYCLE: pending is the only state that can be decided, and a pending ask does not expire - there is no scheduler in this project to run a sweep. Instead a document''s own change closes the questions it washes out, through ONE closure, approval_close_target_asks(): the owner writing or cancelling the document himself (chunk 3, chunk 5d), or an act that makes the ask unanswerable (a sale return recorded against a bill, which is the state cancel_sale() refuses for ever after - chunk 6). A question he can never usefully answer would otherwise sit in his list failing on every tap.';



-- ---------------------------------------------------------------------------
-- 2. save_purchase() - replaced: the two closures are the one function now
-- Its own body travels again; the only difference is the two `perform`s, which now name the
-- table and the three action types they always meant.
-- ---------------------------------------------------------------------------

create or replace function public.save_purchase(p_payload jsonb)
returns public.purchases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy    uuid := public.get_my_pharmacy_id();
  v_role        public.app_role := public.get_my_role();
  v_id          uuid := nullif(p_payload ->> 'purchase_id', '')::uuid;
  v_supplier_id uuid := nullif(p_payload ->> 'supplier_id', '')::uuid;
  v_invoice_no  text := nullif(btrim(coalesce(p_payload ->> 'invoice_no', '')), '');
  v_invoice_date date := nullif(p_payload ->> 'invoice_date', '')::date;
  v_notes       text := nullif(btrim(coalesce(p_payload ->> 'notes', '')), '');
  v_wants       public.purchase_status;
  v_items       jsonb := coalesce(p_payload -> 'items', '[]'::jsonb);
  v_key         text := nullif(btrim(coalesce(p_payload ->> 'idempotency_key', '')), '');
  v_sub_total   numeric(14,2) := coalesce((p_payload ->> 'sub_total')::numeric, 0);
  v_discount    numeric(14,2) := coalesce((p_payload ->> 'discount_total')::numeric, 0);
  v_tax_total   numeric(14,2) := coalesce((p_payload ->> 'tax_total')::numeric, 0);
  v_grand_total numeric(14,2) := coalesce((p_payload ->> 'grand_total')::numeric, 0);
  v_supplier    public.suppliers;
  v_existing    public.purchases;
  v_purchase    public.purchases;
  v_created     boolean := v_id is null;
  v_undo        jsonb;
  v_batch_ids   jsonb := '{}'::jsonb;
  v_line        jsonb;
  v_product_id  uuid;
  v_batch_no    text;
  v_batch_id    uuid;
  v_qty         int;
  v_sig         text;
  v_seen        text[] := array[]::text[];
  v_position    int := 0;
  v_action      public.approval_action_type;
  v_title       text;
  v_summary     text;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  v_wants := coalesce(
    nullif(btrim(coalesce(p_payload ->> 'status', '')), ''),
    'draft'
  )::public.purchase_status;

  if v_wants not in (
    'draft'::public.purchase_status,
    'ordered'::public.purchase_status,
    'received'::public.purchase_status,
    'cancelled'::public.purchase_status
  ) then
    raise exception '% is not a status a purchase is written to', v_wants
      using errcode = 'check_violation';
  end if;

  -- -------------------------------------------------------------------------
  -- A cancellation: it moves the status and touches nothing else
  --
  -- Deliberately before any of the document's own validation. A cancellation is
  -- not an edit, so it is not asked to carry an invoice and lines it does not
  -- have - and on a RECEIVED document it must not rewrite or stage anything:
  -- its stock and payable are posted, and a document that says `pending_approval`
  -- over posted stock would be a lie about what is in the ledger.
  -- -------------------------------------------------------------------------
  if v_wants = 'cancelled'::public.purchase_status then
    if v_created then
      raise exception 'a purchase has to exist before it can be cancelled'
        using errcode = 'check_violation';
    end if;

    select * into v_existing
      from public.purchases p
     where p.id = v_id
       and p.pharmacy_id = v_pharmacy
     for update;

    if not found then
      raise exception 'that purchase is not in this pharmacy'
        using errcode = 'check_violation';
    end if;

    if v_existing.status = 'cancelled'::public.purchase_status then
      raise exception 'that purchase is cancelled already'
        using errcode = 'check_violation';
    end if;

    if v_role = 'owner'::public.app_role then
      update public.purchases p
         set status = 'cancelled'::public.purchase_status
       where p.id = v_existing.id
      returning * into v_purchase;

      -- He did it himself, so anything his staff asked about this document has been answered
      -- - by him, by acting. Leaving it in his queue would be a question with no answer left.
      perform public.approval_close_target_asks(
        p_target_table => 'purchases',
        p_target_id => v_purchase.id,
        p_note => 'the owner cancelled the document himself',
        p_action_types => array[
          'purchase'::public.approval_action_type,
          'purchase_edit'::public.approval_action_type,
          'purchase_delete'::public.approval_action_type
        ]::public.approval_action_type[]
      );

      -- Re-read: AFTER triggers have run by now, and the caller gets the row as it stands.
      select * into v_purchase from public.purchases p where p.id = v_purchase.id;

      return v_purchase;
    end if;

    -- Staff: the ask, and NOTHING on the document. A refusal leaves it exactly as it is.
    perform public.request_approval(
      p_action_type => 'purchase_delete',
      p_title => 'Cancel purchase ' || v_existing.invoice_no,
      p_summary =>
        'the document stays in the records and keeps its number, and is taken out of the open '
        || 'orders. Nothing is posted or unposted by this.',
      p_payload => jsonb_build_object('from_status', v_existing.status::text),
      p_target_table => 'purchases',
      p_target_id => v_existing.id,
      p_idempotency_key => v_key
    );

    return v_existing;
  end if;

  -- -------------------------------------------------------------------------
  -- The document's own write
  -- -------------------------------------------------------------------------
  if v_supplier_id is null then
    raise exception 'a purchase needs the supplier the invoice is from'
      using errcode = 'check_violation';
  end if;

  select * into v_supplier
    from public.suppliers s
   where s.id = v_supplier_id
     and s.pharmacy_id = v_pharmacy;

  if not found then
    raise exception 'that supplier is not in this pharmacy'
      using errcode = 'check_violation';
  end if;

  if v_invoice_no is null then
    raise exception 'a purchase needs the supplier''s invoice number'
      using errcode = 'check_violation';
  end if;

  if v_invoice_date is null then
    raise exception 'a purchase needs its invoice date'
      using errcode = 'check_violation';
  end if;

  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'a purchase needs at least one line'
      using errcode = 'check_violation';
  end if;

  -- The payable `ledger_auto_entry_purchase()` will post has to agree with the document that
  -- carries it. Both figures are the invoice's (see the header): this only refuses one that does
  -- not add up.
  if abs(v_grand_total - (v_sub_total + v_tax_total)) > 0.01 then
    raise exception 'the document''s grand total (%) is not its taxable value plus its tax (%)',
      v_grand_total, v_sub_total + v_tax_total
      using errcode = 'check_violation';
  end if;

  if not v_created then
    select * into v_existing
      from public.purchases p
     where p.id = v_id
       and p.pharmacy_id = v_pharmacy
     for update;

    if not found then
      raise exception 'that purchase is not in this pharmacy'
        using errcode = 'check_violation';
    end if;

    -- The same rule `_requireEditable` enforced in the client, now where it cannot be skipped:
    -- a received document's lines produced the stock and the ledger entry, and the triggers
    -- deliberately never reverse those, so editing them would leave the two disagreeing.
    if v_existing.status = 'received'::public.purchase_status then
      raise exception 'this purchase is received already, and its stock is booked in: correct it with a purchase return or a stock adjustment instead'
        using errcode = 'check_violation';
    end if;

    if v_existing.status = 'cancelled'::public.purchase_status then
      raise exception 'this purchase is cancelled already'
        using errcode = 'check_violation';
    end if;

    -- What a refusal puts back. Only captured for an existing document: a document this very
    -- write creates has no pre-image, so refusing the ask that created it means it never
    -- counted, and it is soft-deleted rather than restored.
    v_undo := jsonb_build_object(
      'header', to_jsonb(v_existing),
      'items', coalesce(
        (
          select jsonb_agg(to_jsonb(i) order by i.created_at, i.id)
            from public.purchase_items i
           where i.purchase_id = v_existing.id
             and i.pharmacy_id = v_pharmacy
        ),
        '[]'::jsonb
      )
    );
  end if;

  -- -------------------------------------------------------------------------
  -- The lines, checked for shape before anything is written
  --
  -- Shape only: the money on this document is the supplier's invoice, transcribed
  -- (see the header). What is checked is what the columns themselves require and
  -- what a receipt needs to post - the client checks the same things
  -- (`PurchasesRepository.validateLines`), because a screen that skipped them
  -- would otherwise fail in front of a user with a raw Postgres error.
  -- -------------------------------------------------------------------------
  for v_line in select * from jsonb_array_elements(v_items) loop
    v_position := v_position + 1;

    v_product_id := nullif(v_line ->> 'product_id', '')::uuid;
    v_qty := coalesce((v_line ->> 'qty')::int, 0);
    v_batch_no := nullif(btrim(coalesce(v_line ->> 'batch_no', '')), '');

    if v_product_id is null then
      raise exception 'line % needs a product', v_position
        using errcode = 'check_violation';
    end if;

    if not exists (
      select 1 from public.products pr
       where pr.id = v_product_id
         and pr.pharmacy_id = v_pharmacy
    ) then
      raise exception 'line % names a product that is not in this pharmacy', v_position
        using errcode = 'check_violation';
    end if;

    if v_qty <= 0 then
      raise exception 'line % needs a quantity greater than zero', v_position
        using errcode = 'check_violation';
    end if;

    if coalesce((v_line ->> 'free_qty')::int, 0) < 0 then
      raise exception 'line % cannot have a negative free quantity', v_position
        using errcode = 'check_violation';
    end if;

    if v_wants = 'received'::public.purchase_status then
      if v_batch_no is null then
        raise exception 'line % needs a batch number before the goods can be booked in', v_position
          using errcode = 'check_violation';
      end if;

      if nullif(v_line ->> 'expiry_date', '') is null then
        raise exception 'line % needs an expiry date before the goods can be booked in', v_position
          using errcode = 'check_violation';
      end if;

      -- Two lines naming one batch would make the upsert try to affect one row twice in a single
      -- statement, which Postgres refuses outright anyway - refused here so the sentence says why.
      v_sig := v_product_id::text || '|' || v_batch_no;

      if v_sig = any(v_seen) then
        raise exception 'the same batch of one product appears twice - combine the lines or give them different batch numbers'
          using errcode = 'check_violation';
      end if;

      v_seen := v_seen || v_sig;
    end if;
  end loop;

  -- 1. The batches - only when the goods are being booked in. A draft or an order has batch
  --    numbers on its lines and no batch rows yet, exactly as it had before this migration.
  if v_wants = 'received'::public.purchase_status then
    for v_line in select * from jsonb_array_elements(v_items) loop
      v_product_id := nullif(v_line ->> 'product_id', '')::uuid;
      v_batch_no := nullif(btrim(coalesce(v_line ->> 'batch_no', '')), '');
      v_sig := v_product_id::text || '|' || v_batch_no;

      insert into public.product_batches (
        pharmacy_id, product_id, batch_no, expiry_date, mfg_date,
        purchase_rate, mrp, selling_rate
      ) values (
        v_pharmacy,
        v_product_id,
        v_batch_no,
        nullif(v_line ->> 'expiry_date', '')::date,
        nullif(v_line ->> 'mfg_date', '')::date,
        coalesce((v_line ->> 'purchase_rate')::numeric, 0),
        coalesce((v_line ->> 'mrp')::numeric, 0),
        coalesce((v_line ->> 'selling_rate')::numeric, 0)
      )
      on conflict (pharmacy_id, product_id, batch_no) do update
        set expiry_date  = excluded.expiry_date,
            mfg_date     = excluded.mfg_date,
            purchase_rate = excluded.purchase_rate,
            mrp          = excluded.mrp,
            selling_rate = excluded.selling_rate
      returning id into v_batch_id;

      v_batch_ids := v_batch_ids || jsonb_build_object(v_sig, v_batch_id::text);
    end loop;
  end if;

  -- 2. The header. Its status here is NEVER the posting one: `received` is applied at the very
  --    end, after the lines, so the document-level trigger owns the posting.
  if v_created then
    insert into public.purchases (
      pharmacy_id, supplier_id, invoice_no, invoice_date, status,
      sub_total, discount_total, tax_total, grand_total, notes, created_by
    ) values (
      v_pharmacy,
      v_supplier_id,
      v_invoice_no,
      v_invoice_date,
      (case
        when v_role = 'owner'::public.app_role and v_wants <> 'received'::public.purchase_status
          then v_wants
        when v_role = 'owner'::public.app_role
          then 'draft'::public.purchase_status
        else 'pending_approval'::public.purchase_status
      end),
      v_sub_total,
      v_discount,
      v_tax_total,
      v_grand_total,
      v_notes,
      auth.uid()
    )
    returning * into v_purchase;
  else
    update public.purchases p
       set supplier_id    = v_supplier_id,
           invoice_no     = v_invoice_no,
           invoice_date   = v_invoice_date,
           notes          = v_notes,
           sub_total      = v_sub_total,
           discount_total = v_discount,
           tax_total      = v_tax_total,
           grand_total    = v_grand_total,
           status         = (case
             when v_role = 'owner'::public.app_role and v_wants <> 'received'::public.purchase_status
               then v_wants
             when v_role = 'owner'::public.app_role
               then 'draft'::public.purchase_status
             else 'pending_approval'::public.purchase_status
           end)
     where p.id = v_existing.id
    returning * into v_purchase;
  end if;

  -- 3. The lines, replaced wholesale. Replace rather than diff, exactly as the client did: a GRN
  --    can change a line's batch, quantity and rates, and a partial update would leave the
  --    document's totals describing a line set that no longer exists.
  delete from public.purchase_items i
   where i.purchase_id = v_purchase.id
     and i.pharmacy_id = v_pharmacy;

  for v_line in select * from jsonb_array_elements(v_items) loop
    v_product_id := nullif(v_line ->> 'product_id', '')::uuid;
    v_batch_no := nullif(btrim(coalesce(v_line ->> 'batch_no', '')), '');
    v_sig := v_product_id::text || '|' || v_batch_no;
    v_batch_id := nullif(v_batch_ids ->> v_sig, '')::uuid;

    insert into public.purchase_items (
      pharmacy_id, purchase_id, product_id, batch_id, product_name_raw, batch_no,
      expiry_date, hsn_code, qty, free_qty, purchase_rate, mrp, selling_rate,
      discount_percent, gst_percent,
      cgst_amount, sgst_amount, igst_amount, tax_amount, total_amount
    ) values (
      v_pharmacy,
      v_purchase.id,
      v_product_id,
      v_batch_id,
      nullif(btrim(coalesce(v_line ->> 'product_name_raw', '')), ''),
      v_batch_no,
      nullif(v_line ->> 'expiry_date', '')::date,
      nullif(btrim(coalesce(v_line ->> 'hsn_code', '')), ''),
      coalesce((v_line ->> 'qty')::int, 0),
      coalesce((v_line ->> 'free_qty')::int, 0),
      coalesce((v_line ->> 'purchase_rate')::numeric, 0),
      coalesce((v_line ->> 'mrp')::numeric, 0),
      coalesce((v_line ->> 'selling_rate')::numeric, 0),
      coalesce((v_line ->> 'discount_percent')::numeric, 0),
      coalesce((v_line ->> 'gst_percent')::numeric, 0),
      coalesce((v_line ->> 'cgst_amount')::numeric, 0),
      coalesce((v_line ->> 'sgst_amount')::numeric, 0),
      coalesce((v_line ->> 'igst_amount')::numeric, 0),
      coalesce((v_line ->> 'tax_amount')::numeric, 0),
      coalesce((v_line ->> 'total_amount')::numeric, 0)
    );
  end loop;

  -- 4. The status that posts. Only the owner sets it in a save; a member of staff's document stays
  --    staged, and the flip happens in `decide_approval()` when the owner answers.
  if v_role = 'owner'::public.app_role then
    if v_wants = 'received'::public.purchase_status then
      update public.purchases p
         set status = 'received'::public.purchase_status
       where p.id = v_purchase.id
      returning * into v_purchase;
    end if;

    -- Same as the cancellation above: his own write answers whatever his staff asked about this
    -- document, so the ask does not sit in his queue after he has already done the thing.
    perform public.approval_close_target_asks(
      p_target_table => 'purchases',
      p_target_id => v_purchase.id,
      p_note => 'the owner saved the document himself',
      p_action_types => array[
        'purchase'::public.approval_action_type,
        'purchase_edit'::public.approval_action_type,
        'purchase_delete'::public.approval_action_type
      ]::public.approval_action_type[]
    );

    -- Re-read rather than returning the UPDATE's own row: the receipt's stamp is written by an
    -- AFTER trigger, which runs after RETURNING has been evaluated - so the row returned here
    -- would claim a receipt that had not been posted yet.
    select * into v_purchase from public.purchases p where p.id = v_purchase.id;

    return v_purchase;
  end if;

  update public.purchases p
     set status = 'pending_approval'::public.purchase_status
   where p.id = v_purchase.id
  returning * into v_purchase;

  -- The ask. Its payload is what approving it will DO (`resume_status`) and what a refusal puts
  -- back (`undo`), and the one pending ask about this document is refreshed rather than stacked.
  v_action := public.approval_pending_purchase_type(
    v_purchase.id,
    (case
      when v_created then 'purchase'::public.approval_action_type
      else 'purchase_edit'::public.approval_action_type
    end)
  );

  v_title := 'Purchase ' || v_purchase.invoice_no || ' from ' || v_supplier.name;

  v_summary := v_position || (case when v_position = 1 then ' line' else ' lines' end)
    || ' · ₹' || to_char(v_purchase.grand_total, 'FM9999999990.00')
    || (case v_wants
          when 'received'::public.purchase_status
            then ' · books the goods into stock and raises the supplier payable'
          when 'ordered'::public.purchase_status
            then ' · records it as ordered'
          else ' · saves it as a draft'
        end);

  if v_undo is not null then
    v_summary := v_summary || ' · replaces the document as it stands';
  end if;

  perform public.request_approval(
    p_action_type => v_action,
    p_title => v_title,
    p_summary => v_summary,
    p_payload => jsonb_build_object(
      'resume_status', v_wants::text,
      'undo', v_undo
    ),
    p_target_table => 'purchases',
    p_target_id => v_purchase.id,
    p_idempotency_key => v_key
  );

  -- Re-read, for the same reason as the owner's path above: every caller gets the row as it
  -- actually stands, whatever the triggers did to it.
  select * into v_purchase from public.purchases p where p.id = v_purchase.id;

  return v_purchase;
end;
$$;

comment on function public.save_purchase(jsonb) is
  'The one write path for a purchase document: its header, its lines, and - when it is being booked in - the batches its lines come out of. The owner writes it directly, exactly as PostgREST used to; anybody else''s save is STAGED as pending_approval and raises one approval request whose payload says which status approving it would give the document, and what a refusal restores. A status of `cancelled` is a cancellation rather than an edit: it moves the status and touches nothing else, and for staff it is asked for as purchase_delete with the document left untouched. Refuses a document that is received or cancelled already.';;

-- ---------------------------------------------------------------------------
-- 3. decide_approval() - replaced: the cancelled-purchase closure is the one function now
-- Its own body travels again; one `perform` changes.
-- ---------------------------------------------------------------------------

create or replace function public.decide_approval(
  p_id uuid,
  p_approve boolean,
  p_note text default null
) returns public.approval_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_role     public.app_role := public.get_my_role();
  v_row      public.approval_requests;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  if v_role is distinct from 'owner'::public.app_role then
    raise exception 'only the owner can decide an approval request'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_row
    from public.approval_requests a
   where a.id = p_id
     and a.pharmacy_id = v_pharmacy
   for update;

  if not found then
    raise exception 'that approval request is not in this pharmacy'
      using errcode = 'check_violation';
  end if;

  if v_row.status <> 'pending'::public.approval_status then
    raise exception 'that request has already been decided (%)', v_row.status
      using errcode = 'check_violation';
  end if;

  if not public.approval_has_executor(v_row.action_type) then
    raise exception 'the approval for % is not available yet', v_row.action_type
      using errcode = 'feature_not_supported';
  end if;

  -- The effect, while the request is still the only thing that can move. A write that cannot be
  -- carried out raises here, in one transaction with the decision - so the owner can never see
  -- "approved" on a request whose effect never landed.
  perform public.approval_execute(
    p_action_type => v_row.action_type,
    p_target_id => v_row.target_id,
    p_payload => v_row.payload,
    p_approve => p_approve
  );

  update public.approval_requests a
     set status        = (case when p_approve then 'approved' else 'rejected' end)::public.approval_status,
         decided_by    = auth.uid(),
         decided_at    = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), '')
   where a.id = v_row.id
  returning * into v_row;

  -- A cancelled purchase has nothing left to ask about, so any other ask about it is closed
  -- rather than left in the owner's list waiting for an answer that can no longer change anything.
  -- Closed as REFUSED, because that is what it was: he did not allow it. Every other outcome
  -- leaves the document's other questions standing - a receipt does not stop anyone asking to
  -- cancel it afterwards, and a refusal does not answer a different question.
  if v_row.action_type in (
    'purchase'::public.approval_action_type,
    'purchase_edit'::public.approval_action_type,
    'purchase_delete'::public.approval_action_type
  ) then
    if exists (
      select 1 from public.purchases p
       where p.id = v_row.target_id
         and p.pharmacy_id = v_pharmacy
         and p.status = 'cancelled'::public.purchase_status
    ) then
      perform public.approval_close_target_asks(
        p_target_table => 'purchases',
        p_target_id => v_row.target_id,
        p_note => 'the document was cancelled, so this question no longer had an answer',
        p_action_types => array[
          'purchase'::public.approval_action_type,
          'purchase_edit'::public.approval_action_type,
          'purchase_delete'::public.approval_action_type
        ]::public.approval_action_type[],
        p_except => v_row.id
      );
    end if;
  end if;

  return v_row;
end;
$$;

comment on function public.decide_approval(uuid, boolean, text) is
  'The owner''s answer to one request: approved or rejected, with a note. Owner only; a request can be decided once. Approving carries the write out here - a purchase takes the status it was saved with, a return or a stock adjustment is written from the document its payload carries - which is what makes "approved" mean something. An action type this build cannot execute, and a decision whose write cannot be carried out, are refused rather than recorded.';;

-- ---------------------------------------------------------------------------
-- 4. cancel_sale() - replaced: its own UPDATE becomes the one closure
-- Its own body travels again. The inline UPDATE it carried since chunk 5d was the SECOND
-- implementation of this rule; it is now a call, and the rule it applies is unchanged.
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

    -- A cancelled bill has nothing left for its own questions to be about, so they are closed
    -- rather than left in the owner's list waiting for an answer that can no longer change anything.
    -- Closed as REFUSED, because that is what it was: he did not allow it - and through the ONE
    -- closure chunk 3 introduced for a cancelled purchase, not a second update of its own.
    perform public.approval_close_target_asks(
      p_target_table => 'sales',
      p_target_id => v_sale.id,
      p_note => 'the bill was cancelled, so this question no longer had an answer',
      p_action_types => array[
        'sale_cancel'::public.approval_action_type,
        'sale_edit'::public.approval_action_type
      ]::public.approval_action_type[]
    );

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
  'Cancels a posted bill, or - for anybody but the owner - raises one sale_cancel approval request and writes nothing. Only for a bill NOTHING has happened to (no sale return, no allocation against it, nothing still owed), which the shared shape check enforces for the ask and for the owner''s own write alike. The status flip is the whole act: the goods are not returned and the bill''s ledger entry is not reversed - the ask says so in its own summary, and a correction involving goods is a sale return. Answers {"outcome", "document", "request_id"}.';;

-- ---------------------------------------------------------------------------
-- 5. record_sale_return() - replaced: a recorded return closes the cancel ask it strands
-- Its own body travels again, with one call added in the owner's branch. That branch is also the
-- one `document_apply_decision()` performs, so an approved return closes the ask at the moment
-- the return is written - which is the moment the bill actually moves on. A staff return writes
-- nothing, so it closes nothing: the bill has not changed yet.
-- ---------------------------------------------------------------------------

-- Records a sale return: goods coming back from a patient.
create or replace function public.record_sale_return(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy  uuid := public.get_my_pharmacy_id();
  v_role      public.app_role := public.get_my_role();
  v_sale      public.sales;
  v_sale_id   uuid := nullif(p_payload ->> 'sale_id', '')::uuid;
  v_items     jsonb := coalesce(p_payload -> 'items', '[]'::jsonb);
  v_restock   boolean;
  v_key       text := nullif(btrim(coalesce(p_payload ->> 'idempotency_key', '')), '');
  v_doc       public.sale_returns;
  v_request   public.approval_requests;
  v_problem   text;
  v_lines     int;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  v_problem := public.document_payload_problem('sale_return', p_payload, v_pharmacy);

  if v_problem is not null then
    raise exception '%', v_problem
      using errcode = 'check_violation';
  end if;

  select * into v_sale
    from public.sales s
   where s.id = v_sale_id
     and s.pharmacy_id = v_pharmacy;

  if not found then
    raise exception 'that sale is not in this pharmacy'
      using errcode = 'check_violation';
  end if;

  -- The shared check above guarantees this key is the literal `true` or `false`, so the cast cannot
  -- fail - and there is no default on purpose: `stock_restore_on_sale_return()` reads a missing
  -- `restock` as false, so guessing "true" would put goods back on the shelf nobody said were
  -- resellable, and guessing "false" would write off goods somebody did.
  v_restock := (p_payload ->> 'restock')::boolean;

  v_lines := jsonb_array_length(v_items);

  if v_role = 'owner'::public.app_role then
    insert into public.sale_returns (
      pharmacy_id, sale_id, customer_id, return_date, reason, refund_mode, restock,
      sub_total, tax_total, grand_total, created_by
    ) values (
      v_pharmacy,
      v_sale.id,
      v_sale.customer_id,
      coalesce(nullif(p_payload ->> 'return_date', '')::date, current_date),
      nullif(btrim(coalesce(p_payload ->> 'reason', '')), ''),
      coalesce((p_payload ->> 'refund_mode')::public.payment_mode, 'cash'),
      v_restock,
      coalesce((p_payload ->> 'sub_total')::numeric, 0),
      coalesce((p_payload ->> 'tax_total')::numeric, 0),
      coalesce((p_payload ->> 'grand_total')::numeric, 0),
      auth.uid()
    )
    returning * into v_doc;

    insert into public.sale_return_items (
      pharmacy_id, sale_return_id, sale_item_id, product_id, batch_id, qty,
      rate, gst_percent, tax_amount, total_amount
    )
    select
      v_pharmacy,
      v_doc.id,
      nullif(i ->> 'sale_item_id', '')::uuid,
      nullif(i ->> 'product_id', '')::uuid,
      nullif(i ->> 'batch_id', '')::uuid,
      coalesce((i ->> 'qty')::int, 0),
      coalesce((i ->> 'rate')::numeric, 0),
      coalesce((i ->> 'gst_percent')::numeric, 0),
      coalesce((i ->> 'tax_amount')::numeric, 0),
      coalesce((i ->> 'total_amount')::numeric, 0)
    from jsonb_array_elements(v_items) i;

    select * into v_doc from public.sale_returns r where r.id = v_doc.id;

    -- The bill now has a return against it, and that is exactly the state `document_payload_problem()`
    -- refuses a cancellation for ("that bill has a sale return against it, so the goods already came
    -- back"). A question his staff still had standing to CANCEL this bill can therefore never be
    -- answered - approving it would raise on every tap - so it is closed here, through the ONE
    -- closure, at the moment the bill moved on. Only the cancellation asks: the printed identity of a
    -- bill that has had something returned is still perfectly correctable.
    perform public.approval_close_target_asks(
      p_target_table => 'sales',
      p_target_id => v_sale.id,
      p_note => 'a sale return was recorded against the bill, so it can no longer be cancelled',
      p_action_types => array[
        'sale_cancel'::public.approval_action_type
      ]::public.approval_action_type[]
    );

    return jsonb_build_object(
      'outcome', 'recorded',
      'document', to_jsonb(v_doc),
      'request_id', null
    );
  end if;

  v_request := public.request_approval(
    p_action_type => 'sale_return',
    p_title => 'Sale return for ' || v_sale.invoice_no,
    p_summary => v_lines || (case when v_lines = 1 then ' line' else ' lines' end)
      || ' · ₹' || to_char(coalesce((p_payload ->> 'grand_total')::numeric, 0), 'FM9999999990.00')
      || (case when v_restock then ' · the goods go back on the shelf'
               else ' · written off, not restocked' end),
    p_payload => p_payload,
    p_target_table => 'sale_returns',
    p_idempotency_key => v_key
  );

  return jsonb_build_object(
    'outcome', 'staged',
    'document', null,
    'request_id', v_request.id
  );
end;
$$;

comment on function public.record_sale_return(jsonb) is
  'Records a sale return, or - for anybody but the owner - raises one approval request carrying it and writes nothing. The patient comes from the sale and the restock decision from the payload; the lines are written in ONE statement so a refusal takes the whole set. Answers with {"outcome", "document", "request_id"}.';;

-- ---------------------------------------------------------------------------
-- 6. The purchase-specific closure is retired
-- Dropped rather than left beside the generic one: two functions that close the pending asks
-- about a document are two mechanisms for one action, which is the rule this module has kept
-- since chunk 1. Nothing calls it after sections 2 and 3, and it was never reachable by a session.
-- ---------------------------------------------------------------------------

drop function if exists public.approval_close_purchase_asks(uuid, uuid, text);


-- ---------------------------------------------------------------------------
-- 7. Grants
-- The new closure is internal exactly as the function it replaces was: reachable from
-- `save_purchase()`, `decide_approval()`, `cancel_sale()` and `record_sale_return()`, all
-- SECURITY DEFINER, which is the only place it means anything.
-- ---------------------------------------------------------------------------

do $$
begin
  execute 'revoke execute on function public.approval_close_target_asks(text, uuid, text, public.approval_action_type[], uuid) from anon, authenticated, public';
exception
  when undefined_object then
    -- Role or function missing in a bare (non-Supabase) cluster: nothing to revoke.
    null;
end $$;
