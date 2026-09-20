-- Migration: 20260920000037_phase7a_allocation_integrity | Purpose: stop a collection
-- over-allocating a bill, and let an existing deposit be applied without taking money twice.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create-or-replace functions, guarded grants.
--
-- Why 00036 was not enough, stated plainly
-- ---------------------------------------
-- 00036's `collect_payment()` checked two things: that the allocations did not exceed the
-- RECEIPT, and that each target belonged to the payer. It did NOT check that they did not
-- exceed the target's OUTSTANDING. So two collections of 800 against an 800 bill would both
-- be accepted and the bill would end up settled twice - the exact over-allocation the owner's
-- brief rules out ("Concurrent collections cannot over-allocate a bill"), and a way for the
-- ledger to disagree with the account it is supposed to describe.
--
-- It also had no way to apply money that had ALREADY been taken. A deposit (a receipt whose
-- allocations were less than its amount) could be seen in `patient_account()` and never
-- applied, because the only writer of allocations also created a receipt - and "applying a
-- deposit is not a second receipt of money" (D-075).
--
-- Two things are added, and one of them is a lock:
--
--   * every allocation is checked against the target's outstanding, computed under a
--     `for update` lock on the target row. The lock is what makes the check mean anything
--     between two concurrent sessions: the second one waits, and by the time it computes the
--     aggregate it sees the first one's committed allocation (READ COMMITTED takes a fresh
--     snapshot per statement, so the aggregate must - and does - run after the lock).
--   * `allocate_payment()` applies an existing receipt's unallocated remainder, writing only
--     `payment_allocations` and touching neither `payments` nor `ledger_entries`.
--
-- Deadlock note, recorded rather than discovered: a collection may name several targets.
-- They are processed in a deterministic order (by target id), so two concurrent collections
-- touching the same pair cannot take the locks in opposite orders. A deadlock would in any
-- case abort one transaction whole - the allocation path is a single transaction, so there is
-- no partial write to clean up.

-- ---------------------------------------------------------------------------
-- 1. collect_payment() - replaced: the same receipt path, with a limit per target
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
  v_pharmacy   uuid := public.get_my_pharmacy_id();
  v_key        text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_alloc      jsonb := coalesce(p_allocations, '[]'::jsonb);
  v_payment    public.payments;
  v_requested  numeric(14,2);
  v_item       jsonb;
  v_sale_id    uuid;
  v_adm_id     uuid;
  v_amount     numeric(14,2);
  v_lock       uuid;
  v_charges    numeric(14,2);
  v_returns    numeric(14,2);
  v_allocated  numeric(14,2);
  v_left       numeric(14,2);
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

    -- Deterministic order: by target id, sales before admissions. See the header note on
    -- why this is not cosmetic.
    for v_item in
      select value
        from jsonb_array_elements(v_alloc)
       order by (value ->> 'sale_id')      nulls last,
                (value ->> 'admission_id') nulls last
    loop
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
        -- Lock first, then measure. The lock is what stops two concurrent collections from
        -- both passing the check below on the same bill.
        select s.id into v_lock
          from public.sales s
         where s.id = v_sale_id
           and s.pharmacy_id = v_pharmacy
           and (p_party_type <> 'customer' or s.customer_id = p_party_id)
           for update;

        if not found then
          raise exception 'that sale is not one this party owes in this pharmacy'
            using errcode = 'check_violation';
        end if;

        select s.grand_total,
               coalesce((select sum(r.grand_total)
                           from public.sale_returns r
                          where r.sale_id = v_sale_id
                            and r.pharmacy_id = v_pharmacy
                            and r.status <> 'cancelled'), 0),
               coalesce((select sum(pa.amount)
                           from public.payment_allocations pa
                          where pa.sale_id = v_sale_id
                            and pa.pharmacy_id = v_pharmacy), 0)
          into v_charges, v_returns, v_allocated
          from public.sales s
         where s.id = v_sale_id;

        v_left := round(v_charges - v_returns - v_allocated, 2);

        if round(v_amount, 2) > v_left then
          raise exception 'that would over-settle the bill: % is outstanding on it, not %', v_left, v_amount
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
        select a.id into v_lock
          from public.admissions a
         where a.id = v_adm_id
           and a.pharmacy_id = v_pharmacy
           and (p_party_type <> 'customer' or a.customer_id = p_party_id)
           for update;

        if not found then
          raise exception 'that admission is not one this patient owes in this pharmacy'
            using errcode = 'check_violation';
        end if;

        -- The episode's own aggregate, so the limit and the balance the operator is looking
        -- at cannot be computed two different ways.
        select a.outstanding into v_left
          from public.admission_account(v_adm_id) a;

        if round(v_amount, 2) > coalesce(v_left, 0) then
          raise exception 'that would over-settle the admission: % is outstanding on it, not %',
            coalesce(v_left, 0), v_amount
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
  'Takes a receipt through record_payment() and applies it to the sales or admission accounts it names, in one transaction. Each allocation is limited to the target''s outstanding, computed under a row lock so two concurrent collections cannot both settle the same bill. Allocations may total less than the receipt (the remainder is an unallocated deposit) but never more. Idempotent on p_idempotency_key.';

-- ---------------------------------------------------------------------------
-- 2. allocate_payment() - apply money that was already taken
--
--    The deposit case. A receipt whose allocations were less than its amount leaves an
--    unallocated remainder; this applies that remainder to documents later, and it writes
--    ONLY an allocation row. No `payments` row, no `ledger_entries` row - the money arrived
--    when the receipt was written, and applying it must not look like a second receipt
--    (D-075).
--
--    The limit is the receipt's own unallocated remainder, so a deposit cannot apply more
--    than it holds; and each target is checked and locked exactly as collect_payment does.
-- ---------------------------------------------------------------------------
create or replace function public.allocate_payment(
  p_payment_id uuid,
  p_allocations jsonb
) returns public.payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy   uuid := public.get_my_pharmacy_id();
  v_payment    public.payments;
  v_alloc      jsonb := coalesce(p_allocations, '[]'::jsonb);
  v_requested  numeric(14,2);
  v_held       numeric(14,2);
  v_already    numeric(14,2);
  v_item       jsonb;
  v_sale_id    uuid;
  v_adm_id     uuid;
  v_amount     numeric(14,2);
  v_lock       uuid;
  v_charges    numeric(14,2);
  v_returns    numeric(14,2);
  v_allocated  numeric(14,2);
  v_left       numeric(14,2);
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  if jsonb_array_length(v_alloc) = 0 then
    raise exception 'an allocation needs at least one target'
      using errcode = 'check_violation';
  end if;

  select * into v_payment
    from public.payments p
   where p.id = p_payment_id
     and p.pharmacy_id = v_pharmacy
   for update;

  if not found then
    raise exception 'that receipt is not in this pharmacy'
      using errcode = 'check_violation';
  end if;

  select coalesce(sum(pa.amount), 0)
    into v_already
    from public.payment_allocations pa
   where pa.payment_id = v_payment.id
     and pa.pharmacy_id = v_pharmacy;

  v_held := round(v_payment.amount - v_already, 2);

  select coalesce(sum((a ->> 'amount')::numeric), 0)
    into v_requested
    from jsonb_array_elements(v_alloc) as a;

  if round(v_requested, 2) > v_held then
    raise exception 'this receipt holds % unallocated, so it cannot apply %', v_held, v_requested
      using errcode = 'check_violation';
  end if;

  for v_item in
    select value
      from jsonb_array_elements(v_alloc)
     order by (value ->> 'sale_id')      nulls last,
              (value ->> 'admission_id') nulls last
  loop
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
      select s.id into v_lock
        from public.sales s
       where s.id = v_sale_id
         and s.pharmacy_id = v_pharmacy
         and (v_payment.party_type <> 'customer' or s.customer_id = v_payment.customer_id)
         for update;

      if not found then
        raise exception 'that sale is not owed by the party this receipt is from'
          using errcode = 'check_violation';
      end if;

      select s.grand_total,
             coalesce((select sum(r.grand_total)
                         from public.sale_returns r
                        where r.sale_id = v_sale_id
                          and r.pharmacy_id = v_pharmacy
                          and r.status <> 'cancelled'), 0),
             coalesce((select sum(pa.amount)
                         from public.payment_allocations pa
                        where pa.sale_id = v_sale_id
                          and pa.pharmacy_id = v_pharmacy), 0)
        into v_charges, v_returns, v_allocated
        from public.sales s
       where s.id = v_sale_id;

      v_left := round(v_charges - v_returns - v_allocated, 2);

      if round(v_amount, 2) > v_left then
        raise exception 'that would over-settle the bill: % is outstanding on it, not %', v_left, v_amount
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
      select a.id into v_lock
        from public.admissions a
       where a.id = v_adm_id
         and a.pharmacy_id = v_pharmacy
         and (v_payment.party_type <> 'customer' or a.customer_id = v_payment.customer_id)
         for update;

      if not found then
        raise exception 'that admission is not owed by the party this receipt is from'
          using errcode = 'check_violation';
      end if;

      select a.outstanding into v_left
        from public.admission_account(v_adm_id) a;

      if round(v_amount, 2) > coalesce(v_left, 0) then
        raise exception 'that would over-settle the admission: % is outstanding on it, not %',
          coalesce(v_left, 0), v_amount
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

  select * into v_payment
    from public.payments p
   where p.id = v_payment.id;

  return v_payment;
end;
$$;

comment on function public.allocate_payment(uuid, jsonb) is
  'Applies an existing receipt''s unallocated remainder to sales or admissions. Writes only payment_allocations - never a payment or a ledger row - so applying a deposit is not a second receipt. Limited to what the receipt still holds and to each target''s outstanding, under a row lock.';

-- ---------------------------------------------------------------------------
-- 3. Grants - the same convention as every other RPC in this tree
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.allocate_payment(uuid, jsonb) to authenticated';
  execute 'revoke execute on function public.allocate_payment(uuid, jsonb) from anon, public';
exception
  when undefined_object then
    null;
end $$;
