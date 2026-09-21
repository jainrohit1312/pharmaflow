-- Migration: 20260921000045_phase6_5c_approval_returns | Purpose: put purchase returns, sale
-- returns and stock adjustments behind the owner's approval, on the rail chunk 3 built.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create-or-replace functions, guarded revoke/grant.
--
-- The owner's policy, unchanged: "purchase return, sale return, ... any modification and deletion
-- from staff" need his approval, and "only sale bill is allowed without approval". The three action
-- types were declared in the enum by `00043`; this chunk makes them executable - one entry in
-- `approval_has_executor()`, one executor each, and the revokes.
--
-- Why these three are REQUESTED rather than STAGED as a pending row
-- ----------------------------------------------------------------
-- A purchase could be staged as a row (`pending_approval`) because the brief named that state and
-- because a purchase has a life to be in: it is edited, ordered, received. A return and an
-- adjustment are single events - written once, corrected by a contra document, never edited - and
-- they have no status a screen knows how to show. Staging one as a row would put a document in the
-- returns list that has **moved no stock and posted no ledger row**, under a screen with no notion
-- of "waiting", which is a lie about money rather than a state anybody can act on. So for these the
-- REQUEST IS the staging: the whole document travels in `payload`, nothing is written until the
-- owner approves, and approving runs the very inserts the client used to run - which is also why
-- no committed stock or ledger trigger is touched by this migration.
--
-- The trade that buys: the person who raised it sees no document in the list until it is approved.
-- What they see instead is the sentence the write path returns ("Sent to the owner. Nothing has
-- been recorded until he approves it.") and their own ask on the approvals screen, which is the
-- screen chunk 2 built for exactly this.
--
-- The whole document, or a row and its lines
-- ------------------------------------------
-- Each `record_*()` RPC answers with a small envelope rather than a row, because there is no row to
-- answer with for staff:
--
--     {"outcome": "recorded", "document": {...}, "request_id": null}
--     {"outcome": "staged",   "document": null,  "request_id": "uuid"}
--
-- The owner's own write comes back `recorded` with his document, exactly as the direct write did;
-- anybody else's comes back `staged`, and the caller says so instead of navigating to a document
-- that does not exist.
--
-- The figures are the client's, as they are on the purchase side and for the same reason: a return
-- line is a slice of a line the pharmacy already recorded, and `PurchaseReturnTotals` /
-- `SaleReturnTotals` are the one definition of that arithmetic (both already have their own tests).
-- What the server derives itself is the party - the supplier from the purchase, the patient from the
-- sale - and every name it puts in the owner's queue, so the ask cannot describe one document while
-- the write produces another.
--
-- Staleness is refused, not guessed
-- ----------------------------------
-- A return is limited by what is still returnable, and the check that matters is the database's own:
-- `stock_update_on_purchase_return()` raises when a decrement would take a batch below zero, and a
-- sale return's restoration cannot be refused. So approving a return whose goods have since been
-- sold raises, in the trigger's own words, and the request is left pending rather than stamped
-- approved - the same rule chunk 3 follows for a document that has moved on.

-- Why a contra document's payload could not produce a document, or NULL when it could.
--
-- ONE definition, called from two places, because the same shape has to hold on both sides of the
-- rail: `request_approval()` calls it so an ask that answering could not carry out never reaches
-- the owner's list, and each `record_*()` calls it so the owner's own write is held to exactly the
-- same shape - a return with no lines is not a return because he is the one writing it. (It was,
-- before this function existed: the first version of this migration validated only on the ask
-- path, and the test that writes one as the owner found it.)
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

  -- An action type this describes nothing about: the caller owns its validation, as it does for a
  -- purchase document and a discount.
  return null;
end;
$$;

comment on function public.document_payload_problem(public.approval_action_type, jsonb, uuid) is
  'Why a purchase-return, sale-return or stock-adjustment payload could not produce a document, or NULL when it could. One definition, used by request_approval() so an ask that could not be carried out never reaches the owner and by the three record_*() functions so the owner''s own write is held to the same shape.';

-- ---------------------------------------------------------------------------
-- 1. approval_has_executor() - the three action types this chunk makes real
-- ---------------------------------------------------------------------------
create or replace function public.approval_has_executor(p_action_type public.approval_action_type)
returns boolean
language sql
immutable
as $$
  -- One entry per action type whose chunk has landed. Chunk 1 built the discount, chunk 3 the
  -- purchase document, this chunk the three contra documents.
  select p_action_type in (
    'discount_above_limit'::public.approval_action_type,
    'purchase'::public.approval_action_type,
    'purchase_edit'::public.approval_action_type,
    'purchase_delete'::public.approval_action_type,
    'purchase_return'::public.approval_action_type,
    'sale_return'::public.approval_action_type,
    'stock_adjustment'::public.approval_action_type
  );
$$;

comment on function public.approval_has_executor(public.approval_action_type) is
  'Whether this build can actually carry an action type out. request_approval() refuses an action type this returns false for, so the owner''s list can never hold a request that approving would not act on.';

-- ---------------------------------------------------------------------------
-- 2. request_approval() - replaced: a contra document's ask has to carry a document
--
--    These three ask for a document that does not exist yet, so the payload IS the document and the
--    validation is what makes approving it possible: the parent has to be in the caller's pharmacy,
--    the lines have to be there and be writable, and an adjustment has to say which way it goes.
--    An ask that failed any of these would sit in the owner's list and raise when he answered it,
--    which is exactly the shape `approval_has_executor()` exists to prevent for action types.
--
--    The whole body travels again because applied migrations are never edited; nothing else in it
--    changes.
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
  -- about one row. A return has no row yet and a second return against the same sale is a
  -- different document, so these never converge.
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
  'Raises one approval request. Any authorised member of the pharmacy may ask; only the owner may decide (decide_approval). Refuses an action type this build cannot execute, refuses a discount the counter may simply give, refuses a request whose payload could not be carried out, and refreshes an undecided ask about the same purchase instead of stacking a second one. Idempotent on p_idempotency_key.';

-- ---------------------------------------------------------------------------
-- 3. The three write paths
--
--    Each is one RPC for both roles, because the tables stop taking writes from a session
--    entirely (section 5). The role decides what happens: the owner's document is written and
--    returned, anybody else's is raised as a request and the envelope says so. The writes
--    themselves are the SAME inserts the client made - same columns, same order, same single
--    statement for the lines - so the stock and ledger triggers run exactly as they ran before.
-- ---------------------------------------------------------------------------

-- Records a purchase return: goods going back to the supplier.
create or replace function public.record_purchase_return(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy  uuid := public.get_my_pharmacy_id();
  v_role      public.app_role := public.get_my_role();
  v_purchase  public.purchases;
  v_supplier  public.suppliers;
  v_purchase_id uuid := nullif(p_payload ->> 'purchase_id', '')::uuid;
  v_items     jsonb := coalesce(p_payload -> 'items', '[]'::jsonb);
  v_key       text := nullif(btrim(coalesce(p_payload ->> 'idempotency_key', '')), '');
  v_doc       public.purchase_returns;
  v_request   public.approval_requests;
  v_problem   text;
  v_lines     int;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  -- The same shape the ask is held to (see `document_payload_problem`): the owner's own write is
  -- not a different document.
  v_problem := public.document_payload_problem('purchase_return', p_payload, v_pharmacy);

  if v_problem is not null then
    raise exception '%', v_problem
      using errcode = 'check_violation';
  end if;

  select * into v_purchase
    from public.purchases p
   where p.id = v_purchase_id
     and p.pharmacy_id = v_pharmacy;

  if not found then
    raise exception 'that purchase is not in this pharmacy'
      using errcode = 'check_violation';
  end if;

  select * into v_supplier
    from public.suppliers s
   where s.id = v_purchase.supplier_id;

  v_lines := jsonb_array_length(v_items);

  if v_role = 'owner'::public.app_role then
    insert into public.purchase_returns (
      pharmacy_id, purchase_id, supplier_id, return_date, reason,
      sub_total, tax_total, grand_total, created_by
    ) values (
      v_pharmacy,
      v_purchase.id,
      v_purchase.supplier_id,
      coalesce(nullif(p_payload ->> 'return_date', '')::date, current_date),
      nullif(btrim(coalesce(p_payload ->> 'reason', '')), ''),
      coalesce((p_payload ->> 'sub_total')::numeric, 0),
      coalesce((p_payload ->> 'tax_total')::numeric, 0),
      coalesce((p_payload ->> 'grand_total')::numeric, 0),
      auth.uid()
    )
    returning * into v_doc;

    -- One statement for every line, as the client sent them: the trigger moves stock per row and
    -- raises on a batch that is short, and a single INSERT means the raise takes the whole set
    -- with it rather than leaving half the units returned.
    insert into public.purchase_return_items (
      pharmacy_id, purchase_return_id, purchase_item_id, product_id, batch_id, qty,
      purchase_rate, mrp, gst_percent, tax_amount, total_amount
    )
    select
      v_pharmacy,
      v_doc.id,
      nullif(i ->> 'purchase_item_id', '')::uuid,
      nullif(i ->> 'product_id', '')::uuid,
      nullif(i ->> 'batch_id', '')::uuid,
      coalesce((i ->> 'qty')::int, 0),
      coalesce((i ->> 'purchase_rate')::numeric, 0),
      coalesce((i ->> 'mrp')::numeric, 0),
      coalesce((i ->> 'gst_percent')::numeric, 0),
      coalesce((i ->> 'tax_amount')::numeric, 0),
      coalesce((i ->> 'total_amount')::numeric, 0)
    from jsonb_array_elements(v_items) i;

    -- Re-read: the AFTER triggers have run, and the caller gets the row as it stands.
    select * into v_doc from public.purchase_returns r where r.id = v_doc.id;

    return jsonb_build_object(
      'outcome', 'recorded',
      'document', to_jsonb(v_doc),
      'request_id', null
    );
  end if;

  v_request := public.request_approval(
    p_action_type => 'purchase_return',
    p_title => 'Purchase return to ' || v_supplier.name || ' (' || v_purchase.invoice_no || ')',
    p_summary => v_lines || (case when v_lines = 1 then ' line' else ' lines' end)
      || ' · ₹' || to_char(coalesce((p_payload ->> 'grand_total')::numeric, 0), 'FM9999999990.00')
      || ' · debits the supplier',
    p_payload => p_payload,
    p_target_table => 'purchase_returns',
    p_idempotency_key => v_key
  );

  return jsonb_build_object(
    'outcome', 'staged',
    'document', null,
    'request_id', v_request.id
  );
end;
$$;

comment on function public.record_purchase_return(jsonb) is
  'Records a purchase return, or - for anybody but the owner - raises one approval request carrying it and writes nothing. Answers with {"outcome", "document", "request_id"} so a caller can tell a return it can open from one the owner has not answered. The lines are written in ONE statement, as the client sent them, so the stock trigger''s refusal takes the whole set.';

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
  'Records a sale return, or - for anybody but the owner - raises one approval request carrying it and writes nothing. The patient comes from the sale and the restock decision from the payload; the lines are written in ONE statement so a refusal takes the whole set. Answers with {"outcome", "document", "request_id"}.';

-- Records a manual stock correction.
create or replace function public.record_stock_adjustment(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy  uuid := public.get_my_pharmacy_id();
  v_role      public.app_role := public.get_my_role();
  v_product   public.products;
  v_batch     public.product_batches;
  v_product_id uuid := nullif(p_payload ->> 'product_id', '')::uuid;
  v_batch_id  uuid := nullif(p_payload ->> 'batch_id', '')::uuid;
  v_type_key  text := lower(btrim(coalesce(p_payload ->> 'adjustment_type', '')));
  v_type      public.adjustment_type;
  v_qty       int := coalesce((p_payload ->> 'qty')::int, 0);
  v_key       text := nullif(btrim(coalesce(p_payload ->> 'idempotency_key', '')), '');
  v_doc       public.stock_adjustments;
  v_request   public.approval_requests;
  v_problem   text;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  v_problem := public.document_payload_problem('stock_adjustment', p_payload, v_pharmacy);

  if v_problem is not null then
    raise exception '%', v_problem
      using errcode = 'check_violation';
  end if;

  select * into v_product
    from public.products pr
   where pr.id = v_product_id
     and pr.pharmacy_id = v_pharmacy;

  if not found then
    raise exception 'that product is not in this pharmacy'
      using errcode = 'check_violation';
  end if;

  if v_batch_id is not null then
    select * into v_batch
      from public.product_batches b
     where b.id = v_batch_id
       and b.pharmacy_id = v_pharmacy;

    if not found then
      raise exception 'that batch is not in this pharmacy'
        using errcode = 'check_violation';
    end if;
  end if;

  v_type := v_type_key::public.adjustment_type;

  if v_role = 'owner'::public.app_role then
    insert into public.stock_adjustments (
      pharmacy_id, product_id, batch_id, adjustment_type, qty, reason, created_by
    ) values (
      v_pharmacy,
      v_product.id,
      v_batch_id,
      v_type,
      v_qty,
      nullif(btrim(coalesce(p_payload ->> 'reason', '')), ''),
      auth.uid()
    )
    returning * into v_doc;

    return jsonb_build_object(
      'outcome', 'recorded',
      'document', to_jsonb(v_doc),
      'request_id', null
    );
  end if;

  v_request := public.request_approval(
    p_action_type => 'stock_adjustment',
    p_title => 'Stock adjustment: ' || v_product.name,
    p_summary => v_qty || ' ' || (case when v_qty = 1 then 'unit' else 'units' end) || ' '
      || (case when v_type = 'increase'::public.adjustment_type then 'in' else 'out' end)
      || (case when v_batch_id is null then '' else ' of batch ' || v_batch.batch_no end),
    p_payload => p_payload,
    p_target_table => 'stock_adjustments',
    p_idempotency_key => v_key
  );

  return jsonb_build_object(
    'outcome', 'staged',
    'document', null,
    'request_id', v_request.id
  );
end;
$$;

comment on function public.record_stock_adjustment(jsonb) is
  'Records a manual stock correction, or - for anybody but the owner - raises one approval request carrying it and moves nothing. Answers with {"outcome", "document", "request_id"}.';

-- ---------------------------------------------------------------------------
-- 4. The executors, and the one dispatch
-- ---------------------------------------------------------------------------

-- Carries out the owner's answer to a contra document's request.
--
-- Approving WRITES the document from the payload - the same inserts the client made, so the stock
-- and ledger triggers run exactly as they ran for a direct write. Refusing writes nothing at all,
-- which is the other half of why these are requested rather than staged: there is no half-document
-- to put back.
create or replace function public.document_apply_decision(
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
begin
  if not p_approve then
    -- A refusal changes nothing, and that is not a shortcut: nothing was written.
    return;
  end if;

  if p_action_type = 'purchase_return'::public.approval_action_type then
    perform public.record_purchase_return(p_payload);
    return;
  end if;

  if p_action_type = 'sale_return'::public.approval_action_type then
    perform public.record_sale_return(p_payload);
    return;
  end if;

  if p_action_type = 'stock_adjustment'::public.approval_action_type then
    perform public.record_stock_adjustment(p_payload);
    return;
  end if;

  raise exception 'this build cannot carry out a %', p_action_type
    using errcode = 'feature_not_supported';
end;
$$;

comment on function public.document_apply_decision(public.approval_action_type, jsonb, boolean) is
  'Carries out the owner''s answer to a return or a stock adjustment: approving writes the document the payload carries, through the same record_*() path the owner''s own write uses, so the stock and ledger triggers run identically; refusing writes nothing. Internal - called by approval_execute(), not executable by a session.';

-- The one place `decide_approval()` reaches the write an approval authorises.
--
-- A dispatch by FAMILY rather than one function per action type, so the decision path itself has
-- one shape: a purchase is carried out against its own staged row, a contra document against the
-- payload it was raised with, and an action type with no writer here is refused rather than
-- silently doing nothing (which is the same rule `approval_has_executor()` applies to asking).
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
  'The single dispatch decide_approval() calls: a purchase is carried out against its staged row, a return or a stock adjustment against the document its payload carries, and the discount needs nothing because the sale is its execution. An action type with no writer is refused rather than recorded as approved. Internal - not executable by a session.';

-- ---------------------------------------------------------------------------
-- 5. decide_approval() - replaced: the dispatch is one call, and a decision is
--    only recorded when its effect landed
--
--    Everything else is 00043's and 00044's text: owner only, `for update` on the row so two taps
--    cannot both decide it, a decided request refused rather than re-stamped, and the cancelled
--    document's other questions closed with it.
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
  'The owner''s answer to one request: approved or rejected, with a note. Owner only; a request can be decided once. Approving carries the write out here - a purchase takes the status it was saved with, a return or a stock adjustment is written from the document its payload carries - which is what makes "approved" mean something. An action type this build cannot execute, and a decision whose write cannot be carried out, are refused rather than recorded.';

-- ---------------------------------------------------------------------------
-- 6. The revokes - the same migration as the request path, never before it
--
--    These five tables carried the standard tenant-wide four-policy template from 00012 and the
--    table-level grants Supabase gives every public table, so any member of the pharmacy could
--    write a return or an adjustment straight through PostgREST. They stop taking writes from
--    `authenticated` and are reachable only through the three `record_*()` functions above.
--
--    The revoke is per-role, so it covers the owner too: his own return is written by the same RPC,
--    which does exactly what his direct write did and asks him nothing. His AUTHORITY is what is
--    gated, never his route - and there is no route left that a role check could be replaced with.
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'revoke insert, update, delete on public.purchase_returns from authenticated';
  execute 'revoke insert, update, delete on public.purchase_return_items from authenticated';
  execute 'revoke insert, update, delete on public.sale_returns from authenticated';
  execute 'revoke insert, update, delete on public.sale_return_items from authenticated';
  execute 'revoke insert, update, delete on public.stock_adjustments from authenticated';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to revoke.
    null;
end $$;

comment on table public.purchase_returns is
  'Goods going back to a supplier. Written ONLY by record_purchase_return(): `authenticated` has no INSERT, UPDATE or DELETE here. For anybody but the owner that function writes nothing and raises an approval request carrying the return, which decide_approval() then writes. The read policies are unchanged.';
comment on table public.purchase_return_items is
  'The lines of a purchase return. Written only by record_purchase_return(), in one statement per return, because the stock trigger''s refusal has to take the whole set with it.';
comment on table public.sale_returns is
  'Goods coming back from a patient. Written ONLY by record_sale_return() - for anybody but the owner an approval request carries it instead, and nothing is written until the owner approves.';
comment on table public.sale_return_items is
  'The lines of a sale return. Written only by record_sale_return().';
comment on table public.stock_adjustments is
  'Manual stock corrections. Written ONLY by record_stock_adjustment(): `authenticated` has no INSERT here, so a correction is the owner''s own act or his answer to a request. The stock trigger on this table is untouched and runs when the row is written.';

-- ---------------------------------------------------------------------------
-- 7. Grants - the same idiom 00018 settled for this family
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.record_purchase_return(jsonb) to authenticated';
  execute 'revoke execute on function public.record_purchase_return(jsonb) from anon, public';

  execute 'grant execute on function public.record_sale_return(jsonb) to authenticated';
  execute 'revoke execute on function public.record_sale_return(jsonb) from anon, public';

  execute 'grant execute on function public.record_stock_adjustment(jsonb) to authenticated';
  execute 'revoke execute on function public.record_stock_adjustment(jsonb) from anon, public';

  execute 'grant execute on function public.approval_has_executor(public.approval_action_type) to authenticated';
  execute 'revoke execute on function public.approval_has_executor(public.approval_action_type) from anon, public';

  execute 'grant execute on function public.request_approval(public.approval_action_type, text, text, jsonb, text, uuid, text) to authenticated';
  execute 'revoke execute on function public.request_approval(public.approval_action_type, text, text, jsonb, text, uuid, text) from anon, public';

  execute 'grant execute on function public.decide_approval(uuid, boolean, text) to authenticated';
  execute 'revoke execute on function public.decide_approval(uuid, boolean, text) from anon, public';

  -- Internal: the dispatch and the two appliers. Reachable from `decide_approval()` (SECURITY
  -- DEFINER), which is the only place they mean anything.
  execute 'revoke execute on function public.approval_execute(public.approval_action_type, uuid, jsonb, boolean) from anon, authenticated, public';
  execute 'revoke execute on function public.document_apply_decision(public.approval_action_type, jsonb, boolean) from anon, authenticated, public';
  execute 'revoke execute on function public.document_payload_problem(public.approval_action_type, jsonb, uuid) from anon, authenticated, public';
exception
  when undefined_object then
    -- Role or function missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
