-- Migration: 20260921000042_phase7a_bill_discount | Purpose: one bill-level discount in
-- rupees, shared across the sale's lines on the tax-inclusive basis the owner settled.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create-or-replace function (the whole of `checkout_sale`); no schema change.
--
-- The owner's two sentences, and what they decide
-- -----------------------------------------------
-- The discount is a BILL-LEVEL AMOUNT in rupees, entered once near the totals - not a per-line
-- percentage (owner, 2026-09-21): "a bill of 546, a discount of 46, and 500 to pay". And the
-- basis is the tax-INCLUSIVE total, in his words: "we are giving discount on price including gst
-- so after discount gst will be calculated on that discounted total amount".
--
-- So the discount comes off the price on the shelf, and the taxable value and the tax are then
-- extracted from the smaller figure - the same extraction D-075 already does, applied to a
-- smaller number. A discount given at the time of supply reduces the taxable value and the tax
-- with it; taking it off the taxable value instead would over-report GST.
--
-- Why the whole function travels, and not a fragment
-- --------------------------------------------------
-- `checkout_sale()` is one ~600-line plpgsql function in 20260920000036, and the discount has to
-- be applied where the lines are priced. Applied migrations are never edited, so this file
-- REPLACES the function - which means the whole body has to travel. The text below is 00036's
-- function byte for byte with three additions: the `bill_discount` read, the sharing block after
-- the lines are priced, and the function's own `comment`. A truncated `create or replace` would
-- silently drop the rest of the function's behaviour and only its tests would notice, so the
-- rebuilt body was diffed against 00036's before it was applied.
--
-- What the sharing block does
-- ---------------------------
--   * distributes the bill discount across the lines in proportion to each line's own
--     `total_amount`, with the LAST line taking the rounding remainder, so the shares add back
--     to the rupee figure the counter entered exactly;
--   * recomputes each line's taxable value, `tax_amount`, `cgst_amount`, `sgst_amount` and
--     `total_amount` from its discounted inclusive total, with the slab it already has - the same
--     extraction the line got before the discount;
--   * adds the line's share into `sale_items.discount_amount`, so the header's `discount_total` -
--     the figure the receipt prints - stays the sum of the lines and equals what the counter
--     entered. `discount_percent` keeps its old meaning: the line's OWN percentage, untouched by
--     the bill's amount.
--
-- Distributing rather than subtracting at the header is the point: the header is the sum of the
-- lines, so `sub_total + tax_total = grand_total` and the tax heads still add back to the tax
-- charged (D-057, D-075).
--
-- What is refused
-- ---------------
--   * a discount larger than the bill;
--   * a discount above 10% of the bill's tax-inclusive total - D-071's cap, taken on the bill's
--     own total this time;
--   * any bill discount at all on a package or a transfer sale, which have no discount concept.
--
-- The over-cap case is a REFUSAL and not a prompt. D-071's "request approval" offer needs Phase
-- 6.5c's `approval_requests`, which does not exist, and `sales.discount_above_limit_request_id` is
-- deliberately absent from these migrations for that reason (00035's own note). The sentence
-- names the workflow honestly rather than promising one that is not built.
--
-- The legacy seam is untouched
-- ----------------------------
-- `bill_discount` is part of the TYPED contract. An untyped payload is the legacy counter sale
-- whose figures are stored verbatim (00036's seam note), and a key it does not know is left
-- alone exactly as every other unknown key is - so a payload that names no discount behaves
-- exactly as it did before this migration, and an untyped payload cannot take a bill discount.

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

    if v_bill_discount > v_gross_inclusive * 0.10 then
      -- The honest refusal, and the same one the per-line cap makes: D-071 records this as a
      -- real foreign key to Phase 6.5c's approval_requests, which does not exist, so the branch
      -- cannot be built - and an approval-shaped offer would be a lie about a control the owner
      -- relies on.
      raise exception 'a discount above 10%% of the bill needs the owner''s approval, and the approval workflow (Phase 6.5c) is not built yet - bill at 10%% or less'
        using errcode = 'check_violation';
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
  'Writes a sale and its lines in one transaction, pricing and validating per sale_type: a retail rate may not exceed MRP, a discount is capped at 10% of a line''s gross and of a bill''s tax-inclusive total (the payload''s `bill_discount` amount, shared across the lines), GST is extracted from the tax-inclusive rate using the product''s slab (a named 5% default when none is recorded), and a package or transfer rate is the server''s own figure. Idempotent on idempotency_key. A payload that names no sale_type is the legacy counter sale, and a bill discount is not part of that payload''s contract.';
