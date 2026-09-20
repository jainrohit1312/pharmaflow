-- Migration: 20260920000036_phase7a_sale_write_paths | Purpose: one sale RPC that prices
-- and validates per type, one collection RPC that allocates, and the two balance readers.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create-or-replace functions, guarded grants.
--
-- What changes about the money, and why it had to
-- ----------------------------------------------
-- The owner's brief settles the GST question the plan had left open (N-14), for pharmacy
-- sales only: "MRP is tax-inclusive; do not add tax above it. Same-unit MRP 105 at 5%
-- means taxable 100 + GST 5." So the rate on a line is the price the customer pays, and
-- the tax is EXTRACTED from it rather than added on top. Three consequences, all intended:
--
--   * `sale_items.total_amount` stays quantity x rate less discount, so a bill's total is
--     the price on the shelf rather than that price plus tax;
--   * `sub_total` (the taxable value) becomes `grand_total - tax_total`, which is the same
--     identity `checkout_sale` has always used for the header - the header and the lines
--     now agree by construction instead of by coincidence;
--   * a product with no recorded slab is billed at one named POS default (5%) instead of
--     the old blanket 12%, and a product's own slab - including a recorded ZERO - wins over
--     that default. `products.gst_percent` is read for the first time here.
--
-- Historical invoices are untouched: this is the write path, so it decides new documents
-- only. The purchase/GRN path keeps its own 12% default, which is a different question.
--
-- The client's tax figures are no longer trusted. The payload's per-line `gst_percent`,
-- `tax_amount` and the four tax columns are recomputed here from the product's slab and the
-- pharmacy's own state; the client's `rate` and `discount_percent` are inputs that are
-- validated (a retail rate may not exceed MRP; a discount is capped at 10%) rather than
-- taken on trust. That is what "the server must validate ... prices" means in practice.

-- ---------------------------------------------------------------------------
-- 1. pos_default_gst_percent() - the one named default, in one place
--
--    It is a function rather than a literal inside the RPC so that the number has exactly
--    one home and a later "configure the POS default" change is one edit. It is a plain
--    constant today; the brief asks for "one configured/named 5% POS default" and the
--    naming is what this provides.
-- ---------------------------------------------------------------------------
create or replace function public.pos_default_gst_percent()
returns numeric
language sql
immutable
as $$
  -- 5.00, the common slab for a pharmacy counter in India, and the figure the owner
  -- named. Applied ONLY when a product has no slab of its own recorded - never as a
  -- substitute for a slab that exists, and never to a package or transfer line.
  select 5.00::numeric;
$$;

comment on function public.pos_default_gst_percent() is
  'The falls-back-to GST rate for a pharmacy sale whose product has no slab recorded (owner, 2026-09-20: 5%). A product''s own slab, including zero, always wins.';

-- ---------------------------------------------------------------------------
-- 2. checkout_sale(p_payload jsonb) - replaced: type-aware pricing and validation
--
--    The signature is unchanged, so the shipped app keeps working: a payload that does not
--    name a `sale_type` is a legacy counter sale. ONE seam decides the whole contract - a
--    payload that names its type gets every rule below, and an untyped one keeps exactly
--    the behaviour this function had before, for both the identity requirements and the
--    money. That is a deliberate compatibility rule rather than an oversight: the
--    alternative refuses the walk-in sale the app in the field sends, breaks the committed
--    Phase 3/4/5 tests that exercise that caller, and buys nothing - the typed path is the
--    same counter sale with the owner's pricing and identity rules applied. When the new
--    flow is the only caller, the untyped branch is dead code and deleting it is one
--    migration; until then, one seam, applied consistently, is what "preserving legacy
--    compatibility" (the brief) means here.
--
--    What the server decides for a TYPED sale:
--
--      counter       patient required (a customers row); name and mobile snapshotted from
--                    it; the prescriber required if any line is Schedule H/H1/X.
--      ipd_admission the patient plus an admission - either `admission_id` or the
--                    hospital's number, which is found-or-created; the treating doctor is
--                    required; a discharged episode is refused.
--      package       the hospital/account as the debtor, the patient's name and mobile for
--                    traceability, the case reference, and a configured markup - a package
--                    sale is REFUSED while `pharmacies.package_markup_percent` is NULL
--                    rather than priced at an invented default. The rate is purchase cost
--                    plus markup, resolved here; a package line has no discount and needs
--                    its product's own slab (its tax treatment is not settled - see the
--                    report's open items).
--      transfer      source, destination and reason; no patient, no account, no cash and no
--                    GST; the rate is the batch's purchase rate.
--
--    Idempotency: `idempotency_key`, when supplied, makes a retried submit return the
--    original sale instead of ringing up a second one.
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
    -- purchase cost plus a configured markup, or plain purchase cost. A retail rate is the
    -- caller's, defaulted from the batch, and may not exceed MRP.
    if v_type = 'package' then
      v_rate := round(
        coalesce(nullif(v_batch.landed_cost_per_unit, 0), v_batch.purchase_rate)
        * (1 + v_markup / 100),
        2
      );
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
      -- The honest refusal. D-071 makes this a real foreign key to Phase 6.5c's
      -- approval_requests, which does not exist, so the branch cannot be built - and an
      -- approval-shaped modal would be a lie about a control the owner relies on.
      raise exception 'a discount above 10%% needs the owner''s approval, and the approval workflow (Phase 6.5c) is not built yet - bill at 10%% or less'
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
    idempotency_key, created_by
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
  'Writes a sale and its lines in one transaction, pricing and validating per sale_type: a retail rate may not exceed MRP, a discount is capped at 10%, GST is extracted from the tax-inclusive rate using the product''s slab (a named 5% default when none is recorded), and a package or transfer rate is the server''s own figure. Idempotent on idempotency_key. A payload that names no sale_type is the legacy counter sale.';

-- ---------------------------------------------------------------------------
-- 3. collect_payment() - the receipt AND what it settles
--
--    One action, because the two halves must not be able to disagree: a receipt that was
--    written while its allocation failed would take money and leave the bill unpaid, and
--    an allocation without a receipt is money from nowhere. The receipt itself goes through
--    `record_payment()` (Phase 4, D-024) rather than being reimplemented, so the ledger
--    posting for a collection is byte-for-byte the path that already exists.
--
--    `p_allocations` is a JSON array of {sale_id | admission_id, amount}. The total may be
--    LESS than the receipt - the remainder is an unallocated deposit on the account, which
--    is a normal thing for a counter to hold and must stay visible as such ("keep
--    unallocated deposits distinct"). It may not be more: that would apply money the
--    receipt did not take.
-- ---------------------------------------------------------------------------
create or replace function public.collect_payment(
  p_party_type public.party_type,
  p_party_id uuid,
  p_amount numeric,
  p_mode public.payment_mode,
  p_allocations jsonb default null,
  p_reference_no text default null,
  p_payment_date date default null,
  p_notes text default null,
  p_idempotency_key text default null
) returns public.payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy  uuid := public.get_my_pharmacy_id();
  v_key       text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_alloc     jsonb := coalesce(p_allocations, '[]'::jsonb);
  v_payment   public.payments;
  v_requested numeric(14,2);
  v_item      jsonb;
  v_sale_id   uuid;
  v_adm_id    uuid;
  v_amount    numeric(14,2);
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'a collection needs an amount greater than zero'
      using errcode = 'check_violation';
  end if;

  if v_key is not null then
    select * into v_payment
      from public.payments p
     where p.pharmacy_id = v_pharmacy
       and p.idempotency_key = v_key;

    if found then
      return v_payment;
    end if;
  end if;

  -- The receipt and its ledger row: the Phase 4 RPC, unchanged.
  v_payment := public.record_payment(
    p_party_type, p_party_id, p_amount, p_mode, p_reference_no, p_payment_date, p_notes
  );

  if v_key is not null then
    update public.payments p
       set idempotency_key = v_key
     where p.id = v_payment.id
    returning * into v_payment;
  end if;

  if jsonb_array_length(v_alloc) > 0 then
    select coalesce(sum((a ->> 'amount')::numeric), 0)
      into v_requested
      from jsonb_array_elements(v_alloc) as a;

    if round(v_requested, 2) > round(p_amount, 2) then
      raise exception 'the allocations total % but the receipt is only %', v_requested, p_amount
        using errcode = 'check_violation';
    end if;

    for v_item in select * from jsonb_array_elements(v_alloc) loop
      v_sale_id := nullif(v_item ->> 'sale_id', '')::uuid;
      v_adm_id  := nullif(v_item ->> 'admission_id', '')::uuid;
      v_amount  := coalesce((v_item ->> 'amount')::numeric, 0);

      if v_amount <= 0 then
        raise exception 'an allocation needs an amount greater than zero'
          using errcode = 'check_violation';
      end if;

      if (v_sale_id is null) = (v_adm_id is null) then
        raise exception 'an allocation names exactly one target: a sale or an admission'
          using errcode = 'check_violation';
      end if;

      if v_sale_id is not null then
        -- The target must be the payer's own document: a receipt from a patient may not
        -- settle the hospital's package invoice, and a cross-tenant target is refused.
        if not exists (
          select 1 from public.sales s
           where s.id = v_sale_id
             and s.pharmacy_id = v_pharmacy
             and (p_party_type <> 'customer' or s.customer_id = p_party_id)
        ) then
          raise exception 'that sale is not one this party owes in this pharmacy'
            using errcode = 'check_violation';
        end if;

        if not exists (
          select 1 from public.payment_allocations pa
           where pa.payment_id = v_payment.id
             and pa.sale_id = v_sale_id
        ) then
          insert into public.payment_allocations (
            pharmacy_id, payment_id, sale_id, amount, created_by
          ) values (
            v_pharmacy, v_payment.id, v_sale_id, round(v_amount, 2), auth.uid()
          );
        end if;
      else
        if not exists (
          select 1 from public.admissions a
           where a.id = v_adm_id
             and a.pharmacy_id = v_pharmacy
             and (p_party_type <> 'customer' or a.customer_id = p_party_id)
        ) then
          raise exception 'that admission is not one this patient owes in this pharmacy'
            using errcode = 'check_violation';
        end if;

        if not exists (
          select 1 from public.payment_allocations pa
           where pa.payment_id = v_payment.id
             and pa.admission_id = v_adm_id
        ) then
          insert into public.payment_allocations (
            pharmacy_id, payment_id, admission_id, amount, created_by
          ) values (
            v_pharmacy, v_payment.id, v_adm_id, round(v_amount, 2), auth.uid()
          );
        end if;
      end if;
    end loop;
  end if;

  return v_payment;
end;
$$;

comment on function public.collect_payment(public.party_type, uuid, numeric, public.payment_mode, jsonb, text, date, text, text) is
  'Takes a receipt through record_payment() and applies it to the sales or admission accounts it names, in one transaction. Allocations may total less than the receipt (the remainder is an unallocated deposit) but never more. Idempotent on p_idempotency_key.';

-- ---------------------------------------------------------------------------
-- 4. admission_account() and patient_account() - the balances, server-derived
--
--    `outstanding = net charges - allocated collections`, where net charges are what was
--    posted less the returns that cancelled part of it. Nothing here reads a paginated
--    list: these are aggregates over the whole episode or the whole patient, which is what
--    the brief demands of a figure that decides whether a counter lets someone walk out.
--
--    An allocation is counted once, whichever way it was aimed - at the episode or at an
--    individual invoice inside it - because each row is a slice of money and the sum of the
--    slices is what was applied. A payment can never be counted twice through this: the
--    unique indexes in 00035 allow one allocation of one payment per document.
-- ---------------------------------------------------------------------------
create or replace function public.admission_account(p_admission_id uuid)
returns table (
  admission_id uuid,
  customer_id uuid,
  admission_no text,
  patient_name text,
  patient_code text,
  hospital_id uuid,
  admitted_on date,
  discharged_on date,
  status text,
  charges numeric,
  returns_credits numeric,
  allocated numeric,
  outstanding numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  return query
  select
    a.id,
    a.customer_id,
    a.admission_no,
    c.name,
    c.patient_code,
    a.hospital_id,
    a.admitted_on,
    a.discharged_on,
    a.status,
    coalesce(ch.charges, 0),
    coalesce(ch.returns_credits, 0),
    coalesce(al.allocated, 0),
    round(coalesce(ch.charges, 0) - coalesce(ch.returns_credits, 0) - coalesce(al.allocated, 0), 2)
  from public.admissions a
  join public.customers c on c.id = a.customer_id
  left join lateral (
    select
      sum(s.grand_total) as charges,
      coalesce((
        select sum(r.grand_total)
          from public.sale_returns r
         where r.sale_id in (
                 select s2.id from public.sales s2
                  where s2.admission_id = a.id
                    and s2.pharmacy_id = v_pharmacy
                    and s2.status <> 'cancelled'
               )
           and r.pharmacy_id = v_pharmacy
           and r.status <> 'cancelled'
      ), 0) as returns_credits
    from public.sales s
   where s.admission_id = a.id
     and s.pharmacy_id = v_pharmacy
     and s.status <> 'cancelled'
  ) ch on true
  left join lateral (
    select sum(x.amount) as allocated
    from (
      select pa.amount
        from public.payment_allocations pa
       where pa.admission_id = a.id
         and pa.pharmacy_id = v_pharmacy
      union all
      select pa.amount
        from public.payment_allocations pa
        join public.sales s3 on s3.id = pa.sale_id
       where s3.admission_id = a.id
         and s3.pharmacy_id = v_pharmacy
         and pa.pharmacy_id = v_pharmacy
    ) x
  ) al on true
  where a.id = p_admission_id
    and a.pharmacy_id = v_pharmacy;
end;
$$;

comment on function public.admission_account(uuid) is
  'One admission''s charges, returns, allocated collections and outstanding - aggregated server-side over the whole episode (D-025). Tenant-scoped; returns no row for an admission outside the caller''s pharmacy.';

create or replace function public.patient_account(p_customer_id uuid)
returns table (
  customer_id uuid,
  patient_name text,
  patient_code text,
  phone text,
  charges numeric,
  returns_credits numeric,
  allocated numeric,
  outstanding numeric,
  unallocated_deposits numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  return query
  select
    c.id,
    c.name,
    c.patient_code,
    c.phone,
    coalesce(ch.charges, 0),
    coalesce(ch.returns_credits, 0),
    coalesce(al.allocated, 0),
    round(coalesce(ch.charges, 0) - coalesce(ch.returns_credits, 0) - coalesce(al.allocated, 0), 2),
    round(coalesce(rec.received, 0) - coalesce(al.allocated, 0), 2)
  from public.customers c
  left join lateral (
    select
      sum(s.grand_total) as charges,
      coalesce((
        select sum(r.grand_total)
          from public.sale_returns r
          join public.sales s2 on s2.id = r.sale_id
         where s2.customer_id = c.id
           and s2.pharmacy_id = v_pharmacy
           and s2.status <> 'cancelled'
           and r.status <> 'cancelled'
      ), 0) as returns_credits
    from public.sales s
   where s.customer_id = c.id
     and s.pharmacy_id = v_pharmacy
     and s.status <> 'cancelled'
  ) ch on true
  left join lateral (
    select sum(x.amount) as allocated
    from (
      select pa.amount
        from public.payment_allocations pa
        join public.sales s4 on s4.id = pa.sale_id
       where s4.customer_id = c.id
         and pa.pharmacy_id = v_pharmacy
      union all
      select pa.amount
        from public.payment_allocations pa
        join public.admissions a2 on a2.id = pa.admission_id
       where a2.customer_id = c.id
         and pa.pharmacy_id = v_pharmacy
    ) x
  ) al on true
  left join lateral (
    select sum(p.amount) as received
      from public.payments p
     where p.pharmacy_id = v_pharmacy
       and p.party_type = 'customer'
       and p.customer_id = c.id
  ) rec on true
  where c.id = p_customer_id
    and c.pharmacy_id = v_pharmacy;
end;
$$;

comment on function public.patient_account(uuid) is
  'One patient''s charges, returns, allocated collections, outstanding and any unallocated deposit - aggregated server-side (D-025). A package sale never lands here: its debtor is the hospital account, not the patient.';

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.collect_payment(public.party_type, uuid, numeric, public.payment_mode, jsonb, text, date, text, text) to authenticated';
  execute 'revoke execute on function public.collect_payment(public.party_type, uuid, numeric, public.payment_mode, jsonb, text, date, text, text) from anon, public';

  execute 'grant execute on function public.admission_account(uuid) to authenticated';
  execute 'revoke execute on function public.admission_account(uuid) from anon, public';

  execute 'grant execute on function public.patient_account(uuid) to authenticated';
  execute 'revoke execute on function public.patient_account(uuid) from anon, public';

  execute 'grant execute on function public.pos_default_gst_percent() to authenticated';
  execute 'revoke execute on function public.pos_default_gst_percent() from anon, public';
exception
  when undefined_object then
    -- Role or function missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
