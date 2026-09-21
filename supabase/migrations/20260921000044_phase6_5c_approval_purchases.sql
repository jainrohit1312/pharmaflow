-- Migration: 20260921000044_phase6_5c_approval_purchases | Purpose: put the purchase document
-- behind the owner's approval - a staff write is a PENDING document, nothing posts until he says
-- yes, and the tables stop accepting writes from a session altogether.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: `alter type ... add value if not exists`, create-or-replace functions, guarded
-- revoke/grant.

-- The owner's policy, and what "pending GRN" means here
-- ---------------------------------------------------
-- His words (2026-09-21): "I need owner approval on purchase, sale return, purchase return, any
-- modification and deletion from staff. Only sale bill is allowed without approval, rest all
-- functionality is allowed only on approval from owner." Asked how a purchase is gated he chose a
-- **PENDING GRN**: "the GRN is saved as `pending_approval` and nothing posts (no batch stock, no
-- supplier ledger) until he approves. Approving runs the same triggers that run today." And asked
-- what deletion means, he chose a **soft delete**: the row stays, its status becomes `cancelled`.
--
-- So this migration is one status value, one write path, one decision path, and the grants:
--
--   * `purchase_status` gains `pending_approval`. A staff write lands there whatever it asked
--     for; the status the write *wanted* rides on the request as `resume_status`, so approving is
--     "give the document the status it was written with" and rejecting is "put it back".
--   * `save_purchase()` replaces the four writes the client used to make straight to the tables
--     (`purchases` insert/update, `purchase_items` delete+insert, `product_batches` upsert). For
--     the OWNER it behaves exactly as the direct write did - he is not gated, and this is the same
--     route rather than a second one. For STAFF it stages the document and raises the ask.
--   * `decide_approval()` gains the dispatch: approving a purchase runs the write, which is the
--     status flip that fires `stock_apply_purchase()` and `ledger_auto_entry_purchase()` - the
--     very triggers a direct write fired, untouched.
--   * `purchases` and `purchase_items` lose INSERT/UPDATE/DELETE to `authenticated`. This ships in
--     the SAME migration as the request path, never before it: revoking first would leave staff
--     unable to save a purchase at all.
--
-- Why the document is STAGED rather than held in the request payload
-- ---------------------------------------------------------------
-- The alternative was to leave the table alone and carry the whole document in `payload`, applying
-- it on approval. Staging is what the owner's own answer asks for ("the GRN is saved as
-- pending_approval"), and it is the truer of the two states: the document exists, its lines exist,
-- the batches it will come out of exist, the staff can keep working on it, and the owner reads the
-- document itself rather than a copy of it that could differ from what the row would have been.
-- What approving then has to do is exactly one thing - move the status - which is why the posting
-- path cannot drift from the direct one.
--
-- The price of staging, stated rather than discovered: a batch row created for a pending GRN is
-- created at request time (the stock trigger joins on `purchase_items.batch_id`, so the lines need
-- their batches before the status can move), and a REJECTED pending GRN therefore leaves those
-- batch rows behind with a quantity of zero. They hold no stock, they are the rows a later receipt
-- of the same batch would use anyway, and nothing reads a zero-quantity batch as stock - so the
-- cost is a few rows, not a wrong number anywhere.
--
-- What the document's money is, and is not
-- ----------------------------------------
-- **Not recomputed here.** `grand_total` is what the supplier's invoice says is payable, and
-- `ledger_auto_entry_purchase()` posts exactly that (its own comment says so). The invoice is a
-- paper the pharmacy transcribes; a server recomputing `qty x rate` would overwrite the figure on
-- that paper with the pharmacy's own arithmetic, which is the opposite of the rule the sales path
-- follows (D-080) and the opposite of what a purchase IS. So the figures travel from the client,
-- as they did on the direct write, and the one guard here is that the document adds up: its grand
-- total has to be its taxable value plus its tax, or the ledger would hold a payable the document
-- itself contradicts.
--
-- Why a status change is written through `save_purchase` too
-- --------------------------------------------------------
-- There is deliberately no `set_purchase_status()`. "Mark as ordered" is an edit like any other -
-- the owner's policy gates "any modification" - and a status-only RPC would be a second write path
-- for one action, with its own ask, its own staging and its own staleness. Instead the client
-- re-saves the document it has just read with the new status, which stages the content and the
-- status together. A **cancellation is the one exception**, and it is not an edit: it moves the
-- status and touches nothing else, so `save_purchase(status => 'cancelled')` neither rewrites the
-- document nor stages it (staging a received document as `pending_approval` would describe posted
-- stock as unposted). Its ask is `purchase_delete`, and a refusal changes nothing at all.

-- ---------------------------------------------------------------------------
-- 1. The status a staff write waits in
--
--    Appended, so the four statuses that already exist keep the meaning and the sort order they
--    had. Nothing in the schema writes or compares a literal `pending_approval` in DDL - every use
--    is inside a function body, which PostgreSQL only resolves when the function runs. That is
--    deliberate: `alter type ... add value` may not be *used* in the transaction that adds it, and
--    this migration has to apply in one, because that is how `supabase db push` applies a file.
-- ---------------------------------------------------------------------------
alter type public.purchase_status add value if not exists 'pending_approval';

comment on type public.purchase_status is
  'A purchase document''s life. `pending_approval` is a staff write waiting for the owner: the document and its lines are written, nothing has posted, and `decide_approval()` moves it to the status the write asked for. `received` is still the single status that posts stock and a supplier payable (D-013).';

-- ---------------------------------------------------------------------------
-- 2. approval_has_executor() - the three action types this chunk makes real
--
--    The one list that decides whether an ask may be created, kept in step with the dispatch in
--    section 5 by hand: an action type is added here in the same migration that adds its executor,
--    and `request_approval()` refuses one this returns false for.
-- ---------------------------------------------------------------------------
create or replace function public.approval_has_executor(p_action_type public.approval_action_type)
returns boolean
language sql
immutable
as $$
  -- One entry per action type whose chunk has landed. Phase 6.5c chunk 1 built the discount; this
  -- chunk builds the purchase document's three.
  select p_action_type in (
    'discount_above_limit'::public.approval_action_type,
    'purchase'::public.approval_action_type,
    'purchase_edit'::public.approval_action_type,
    'purchase_delete'::public.approval_action_type
  );
$$;

comment on function public.approval_has_executor(public.approval_action_type) is
  'Whether this build can actually carry an action type out. request_approval() refuses an action type this returns false for, so the owner''s list can never hold a request that approving would not act on.';

-- ---------------------------------------------------------------------------
-- 3. request_approval() - replaced: an ask about a purchase has to name a document it can act on
--
--    Two changes, and nothing else:
--
--      * the purchase action types are VALIDATED. An ask about a purchase names a real document in
--        the caller's pharmacy; a content ask names one that is already staged, and says which
--        status approving it would give the document - without that, "approve" would have nothing
--        to do and the owner's list would hold a request whose answer could not be carried out;
--      * an undecided ask about the same document is REFRESHED rather than stacked. A staff member
--        who keeps working on a staged GRN is refining one question, not asking it five times, so
--        the ask the owner already has is updated in place. (The unique index in 00043 is the same
--        rule for one action type; this is what makes it hold while a document's own life can move
--        between `purchase` and `purchase_edit`.)
--
--    The whole body travels again because applied migrations are never edited; everything below
--    outside these two places is 00043's own text.
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

  if v_key is not null then
    select * into v_row
      from public.approval_requests a
     where a.pharmacy_id = v_pharmacy
       and a.idempotency_key = v_key;

    if found then
      return v_row;
    end if;
  end if;

  -- One undecided ask per document, refreshed rather than stacked. Restricted to the purchase
  -- action types on purpose: theirs is the case where the same person keeps refining one question
  -- about one row. Every other action type keeps the behaviour 00043 gave it.
  if p_action_type in (
    'purchase'::public.approval_action_type,
    'purchase_edit'::public.approval_action_type,
    'purchase_delete'::public.approval_action_type
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
  'Raises one approval request. Any authorised member of the pharmacy may ask; only the owner may decide (decide_approval). Refuses an action type this build cannot execute, refuses a discount the counter may simply give, refuses a purchase ask that does not name a document it could act on, and refreshes an undecided ask about the same purchase instead of stacking a second one. Idempotent on p_idempotency_key.';

-- ---------------------------------------------------------------------------
-- 4. The purchase write path
-- ---------------------------------------------------------------------------

-- The action type a new ask about this document should carry: the one an undecided ask already
-- carries, so it converges into that ask instead of putting a second question about one document
-- into the owner's list; or `p_fallback` when the document has nothing pending.
--
-- Not callable by a session (see the grants): it exists so that `save_purchase()` and the executor
-- agree on one rule rather than each spelling it out.
create or replace function public.approval_pending_purchase_type(
  p_purchase_id uuid,
  p_fallback public.approval_action_type
) returns public.approval_action_type
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select a.action_type
        from public.approval_requests a
       where a.pharmacy_id = public.get_my_pharmacy_id()
         and a.target_id = p_purchase_id
         and a.status = 'pending'::public.approval_status
         and a.action_type in (
           'purchase'::public.approval_action_type,
           'purchase_edit'::public.approval_action_type
         )
       order by a.requested_at
       limit 1
    ),
    p_fallback
  );
$$;

comment on function public.approval_pending_purchase_type(uuid, public.approval_action_type) is
  'The action type a new ask about a purchase should carry: whatever an undecided ask about that document already carries, so the ask converges instead of stacking. Internal - not executable by a session.';

-- Closes every undecided ask about one purchase document, as the caller: the owner who wrote the
-- document himself, or the decision that just cancelled it.
--
-- The decision columns are required to be filled on a decided row (00043's own check constraint),
-- which is why this is the owner's action and not a background cleanup: `decided_by` is `auth.uid()`
-- and the note says what happened. Called only from `decide_approval()` and `save_purchase()`.
create or replace function public.approval_close_purchase_asks(
  p_purchase_id uuid,
  p_except uuid,
  p_note text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.approval_requests a
     set status        = 'rejected'::public.approval_status,
         decided_by    = auth.uid(),
         decided_at    = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), '')
   where a.pharmacy_id = public.get_my_pharmacy_id()
     and a.target_id = p_purchase_id
     and a.action_type in (
       'purchase'::public.approval_action_type,
       'purchase_edit'::public.approval_action_type,
       'purchase_delete'::public.approval_action_type
     )
     and a.status = 'pending'::public.approval_status
     and (p_except is null or a.id <> p_except);
end;
$$;

comment on function public.approval_close_purchase_asks(uuid, uuid, text) is
  'Closes every undecided ask about one purchase, as the owner, with a note saying why. Used when the owner writes the document himself and when a decision cancels it. Internal - not executable by a session.';

-- Saves a purchase document: its header, its lines, and - when it is being booked in - the batches
-- its lines come out of.
--
-- The ONE write path for a purchase, and the same one for both roles. The owner gets exactly what
-- the direct write gave him, because he is not gated; a member of staff gets a document staged as
-- `pending_approval` and one question in the owner's list. Which of the two happens is decided
-- here, on `get_my_role()`, and nowhere in the client - a client that skipped the gate would be
-- refused by the tables, whose write grants are revoked at the end of this migration.
--
-- The order of the writes is load-bearing and is the order the client used to use:
--   1. the batches, WITHOUT `qty` (the stock trigger joins on `purchase_items.batch_id` and
--      increments an existing batch, so a line written first would reference nothing and the stock
--      would silently never arrive - and leaving `qty` out means a repeat upsert cannot zero a
--      batch nobody would restore; see the re-receipt trap in `grn_write_order.sql`);
--   2. the lines;
--   3. the status - and for a receipt that is the LAST thing that happens, so
--      `stock_apply_purchase()` owns the posting exactly as it does for a direct write.
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
      perform public.approval_close_purchase_asks(
        p_purchase_id => v_purchase.id,
        p_except => null,
        p_note => 'the owner cancelled the document himself'
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
    perform public.approval_close_purchase_asks(
      p_purchase_id => v_purchase.id,
      p_except => null,
      p_note => 'the owner saved the document himself'
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
  'The one write path for a purchase document: its header, its lines, and - when it is being booked in - the batches its lines come out of. The owner writes it directly, exactly as PostgREST used to; anybody else''s save is STAGED as pending_approval and raises one approval request whose payload says which status approving it would give the document, and what a refusal restores. A status of `cancelled` is a cancellation rather than an edit: it moves the status and touches nothing else, and for staff it is asked for as purchase_delete with the document left untouched. Refuses a document that is received or cancelled already.';

-- ---------------------------------------------------------------------------
-- 5. decide_approval() - replaced: approving a purchase is what carries the write out
--
--    Owner only, and `for update` on the row so two taps cannot both decide it - unchanged. What
--    is new is the dispatch: for a purchase the decision is APPLIED here, as the owner, through
--    the document's own status. Approving a receipt moves the document to `received`, and that
--    one update fires `stock_apply_purchase()` and `ledger_auto_entry_purchase()` - the triggers a
--    direct write fired, with no second copy of their logic anywhere.
--
--    A decision that cannot be applied is refused rather than recorded: the write happens before
--    the request is stamped, both in one transaction, so the owner can never see "approved" on a
--    request whose effect never landed.
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

  -- The effect, while the request is still the only thing that can move.
  perform public.purchase_apply_decision(
    p_purchase_id => v_row.target_id,
    p_action_type => v_row.action_type,
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

  -- A cancelled document has nothing left to ask about, so any other ask about it is closed
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
      perform public.approval_close_purchase_asks(
        p_purchase_id => v_row.target_id,
        p_except => v_row.id,
        p_note => 'the document was cancelled, so this question no longer had an answer'
      );
    end if;
  end if;

  return v_row;
end;
$$;

comment on function public.decide_approval(uuid, boolean, text) is
  'The owner''s answer to one request: approved or rejected, with a note. Owner only; a request can be decided once. Approving a purchase carries the write out here - the document takes the status it was saved with, which for a receipt fires the stock and ledger triggers a direct write fired. An action type this build cannot execute, and a decision that cannot be applied, are refused rather than recorded.';

-- The purchase half of `decide_approval()`: what an answer to a purchase ask actually does.
--
-- A no-op for every other action type, so the dispatch is one call rather than a branch at the
-- call site. It refuses rather than guesses: a document that has moved on since the ask was raised
-- is named, not acted on - approving "book these goods in" against a document somebody has already
-- received would otherwise put a status on it that its posted stock contradicts.
create or replace function public.purchase_apply_decision(
  p_purchase_id uuid,
  p_action_type public.approval_action_type,
  p_payload jsonb,
  p_approve boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_purchase public.purchases;
  v_resume   public.purchase_status;
  v_undo     jsonb := p_payload -> 'undo';
begin
  if p_action_type not in (
    'purchase'::public.approval_action_type,
    'purchase_edit'::public.approval_action_type,
    'purchase_delete'::public.approval_action_type
  ) then
    return;
  end if;

  if p_purchase_id is null then
    raise exception 'that request does not name a purchase document'
      using errcode = 'check_violation';
  end if;

  select * into v_purchase
    from public.purchases p
   where p.id = p_purchase_id
     and p.pharmacy_id = v_pharmacy
   for update;

  if not found then
    raise exception 'that purchase is not in this pharmacy'
      using errcode = 'check_violation';
  end if;

  if p_action_type = 'purchase_delete'::public.approval_action_type then
    -- Nothing was staged for a cancellation, so a refusal has nothing to undo.
    if p_approve then
      if v_purchase.status = 'cancelled'::public.purchase_status then
        raise exception 'that purchase is cancelled already'
          using errcode = 'check_violation';
      end if;

      update public.purchases p
         set status = 'cancelled'::public.purchase_status
       where p.id = v_purchase.id;
    end if;

    return;
  end if;

  if p_approve then
    if v_purchase.status <> 'pending_approval'::public.purchase_status then
      raise exception 'that purchase has moved on since this was asked (% now) - it is no longer waiting for this answer', v_purchase.status
        using errcode = 'check_violation';
    end if;

    v_resume := coalesce(
      nullif(btrim(coalesce(p_payload ->> 'resume_status', '')), ''),
      ''
    )::public.purchase_status;

    if v_resume not in (
      'draft'::public.purchase_status,
      'ordered'::public.purchase_status,
      'received'::public.purchase_status
    ) then
      raise exception 'that request does not say what approving it would do'
        using errcode = 'check_violation';
    end if;

    -- THE write: for a receipt this one update fires the stock and the supplier-payable triggers,
    -- exactly the write a direct receipt ran, because it IS the same transition.
    update public.purchases p
       set status = v_resume
     where p.id = v_purchase.id;

    return;
  end if;

  -- Refused. A document the ask itself created never counted as one, so it is soft-deleted; one
  -- that already existed goes back to exactly what it was.
  if v_undo is null or v_undo = 'null'::jsonb then
    update public.purchases p
       set status = 'cancelled'::public.purchase_status
     where p.id = v_purchase.id;

    return;
  end if;

  perform public.purchase_restore_document(p_purchase_id, v_undo);
end;
$$;

comment on function public.purchase_apply_decision(uuid, public.approval_action_type, jsonb, boolean) is
  'Carries out the owner''s answer to a purchase request: approving gives the document the status it was saved with, refusing restores what the document was before the save - or soft-deletes it, when the refused ask is the one that created it. Internal - called by decide_approval(), not executable by a session.';

-- Puts a document and its lines back exactly as they were before a save that is now refused.
--
-- The pre-image is the whole row plus its lines, captured by `save_purchase()` before it wrote
-- anything (see the `undo` key). Column by column rather than `delete`/`insert`, so the document's
-- id, its number and its audit trail survive a refusal untouched - and its lines are rewritten
-- only because a line set is what an edit replaces.
create or replace function public.purchase_restore_document(
  p_purchase_id uuid,
  p_undo jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
begin
  -- The restore never sets a status that posts: a document can only reach it while it is editable,
  -- and `save_purchase()` refuses to stage a received one. The comment is here because the
  -- invariant is load-bearing rather than obvious.
  update public.purchases p
     set supplier_id    = r.supplier_id,
         invoice_no     = r.invoice_no,
         invoice_date   = r.invoice_date,
         notes          = r.notes,
         status         = r.status,
         sub_total      = r.sub_total,
         discount_total = r.discount_total,
         tax_total      = r.tax_total,
         grand_total    = r.grand_total
    from jsonb_populate_record(null::public.purchases, p_undo -> 'header') r
   where p.id = p_purchase_id
     and p.pharmacy_id = v_pharmacy;

  delete from public.purchase_items i
   where i.purchase_id = p_purchase_id
     and i.pharmacy_id = v_pharmacy;

  insert into public.purchase_items (
    id, pharmacy_id, purchase_id, product_id, batch_id, product_name_raw, batch_no,
    expiry_date, hsn_code, qty, free_qty, purchase_rate, mrp, selling_rate,
    discount_percent, gst_percent,
    cgst_amount, sgst_amount, igst_amount, tax_amount, total_amount,
    created_at, updated_at
  )
  select
    r.id, r.pharmacy_id, r.purchase_id, r.product_id, r.batch_id, r.product_name_raw,
    r.batch_no, r.expiry_date, r.hsn_code, r.qty, r.free_qty, r.purchase_rate, r.mrp,
    r.selling_rate, r.discount_percent, r.gst_percent,
    r.cgst_amount, r.sgst_amount, r.igst_amount, r.tax_amount, r.total_amount,
    r.created_at, r.updated_at
  from jsonb_populate_recordset(null::public.purchase_items, p_undo -> 'items') r
  -- The line trigger fires on this insert as it does on any other. It posts nothing while the
  -- document is not received, which is the only status this can restore to.
  where r.purchase_id = p_purchase_id;
end;
$$;

comment on function public.purchase_restore_document(uuid, jsonb) is
  'Restores a purchase document and its lines from the pre-image a staged save recorded, column by column so the id, the number and the audit trail survive. Internal - called by purchase_apply_decision(), not executable by a session.';

-- ---------------------------------------------------------------------------
-- 6. The revokes - the same migration as the request path, never before it
--
--    Before this, ANY member of the pharmacy could write a purchase straight through PostgREST:
--    `purchases` and `purchase_items` carried the standard tenant-wide four-policy template from
--    00012 and the table-level grants Supabase gives every public table. A gate that lived in a
--    screen would have been a suggestion, because anything holding a session could write the
--    table. So the two tables stop taking writes from `authenticated` altogether and are reachable
--    only through `save_purchase()`.
--
--    The revoke is per-role, so it covers the owner too: he writes "directly" through the same
--    function, which does exactly what his direct write did and asks him nothing. His AUTHORITY is
--    what is gated, never his route.
--
--    `product_batches` deliberately keeps its grants in this chunk: the product form writes batches
--    for the master (a chunk 5 concern, where the product actions are gated), and revoking them
--    here would break a screen whose chunk has not landed. The hole that leaves - a session can
--    still move a batch's `qty` by hand - is recorded in DECISIONS.md as the thing chunk 5 closes.
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'revoke insert, update, delete on public.purchases from authenticated';
  execute 'revoke insert, update, delete on public.purchase_items from authenticated';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to revoke.
    null;
end $$;

comment on table public.purchases is
  'A supplier invoice the pharmacy owes money against. Written ONLY by save_purchase(): `authenticated` has no INSERT, UPDATE or DELETE here, so a session cannot write a purchase directly. A staff save lands as `pending_approval` and posts nothing until the owner approves it through decide_approval(); the owner''s own save writes the status he asked for. The read policies are unchanged.';
comment on table public.purchase_items is
  'The lines of a purchase document. Written ONLY by save_purchase() and purchase_restore_document() - `authenticated` has no INSERT, UPDATE or DELETE here.';

-- ---------------------------------------------------------------------------
-- 7. Grants - the same idiom 00018 settled for this family
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.save_purchase(jsonb) to authenticated';
  execute 'revoke execute on function public.save_purchase(jsonb) from anon, public';

  execute 'grant execute on function public.approval_has_executor(public.approval_action_type) to authenticated';
  execute 'revoke execute on function public.approval_has_executor(public.approval_action_type) from anon, public';

  execute 'grant execute on function public.request_approval(public.approval_action_type, text, text, jsonb, text, uuid, text) to authenticated';
  execute 'revoke execute on function public.request_approval(public.approval_action_type, text, text, jsonb, text, uuid, text) from anon, public';

  execute 'grant execute on function public.decide_approval(uuid, boolean, text) to authenticated';
  execute 'revoke execute on function public.decide_approval(uuid, boolean, text) from anon, public';

  -- Internal: the pieces of the mechanism a caller must not be able to invoke on its own. They are
  -- reachable from `save_purchase()` and `decide_approval()` (both SECURITY DEFINER), which is the
  -- only place they mean anything.
  execute 'revoke execute on function public.approval_pending_purchase_type(uuid, public.approval_action_type) from anon, authenticated, public';
  execute 'revoke execute on function public.approval_close_purchase_asks(uuid, uuid, text) from anon, authenticated, public';
  execute 'revoke execute on function public.purchase_apply_decision(uuid, public.approval_action_type, jsonb, boolean) from anon, authenticated, public';
  execute 'revoke execute on function public.purchase_restore_document(uuid, jsonb) from anon, authenticated, public';
exception
  when undefined_object then
    -- Role or function missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
