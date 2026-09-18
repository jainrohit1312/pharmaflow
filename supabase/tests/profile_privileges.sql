-- SECURITY REGRESSION TEST - profile column privileges + onboarding RPC
-- (migration 20260918000017_harden_profiles).
--
-- Run:
--   supabase db query --linked --file supabase/tests/profile_privileges.sql
--
-- Every line of output is "PASS: ..." or "FAIL: ...". A non-zero exit code is
-- expected: the script ends by raising so the whole thing rolls back.
--
-- Why it impersonates a role instead of asking you to click around the SQL
-- Editor: the vulnerability is about *privileges*, and a superuser query proves
-- nothing about them. Inside one transaction this file sets the JWT claims that
-- `auth.uid()` reads, switches to the `authenticated` role, and then attempts
-- the exact two writes an attacker would make. Rolling back at the end means no
-- part of it persists.

do $$
declare
  v_log      text := '';
  v_user     uuid;
  v_pharmacy uuid;
  v_role     text;
  v_name     text;
  v_allowed  boolean;
  v_count    int;
begin
  select id into v_user from public.profiles order by created_at limit 1;
  if v_user is null then
    raise exception 'PRIVILEGE TEST ABORTED: no profile row to test against';
  end if;

  -- ------------------------------------------------------------------ grants
  -- The table-level grant is the one that matters: while it exists, column
  -- revokes are ignored, which is exactly how this vulnerability survived a
  -- plausible-looking fix.
  v_allowed := has_table_privilege('authenticated', 'public.profiles', 'UPDATE');
  v_log := v_log || case when not v_allowed then 'PASS' else 'FAIL' end
    || ': table-level UPDATE on profiles is revoked from authenticated '
    || '(expected false, got ' || v_allowed || ')' || chr(10);

  v_allowed := has_column_privilege('authenticated', 'public.profiles', 'role', 'UPDATE');
  v_log := v_log || case when not v_allowed then 'PASS' else 'FAIL' end
    || ': role is not updatable by authenticated (expected false, got ' || v_allowed || ')' || chr(10);

  v_allowed := has_column_privilege('authenticated', 'public.profiles', 'pharmacy_id', 'UPDATE');
  v_log := v_log || case when not v_allowed then 'PASS' else 'FAIL' end
    || ': pharmacy_id is not updatable by authenticated (expected false, got ' || v_allowed || ')' || chr(10);

  v_allowed := has_column_privilege('authenticated', 'public.profiles', 'is_active', 'UPDATE');
  v_log := v_log || case when not v_allowed then 'PASS' else 'FAIL' end
    || ': is_active is not updatable by authenticated (expected false, got ' || v_allowed || ')' || chr(10);

  v_allowed := has_column_privilege('authenticated', 'public.profiles', 'full_name', 'UPDATE');
  v_log := v_log || case when v_allowed then 'PASS' else 'FAIL' end
    || ': full_name is still updatable by authenticated (expected true, got ' || v_allowed || ')' || chr(10);

  v_allowed := has_function_privilege(
    'anon',
    'public.onboard_pharmacy(text, text, text, text, text, text, text)',
    'EXECUTE'
  );
  v_log := v_log || case when not v_allowed then 'PASS' else 'FAIL' end
    || ': anon cannot execute onboard_pharmacy (expected false, got ' || v_allowed || ')' || chr(10);

  v_allowed := has_function_privilege(
    'authenticated',
    'public.onboard_pharmacy(text, text, text, text, text, text, text)',
    'EXECUTE'
  );
  v_log := v_log || case when v_allowed then 'PASS' else 'FAIL' end
    || ': authenticated can execute onboard_pharmacy (expected true, got ' || v_allowed || ')' || chr(10);

  -- --------------------------------------------------- behave as the user
  -- As `anon` there is no tenant identity at all, so nothing may be visible.
  execute 'set local role anon';
  select count(*) into v_count from public.products;
  v_log := v_log || case when v_count = 0 then 'PASS' else 'FAIL' end
    || ': anon sees no business rows (expected 0 products, got ' || v_count || ')' || chr(10);
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- Self-promotion: the attack that motivated this migration.
  begin
    update public.profiles set role = 'owner' where id = v_user;
    v_log := v_log || 'FAIL: self-promotion to owner was allowed' || chr(10);
  exception
    when insufficient_privilege then
      v_log := v_log || 'PASS: self-promotion refused (insufficient_privilege)' || chr(10);
  end;

  -- Tenant hop: point your own row at another tenant and every policy follows.
  begin
    update public.profiles set pharmacy_id = gen_random_uuid() where id = v_user;
    v_log := v_log || 'FAIL: rewriting pharmacy_id was allowed' || chr(10);
  exception
    when insufficient_privilege then
      v_log := v_log || 'PASS: rewriting pharmacy_id refused (insufficient_privilege)' || chr(10);
  end;

  -- The columns a user legitimately owns must keep working, or the fix is just
  -- a different outage.
  begin
    update public.profiles set full_name = 'ZZTEST Name' where id = v_user;
    get diagnostics v_count = row_count;
    v_log := v_log || case when v_count = 1 then 'PASS' else 'FAIL' end
      || ': user-editable column still updatable (expected 1 row, got ' || v_count || ')' || chr(10);
  exception
    when others then
      v_log := v_log || 'FAIL: editing full_name was refused (' || sqlerrm || ')' || chr(10);
  end;

  -- Onboarding is not a way to acquire a second pharmacy.
  begin
    perform public.onboard_pharmacy(
      'ZZTEST second pharmacy', null, null, null, null, null, null
    );
    v_log := v_log || 'FAIL: onboarding was allowed for an already-linked account' || chr(10);
  exception
    when unique_violation then
      v_log := v_log || 'PASS: onboarding refused for an already-linked account' || chr(10);
    when others then
      v_log := v_log || 'FAIL: onboarding refused for the wrong reason ('
        || sqlerrm || ')' || chr(10);
  end;

  -- ------------------------------------------------------- the happy path
  -- Unlink the profile as the superuser (this is the state a brand new account
  -- is in), then onboard as the user.
  execute 'reset role';
  update public.profiles set pharmacy_id = null, role = 'viewer' where id = v_user;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  begin
    v_pharmacy := public.onboard_pharmacy(
      'ZZTEST Pharmacy',
      '27ABCDE1234F1Z5',
      '20B/12345',
      '9876543210',
      'Mumbai',
      'Maharashtra',
      '400001'
    );
    v_log := v_log || case when v_pharmacy is not null then 'PASS' else 'FAIL' end
      || ': onboarding created a pharmacy (' || coalesce(v_pharmacy::text, 'NULL') || ')' || chr(10);
  exception
    when others then
      v_log := v_log || 'FAIL: onboarding failed (' || sqlerrm || ')' || chr(10);
  end;

  execute 'reset role';

  select profiles.role, profiles.full_name into v_role, v_name
    from public.profiles where id = v_user;
  v_log := v_log || case when v_role = 'owner' then 'PASS' else 'FAIL' end
    || ': onboarding linked the account as owner (expected owner, got '
    || coalesce(v_role, 'NULL') || ')' || chr(10);

  select count(*) into v_count from public.pharmacies where id = v_pharmacy;
  v_log := v_log || case when v_count = 1 then 'PASS' else 'FAIL' end
    || ': the pharmacy row exists (expected 1, got ' || v_count || ')' || chr(10);

  -- Blank optional fields must land as NULL, not as empty strings.
  select count(*) into v_count
    from public.pharmacies
   where id = v_pharmacy
     and gstin = '27ABCDE1234F1Z5'
     and drug_license_no = '20B/12345'
     and city = 'Mumbai';
  v_log := v_log || case when v_count = 1 then 'PASS' else 'FAIL' end
    || ': the supplied details were stored (expected 1, got ' || v_count || ')' || chr(10);

  raise exception E'PROFILE PRIVILEGE TEST\n%', v_log;
end $$;
