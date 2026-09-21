-- Migration: 20260921000043_phase6_5c_approval_rbac | Purpose: the approval mechanism - one
-- table, one request path, one decision path, and the first action type wired to it.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: guarded enum/table creation, drop-policy-if-exists, create-or-replace functions.
--
-- The owner's policy (2026-09-21), in his words
-- --------------------------------------------
-- "I need owner approval on purchase, sale return, purchase return, any modification and deletion
-- from staff. Only sale bill is allowed without approval, rest all functionality is allowed only on
-- approval from owner." Asked the four questions the plan left open, he settled: a purchase is a
-- **pending GRN** (nothing posts until he approves), **everybody except the owner is gated** (so a
-- pharmacist is too, which supersedes the email-00038 rule for `update_patient`), deletion is a
-- **soft delete**, and the sale bill, a payment and registering a new patient stay **free for every
-- role**.
--
-- What this migration builds, and what it deliberately does not
-- ------------------------------------------------------------
-- It builds the MECHANISM and proves it end to end on **one** action type - D-071's above-10%
-- discount, which is the reason Phase 7a is blocked at that cap. The other action types are declared
-- in the enum, because the enum is the schema's own record of the owner's list, but
-- `approval_has_executor()` returns false for them and `request_approval()` REFUSES one - so nothing
-- can sit in the owner's list that approving would not act on. Each later chunk adds its action
-- type to that function and to its dispatch.
--
-- The mechanism, which is D-071's own design rather than a second one invented for billing:
--
--   * `approval_requests` carries `action_type`, the `payload` of what to do, and the two states
--     (`pending` / `approved` / `rejected`) with who asked, when, who decided and when;
--   * a gate is enforced SERVER-side on the single write path, never by a screen. The controls this
--     has to hold are enforced where the write happens: `checkout_sale()` is the only way a sale is
--     written (D-023), so its cap holds here;
--   * `sales.discount_above_limit_request_id` is a **real foreign key** to `approval_requests(id)`
--     (D-071), and a UNIQUE one - one approval authorises one bill, which is what makes "approved"
--     mean something rather than a stamp any number of bills can quote.
--
-- Why an approved discount must MATCH the bill it authorises
-- ---------------------------------------------------------
-- The owner approves a specific figure on a specific bill, not the idea of a discount. So the
-- request's payload records the discount and the bill's tax-inclusive total, and `checkout_sale()`
-- refuses a bill whose figures differ from the ones he approved - otherwise "approved ₹46 off ₹546"
-- would authorise ₹500 off ₹5000. The bill is also what the owner reads on his screen (chunk 2), so
-- the two cannot drift.

-- ---------------------------------------------------------------------------
-- 1. The two enums
--
--    `approval_action_type` is the owner's list, recorded once here. An action type is ADDED to a
--    later migration with `alter type ... add value` when its chunk lands, which is cheap and needs
--    no table change - so this list is not a one-way door.
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.approval_status as enum ('pending', 'approved', 'rejected');
exception when duplicate_object then null;
end $$;

comment on type public.approval_status is
  'A request awaiting the owner, and the two ways it can end. `pending` is the only state that can be decided.';

do $$ begin
  create type public.approval_action_type as enum (
    'discount_above_limit',
    'purchase',
    'purchase_edit',
    'purchase_delete',
    'purchase_return',
    'sale_return',
    'sale_edit',
    'sale_cancel',
    'stock_adjustment',
    'product_create',
    'product_edit',
    'product_delete',
    'customer_edit',
    'expense_create',
    'expense_edit',
    'expense_delete'
  );
exception when duplicate_object then null;
end $$;

comment on type public.approval_action_type is
  'The owner''s list of actions that need his approval (2026-09-21). `discount_above_limit` is the first implemented one; the rest are declared here as the schema''s record of the policy and are added to approval_has_executor() by the chunk that builds them.';

-- ---------------------------------------------------------------------------
-- 2. approval_requests - one row per thing the owner has been asked to allow
--
--    The payload is what the action needs to be executed, and what the owner's screen shows. It is
--    deliberately jsonb rather than a column per action: the mechanism is ONE, and the six chunks
--    that use it must not each grow the table.
--
--    The decision columns carry the control's whole point: who asked, who allowed it and when. A
--    `pending` row has no decider, and a decided one must have both - a check constraint, because a
--    decided-but-anonymous row is exactly the artefact that would let an unapproved discount look
--    approved.
-- ---------------------------------------------------------------------------
create table if not exists public.approval_requests (
  id                uuid primary key default gen_random_uuid(),
  pharmacy_id       uuid not null references public.pharmacies(id) on delete cascade,
  action_type       public.approval_action_type not null,
  status            public.approval_status not null default 'pending',
  title             text not null,
  summary           text,
  payload           jsonb not null default '{}'::jsonb,
  target_table      text,
  target_id         uuid,
  requested_by      uuid references public.profiles(id) on delete set null,
  requested_at      timestamptz not null default now(),
  decided_by        uuid references public.profiles(id) on delete set null,
  decided_at        timestamptz,
  decision_note     text,
  idempotency_key   text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint approval_requests_decided_check check (
    (status = 'pending'::public.approval_status and decided_by is null and decided_at is null)
    or (status <> 'pending'::public.approval_status and decided_by is not null and decided_at is not null)
  )
);

comment on table public.approval_requests is
  'One thing the owner has been asked to allow: a purchase, a return, a deletion, a master-data edit, an above-cap discount. Written only by request_approval() and changed only by decide_approval() - there is no INSERT or UPDATE policy, so nothing holding a session can forge one or decide its own request.';
comment on column public.approval_requests.payload is
  'What the action needs to be executed, and what the owner reads before deciding. jsonb so one mechanism serves every action type without growing this table.';
comment on column public.approval_requests.target_table is
  'The table the action will write, for the audit trail and the owner''s screen. Null for an action that creates a new row (a purchase, a new product).';
comment on column public.approval_requests.status is
  'pending until the owner decides. `approved` means the action may run - for a discount, that the bill may quote this row as its authority.';
comment on column public.approval_requests.idempotency_key is
  'Optional caller-supplied key. A repeated request with the same key in one pharmacy returns the existing one instead of raising a second ask into the owner''s list.';

create index if not exists approval_requests_pharmacy_status_idx
  on public.approval_requests (pharmacy_id, status, requested_at desc);

create index if not exists approval_requests_pharmacy_action_idx
  on public.approval_requests (pharmacy_id, action_type, status);

-- One pending ask per target: a second request for the same document converges instead of stacking
-- in the owner's list. Partial, because a create has no target yet and many rows share a null.
create unique index if not exists approval_requests_pending_target_key
  on public.approval_requests (pharmacy_id, action_type, target_id)
  where status = 'pending'::public.approval_status and target_id is not null;

create unique index if not exists approval_requests_pharmacy_idempotency_key
  on public.approval_requests (pharmacy_id, idempotency_key)
  where idempotency_key is not null;

drop trigger if exists set_updated_at on public.approval_requests;
create trigger set_updated_at before update on public.approval_requests
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. RLS - the owner sees everything, staff see their own, nobody writes directly
--
--    The SELECT policy is the whole read model: an owner's list is every request in his pharmacy, a
--    cashier's is the ones he raised. There is deliberately NO insert, update or delete policy - the
--    same reasoning `payment_allocations` records - because the two writers that validate the ask
--    and the authority to decide it are `request_approval()` and `decide_approval()`.
-- ---------------------------------------------------------------------------
alter table public.approval_requests enable row level security;

drop policy if exists approval_requests_select on public.approval_requests;
create policy approval_requests_select on public.approval_requests
  for select using (
    pharmacy_id = public.get_my_pharmacy_id()
    and (
      public.get_my_role() = 'owner'
      or requested_by = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- 4. approval_has_executor() - which action types this build can actually run
--
--    The one list that decides whether an ask may be created. A request whose action type has no
--    executor is REFUSED rather than accepted, because the alternative is a row in the owner's list
--    that approving would silently do nothing about - and "approved" is a control the owner relies
--    on, so it must never be a stamp with no effect.
-- ---------------------------------------------------------------------------
create or replace function public.approval_has_executor(p_action_type public.approval_action_type)
returns boolean
language sql
immutable
as $$
  -- One entry per action type whose chunk has landed. Phase 6.5c chunk 1 built the discount; each
  -- later chunk adds its own here in the same migration that adds its executor.
  select p_action_type = 'discount_above_limit'::public.approval_action_type;
$$;

comment on function public.approval_has_executor(public.approval_action_type) is
  'Whether this build can actually carry an action type out. request_approval() refuses an action type this returns false for, so the owner''s list can never hold a request that approving would not act on.';

-- ---------------------------------------------------------------------------
-- 5. request_approval() - the one way a request is raised
--
--    Security definer and granted to `authenticated`, so any authorised member of the pharmacy may
--    ask: a cashier, a pharmacist, the owner himself. There is no role check on ASKING - the policy
--    is who may ACT, and that is decided in decide_approval() and enforced again on the write path.
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

  if v_key is not null then
    select * into v_row
      from public.approval_requests a
     where a.pharmacy_id = v_pharmacy
       and a.idempotency_key = v_key;

    if found then
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
  'Raises one approval request. Any authorised member of the pharmacy may ask; only the owner may decide (decide_approval). Refuses an action type this build cannot execute. Idempotent on p_idempotency_key.';

-- ---------------------------------------------------------------------------
-- 6. decide_approval() - the owner's answer, and the only hand that can give one
--
--    Owner only, and `for update` on the row so two taps cannot both decide it. A non-pending
--    request is refused rather than re-stamped, which is what makes a decision final.
--
--    For an APPROVAL, the action is carried out here in the chunks that write a document (a GRN, a
--    return). The discount needs no execution of its own: the sale IS the execution, and it quotes
--    this row as its authority through `sales.discount_above_limit_request_id`. That is why the
--    dispatch has exactly one entry today, and why `approval_has_executor()` refuses the rest.
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

  update public.approval_requests a
     set status        = (case when p_approve then 'approved' else 'rejected' end)::public.approval_status,
         decided_by    = auth.uid(),
         decided_at    = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), '')
   where a.id = v_row.id
  returning * into v_row;

  return v_row;
end;
$$;

comment on function public.decide_approval(uuid, boolean, text) is
  'The owner''s answer to one request: approved or rejected, with a note. Owner only; a request can be decided once. Approving an action type this build cannot execute is refused rather than recorded.';

-- ---------------------------------------------------------------------------
-- 7. sales.discount_above_limit_request_id - the real foreign key D-071 records
--
--    00035 wrote the column OFF the Phase 7a migrations on purpose - its target did not exist - and
--    its own comment says why. This is that target, so the column arrives here, as a real FK and
--    UNIQUE: one approval authorises one bill, so a second bill quoting the same row is refused by
--    the database rather than by a convention nobody can see.
-- ---------------------------------------------------------------------------
alter table public.sales
  add column if not exists discount_above_limit_request_id uuid
    references public.approval_requests(id) on delete set null;

comment on column public.sales.discount_above_limit_request_id is
  'The owner''s approval for a discount above 10% of this bill (D-071). A real foreign key, never an id the client invents, and unique: one approval authorises one bill.';

create unique index if not exists sales_discount_approval_key
  on public.sales (discount_above_limit_request_id)
  where discount_above_limit_request_id is not null;

-- ---------------------------------------------------------------------------
-- 8. Grants - the same idiom 00018 settled for this family
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.approval_has_executor(public.approval_action_type) to authenticated';
  execute 'revoke execute on function public.approval_has_executor(public.approval_action_type) from anon, public';

  execute 'grant execute on function public.request_approval(public.approval_action_type, text, text, jsonb, text, uuid, text) to authenticated';
  execute 'revoke execute on function public.request_approval(public.approval_action_type, text, text, jsonb, text, uuid, text) from anon, public';

  execute 'grant execute on function public.decide_approval(uuid, boolean, text) to authenticated';
  execute 'revoke execute on function public.decide_approval(uuid, boolean, text) from anon, public';
exception
  when undefined_object then
    -- Role or function missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;

-- ---------------------------------------------------------------------------
-- 9. checkout_sale() - replaced: the cap is now the owner's to lift
--
--    Applied migrations are never edited, so the whole ~700-line body travels again - it is
--    00042's own text with the approval wired into the one branch that used to refuse. It was
--    diffed against 00042 before it was applied. Two things change, and nothing else:
--
--      * an over-cap bill discount is ALLOWED for the owner, and for anyone else only against
--        his approved `discount_above_limit` request whose recorded discount and bill total are
--        this bill's own figures - so an approval cannot be stretched to a different bill;
--      * the sale stamps which approval let it through, and a UNIQUE index makes that approval
--        good for one bill only.
--
--    The per-line cap is untouched except for its sentence: what the owner approves is a figure
--    on the bill.
-- ---------------------------------------------------------------------------
create or replace function public.checkout_sale(p_payload jsonb)
returns public.sales
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy        uuid := public.get_my_pharmacy_id();
  v_type_key        text := nullif(btrim(coalesce(p_payload ->> 'sale_type', '')), '');
  v_typed           boolean := v_type_key is not null;
  v_type            public.sale_type;
  v_items           jsonb := coalesce(p_payload -> 'items', '[]'::jsonb);
  v_key             text := nullif(btrim(coalesce(p_payload ->> 'idempotency_key', '')), '');
  v_existing        public.sales;
  v_customer_id     uuid := nullif(p_payload ->> 'customer_id', '')::uuid;
  v_customer        public.customers;
  v_customer_name   text;
  v_customer_phone  text;
  v_amount_paid     numeric(14,2) := coalesce((p_payload ->> 'amount_paid')::numeric, 0);
  v_place           text := nullif(btrim(coalesce(p_payload ->> 'place_of_supply', '')), '');
  v_state           text;
  v_pharmacy_hosp   uuid;
  v_markup          numeric(5,2);
  v_intra           boolean;
  v_patient_name    text := nullif(btrim(coalesce(p_payload ->> 'patient_name', '')), '');
  v_patient_mobile  text := public.normalize_indian_mobile(p_payload ->> 'patient_mobile');
  v_patient_address text := nullif(btrim(coalesce(p_payload ->> 'patient_address', '')), '');
  v_doctor_id       uuid := nullif(p_payload ->> 'doctor_id', '')::uuid;
  v_doctor_name     text := nullif(btrim(coalesce(p_payload ->> 'doctor_name', '')), '');
  v_hospital_ref    text := nullif(btrim(coalesce(p_payload ->> 'hospital_reference', '')), '');
  v_hospital_id     uuid;
  v_admission       public.admissions;
  v_admission_id    uuid;
  v_admission_no    text;
  v_admission_state text;
  v_from            text := nullif(btrim(coalesce(p_payload ->> 'from_location', '')), '');
  v_to              text := nullif(btrim(coalesce(p_payload ->> 'to_location', '')), '');
  v_transfer_reason text := nullif(btrim(coalesce(p_payload ->> 'transfer_reason', '')), '');
  v_transfer_note   text;
  v_doc_no          text;
  v_line            jsonb;
  v_batch           public.product_batches;
  v_product         public.products;
  v_qty             int;
  v_rate            numeric(14,2);
  v_discount_pct    numeric(5,2);
  v_discount_amt    numeric(14,2);
  v_slab            numeric(5,2);
  v_line_total      numeric(14,2);
  v_taxable         numeric(14,2);
  v_tax             numeric(14,2);
  v_cgst            numeric(14,2);
  v_sgst            numeric(14,2);
  v_igst            numeric(14,2);
  v_needs_doctor    boolean := false;
  v_lines           jsonb := '[]'::jsonb;
  v_bill_discount   numeric(14,2) := coalesce((p_payload ->> 'bill_discount')::numeric, 0);
  v_discount_approval_id uuid := nullif(p_payload ->> 'discount_approval_id', '')::uuid;
  v_approval_id     uuid;
  v_role            public.app_role := public.get_my_role();
  v_approval        public.approval_requests;
  v_gross_inclusive numeric(14,2);
  v_running_share   numeric(14,2);
  v_share           numeric(14,2);
  v_discounted      numeric(14,2);
  v_line_count      int;
  v_index           int;
  v_cur             jsonb;
  v_rebuilt         jsonb := '[]'::jsonb;
  v_grand           numeric(14,2);
  v_tax_total       numeric(14,2);
  v_discount_total  numeric(14,2);
  v_sub_total       numeric(14,2);
  v_balance         numeric(14,2);
  v_sale            public.sales;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  if jsonb_array_length(v_items) = 0 then
    raise exception 'a sale needs at least one line'
      using errcode = 'check_violation';
  end if;

  -- A retried submit is the same sale, not a second one.
  if v_key is not null then
    select * into v_existing
      from public.sales s
     where s.pharmacy_id = v_pharmacy
       and s.idempotency_key = v_key;

    if found then
      return v_existing;
    end if;
  end if;

  select p.state, p.hospital_id, p.package_markup_percent
    into v_state, v_pharmacy_hosp, v_markup
    from public.pharmacies p
   where p.id = v_pharmacy;

  -- The place of supply is derived, not typed: the pharmacy's own state is the default,
  -- and an explicit value from an authorised flow still wins. A patient's address is never
  -- read as a tax jurisdiction (the brief says so, and `customers` has no state column).
  v_place := coalesce(v_place, v_state);
  v_intra := v_place is null or v_state is null or lower(v_place) = lower(v_state);

  v_type := coalesce(v_type_key, 'counter')::public.sale_type;

  if v_customer_id is not null then
    select * into v_customer
      from public.customers c
     where c.id = v_customer_id
       and c.pharmacy_id = v_pharmacy;

    if not found then
      raise exception 'that patient is not in this pharmacy'
        using errcode = 'check_violation';
    end if;

    v_customer_name  := v_customer.name;
    v_customer_phone := v_customer.phone;
  end if;

  -- -------------------------------------------------------------------------
  -- The type decides what the bill must carry
  -- -------------------------------------------------------------------------
  if v_type = 'counter' then
    if v_typed then
      if v_customer_id is null then
        raise exception 'a pharmacy sale needs a patient: select or register one before the medicines'
          using errcode = 'check_violation';
      end if;

      v_patient_name   := coalesce(v_patient_name, v_customer_name);
      v_patient_mobile := coalesce(v_patient_mobile,
                                   public.normalize_indian_mobile(v_customer_phone),
                                   v_customer_phone);

      if v_patient_name is null then
        raise exception 'that patient has no name on file'
          using errcode = 'check_violation';
      end if;

      if v_patient_mobile is null then
        raise exception 'that patient has no mobile number on file, and a pharmacy sale needs one'
          using errcode = 'check_violation';
      end if;
    end if;

  elsif v_type = 'ipd_admission' then
    if v_customer_id is null then
      raise exception 'an IPD sale needs the patient'
        using errcode = 'check_violation';
    end if;

    if nullif(p_payload ->> 'admission_id', '') is not null then
      select * into v_admission
        from public.admissions a
       where a.id = (p_payload ->> 'admission_id')::uuid
         and a.pharmacy_id = v_pharmacy;

      if not found then
        raise exception 'that admission is not in this pharmacy'
          using errcode = 'check_violation';
      end if;

      if v_admission.customer_id <> v_customer_id then
        raise exception 'that admission belongs to a different patient'
          using errcode = 'check_violation';
      end if;
    else
      if v_hospital_ref is null then
        raise exception 'an IPD sale needs the hospital''s admission number, or a chosen admission'
          using errcode = 'check_violation';
      end if;

      v_admission := public.save_admission(
        v_customer_id,
        v_hospital_ref,
        null,
        nullif(p_payload ->> 'admitted_on', '')::date,
        p_payload ->> 'ward',
        p_payload ->> 'bed',
        v_doctor_id,
        v_doctor_name,
        null
      );
    end if;

    v_admission_id    := v_admission.id;
    v_admission_no    := v_admission.admission_no;
    v_admission_state := v_admission.status;

    if v_admission_state <> 'active' then
      raise exception 'admission % is discharged - open a new episode or bill this as a counter sale', v_admission_no
        using errcode = 'check_violation';
    end if;

    v_hospital_ref := v_admission_no;
    v_hospital_id  := coalesce(v_admission.hospital_id, v_pharmacy_hosp);
    v_doctor_name  := coalesce(v_doctor_name, v_admission.treating_doctor_name);

    if v_doctor_name is null then
      raise exception 'an IPD sale needs the treating doctor'
        using errcode = 'check_violation';
    end if;

    v_patient_name   := coalesce(v_patient_name, v_customer_name);
    v_patient_mobile := coalesce(v_patient_mobile,
                                 public.normalize_indian_mobile(v_customer_phone),
                                 v_customer_phone);

    if v_patient_mobile is null then
      raise exception 'that patient has no mobile number on file, and an IPD sale needs one'
        using errcode = 'check_violation';
    end if;

  elsif v_type = 'package' then
    if v_customer_id is null then
      raise exception 'a package sale needs the hospital or account being billed'
        using errcode = 'check_violation';
    end if;

    if v_patient_name is null then
      raise exception 'a package bill needs the patient''s name'
        using errcode = 'check_violation';
    end if;

    if v_patient_mobile is null then
      raise exception 'a package bill needs the patient''s mobile number'
        using errcode = 'check_violation';
    end if;

    if v_hospital_ref is null then
      raise exception 'a package bill needs the package or case reference'
        using errcode = 'check_violation';
    end if;

    if v_markup is null then
      raise exception 'this pharmacy has no package markup configured, so a package cannot be priced: set pharmacies.package_markup_percent'
        using errcode = 'check_violation';
    end if;

  elsif v_type = 'transfer' then
    if v_from is null or v_to is null then
      raise exception 'a transfer needs a source and a destination'
        using errcode = 'check_violation';
    end if;

    if v_from = v_to then
      raise exception 'a transfer''s source and destination cannot be the same'
        using errcode = 'check_violation';
    end if;

    if v_transfer_reason is null then
      raise exception 'a transfer needs a reason'
        using errcode = 'check_violation';
    end if;

    if v_customer_id is not null then
      raise exception 'a transfer is stock moving between locations, not a sale: it has no patient or account'
        using errcode = 'check_violation';
    end if;

    if v_amount_paid <> 0 then
      raise exception 'a transfer takes no payment'
        using errcode = 'check_violation';
    end if;
  end if;

  -- A prescriber's name converges on the master (D-072) for ANY typed sale that names one -
  -- a counter prescription fills the referral record too, not only an admission. The bill
  -- keeps the spelling it was given; this only decides which master row that spelling points
  -- at. The IPD path has already created the row inside save_admission, so this finds it.
  if v_typed and v_doctor_name is not null and v_doctor_id is null then
    select d.id into v_doctor_id
      from public.doctors d
     where d.pharmacy_id = v_pharmacy
       and lower(d.name) = lower(v_doctor_name);

    if v_doctor_id is null then
      insert into public.doctors (pharmacy_id, name)
      values (v_pharmacy, v_doctor_name)
      returning id into v_doctor_id;
    end if;
  end if;

  -- -------------------------------------------------------------------------
  -- The lines: price, discount, slab and tax are resolved here
  -- -------------------------------------------------------------------------
  for v_line in select * from jsonb_array_elements(v_items) loop
    select * into v_batch
      from public.product_batches b
     where b.id = (v_line ->> 'batch_id')::uuid
       and b.pharmacy_id = v_pharmacy;

    if not found then
      raise exception 'a sale line references a batch outside this pharmacy'
        using errcode = 'check_violation';
    end if;

    select * into v_product
      from public.products p
     where p.id = (v_line ->> 'product_id')::uuid
       and p.pharmacy_id = v_pharmacy;

    if not found then
      raise exception 'a sale line references a product outside this pharmacy'
        using errcode = 'check_violation';
    end if;

    -- The batch is the thing that holds stock; a line that names another product's batch
    -- would move the wrong stock while looking right on the bill.
    if v_batch.product_id <> v_product.id then
      raise exception 'a sale line''s product and batch disagree'
        using errcode = 'check_violation';
    end if;

    v_qty := coalesce((v_line ->> 'qty')::int, 0);

    if v_qty <= 0 then
      raise exception 'a sale line needs a quantity greater than zero'
        using errcode = 'check_violation';
    end if;

    if not v_typed then
      -- LEGACY (see the seam note above): the payload's own figures, stored verbatim -
      -- which is exactly what this function has always done. Nothing is derived here, not
      -- even the line total: the old body never recomputed one, and a caller that sends a
      -- total different from qty x rate (a fixture, or an app with its own rounding) must
      -- keep getting what it sent. The typed path below is where the server takes over.
      v_lines := v_lines || jsonb_build_object(
        'product_id',       v_product.id,
        'batch_id',         v_batch.id,
        'qty',              v_qty,
        'rate',             coalesce((v_line ->> 'rate')::numeric, 0),
        'discount_percent', coalesce((v_line ->> 'discount_percent')::numeric, 0),
        'discount_amount',  coalesce((v_line ->> 'discount_amount')::numeric, 0),
        'gst_percent',      coalesce((v_line ->> 'gst_percent')::numeric, 0),
        'cgst_amount',      coalesce((v_line ->> 'cgst_amount')::numeric, 0),
        'sgst_amount',      coalesce((v_line ->> 'sgst_amount')::numeric, 0),
        'igst_amount',      coalesce((v_line ->> 'igst_amount')::numeric, 0),
        'tax_amount',       coalesce((v_line ->> 'tax_amount')::numeric, 0),
        'total_amount',     coalesce((v_line ->> 'total_amount')::numeric, 0),
        'schedule_type',    coalesce(nullif(v_line ->> 'schedule_type', ''), 'OTC')
      );

      continue;
    end if;

    -- The rate, per type. Package and transfer rates are the server's figures (D-067/D-070):
    -- purchase rate plus the pharmacy's configured markup, or plain purchase rate. A retail
    -- rate is the caller's, defaulted from the batch, and may not exceed MRP.
    if v_type = 'package' then
      -- The confirmed rule (owner, 2026-09-20): purchase rate x (1 + markup/100). It is the
      -- BATCH'S PURCHASE RATE, deliberately - not the landed cost. Landed cost (00016) is a
      -- different number, it is absent for the whole opening-stock catalogue, and a fallback
      -- to it would have been an invented basis. `v_markup` may be 0: a configured zero is a
      -- real deal (the owner's own "0% is a value, not an absence", D-068) and multiplies to
      -- the purchase rate itself.
      v_rate := round(v_batch.purchase_rate * (1 + v_markup / 100), 2);
    elsif v_type = 'transfer' then
      v_rate := coalesce(v_batch.purchase_rate, 0);
    else
      v_rate := coalesce(
        (v_line ->> 'rate')::numeric,
        nullif(v_batch.selling_rate, 0),
        v_batch.mrp
      );
    end if;

    if v_rate is null or v_rate <= 0 then
      raise exception 'cannot price % - it has no rate and no MRP', v_product.name
        using errcode = 'check_violation';
    end if;

    if v_type in ('counter', 'ipd_admission') and v_batch.mrp > 0 and v_rate > v_batch.mrp then
      raise exception 'the rate for % is above its MRP of %', v_product.name, v_batch.mrp
        using errcode = 'check_violation';
    end if;

    v_discount_pct := coalesce((v_line ->> 'discount_percent')::numeric, 0);

    if v_discount_pct < 0 or v_discount_pct > 100 then
      raise exception 'a discount percent must be between 0 and 100'
        using errcode = 'check_violation';
    end if;

    if v_type in ('package', 'transfer') and v_discount_pct <> 0 then
      raise exception 'a % sale has no discount', v_type
        using errcode = 'check_violation';
    end if;

    if v_type in ('counter', 'ipd_admission') and v_discount_pct > 10 then
      -- Still refused, and now for the truthful reason: what the owner approves is a figure on
      -- the BILL, so the extra belongs on the bill's discount where he can see it - not spread
      -- across lines he never saw. The counter stops offering a line discount at all (Step 3 of
      -- the discount brief), so this is the field a caller sends by hand.
      raise exception 'a line discount above 10%% is not accepted: give the extra on the bill''s discount, where the owner can approve it'
        using errcode = 'check_violation';
    end if;

    v_discount_amt := round(v_qty * v_rate * v_discount_pct / 100, 2);
    v_line_total   := round(v_qty * v_rate - v_discount_amt, 2);

    if v_line_total < 0 then
      raise exception 'the discount on % is larger than the line', v_product.name
        using errcode = 'check_violation';
    end if;

    -- The slab: the product's own, including a recorded zero. A transfer carries none.
    if v_type = 'transfer' then
      v_slab := 0;
    else
      v_slab := v_product.gst_percent;

      if v_slab is null then
        if v_type = 'package' then
          raise exception 'a package line needs its product''s GST slab recorded (% has none, and the package tax treatment is not settled)', v_product.name
            using errcode = 'check_violation';
        end if;

        v_slab := public.pos_default_gst_percent();
      end if;
    end if;

    if v_slab < 0 then
      raise exception '% has a negative GST slab recorded', v_product.name
        using errcode = 'check_violation';
    end if;

    -- Tax EXTRACTED from the tax-inclusive line total (see the header).
    if v_slab > 0 then
      v_taxable := round(v_line_total / (1 + v_slab / 100), 2);
      v_tax     := round(v_line_total - v_taxable, 2);
    else
      v_taxable := v_line_total;
      v_tax     := 0;
    end if;

    if v_intra then
      -- The rounded half first, then the remainder: the same rule as the printed bill
      -- (D-057), so the two heads always add back to the tax that was charged.
      v_cgst := round(v_tax / 2, 2);
      v_sgst := round(v_tax - v_cgst, 2);
      v_igst := 0;
    else
      v_cgst := 0;
      v_sgst := 0;
      v_igst := v_tax;
    end if;

    v_lines := v_lines || jsonb_build_object(
      'product_id',       v_product.id,
      'batch_id',         v_batch.id,
      'qty',              v_qty,
      'rate',             v_rate,
      'discount_percent', v_discount_pct,
      'discount_amount',  v_discount_amt,
      'gst_percent',      v_slab,
      'cgst_amount',      v_cgst,
      'sgst_amount',      v_sgst,
      'igst_amount',      v_igst,
      'tax_amount',       v_tax,
      'total_amount',     v_line_total,
      'schedule_type',    v_product.schedule_type::text
    );

    if v_product.schedule_type in ('H', 'H1', 'X', 'narcotic') then
      v_needs_doctor := true;
    end if;
  end loop;

  -- A Schedule H/H1/X bill has to name its prescriber (D-072); on a pharmacy sale that is
  -- the rule that makes `doctor_name` required. A package sale is the hospital buying, so
  -- the rule does not apply to it.
  if v_needs_doctor and v_type in ('counter', 'ipd_admission') and v_doctor_name is null then
    raise exception 'a Schedule H/H1/X line needs the prescriber''s name'
      using errcode = 'check_violation';
  end if;

  -- -------------------------------------------------------------------------
  -- The bill's own discount: one amount in rupees, taken off the tax-inclusive
  -- total and shared across the lines (owner, 2026-09-21)
  --
  -- The basis is the owner's own sentence (quoted in this migration's header): the discount
  -- comes off the tax-INCLUSIVE total, and the taxable value and the tax are then extracted
  -- from the smaller figure - the same extraction the line just got, applied to a smaller
  -- number. Rebuilding every line's money here, rather than subtracting the discount at the
  -- header, is what keeps the header the sum of the lines: `sub_total + tax_total =
  -- grand_total`, and the four tax heads adding back to the tax charged (D-057).
  --
  -- A payload that names no discount skips all of this, and a non-zero one on the legacy
  -- untyped path never reaches it (the seam note above).
  -- -------------------------------------------------------------------------
  if v_typed and v_bill_discount <> 0 then
    if v_bill_discount < 0 then
      raise exception 'a discount cannot be negative'
        using errcode = 'check_violation';
    end if;

    if v_type not in ('counter', 'ipd_admission') then
      raise exception 'a % sale has no discount', v_type
        using errcode = 'check_violation';
    end if;

    -- The bill's tax-inclusive total BEFORE the bill discount: the sum of the lines' own
    -- totals, each already net of its own discount. The 10% cap is taken on this figure, so a
    -- bill of 546 may carry at most 54.60.
    select coalesce(sum((i ->> 'total_amount')::numeric), 0)
      into v_gross_inclusive
      from jsonb_array_elements(v_lines) as i;

    if v_bill_discount > v_gross_inclusive then
      raise exception 'the discount of % is larger than the bill''s %', v_bill_discount, v_gross_inclusive
        using errcode = 'check_violation';
    end if;

    -- Over the cap (D-071). The owner is free - his own discount needs nobody's permission
    -- (owner, 2026-09-21) - and every other role needs HIS: either the approval he signed for
    -- this very figure on this very bill, or nothing.
    if v_bill_discount > v_gross_inclusive * 0.10 then
      if v_role = 'owner'::public.app_role then
        v_approval_id := null;
      else
        if v_discount_approval_id is null then
          raise exception 'a discount above 10%% of the bill needs the owner''s approval: ask for it, and bill once he has given it'
            using errcode = 'check_violation';
        end if;

        select * into v_approval
          from public.approval_requests a
         where a.id = v_discount_approval_id
           and a.pharmacy_id = v_pharmacy
           and a.action_type = 'discount_above_limit'::public.approval_action_type
           and a.status = 'approved'::public.approval_status;

        if not found then
          raise exception 'that approval is not one this pharmacy has given for a discount'
            using errcode = 'check_violation';
        end if;

        -- He approved a FIGURE on a BILL, not the idea of a discount: ``approved 46 off 546``
        -- must not become authority for 500 off 5000. Both figures have to be the ones he saw.
        if coalesce((v_approval.payload ->> 'discount_amount')::numeric, -1) <> v_bill_discount
           or coalesce((v_approval.payload ->> 'bill_gross')::numeric, -1) <> v_gross_inclusive then
          raise exception 'the owner approved a discount of % on a bill of %, not % on %',
            v_approval.payload ->> 'discount_amount', v_approval.payload ->> 'bill_gross',
            v_bill_discount, v_gross_inclusive
            using errcode = 'check_violation';
        end if;

        -- Recorded on the sale below, through a real foreign key that is UNIQUE: one approval
        -- authorises one bill, so the same approval cannot cover a second one.
        v_approval_id := v_approval.id;
      end if;
    end if;

    v_line_count    := jsonb_array_length(v_lines);
    v_rebuilt       := '[]'::jsonb;
    v_running_share := 0;

    for v_index in 0 .. v_line_count - 1 loop
      v_cur := v_lines -> v_index;

      if v_index < v_line_count - 1 then
        v_share := round((v_cur ->> 'total_amount')::numeric * v_bill_discount / v_gross_inclusive, 2);
      else
        -- Whatever the shares above left over. This is what makes them add back to the rupee
        -- figure the counter entered rather than to something a paisa short of it.
        v_share := round(v_bill_discount - v_running_share, 2);
      end if;

      v_running_share := v_running_share + v_share;
      v_discounted    := round((v_cur ->> 'total_amount')::numeric - v_share, 2);

      if v_discounted < 0 then
        raise exception 'the discount is larger than one of its lines'
          using errcode = 'check_violation';
      end if;

      -- The line's slab and the extraction, exactly as the loop above worked them out for the
      -- undiscounted total - the discounted inclusive figure is simply a smaller one.
      v_slab := (v_cur ->> 'gst_percent')::numeric;

      if v_slab > 0 then
        v_taxable := round(v_discounted / (1 + v_slab / 100), 2);
        v_tax     := round(v_discounted - v_taxable, 2);
      else
        v_taxable := v_discounted;
        v_tax     := 0;
      end if;

      if v_intra then
        v_cgst := round(v_tax / 2, 2);
        v_sgst := round(v_tax - v_cgst, 2);
        v_igst := 0;
      else
        v_cgst := 0;
        v_sgst := 0;
        v_igst := v_tax;
      end if;

      v_rebuilt := v_rebuilt || jsonb_build_object(
        'product_id',       (v_cur ->> 'product_id')::uuid,
        'batch_id',         (v_cur ->> 'batch_id')::uuid,
        'qty',              (v_cur ->> 'qty')::int,
        'rate',             (v_cur ->> 'rate')::numeric,
        'discount_percent', (v_cur ->> 'discount_percent')::numeric,
        -- The line's OWN discount plus its share of the bill's, which is what makes the header's
        -- `discount_total` - the figure the receipt prints - the sum of these rows.
        'discount_amount',  round((v_cur ->> 'discount_amount')::numeric + v_share, 2),
        'gst_percent',      v_slab,
        'cgst_amount',      v_cgst,
        'sgst_amount',      v_sgst,
        'igst_amount',      v_igst,
        'tax_amount',       v_tax,
        'total_amount',     v_discounted,
        'schedule_type',    v_cur ->> 'schedule_type'
      );
    end loop;

    v_lines := v_rebuilt;
  end if;

  if v_type = 'transfer' then
    v_amount_paid := 0;
  end if;

  select coalesce(sum((i ->> 'total_amount')::numeric), 0),
         coalesce(sum((i ->> 'tax_amount')::numeric), 0),
         coalesce(sum((i ->> 'discount_amount')::numeric), 0)
    into v_grand, v_tax_total, v_discount_total
    from jsonb_array_elements(v_lines) as i;

  v_grand          := round(v_grand, 2);
  v_tax_total      := round(v_tax_total, 2);
  v_discount_total := round(v_discount_total, 2);
  v_sub_total      := round(v_grand - v_tax_total, 2);
  v_balance        := round(v_grand - v_amount_paid, 2);

  if v_type = 'transfer' then
    -- A transfer owes nothing. Its lines are valued at cost, so the document carries what
    -- moved - but no one is the debtor on a stock movement, which is why the CHECK in
    -- 00035 requires a transfer's balance_due to be zero.
    v_balance := 0;
  end if;

  if v_balance > 0 and v_customer_id is null then
    raise exception 'a sale with an unpaid balance needs a customer to owe it'
      using errcode = 'check_violation';
  end if;

  v_doc_no := public.next_sale_invoice_no();

  if v_type = 'transfer' then
    v_transfer_note := 'TR' || substr(v_doc_no, 3);
  end if;

  insert into public.sales (
    pharmacy_id, customer_id, invoice_no, sale_date, status,
    sub_total, discount_total, tax_total, grand_total,
    payment_mode, amount_paid, balance_due, place_of_supply,
    sale_type, hospital_id, admission_id,
    patient_name, patient_mobile, patient_address,
    doctor_id, doctor_name, hospital_reference,
    from_location, to_location, transfer_reason, transfer_note_no,
    discount_above_limit_request_id, idempotency_key, created_by
  ) values (
    v_pharmacy,
    v_customer_id,
    v_doc_no,
    now(),
    (case when v_balance > 0 then 'credit' else 'completed' end)::public.sale_status,
    v_sub_total,
    v_discount_total,
    v_tax_total,
    v_grand,
    coalesce((p_payload ->> 'payment_mode')::public.payment_mode, 'cash'),
    v_amount_paid,
    v_balance,
    v_place,
    v_type,
    v_hospital_id,
    v_admission_id,
    v_patient_name,
    v_patient_mobile,
    v_patient_address,
    v_doctor_id,
    v_doctor_name,
    v_hospital_ref,
    v_from,
    v_to,
    v_transfer_reason,
    v_transfer_note,
    v_approval_id,
    v_key,
    auth.uid()
  )
  returning * into v_sale;

  insert into public.sale_items (
    pharmacy_id, sale_id, product_id, batch_id, qty, rate,
    discount_percent, discount_amount, gst_percent,
    cgst_amount, sgst_amount, igst_amount, tax_amount, total_amount,
    schedule_type
  )
  select
    v_pharmacy,
    v_sale.id,
    (i ->> 'product_id')::uuid,
    (i ->> 'batch_id')::uuid,
    (i ->> 'qty')::int,
    (i ->> 'rate')::numeric,
    (i ->> 'discount_percent')::numeric,
    (i ->> 'discount_amount')::numeric,
    (i ->> 'gst_percent')::numeric,
    (i ->> 'cgst_amount')::numeric,
    (i ->> 'sgst_amount')::numeric,
    (i ->> 'igst_amount')::numeric,
    (i ->> 'tax_amount')::numeric,
    (i ->> 'total_amount')::numeric,
    (i ->> 'schedule_type')::public.schedule_type
  from jsonb_array_elements(v_lines) as i;

  -- Re-read after the lines and the triggers, so the caller gets the final row.
  select * into v_sale
    from public.sales s
   where s.id = v_sale.id
     and s.pharmacy_id = v_pharmacy;

  return v_sale;
end;
$$;

comment on function public.checkout_sale(jsonb) is
  'Writes a sale and its lines in one transaction, pricing and validating per sale_type: a retail rate may not exceed MRP, a discount is capped at 10% of a line''s gross and of a bill''s tax-inclusive total (the payload''s `bill_discount` amount, shared across the lines), GST is extracted from the tax-inclusive rate using the product''s slab (a named 5% default when none is recorded), and a package or transfer rate is the server''s own figure. A bill discount above 10% of the bill is allowed only for the owner, or against an APPROVED `discount_above_limit` request whose recorded figures are this bill''s - which the sale then carries on `discount_above_limit_request_id`, a unique foreign key, so one approval authorises one bill. Idempotent on idempotency_key. A payload that names no sale_type is the legacy counter sale, and a bill discount is not part of that payload''s contract.';
