-- Migration: 20260918000018_harden_profiles_anon | Purpose: take EXECUTE on onboard_pharmacy away from anon
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: revoke/grant are idempotent; guarded for non-Supabase clusters.
--
-- Why this needs its own migration
-- -------------------------------
-- 20260918000017 revoked EXECUTE on `onboard_pharmacy` from PUBLIC, which is the
-- textbook way to undo PostgreSQL's default grant. On Supabase that is not
-- enough: `anon` and `authenticated` hold EXECUTE through grants made directly
-- to those roles (Supabase's `alter default privileges ... grant all on
-- functions to anon, authenticated`), so removing the PUBLIC grant leaves their
-- own grant intact. Verified against the live database after 00017 was applied:
--
--   select has_function_privilege('anon', 'public.onboard_pharmacy(...)', 'EXECUTE');
--   -- true, despite `revoke all ... from public`
--
-- 00017 is left untouched: it is already applied, and `supabase db push` does
-- not re-run applied versions. This is the same trap as the table-level UPDATE
-- grant in 00017 - privileges inherited from a role-specific grant are
-- invisible to a revoke aimed at PUBLIC.

do $$
begin
  -- Two statements because `from public, anon` would fail on a cluster without
  -- an `anon` role, and this file has to stay runnable on plain Postgres.
  execute 'revoke all on function public.onboard_pharmacy(text, text, text, text, text, text, text) from public';
  execute 'revoke all on function public.onboard_pharmacy(text, text, text, text, text, text, text) from anon';
  execute 'grant execute on function public.onboard_pharmacy(text, text, text, text, text, text, text) to authenticated';
exception
  when undefined_object then
    -- Role or function missing in a bare cluster: nothing to re-point.
    null;
end $$;
