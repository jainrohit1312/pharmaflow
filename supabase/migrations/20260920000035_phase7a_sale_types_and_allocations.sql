-- Migration: 20260920000035_phase7a_sale_types_and_allocations | Purpose: the four sale
-- types on `sales`, and the allocation table that lets an outstanding balance be a
-- server-derived figure rather than a sum of rows a client happened to load.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: add-column-if-not-exists, guarded enum creation, drop-constraint-if-exists
-- before every constraint, drop-policy-if-exists before every policy, create-or-replace
-- functions, guarded grants.
--
-- The one rule this file exists to make true
-- -----------------------------------------
-- D-025 and the owner's brief agree that a balance is a server-side aggregate, never a
-- sum over a paginated list: the brief says "Balances must be server-derived
-- authoritative values, not sums of a paginated sales list." A charge and a collection
-- therefore have to be separable things that the database can count, which is what
-- `payment_allocations` is: one row per slice of money applied to one document. The
-- receipts themselves keep living in `payments` (Phase 4, D-024), and an allocation is
-- explicitly NOT a second receipt - applying a deposit the counter already took is not
-- taking it again.
--
-- What is deliberately NOT here: `sales.discount_above_limit_request_id`. D-071 records
-- it as a real foreign key to Phase 6.5c's `approval_requests`, which does not exist, and
-- the owner confirmed the order is 6.5c before this work (D-071, MASTER_PLAN Phase 7
-- Sequencing). So the column is absent rather than soft, and the server refuses an
-- above-10% line for the honest reason - named in the message - instead of pretending an
-- approval happened. That is the whole of the missing branch: see 00036 for the refusal.

-- ---------------------------------------------------------------------------
-- 1. pharmacies.package_markup_percent - nullable, and NULL refuses a package sale
--
--    D-070 recorded this column as `numeric(5,2) default 20` and then flagged its own
--    consequence as an open item: "A not-null default of 20 makes 'unconfigured'
--    indistinguishable from 'intentionally 20%'." The owner's brief for this work
--    settles which way to fall - "Package cost basis, markup and tax treatment must be
--    explicitly configured/resolved; do not silently guess unresolved settings" - so the
--    column has NO default and a package sale is REFUSED while it is NULL, naming exactly
--    what has to be configured. This is the same rule the catalogue already applies to a
--    GST slab (00031: "NULL keeps 'nobody has said' distinguishable from '5%'") and to a
--    hospital share (D-068: 0% is a value, not an absence).
--
--    The owner still has to supply the four real values (D-070). Until then the package
--    flow exists, validates, and refuses with a message that names the setting.
-- ---------------------------------------------------------------------------
alter table public.pharmacies
  add column if not exists package_markup_percent numeric(5,2);

comment on column public.pharmacies.package_markup_percent is
  'The service markup on purchase cost for a package sale (D-070), e.g. 20.00 for 20%. NULL means nobody has configured it, and a package sale is refused rather than priced at an invented default - the same "absence is not a value" rule the GST slab and hospital share follow.';

-- ---------------------------------------------------------------------------
-- 2. sale_type - four types, and the columns each bill carries
--
--    The enum and the twelve columns D-067 records, minus the deferred approval FK.
--    `sale_type` defaults to 'counter' exactly as D-067 says, and that default carries
--    the warning that decision already records: a caller who forgets to send a type gets
--    a counter sale. The write path in 00036 therefore requires the type-aware fields
--    whenever a type is named, and leaves an untyped payload alone as the legacy counter
--    sale the shipped app sends.
--
--    `hospital_id` is a SNAPSHOT taken from the pharmacy's own hospital (D-067), never
--    from the payload: a pharmacy that moves premises must not rewrite a settled month.
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.sale_type as enum ('counter', 'ipd_admission', 'package', 'transfer');
exception when duplicate_object then null;
end $$;

alter table public.sales
  add column if not exists sale_type            public.sale_type not null default 'counter',
  add column if not exists hospital_id          uuid references public.hospitals(id) on delete set null,
  add column if not exists admission_id         uuid references public.admissions(id) on delete set null,
  add column if not exists patient_name         text,
  add column if not exists patient_mobile       text,
  add column if not exists patient_address      text,
  add column if not exists doctor_id            uuid references public.doctors(id) on delete set null,
  add column if not exists doctor_name          text,
  add column if not exists hospital_reference   text,
  add column if not exists from_location        text,
  add column if not exists to_location          text,
  add column if not exists transfer_reason      text,
  add column if not exists transfer_note_no     text,
  add column if not exists idempotency_key      text;

comment on column public.sales.sale_type is
  'One of the four types D-067 defines. Defaults to counter, which is the common sale and the wrong answer for a caller that forgets to send one.';
comment on column public.sales.hospital_id is
  'The hospital, snapshotted from pharmacies.hospital_id at sale time (D-067). Never taken from the payload, so a pharmacy changing premises cannot rewrite a settled month.';
comment on column public.sales.admission_id is
  'The episode an ipd_admission sale posts its credit to. NULL for the other three types. One patient may have many admissions and their balances never mix.';
comment on column public.sales.patient_name is
  'The patient as this bill printed them - a snapshot, like doctor_name. Editing the patient master later never rewrites an old bill.';
comment on column public.sales.patient_mobile is
  'The patient''s contact as this bill recorded it, in canonical 10-digit form. A snapshot, for the same reason as patient_name.';
comment on column public.sales.hospital_reference is
  'The hospital''s own OPD/IPD number for this sale - D-067''s hospital_reference, copied from the admission. It is the external reference, NOT the patient id and NOT a UUID.';
comment on column public.sales.transfer_reason is
  'Why stock moved. Named transfer_reason rather than D-067''s bare `reason`: on a table that also carries a cancelled sale, a column called `reason` does not say what it is a reason for.';
comment on column public.sales.idempotency_key is
  'Optional caller-supplied key. Two checkouts with the same key in one pharmacy are one sale, so a retried submit cannot ring up a second bill (the brief: "retries cannot create duplicate bills, receipts or transfer movements").';

-- Per-type structural invariants. Every pre-Phase-7a row is a `counter` with all of the
-- new columns NULL, so each predicate below is trivially true for it and the constraints
-- validate against existing data - no NOT VALID gymnastics, and no historical row is
-- rewritten to satisfy a new rule.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'sales_ipd_needs_reference') then
    alter table public.sales add constraint sales_ipd_needs_reference
      check (sale_type <> 'ipd_admission' or hospital_reference is not null);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'sales_package_needs_account') then
    alter table public.sales add constraint sales_package_needs_account
      check (
        sale_type <> 'package'
        or (customer_id is not null and hospital_reference is not null and discount_total = 0)
      );
  end if;

  if not exists (select 1 from pg_constraint where conname = 'sales_transfer_shape') then
    alter table public.sales add constraint sales_transfer_shape
      check (
        sale_type <> 'transfer'
        or (
          from_location is not null
          and to_location is not null
          and from_location <> to_location
          and transfer_reason is not null
          and customer_id is null
          and amount_paid = 0
          and balance_due = 0
          and tax_total = 0
        )
      );
  end if;

  if not exists (select 1 from pg_constraint where conname = 'sales_patient_identity_before_7a') then
    -- A typed pharmacy sale must carry the identity the brief requires. Legacy counter
    -- rows are exempt by the sale_type check itself, which is the compatibility rule the
    -- write path documents in full.
    alter table public.sales add constraint sales_patient_identity_before_7a
      check (
        sale_type not in ('counter', 'ipd_admission')
        or (patient_name is null and patient_mobile is null)
        or (patient_name is not null and patient_mobile is not null)
      );
  end if;
end $$;

create index if not exists sales_pharmacy_sale_type_idx on public.sales (pharmacy_id, sale_type);
create index if not exists sales_admission_id_idx       on public.sales (admission_id);

-- One sale per key, per pharmacy. Partial, so the many rows with no key are unconstrained.
create unique index if not exists sales_pharmacy_idempotency_key
  on public.sales (pharmacy_id, idempotency_key)
  where idempotency_key is not null;

-- ---------------------------------------------------------------------------
-- 3. payments.idempotency_key - the same guard for a collection
--
--    "Retries cannot create duplicate receipts." A collection writes a payment and a
--    ledger row; without a key, a retried tap on a slow connection is two receipts for
--    one handover of cash.
-- ---------------------------------------------------------------------------
alter table public.payments
  add column if not exists idempotency_key text;

comment on column public.payments.idempotency_key is
  'Optional caller-supplied key. A repeated collection with the same key in one pharmacy returns the existing payment instead of taking the money twice.';

create unique index if not exists payments_pharmacy_idempotency_key
  on public.payments (pharmacy_id, idempotency_key)
  where idempotency_key is not null;

-- ---------------------------------------------------------------------------
-- 4. payment_allocations - which money paid which document
--
--    Exactly one target per row: a sale (an OPD or counter invoice) or an admission
--    (the IPD account). The two are different questions - "is this bill paid" and "what
--    does this episode owe" - and a partial unique index admits one allocation of a given
--    payment to a given document, so a retry converges instead of stacking.
--
--    An allocation is NOT a receipt. The money arrived when the `payments` row was
--    written (Phase 4, D-024); this table says where it was applied, which is why
--    applying a deposit moves a balance without touching the cash book.
-- ---------------------------------------------------------------------------
create table if not exists public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references public.pharmacies(id) on delete cascade,
  payment_id uuid not null references public.payments(id) on delete cascade,
  sale_id uuid references public.sales(id) on delete cascade,
  admission_id uuid references public.admissions(id) on delete cascade,
  amount numeric(14,2) not null check (amount > 0),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payment_allocations_target_check check (
    (sale_id is not null and admission_id is null)
    or (sale_id is null and admission_id is not null)
  )
);

comment on table public.payment_allocations is
  'One slice of one payment applied to one document (a sale or an admission). The charges an admission owes are its sales; the money settled is these rows. Summing them is how a balance stays a server-derived figure (D-025).';
comment on column public.payment_allocations.admission_id is
  'The episode this money was applied to. An IPD bill is posted to the admission account, so its settlement is recorded here rather than against the individual sale.';

create unique index if not exists payment_allocations_payment_sale_key
  on public.payment_allocations (payment_id, sale_id)
  where sale_id is not null;

create unique index if not exists payment_allocations_payment_admission_key
  on public.payment_allocations (payment_id, admission_id)
  where admission_id is not null;

create index if not exists payment_allocations_pharmacy_id_idx  on public.payment_allocations (pharmacy_id);
create index if not exists payment_allocations_sale_id_idx      on public.payment_allocations (sale_id);
create index if not exists payment_allocations_admission_id_idx on public.payment_allocations (admission_id);
create index if not exists payment_allocations_payment_id_idx   on public.payment_allocations (payment_id);

drop trigger if exists set_updated_at on public.payment_allocations;
create trigger set_updated_at before update on public.payment_allocations
  for each row execute function public.set_updated_at();

alter table public.payment_allocations enable row level security;

drop policy if exists payment_allocations_pharmacy_select on public.payment_allocations;
create policy payment_allocations_pharmacy_select on public.payment_allocations
  for select using (pharmacy_id = public.get_my_pharmacy_id());

drop policy if exists payment_allocations_pharmacy_delete on public.payment_allocations;
create policy payment_allocations_pharmacy_delete on public.payment_allocations
  for delete using (pharmacy_id = public.get_my_pharmacy_id());

-- No insert/update policy on purpose: an allocation moves a balance, and the only writer
-- that also validates the receipt and the target's owner is collect_payment() (00036).
-- The same reasoning import_jobs uses for having no write policy at all.

-- ---------------------------------------------------------------------------
-- 5. ledger_auto_entry_sale() - replaced so a counter settlement is also allocated
--
--    Applied migrations are never edited, so this is the correction idiom the tree
--    already uses (00015 replaced its own stock functions, 00016 replaced the purchase
--    pair): the body is repeated verbatim from 00019 with ONE addition.
--
--    The addition is required by the new balance rule, and its absence would be a real
--    defect rather than a missing nicety. This trigger writes a `payments` row for a
--    sale paid at the counter. Once a patient is attached to every pharmacy sale (the
--    brief), that path runs for nearly every counter sale - and an outstanding figure
--    computed as charges less allocations would report a fully-paid ₹500 bill as ₹500
--    still owing, because the money arrived through this trigger and was never applied
--    to anything. So the trigger now writes the allocation for the money it records.
--
--    Nothing else changes: the same idempotency guards, the same three rows, the same
--    early returns for a cancelled sale and for a sale with no customer (which is what a
--    legacy walk-in still is).
-- ---------------------------------------------------------------------------
create or replace function public.ledger_auto_entry_sale()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry_date date := coalesce(new.sale_date::date, current_date);
  v_payment_id uuid;
begin
  -- A cancelled sale never happened, so it posts nothing.
  if new.status = 'cancelled' then
    return new;
  end if;

  -- No party, nothing to post (see the header note). This is the walk-in cash
  -- sale, which is the commonest sale a pharmacy makes.
  if new.customer_id is null then
    return new;
  end if;

  -- Idempotency guard: the receivable row is keyed by reference_id = sale id.
  if not exists (
    select 1 from public.ledger_entries
    where reference_type = 'sale' and reference_id = new.id
  ) then
    insert into public.ledger_entries (
      pharmacy_id, entry_date, party_type, customer_id,
      reference_type, reference_id, description, debit, credit, created_by
    ) values (
      new.pharmacy_id,
      v_entry_date,
      'customer',
      new.customer_id,
      'sale',
      new.id,
      'Sale ' || coalesce(new.invoice_no, new.id::text),
      coalesce(new.grand_total, 0),
      0,
      new.created_by
    );
  end if;

  -- The counter settlement, once per sale. Guarded on the payments row rather
  -- than on the ledger row, because that is the row this block creates - and the
  -- allocation below lives inside this block for the same reason: the guard is what
  -- makes it fire exactly once.
  if coalesce(new.amount_paid, 0) > 0
     and not exists (
       select 1 from public.payments
       where pharmacy_id = new.pharmacy_id
         and party_type = 'customer'
         and customer_id = new.customer_id
         and reference_no = new.invoice_no
     )
  then
    insert into public.payments (
      pharmacy_id, party_type, customer_id, amount, mode,
      reference_no, payment_date, notes, created_by
    ) values (
      new.pharmacy_id,
      'customer',
      new.customer_id,
      new.amount_paid,
      new.payment_mode,
      new.invoice_no,
      v_entry_date,
      'Auto-captured from sale ' || coalesce(new.invoice_no, new.id::text),
      new.created_by
    )
    returning id into v_payment_id;

    insert into public.ledger_entries (
      pharmacy_id, entry_date, party_type, customer_id,
      reference_type, reference_id, description, debit, credit, created_by
    ) values (
      new.pharmacy_id,
      v_entry_date,
      'customer',
      new.customer_id,
      'payment',
      v_payment_id,
      'Paid at the counter for ' || coalesce(new.invoice_no, new.id::text),
      0,
      new.amount_paid,
      new.created_by
    );

    -- The money this block just recorded was taken FOR this sale, so it is applied
    -- to it. Without this row the counter takings are invisible to every balance
    -- computed from allocations, and a paid bill reads as unpaid.
    insert into public.payment_allocations (
      pharmacy_id, payment_id, sale_id, amount, created_by
    ) values (
      new.pharmacy_id,
      v_payment_id,
      new.id,
      new.amount_paid,
      new.created_by
    );
  end if;

  return new;
end;
$$;

comment on function public.ledger_auto_entry_sale() is
  'Posts the receivable for a customer-attached sale, and for a counter settlement the payment, its ledger credit and its allocation to the sale. Replaced in 00035 to add the allocation; the guards and the other postings are unchanged from 00019.';
