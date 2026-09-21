-- Phase 6.5c chunk 6 - functional test for migration 20260922000048 (the expense notification's
-- delivery half: the address the email leg needs, and what "queued" means).
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase6_5c_expense_delivery.sql
--
-- COUNTING
--   The last line reads "<n> PASS / <m> FAIL of <k> assertions", where k counts assertion lines
--   only, and the self-check on the line above it asserts that every logged line is a PASS or a
--   FAIL. The self-check is itself one of the counted assertions, because it is one.
--
-- HOW TO READ THE RESULT
--   The evidence comes back in the error message: every line is either "PASS: ..." or "FAIL: ...",
--   and the last line counts them. A non-zero exit code is expected and means the script ran to
--   completion, not that it failed.
--
-- WHY IT ENDS WITH RAISE EXCEPTION
--   The whole file is one DO block, which is one statement and therefore one implicit transaction.
--   Raising at the end rolls every fixture back, so it is safe against the hosted project.
--
-- IMPERSONATION
--   Fixtures are written as the owner of the database, then the session becomes `authenticated` and
--   the JWT claims are re-pointed as each case needs them: at the client's owner (who is not gated),
--   at a CASHIER, and at a second colleague. The signup cases are written and asserted BEFORE the
--   role switch, because `auth.users` is not a table `authenticated` can write and a brand-new
--   profile has no pharmacy yet, so no policy would show it to this session.
--
-- WHAT IT PROVES
--   1.  The column, and who may write it: `profiles.email` exists as a nullable text column,
--       `authenticated` still has NO table-level UPDATE on profiles (00017's rule), and the new
--       column IS updatable - on the same rows `profiles.phone` already is, which is 00012's pair of
--       policies and nothing wider. A cashier still cannot reach a colleague's row.
--   2.  `handle_new_user()` carries a new account's address onto its profile, trimmed - and a blank
--       one lands as NULL rather than as an empty string, so "no address" is one value and not two.
--   3.  One delivery-log row per channel the account can be REACHED on, and none for a channel it
--       cannot: neither address, number only, address only, and both. The email leg is the one this
--       migration added; the WhatsApp leg and the in-app row are chunk 5a-c's and are re-asserted
--       here so the four cases are one matrix rather than a claim about one of them.
--   4.  Every row the trigger opens is `queued` with no provider, and only the in-app leg's row
--       points at the inbox row it wrote - one expense, one inbox row, three delivery records at
--       most, and no second row for one message.
--   5.  An edit and a deletion queue the email leg too, under their own titles: the three acts D-085
--       retired from the approval enum, and the three a session can still perform on `expenses`.
--   6.  Where the dispatch lives and what it waits on is in the SCHEMA's own comment - on the
--       `notification_status` type a reader consults to ask what `queued` means (D-088). The next
--       reader does not have to find a chat log to learn that nothing sends these yet.
--   7.  The rail itself is unchanged and still closed: `notify_owner_of_expense()` is not executable
--       by a session, and `queue_notification()` still is.
--
-- WHAT IT DELIBERATELY DOES NOT REPEAT
--   The trigger's TENANT guard (an expense in another pharmacy tells nobody here) is unchanged by
--   this migration and is asserted by phase6_5c_master_data.sql, together with the inbox row's own
--   tenancy. This file is about the delivery half.

do $$
declare
  v_log            text[] := array[]::text[];
  v_pharmacy       uuid;
  v_owner          uuid;
  v_cashier        uuid := '00000000-0000-0000-0000-000000000061';
  v_colleague      uuid := '00000000-0000-0000-0000-000000000062';
  v_new_user       uuid := '00000000-0000-0000-0000-000000000063';
  v_pad_user       uuid := '00000000-0000-0000-0000-000000000064';
  v_blank_user     uuid := '00000000-0000-0000-0000-000000000065';
  v_email          text;
  v_expense        uuid;
  v_inbox          uuid;
  v_rows           int;
  v_allowed        boolean;
  v_comment        text;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE6.5C EXPENSE DELIVERY TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_owner
    from public.profiles
   where pharmacy_id = v_pharmacy and role = 'owner'
   order by created_at
   limit 1;
  if v_owner is null then
    raise exception 'PHASE6.5C EXPENSE DELIVERY TEST ABORTED: no owner profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------ fixtures
  -- `handle_new_user()` creates the profile row when the auth user is inserted, so the role and the
  -- pharmacy are SET afterwards rather than passed to the insert.
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_cashier, 'zztest-61-cashier@example.invalid', '{"full_name":"ZZTEST 61 cashier"}'::jsonb)
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_cashier, 'ZZTEST 61 cashier', 'cashier', v_pharmacy)
  on conflict (id) do update
    set full_name = excluded.full_name,
        role = excluded.role,
        pharmacy_id = excluded.pharmacy_id;

  insert into auth.users (id, email, raw_user_meta_data)
  values (v_colleague, 'zztest-61-colleague@example.invalid', '{"full_name":"ZZTEST 61 colleague"}'::jsonb)
  on conflict (id) do nothing;

  insert into public.profiles (id, full_name, role, pharmacy_id)
  values (v_colleague, 'ZZTEST 61 colleague', 'cashier', v_pharmacy)
  on conflict (id) do update
    set full_name = excluded.full_name,
        role = excluded.role,
        pharmacy_id = excluded.pharmacy_id;

  -- ================================================================= 1. the column, and its grant
  select count(*) into v_rows
    from information_schema.columns
   where table_schema = 'public'
     and table_name = 'profiles'
     and column_name = 'email'
     and data_type = 'text'
     and is_nullable = 'YES';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 1. profiles.email is a nullable text column (expected 1, got ' || v_rows || ')');

  -- 00017's rule still holds: while a table-level UPDATE grant exists, column grants are cosmetic -
  -- which is exactly how the privilege-escalation hole survived a plausible-looking fix.
  v_allowed := has_table_privilege('authenticated', 'public.profiles', 'UPDATE');
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 1. and the table-level UPDATE on profiles is still revoked from authenticated (expected false, got '
    || v_allowed || ')');

  v_allowed := has_column_privilege('authenticated', 'public.profiles', 'email', 'UPDATE');
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 1. the address is updatable by authenticated, the way his phone already is (expected true, got '
    || v_allowed || ')');

  -- The signup cases, before the role switch: `auth.users` is not a table `authenticated` may write,
  -- and a fresh profile is linked to no pharmacy yet, so no policy would show it to this session.
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_new_user, 'zztest-61-new@example.invalid', '{"full_name":"ZZTEST 61 new"}'::jsonb)
  on conflict (id) do nothing;

  select p.email into v_email from public.profiles p where p.id = v_new_user;
  v_log := array_append(v_log, case when v_email = 'zztest-61-new@example.invalid' then 'PASS' else 'FAIL' end
    || ': 1. a new account''s profile carries the address it signed up with (got '
    || coalesce(v_email, 'NULL') || ')');

  insert into auth.users (id, email, raw_user_meta_data)
  values (v_pad_user, '  zztest-61-padded@example.invalid  ', '{"full_name":"ZZTEST 61 padded"}'::jsonb)
  on conflict (id) do nothing;

  select p.email into v_email from public.profiles p where p.id = v_pad_user;
  v_log := array_append(v_log, case when v_email = 'zztest-61-padded@example.invalid' then 'PASS' else 'FAIL' end
    || ': 1. and it is trimmed, so a padded address is not a different address (got "'
    || coalesce(v_email, 'NULL') || '")');

  insert into auth.users (id, email, raw_user_meta_data)
  values (v_blank_user, '', '{"full_name":"ZZTEST 61 blank"}'::jsonb)
  on conflict (id) do nothing;

  select p.email into v_email from public.profiles p where p.id = v_blank_user;
  v_log := array_append(v_log, case when v_email is null then 'PASS' else 'FAIL' end
    || ': 1. an account with no address gets NULL rather than an empty string, so "none" is one value (got '
    || coalesce('"' || v_email || '"', 'NULL') || ')');

  -- ------------------------------------------------------------------ now behave as the users
  execute 'set local role authenticated';

  -- The owner writes his own address: the row policy is his own row, the column is granted.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  update public.profiles p set email = 'zztest-61-owner@example.invalid' where p.id = v_owner;
  get diagnostics v_rows = row_count;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 1. the owner sets his own address (expected 1 row, got ' || v_rows || ')');

  -- A cashier may edit himself and NOT a colleague: the grant is a column, the row set is 00012's
  -- policies, and this is the assertion that says the grant did not widen them.
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  update public.profiles p set email = 'zztest-61-cashier-himself@example.invalid' where p.id = v_cashier;
  get diagnostics v_rows = row_count;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 1. and a cashier may correct his own address too (expected 1 row, got ' || v_rows || ')');

  update public.profiles p set email = 'zztest-61-hijack@example.invalid' where p.id = v_owner;
  get diagnostics v_rows = row_count;
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 1. but a cashier cannot reach the owner''s row at all (expected 0 rows, got ' || v_rows || ')');

  -- Read back as the OWNER, because his row is the one `profiles_select_self` shows him and nobody
  -- else's business is visible to the cashier who just tried - which is itself the point.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  select p.email into v_email from public.profiles p where p.id = v_owner;
  v_log := array_append(v_log, case when v_email = 'zztest-61-owner@example.invalid' then 'PASS' else 'FAIL' end
    || ': 1. so the refused write left his address exactly as it was (got "'
    || coalesce(v_email, 'NULL') || '")');

  -- ================================================================= 2. the trigger's three legs
  -- The expense is recorded by the CASHIER in every case below, because who recorded it is what the
  -- notification names - and it is the cashier who must be able to record one at all (D-085).
  --
  -- Case (a): neither a number nor an address.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  update public.profiles p set phone = null, email = null where p.id = v_owner;

  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  insert into public.expenses (pharmacy_id, category, amount, expense_date, payment_mode)
  values (v_pharmacy, 'ZZTEST 61 neither', 11, current_date, 'cash');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 neither%';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 2. with no number and no address, the expense opens exactly ONE delivery record (expected 1, got '
    || v_rows || ')');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 neither%' and l.channel = 'in_app';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 2. and it is the in-app leg, which needs no destination (expected 1, got ' || v_rows || ')');

  -- Case (b): a number, no address.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  update public.profiles p set phone = '9000000061', email = null where p.id = v_owner;

  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  insert into public.expenses (pharmacy_id, category, amount, expense_date, payment_mode)
  values (v_pharmacy, 'ZZTEST 61 number', 22, current_date, 'cash');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 number%';
  v_log := array_append(v_log, case when v_rows = 2 then 'PASS' else 'FAIL' end
    || ': 2. with a number and no address, TWO records: the inbox and the phone (expected 2, got '
    || v_rows || ')');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 number%'
     and l.channel = 'whatsapp' and l.destination = '9000000061' and l.status = 'queued';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 2. the phone leg carries the number his profile holds and is queued, not sent (expected 1, got '
    || v_rows || ')');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 number%' and l.channel = 'email';
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 2. and no email record, because there is no address to send it to (expected 0, got '
    || v_rows || ')');

  -- Case (c): an address, no number. This is the leg this migration added.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  update public.profiles p
     set phone = null,
         email = 'zztest-61-owner@example.invalid'
   where p.id = v_owner;

  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  insert into public.expenses (pharmacy_id, category, amount, expense_date, payment_mode)
  values (v_pharmacy, 'ZZTEST 61 address', 33, current_date, 'cash');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 address%';
  v_log := array_append(v_log, case when v_rows = 2 then 'PASS' else 'FAIL' end
    || ': 2. with an address and no number, TWO records: the inbox and the email (expected 2, got '
    || v_rows || ')');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 address%'
     and l.channel = 'email'
     and l.destination = 'zztest-61-owner@example.invalid'
     and l.status = 'queued'
     and l.provider is null;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 2. the email leg carries the address his profile holds, queued with no provider (expected 1, got '
    || v_rows || ')');

  -- The subject is the only headline this message has, and email is the one channel that carries one.
  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 address%'
     and l.channel = 'email' and l.subject = 'Expense recorded';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 2. and it carries the act as its subject, so the mail has a headline (expected 1, got '
    || v_rows || ')');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 address%' and l.channel = 'whatsapp';
  v_log := array_append(v_log, case when v_rows = 0 then 'PASS' else 'FAIL' end
    || ': 2. and no phone record, because there is no number to send it to (expected 0, got '
    || v_rows || ')');

  -- Case (d): both. One row each, and no more.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  update public.profiles p
     set phone = '9000000061',
         email = 'zztest-61-owner@example.invalid'
   where p.id = v_owner;

  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  insert into public.expenses (pharmacy_id, category, amount, expense_date, payment_mode)
  values (v_pharmacy, 'ZZTEST 61 both', 44, current_date, 'cash');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 both%';
  v_log := array_append(v_log, case when v_rows = 3 then 'PASS' else 'FAIL' end
    || ': 2. with both, THREE records and not four - one per channel, never two for one message (expected 3, got '
    || v_rows || ')');

  -- ================================================================= 3. what those rows point at
  select e.id into v_expense
    from public.expenses e
   where e.pharmacy_id = v_pharmacy and e.category = 'ZZTEST 61 both';

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 both%'
     and l.status = 'queued' and l.provider is null;
  v_log := array_append(v_log, case when v_rows = 3 then 'PASS' else 'FAIL' end
    || ': 3. every one of them is queued with no provider: the message is OWED, not sent (expected 3, got '
    || v_rows || ')');

  -- The inbox row is the OWNER's, and `notifications_select_own` is `user_id = auth.uid()`, so it is
  -- invisible to the cashier who recorded the expense. Read it as the owner.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_owner::text, true);

  select count(*) into v_rows from public.notifications n
   where n.user_id = v_owner and n.type = 'expense' and n.message like '%ZZTEST 61 both%';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 3. and exactly ONE row landed in his inbox, not one per channel (expected 1, got '
    || v_rows || ')');

  select n.id into v_inbox from public.notifications n
   where n.user_id = v_owner and n.type = 'expense' and n.message like '%ZZTEST 61 both%'
   order by n.created_at limit 1;

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 both%'
     and l.channel = 'in_app' and l.notification_id = v_inbox;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 3. the in-app record is the one that POINTS AT that row, which is what makes "we told him" answerable (expected 1, got '
    || v_rows || ')');

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 both%'
     and l.channel in ('whatsapp', 'email') and l.notification_id is null;
  v_log := array_append(v_log, case when v_rows = 2 then 'PASS' else 'FAIL' end
    || ': 3. and the two dispatch records point at nothing, because neither writes an inbox row (expected 2, got '
    || v_rows || ')');

  -- ================================================================= 4. an edit and a deletion
  perform set_config('request.jwt.claims', json_build_object('sub', v_cashier::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_cashier::text, true);

  update public.expenses e set amount = 55 where e.id = v_expense;

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%55.00%' and l.channel = 'email'
     and l.subject = 'Expense changed';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 4. an expense EDIT queues the email leg too, under its own title (expected 1, got '
    || v_rows || ')');

  delete from public.expenses e where e.id = v_expense;

  select count(*) into v_rows from public.notification_logs l
   where l.pharmacy_id = v_pharmacy and l.body like '%ZZTEST 61 both%' and l.channel = 'email'
     and l.subject = 'Expense deleted';
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 4. and so does a deletion (expected 1, got ' || v_rows || ')');

  -- ================================================================= 5. what the schema now says
  v_comment := obj_description('public.notification_status'::regtype, 'pg_type');
  v_log := array_append(v_log, case when v_comment is not null then 'PASS' else 'FAIL' end
    || ': 5. the notification_status type has a comment at last, which is where a reader asks what queued means');

  v_log := array_append(v_log, case when v_comment like '%owed%' then 'PASS' else 'FAIL' end
    || ': 5. and it says a queued row is a message OWED rather than sent (got '
    || coalesce(v_comment, 'NULL') || ')');

  v_log := array_append(v_log, case
    when v_comment like '%N-1%' and v_comment like '%nothing yet%' then 'PASS' else 'FAIL' end
    || ': 5. and names where the dispatch waits, so the next reader does not have to find a chat log (D-088)');

  select col_description('public.notification_logs'::regclass, a.attnum) into v_comment
    from pg_attribute a
   where a.attrelid = 'public.notification_logs'::regclass
     and a.attname = 'status';
  v_log := array_append(v_log, case when v_comment like '%OWED%' then 'PASS' else 'FAIL' end
    || ': 5. and the delivery log''s own status column says the same thing where an operator reads it');

  -- ================================================================= 6. the rail is still closed
  v_allowed := has_function_privilege('authenticated', 'public.notify_owner_of_expense()', 'EXECUTE');
  v_log := array_append(v_log, case when not v_allowed then 'PASS' else 'FAIL' end
    || ': 6. the trigger function is not executable by a session - it is fired by the table (expected false, got '
    || v_allowed || ')');

  v_allowed := has_function_privilege('authenticated', 'public.queue_notification(jsonb)', 'EXECUTE');
  v_log := array_append(v_log, case when v_allowed then 'PASS' else 'FAIL' end
    || ': 6. while the rail it uses is still reachable, unchanged (expected true, got '
    || v_allowed || ')');

  v_log := array_append(v_log, case
    when (select pg_get_functiondef(p.oid) from pg_proc p
           where p.proname = 'notify_owner_of_expense') like '%v_owner.email%' then 'PASS' else 'FAIL' end
    || ': 6. and the trigger function is the one that reads the address, not something else wearing its name');

  select count(*) into v_rows
    from pg_trigger t
   where t.tgrelid = 'public.expenses'::regclass
     and t.tgname = 'notify_owner_of_expense'
     and not t.tgisinternal
     and (t.tgtype & 4) = 4 and (t.tgtype & 8) = 8 and (t.tgtype & 16) = 16;
  v_log := array_append(v_log, case when v_rows = 1 then 'PASS' else 'FAIL' end
    || ': 6. fired on INSERT, UPDATE and DELETE, which is the three acts D-085 retired from the enum (expected 1, got '
    || v_rows || ')');

  -- ================================================================ summary
  v_log := array_append(v_log, case
    when (select count(*) from unnest(v_log) l
           where coalesce(l, '') not like 'PASS%'
             and coalesce(l, '') not like 'FAIL%') = 0
      then 'PASS' else 'FAIL' end
    || ': 0. every logged line is a PASS or a FAIL (nothing skipped, nothing truncated)');

  v_log := array_append(v_log, 'SUMMARY: '
    || (select count(*) from unnest(v_log) l where l like 'PASS%') || ' PASS / '
    || (select count(*) from unnest(v_log) l where l like 'FAIL%') || ' FAIL of '
    || (select count(*) from unnest(v_log) l
         where l like 'PASS%' or l like 'FAIL%') || ' assertions');

  raise exception E'PHASE6.5C EXPENSE DELIVERY TEST\n%', array_to_string(v_log, chr(10));
end $$;
