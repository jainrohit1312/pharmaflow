-- Migration: 20260918000017_harden_profiles | Purpose: close a privilege-escalation path on profiles and add a server-side onboarding RPC
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: drop policy if exists / create or replace function / guarded grants.
--
-- The vulnerability
-- -----------------
-- `profiles_update_self` (migration 00012) is `for update using (id = auth.uid())
-- with check (id = auth.uid())`. RLS is row-level, not column-level, so it let
-- any authenticated user write ANY column of their own row - including `role`
-- and `pharmacy_id`. Combined with `get_my_pharmacy_id()` reading that same row,
-- that is both self-promotion to owner and a tenant hop: point your own
-- `pharmacy_id` at another tenant's uuid and every RLS policy scopes to them.
--
-- Why the obvious fix does not work
-- ---------------------------------
-- The natural fix is a column-level revoke:
--     revoke update (role, pharmacy_id, is_active) on public.profiles from authenticated;
-- On this project that statement does NOTHING. Supabase grants table-level
-- privileges to `authenticated` on every public table, and in PostgreSQL a
-- table-level privilege covers all columns: column-level revokes are only
-- consulted when the table-level privilege is absent. Verified against the live
-- database before writing this file:
--     select has_table_privilege('authenticated','public.profiles','UPDATE');  -- true
--     select has_column_privilege('authenticated','public.profiles','role','UPDATE');  -- true
--
-- The table-level grant therefore has to be revoked first, and the permitted
-- columns granted back explicitly. The same pattern is required anywhere a
-- column needs protecting on a table Supabase has granted wholesale.
--
-- What this migration does
-- ------------------------
--   1. Table-level UPDATE revoked from `authenticated` on `profiles`, then
--      UPDATE granted back on the three columns a user may edit about
--      themselves (full_name, phone, avatar_url).
--   2. The self-update RLS policy is kept, and simplified: it still provides the
--      row restriction (you may only touch your own row), while the column
--      privileges now enforce the column restriction.
--   3. `onboard_pharmacy()` - a SECURITY DEFINER RPC that creates a pharmacy and
--      links the caller to it as owner. It runs as its owner, so it bypasses
--      both RLS and the column privileges; that is precisely why the legitimate
--      path is a server-side function rather than two client writes.
--
--   Nothing in the app writes `profiles` today (the auth repository only reads
--   it), so the revoke cannot break an existing flow. Legitimate profile edits
--   still work through the granted columns.

-- ---------------------------------------------------------------------------
-- 1. Column-level protection for the sensitive columns
-- ---------------------------------------------------------------------------
do $$
begin
  -- The table-level grant is what actually permits the update; without this
  -- revoke the column grants below would be cosmetic.
  execute 'revoke update on public.profiles from authenticated';

  -- Granted back explicitly, because the revoke above takes UPDATE away
  -- entirely. These are the columns a user may change about themselves.
  execute 'grant update (full_name, phone, avatar_url) on public.profiles to authenticated';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to revoke.
    null;
end $$;

comment on table public.profiles is
  'Application user profile, 1:1 with auth.users; may predate pharmacy assignment. `role`, `pharmacy_id` and `is_active` are NOT updatable by authenticated: elevated through SECURITY DEFINER RPCs only.';

-- ---------------------------------------------------------------------------
-- 2. The self-update policy, kept for the row restriction
--
--    Recreated identically on purpose: it is still the only thing stopping a
--    user from touching somebody else's profile row. The column restriction
--    lives in the grants above, because RLS cannot express it.
-- ---------------------------------------------------------------------------
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update
  using (id = auth.uid())
  with check (id = auth.uid());

-- ---------------------------------------------------------------------------
-- 3. Onboarding RPC
--
--    Creates the pharmacy, links the caller to it as owner, and returns the new
--    pharmacy id. The caller cannot do this itself any more, which is the point.
-- ---------------------------------------------------------------------------
create or replace function public.onboard_pharmacy(
  p_pharmacy_name text,
  p_gstin text,
  p_drug_license text,
  p_phone text,
  p_city text,
  p_state text,
  p_pincode text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id       uuid;
  v_existing      uuid;
  v_pharmacy_id   uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'You must be signed in to create a pharmacy'
      using errcode = '42501';
  end if;

  if coalesce(btrim(p_pharmacy_name), '') = '' then
    raise exception 'Pharmacy name is required'
      using errcode = '22023';
  end if;

  -- One pharmacy per account. Onboarding is not a route to a second outlet, and
  -- it must not become a way to move between tenants.
  select pharmacy_id into v_existing
    from public.profiles
   where id = v_user_id;

  if v_existing is not null then
    raise exception 'This account is already linked to a pharmacy'
      using errcode = '23505';
  end if;

  -- Blank strings become NULL so "not supplied" is one value, not two.
  insert into public.pharmacies (
    name, gstin, drug_license_no, phone, city, state, pincode
  ) values (
    btrim(p_pharmacy_name),
    nullif(btrim(coalesce(p_gstin, '')), ''),
    nullif(btrim(coalesce(p_drug_license, '')), ''),
    nullif(btrim(coalesce(p_phone, '')), ''),
    nullif(btrim(coalesce(p_city, '')), ''),
    nullif(btrim(coalesce(p_state, '')), ''),
    nullif(btrim(coalesce(p_pincode, '')), '')
  )
  returning id into v_pharmacy_id;

  update public.profiles
     set pharmacy_id = v_pharmacy_id,
         role = 'owner'
   where id = v_user_id;

  -- Checked immediately after the UPDATE, before anything else can reset FOUND.
  -- The profile row is created by the handle_new_user trigger at signup, so a
  -- missing one means the account is malformed: fail the whole transaction
  -- rather than leave a pharmacy that nobody owns.
  if not found then
    raise exception 'No profile exists for this account'
      using errcode = 'P0002';
  end if;

  return v_pharmacy_id;
end;
$$;

comment on function public.onboard_pharmacy(text, text, text, text, text, text, text) is
  'Creates a pharmacy for the calling user and links them to it as owner. The only supported way to set profiles.pharmacy_id and profiles.role, because those columns are no longer updatable by authenticated.';

-- Postgres grants EXECUTE to PUBLIC on new functions, so the revoke is what
-- makes the grant below meaningful: `anon` must not be able to create tenants.
do $$
begin
  execute 'revoke all on function public.onboard_pharmacy(text, text, text, text, text, text, text) from public';
  execute 'grant execute on function public.onboard_pharmacy(text, text, text, text, text, text, text) to authenticated';
exception
  when undefined_object then
    null;
end $$;
