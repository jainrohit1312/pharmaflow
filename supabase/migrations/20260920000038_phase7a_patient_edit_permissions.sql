-- Migration: 20260920000038_phase7a_patient_edit_permissions | Purpose: make editing an
-- existing patient master a server-enforced permission, not a hidden button.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create-or-replace function, guarded revoke/grant, drop-policy-if-exists.
--
-- N-17(a), resolved
-- ----------------
-- The owner's brief: "Staff may search/select patients and create the minimum identity
-- necessary for an authorized new sale. Updating an existing patient master remains
-- permission-controlled; invoice-specific details must not silently edit the master." And the
-- follow-up brief says plainly: "Do not rely on disabled buttons as the security boundary."
--
-- Before this file, `customers` carried the standard tenant-wide four-policy template, so ANY
-- member of the pharmacy - a cashier, a viewer - could rewrite a patient's name, mobile and
-- demographics through PostgREST. Two things close that, using the idiom migration 00017
-- already established for `profiles`:
--
--   1. **Column-level privileges.** The patient-identity columns stop being writable by
--      `authenticated` at all, and are written only by a SECURITY DEFINER function. The
--      columns the existing customers form owns (name, phone, email, address, gstin, opening
--      balance, loyalty points, is_active) are granted back explicitly, so **no existing
--      screen changes behaviour**. This is deliberate: the customer-edit form is a different
--      module and this phase does not get to alter what it can do.
--   2. **`update_patient()`**, which requires the owner or a pharmacist. A cashier may still
--      register a patient for a sale (`save_patient`, unchanged) and may still edit a
--      customer's name and phone; a cashier may not rewrite a patient's master record.
--
-- Why the split is where it is: `patient_code` is identity (minted by the counter, never
-- typed), the demographics are clinical, and `opening_balance` / `loyalty_points` / `gstin`
-- are financial or on the tax books - the last group stays with the form that already owns
-- them, which is why it is granted back rather than dragged in here.
--
-- The table-level revoke is required for the same reason 00017 records: Supabase grants ALL on
-- public tables to `authenticated`, a table-level privilege covers every column, and
-- column-level grants are only consulted when the table-level one is absent.

-- ---------------------------------------------------------------------------
-- 1. The patient-identity columns become RPC-only
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'revoke update on public.customers from authenticated';

  -- Granted back: exactly the columns the existing customers form writes
  -- (`CustomerDraft.toJson()` - name, opening_balance, loyalty_points, is_active, phone,
  -- email, address, gstin), so the customers screen is untouched by this migration.
  execute 'grant update (name, phone, email, address, gstin, opening_balance, loyalty_points, is_active) on public.customers to authenticated';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to revoke.
    null;
end $$;

comment on table public.customers is
  'A customer a pharmacy bills, and - since Phase 7a - the patient master (D-074). `patient_code`, `date_of_birth`, `age_years`, `age_months`, `sex`, `guardian_name`, `guardian_phone` and `notes` are NOT updatable by authenticated: they are written only by update_patient() (owner or pharmacist), or assigned by save_patient() when a patient is registered. `opening_balance`, `loyalty_points`, `gstin` and `is_active` stay with the customers form that owns them.';

-- ---------------------------------------------------------------------------
-- 2. update_patient() - the gated edit of an existing master
--
--    Contact rule, on purpose the same as save_patient's: a patient must end the call with a
--    contact number, their own or a guardian's. An edit that would leave a patient with no
--    number would make the next pharmacy sale refuse to bill them ("that patient has no
--    mobile number on file"), so it is refused here instead - where the operator can see why.
--
--    What an edit may NOT do, stated so it is not discovered later: change `patient_code`
--    (identity, minted by the counter), change `opening_balance` / `loyalty_points` / `gstin`
--    / `is_active` (the customers form owns them), or move a patient to another pharmacy.
-- ---------------------------------------------------------------------------
create or replace function public.update_patient(
  p_patient_id uuid,
  p_name text,
  p_mobile text default null,
  p_guardian_phone text default null,
  p_address text default null,
  p_date_of_birth date default null,
  p_age_years int default null,
  p_age_months int default null,
  p_sex text default null,
  p_guardian_name text default null,
  p_notes text default null
) returns public.customers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy  uuid := public.get_my_pharmacy_id();
  v_role      public.app_role := public.get_my_role();
  v_patient   public.customers;
  v_name      text := btrim(coalesce(p_name, ''));
  v_mobile    text := public.normalize_indian_mobile(p_mobile);
  v_guardian  text := public.normalize_indian_mobile(p_guardian_phone);
  v_sex       text := nullif(lower(btrim(coalesce(p_sex, ''))), '');
  v_contact   text;
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  -- The permission, enforced here rather than by hiding a control.
  if v_role is null or v_role not in ('owner', 'pharmacist') then
    raise exception 'changing a patient''s details needs the owner or a pharmacist'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_patient
    from public.customers c
   where c.id = p_patient_id
     and c.pharmacy_id = v_pharmacy
   for update;

  if not found then
    raise exception 'that patient is not in this pharmacy'
      using errcode = 'check_violation';
  end if;

  if v_name = '' then
    raise exception 'a patient needs a name'
      using errcode = 'check_violation';
  end if;

  if p_mobile is not null and btrim(p_mobile) <> '' and v_mobile is null then
    raise exception 'that mobile number is not a valid Indian mobile (10 digits, starting 6-9)'
      using errcode = 'check_violation';
  end if;

  if p_guardian_phone is not null and btrim(p_guardian_phone) <> '' and v_guardian is null then
    raise exception 'that guardian mobile number is not a valid Indian mobile (10 digits, starting 6-9)'
      using errcode = 'check_violation';
  end if;

  v_contact := coalesce(v_mobile, v_guardian, v_patient.phone);

  if v_contact is null then
    raise exception 'a patient needs a mobile number, or a guardian''s for a child or dependant'
      using errcode = 'check_violation';
  end if;

  if v_sex is not null and v_sex not in ('male', 'female', 'other') then
    raise exception 'sex must be male, female or other'
      using errcode = 'check_violation';
  end if;

  if p_date_of_birth is not null and p_date_of_birth > current_date then
    raise exception 'a date of birth cannot be in the future'
      using errcode = 'check_violation';
  end if;

  update public.customers c
     set name          = v_name,
         phone         = v_contact,
         address       = nullif(btrim(coalesce(p_address, '')), ''),
         date_of_birth = p_date_of_birth,
         age_years     = p_age_years,
         age_months    = p_age_months,
         sex           = v_sex,
         guardian_name = nullif(btrim(coalesce(p_guardian_name, '')), ''),
         guardian_phone = v_guardian,
         notes         = nullif(btrim(coalesce(p_notes, '')), '')
   where c.id = v_patient.id
  returning * into v_patient;

  return v_patient;
end;
$$;

comment on function public.update_patient(uuid, text, text, text, text, date, integer, integer, text, text, text) is
  'Edits an existing patient master. Requires the owner or a pharmacist; refuses to leave the patient without a contact number; never changes patient_code or the financial columns the customers form owns.';

-- ---------------------------------------------------------------------------
-- 3. Grants
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.update_patient(uuid, text, text, text, text, date, integer, integer, text, text, text) to authenticated';
  execute 'revoke execute on function public.update_patient(uuid, text, text, text, text, date, integer, integer, text, text, text) from anon, public';
exception
  when undefined_object then
    null;
end $$;
