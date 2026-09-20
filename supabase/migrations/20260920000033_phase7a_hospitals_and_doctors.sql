-- Migration: 20260920000033_phase7a_hospitals_and_doctors | Purpose: the hospital a
-- pharmacy sits in (D-068) and the prescriber master the four sale types need (D-072).
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: if-not-exists tables/columns/indexes, drop-policy-if-exists before every
-- policy, drop-trigger-if-exists before every trigger.
--
-- Why these two tables land with Phase 7a instead of waiting for Phase 7b
-- ----------------------------------------------------------------------
-- D-068 recorded `hospitals` and `pharmacies.hospital_id` as part of the
-- profit-sharing phase, and D-072 recorded `doctors` as a referral-tracking master.
-- Both are pulled forward here because the four sale types cannot be built without
-- them: an `ipd_admission` bill has to name the patient's hospital and D-067 requires
-- that hospital to be prefilled from the pharmacy's own (`pharmacies.hospital_id`),
-- and a Schedule H/H1/X bill has to be able to name its prescriber (D-072).
--
-- What this file deliberately does NOT do: compute a share, seed a percentage, or
-- create `hospital_profit_sharing`. The profit-sharing half of D-068 stays Phase 7b,
-- exactly where it was recorded. There is no share column on `hospitals` for the same
-- reason - a percentage that lives in two places is a percentage that disagrees.
--
-- One deviation from D-068's column list, recorded rather than silent
-- ------------------------------------------------------------------
-- `hospitals` carries `pharmacy_id`, which D-068's list does not have. A table with
-- no tenant column cannot use the project's per-tenant policy template (D-004) and
-- would need a bespoke policy, and `hospital_profit_sharing` is `(pharmacy_id,
-- hospital_id)` anyway, so a hospital is a row of the pharmacy that sits in it. The
-- standard four-policy tenant template therefore applies unchanged, and "the
-- group's hospitals" is a per-pharmacy question - which is what one-pharmacy-per-
-- hospital already means (D-068).
--
-- Nothing reads `hospitals.state` today: it is on D-068's column list and a place of
-- supply for a sale is derived from the PHARMACY's own state (see the sale write path
-- in 00035), never from a patient's address. The column is kept for the hospital's
-- own address, which a package invoice prints.

-- ---------------------------------------------------------------------------
-- 1. hospitals - the premises a pharmacy sells through
--
--    Created before `pharmacies.hospital_id` below, because the FK needs its target.
--    `is_active` rather than a delete: a hospital that stops hosting this pharmacy
--    still has settled months and printed bills pointing at it.
-- ---------------------------------------------------------------------------
create table if not exists public.hospitals (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references public.pharmacies(id) on delete cascade,
  name text not null,
  address text,
  city text,
  state text,
  contact_person text,
  contact_phone text,
  contact_email text,
  gstin text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.hospitals is
  'The hospital a pharmacy sits in, one row per pharmacy in practice (D-068). Phase 7a reads it to prefill an IPD or package bill; the profit-sharing rules that reference it are Phase 7b.';
comment on column public.hospitals.pharmacy_id is
  'The pharmacy that sells through this hospital. Not in D-068''s column list - added so the tenant policy template (D-004) applies and so hospital_profit_sharing''s (pharmacy_id, hospital_id) has both halves tenant-scoped.';
comment on column public.hospitals.state is
  'The hospital''s own state, for its address on a package invoice. Never used to derive a sale''s place of supply - that comes from the pharmacy''s state.';
comment on column public.hospitals.is_active is
  'False when this pharmacy no longer sells through this hospital. Existing sales keep their hospital_id snapshot regardless.';

-- ---------------------------------------------------------------------------
-- 2. pharmacies.hospital_id - the link D-067 prefills an IPD bill from
--
--    `on delete set null` rather than cascade: deleting the hospital must not delete
--    the pharmacy. One pharmacy sits in exactly one hospital (D-068), which is why
--    this is a column and not a join table.
-- ---------------------------------------------------------------------------
alter table public.pharmacies
  add column if not exists hospital_id uuid references public.hospitals(id) on delete set null;

comment on column public.pharmacies.hospital_id is
  'The hospital this pharmacy sells through, if one is configured. An ipd_admission or package bill takes its hospital_id snapshot from here; NULL means no hospital has been configured yet, which is not the same as "no hospital".';

-- ---------------------------------------------------------------------------
-- 3. doctors - the prescriber, recorded and never paid (D-072)
--
--    Deliberately has no commercial column: the `default_profit_share_percent` the
--    first version of D-068 put here is gone, because a doctor takes no share of
--    anything. `name` is unique per pharmacy case-insensitively so that a name typed
--    three ways is one master row and three spellings on three bills - the sale keeps
--    its own `doctor_name` snapshot for exactly that reason (D-072).
-- ---------------------------------------------------------------------------
create table if not exists public.doctors (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references public.pharmacies(id) on delete cascade,
  name text not null,
  specialization text,
  contact text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.doctors is
  'Prescribers, scoped per pharmacy (D-072). A Schedule H/H1/X bill has to name one; a doctor is never a profit-sharing party.';
comment on column public.doctors.name is
  'The prescriber''s name as the master holds it. A sale keeps its own doctor_name snapshot, so re-pointing this later never rewrites a printed bill.';

create unique index if not exists doctors_pharmacy_name_key
  on public.doctors (pharmacy_id, lower(name));

create index if not exists hospitals_pharmacy_id_idx on public.hospitals (pharmacy_id);
create index if not exists doctors_pharmacy_id_idx   on public.doctors (pharmacy_id);

-- ---------------------------------------------------------------------------
-- 4. updated_at bookkeeping - the same trigger every other business table carries
-- ---------------------------------------------------------------------------
drop trigger if exists set_updated_at on public.hospitals;
create trigger set_updated_at before update on public.hospitals
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.doctors;
create trigger set_updated_at before update on public.doctors
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. RLS - the standard four-policy tenant template
--
--    Both tables carry pharmacy_id, so this is the same select/insert/update/delete
--    shape migration 00012 writes for every business table. Every role in the
--    pharmacy may read them (a bill has to name the prescriber); who may EDIT a
--    doctor or a hospital is left to the settings screens that own them, which is
--    where a role rule belongs until the RBAC phase lands.
-- ---------------------------------------------------------------------------
alter table public.hospitals enable row level security;
alter table public.doctors   enable row level security;

drop policy if exists hospitals_pharmacy_select on public.hospitals;
create policy hospitals_pharmacy_select on public.hospitals
  for select using (pharmacy_id = public.get_my_pharmacy_id());

drop policy if exists hospitals_pharmacy_insert on public.hospitals;
create policy hospitals_pharmacy_insert on public.hospitals
  for insert with check (pharmacy_id = public.get_my_pharmacy_id());

drop policy if exists hospitals_pharmacy_update on public.hospitals;
create policy hospitals_pharmacy_update on public.hospitals
  for update using (pharmacy_id = public.get_my_pharmacy_id())
  with check (pharmacy_id = public.get_my_pharmacy_id());

drop policy if exists hospitals_pharmacy_delete on public.hospitals;
create policy hospitals_pharmacy_delete on public.hospitals
  for delete using (pharmacy_id = public.get_my_pharmacy_id());

drop policy if exists doctors_pharmacy_select on public.doctors;
create policy doctors_pharmacy_select on public.doctors
  for select using (pharmacy_id = public.get_my_pharmacy_id());

drop policy if exists doctors_pharmacy_insert on public.doctors;
create policy doctors_pharmacy_insert on public.doctors
  for insert with check (pharmacy_id = public.get_my_pharmacy_id());

drop policy if exists doctors_pharmacy_update on public.doctors;
create policy doctors_pharmacy_update on public.doctors
  for update using (pharmacy_id = public.get_my_pharmacy_id())
  with check (pharmacy_id = public.get_my_pharmacy_id());

drop policy if exists doctors_pharmacy_delete on public.doctors;
create policy doctors_pharmacy_delete on public.doctors
  for delete using (pharmacy_id = public.get_my_pharmacy_id());
