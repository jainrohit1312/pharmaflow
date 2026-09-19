-- Phase 5 notification queue - functional test for migration
-- 20260919000028_phase5_queue_notification.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase5_notifications.sql
--
-- HOW TO READ THE RESULT
--   Every line is "PASS: ..." or "FAIL: ...", and the last line is
--   "SUMMARY: n PASS / n FAIL of n assertions". A non-zero exit code is expected
--   and means the script ran to completion: it ends by raising, so the whole DO
--   block (one statement, one transaction) rolls back and no ZZTEST pharmacy,
--   profile, customer, notification or dispatch row survives.
--
-- WHY IT IMPERSONATES
--   `queue_notification` is SECURITY DEFINER, so RLS is NOT applied to its own
--   inserts - it restates the `notifications` insert policy by hand, and the only
--   way to prove the restatement is to call it as `authenticated` with a JWT set
--   and to put a second tenant's user in reach. The settle half of the sequence is
--   an ordinary RLS-governed update, so the same impersonation proves that too.
--
-- WHAT IT PROVES
--   1.  The pair: one call writes the dispatch record and the in-app row it
--       points at, the log starts `queued` with no provider, and it is linked.
--   2.  The in-app row's payload: the recipient, `type` defaulting to 'message',
--       `title` falling back to the subject, the message verbatim, channel
--       `in_app`, and `data` carrying the dispatch context (with no null keys).
--   3.  The option to write no in-app row at all: `notification_id` is null and
--       nothing lands in `notifications`.
--   4.  The tenant comes from the caller and never from the payload; a colleague
--       in the same pharmacy is a legal recipient, a user of another pharmacy is
--       refused, and the refused call writes nothing.
--   5.  The guards and their sentences: channel, recipient, body, uuid - each a
--       check_violation (23514) the app can show verbatim, and each writing
--       nothing.
--   6.  The settle path under RLS: the caller updates their own queued row to
--       `sent` with the provider's answer, and cannot touch another tenant's.
--   7.  The function's own contract: SECURITY DEFINER, VOLATILE (it writes),
--       search_path pinned, no pharmacy argument, EXECUTE for `authenticated` and
--       not for `anon`.
--
-- The table properties themselves - the enums, the policies, the absence of a
-- delete policy, the foreign key on notification_id - belong to migration 00022 and
-- are asserted by supabase/tests/phase5_ai_notifications.sql. This test does not
-- repeat them.

do $$
declare
  v_log        text[] := array[]::text[];
  v_pass       int;
  v_fail       int;
  v_pharmacy   uuid;
  v_user       uuid;
  v_colleague  uuid := gen_random_uuid();
  v_other_user uuid := gen_random_uuid();
  v_other      uuid;
  v_customer   uuid;
  v_foreign    uuid;   -- another tenant's queued dispatch
  v_result     jsonb;
  v_log_id     uuid;
  v_notif_id   uuid;
  v_row        public.notification_logs%rowtype;
  v_notif      public.notifications%rowtype;
  v_logs_before int;
  v_logs_after  int;
  v_n          int;
  v_prosecdef  boolean;
  v_provolatile char;
  v_proconfig  text[];
  v_identity   text;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE5 NOTIFICATIONS TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user from public.profiles where pharmacy_id = v_pharmacy order by created_at limit 1;
  if v_user is null then
    raise exception 'PHASE5 NOTIFICATIONS TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------- fixtures
  -- Written as postgres, which owns the tables and is not subject to RLS: the
  -- second tenant is what the guard is proven against, and there is no other way
  -- to get one inside a transaction.
  insert into public.pharmacies (name)
  values ('ZZTEST phase5 dispatch other pharmacy')
  returning id into v_other;

  insert into auth.users (id, email)
  values (v_colleague, 'zztest-phase5-colleague@example.com');
  update public.profiles set pharmacy_id = v_pharmacy where id = v_colleague;

  insert into auth.users (id, email)
  values (v_other_user, 'zztest-phase5-dispatch-other@example.com');
  update public.profiles set pharmacy_id = v_other where id = v_other_user;

  insert into public.customers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST dispatch customer')
  returning id into v_customer;

  -- A queued dispatch that belongs to somebody else, so the settle half can be
  -- shown to reach only the caller's own rows.
  insert into public.notification_logs (pharmacy_id, recipient_type, channel, status)
  values (v_other, 'other', 'email', 'queued')
  returning id into v_foreign;

  -- ------------------------------------------------------------------ as the user
  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- ------------------------------------------------------- 1. the pair, in one call
  v_result := public.queue_notification(
    jsonb_build_object(
      'channel', 'whatsapp',
      'destination', '+910000000000',
      'subject', 'ZZTEST subject',
      'body', 'ZZTEST hello from the queue',
      'recipient_type', 'customer',
      'recipient_id', v_customer,
      'notify_user_id', v_user,
      'type', 'probe',
      'title', 'ZZTEST title'
    )
  );

  v_log_id   := (v_result->>'log_id')::uuid;
  v_notif_id := (v_result->>'notification_id')::uuid;

  v_log := array_append(
    v_log,
    case when v_log_id is not null and v_notif_id is not null then 'PASS' else 'FAIL' end
      || ': 1. one call answers with both ids (log ' || coalesce(v_log_id::text, 'null')
      || ', notification ' || coalesce(v_notif_id::text, 'null') || ')'
  );

  select * into v_row from public.notification_logs where id = v_log_id;
  v_log := array_append(
    v_log,
    case when v_row.id is not null then 'PASS' else 'FAIL' end
      || ': 1. the dispatch record exists'
  );

  v_log := array_append(
    v_log,
    case
      when v_row.status = 'queued' and v_row.provider is null then 'PASS'
      else 'FAIL'
    end
      || ': 1. it starts queued with no provider: nothing has been sent yet (got '
      || coalesce(v_row.status::text, 'missing') || '/' || coalesce(v_row.provider, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when v_row.notification_id = v_notif_id then 'PASS' else 'FAIL' end
      || ': 1. the log points at the in-app row it claims'
  );

  v_log := array_append(
    v_log,
    case
      when v_row.pharmacy_id = v_pharmacy
        and v_row.channel = 'whatsapp'
        and v_row.recipient_type = 'customer'
        and v_row.recipient_id = v_customer
        and v_row.destination = '+910000000000'
        and v_row.subject = 'ZZTEST subject'
        and v_row.body = 'ZZTEST hello from the queue'
        and v_row.created_by = v_user
      then 'PASS' else 'FAIL'
    end
      || ': 1. the record carries the attempt: the caller''s tenant, the channel, the recipient, the destination, the subject and the body verbatim'
  );

  -- ------------------------------------------------------ 2. the in-app row
  select * into v_notif from public.notifications where id = v_notif_id;

  v_log := array_append(
    v_log,
    case
      when v_notif.user_id = v_user
        and v_notif.pharmacy_id = v_pharmacy
        and v_notif.type = 'probe'
        and v_notif.title = 'ZZTEST title'
        and v_notif.message = 'ZZTEST hello from the queue'
        and v_notif.channel = 'in_app'
        and v_notif.read_at is null
      then 'PASS' else 'FAIL'
    end
      || ': 2. the in-app row is addressed to the caller''s user, unread, on the in-app channel, with the caller''s own title'
  );

  v_log := array_append(
    v_log,
    case
      when v_notif.data->>'dispatch_channel' = 'whatsapp'
        and v_notif.data->>'recipient_type' = 'customer'
        and v_notif.data->>'recipient_id' = v_customer::text
      then 'PASS' else 'FAIL'
    end
      || ': 2. data carries the dispatch context, which is what the column is documented for ('
      || coalesce(v_notif.data::text, 'null') || ')'
  );

  -- A second call to show the two defaults, on a colleague rather than the caller,
  -- which is also the "a pharmacy may notify one of its own" half of the guard.
  -- The row it writes is addressed to the colleague, so the caller cannot read it
  -- back - RLS on `notifications` is user-addressed, not tenant-addressed - and the
  -- assertions about what is *in* it are made as postgres further down. That the
  -- caller cannot see it is asserted here.
  v_result := public.queue_notification(
    jsonb_build_object(
      'channel', 'email',
      'destination', 'zztest-phase5-colleague@example.com',
      'subject', 'ZZTEST subject two',
      'body', 'ZZTEST second body',
      'recipient_type', 'user',
      'notify_user_id', v_colleague
    )
  );
  v_notif_id := (v_result->>'notification_id')::uuid;

  select count(*) into v_n from public.notifications where id = v_notif_id;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 2. a colleague''s in-app row is not the caller''s to read (found ' || v_n || ')'
  );

  -- ------------------------------------------- 3. the option to write no in-app row
  v_result := public.queue_notification(
    jsonb_build_object(
      'channel', 'email',
      'destination', 'zztest-supplier@example.com',
      'body', 'ZZTEST a supplier order that is not also an inbox item',
      'recipient_type', 'other'
    )
  );

  v_log := array_append(
    v_log,
    case when jsonb_typeof(v_result->'notification_id') = 'null' then 'PASS' else 'FAIL' end
      || ': 3. a dispatch with no notify_user_id answers with a null notification_id ('
      || coalesce(v_result->>'notification_id', 'missing') || ')'
  );

  select count(*) into v_n
    from public.notifications
   where id = (v_result->>'notification_id')::uuid;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 3. and nothing lands in the in-app list (found ' || v_n || ')'
  );

  -- ---------------------------------------- 4. the tenant is the caller's, not the payload's
  v_result := public.queue_notification(
    jsonb_build_object(
      'channel', 'email',
      'destination', 'zztest-supplier@example.com',
      'body', 'ZZTEST a payload claiming another tenant',
      'recipient_type', 'other',
      'notify_user_id', v_user,
      'pharmacy_id', v_other
    )
  );

  select * into v_row from public.notification_logs
   where id = (v_result->>'log_id')::uuid;
  select * into v_notif from public.notifications
   where id = (v_result->>'notification_id')::uuid;

  v_log := array_append(
    v_log,
    case
      when v_row.pharmacy_id = v_pharmacy and v_notif.pharmacy_id = v_pharmacy
      then 'PASS' else 'FAIL'
    end
      || ': 4. a pharmacy_id in the payload is ignored: both rows carry the caller''s tenant'
  );

  -- What landed *nowhere* is read as postgres further down, because the
  -- notifications select policy is `user_id = auth.uid()` and would answer 0 for
  -- another tenant even if a row were there - an assertion RLS makes vacuous is
  -- not an assertion.

  select count(*) into v_logs_before
    from public.notification_logs where pharmacy_id = v_pharmacy;

  begin
    perform public.queue_notification(
      jsonb_build_object(
        'channel', 'email',
        'destination', 'zztest-other@example.com',
        'body', 'ZZTEST addressed to a user of another pharmacy',
        'recipient_type', 'user',
        'notify_user_id', v_other_user
      )
    );
    v_log := array_append(
      v_log, 'FAIL: 4. a user of another pharmacy was accepted as the recipient'
    );
  exception
    when check_violation then
      v_log := array_append(
        v_log,
        case when position('not in this pharmacy' in sqlerrm) > 0 then 'PASS' else 'FAIL' end
          || ': 4. a recipient in another pharmacy is refused with its own sentence ('
          || sqlerrm || ')'
      );
    when others then
      v_log := array_append(
        v_log, 'FAIL: 4. the cross-tenant recipient was refused for the wrong reason ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  -- ----------------------------------------------------------- 5. the guards, and their sentences
  begin
    perform public.queue_notification(
      jsonb_build_object(
        'channel', 'whatsapp_cloud',
        'body', 'ZZTEST',
        'recipient_type', 'other'
      )
    );
    v_log := array_append(v_log, 'FAIL: 5. an unknown channel was accepted');
  exception
    when check_violation then
      v_log := array_append(
        v_log,
        case when position('channel' in sqlerrm) > 0 then 'PASS' else 'FAIL' end
          || ': 5. an unknown channel is refused by name (23514: ' || sqlerrm || ')'
      );
    when others then
      v_log := array_append(
        v_log, 'FAIL: 5. the unknown channel was refused for the wrong reason ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  begin
    perform public.queue_notification(
      jsonb_build_object('channel', 'email', 'body', 'ZZTEST', 'recipient_type', '')
    );
    v_log := array_append(v_log, 'FAIL: 5. a missing recipient type was accepted');
  exception
    when check_violation then
      v_log := array_append(
        v_log,
        case when position('recipient' in sqlerrm) > 0 then 'PASS' else 'FAIL' end
          || ': 5. a missing recipient type is refused by name (23514: ' || sqlerrm || ')'
      );
    when others then
      v_log := array_append(
        v_log, 'FAIL: 5. the missing recipient type was refused for the wrong reason ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  begin
    perform public.queue_notification(
      jsonb_build_object(
        'channel', 'email',
        'body', E'   \n  ',
        'recipient_type', 'other'
      )
    );
    v_log := array_append(v_log, 'FAIL: 5. a whitespace-only body was accepted');
  exception
    when check_violation then
      v_log := array_append(
        v_log,
        case when position('body' in sqlerrm) > 0 then 'PASS' else 'FAIL' end
          || ': 5. a body that is nothing but whitespace is refused (23514: ' || sqlerrm || ')'
      );
    when others then
      v_log := array_append(
        v_log, 'FAIL: 5. the empty body was refused for the wrong reason ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  begin
    perform public.queue_notification(
      jsonb_build_object(
        'channel', 'email',
        'body', 'ZZTEST',
        'recipient_type', 'customer',
        'recipient_id', 'not-a-uuid'
      )
    );
    v_log := array_append(v_log, 'FAIL: 5. a recipient_id that is not a uuid was accepted');
  exception
    when check_violation then
      v_log := array_append(
        v_log,
        case when position('uuid' in sqlerrm) > 0 then 'PASS' else 'FAIL' end
          || ': 5. an id that is not a uuid is refused by name (23514: ' || sqlerrm || ')'
      );
    when others then
      v_log := array_append(
        v_log, 'FAIL: 5. the bad uuid was refused for the wrong reason ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  -- A refusal writes nothing: four refusals above, so the dispatch count must be
  -- exactly where it was before the first of them.
  select count(*) into v_logs_after
    from public.notification_logs where pharmacy_id = v_pharmacy;
  v_log := array_append(
    v_log,
    case when v_logs_after = v_logs_before then 'PASS' else 'FAIL' end
      || ': 5. a refused call records nothing at all (' || v_logs_before
      || ' -> ' || v_logs_after || ')'
  );

  -- The message verbatim: a body with an edge newline keeps it, because it is the
  -- text that gets delivered and not a value to tidy.
  v_result := public.queue_notification(
    jsonb_build_object(
      'channel', 'email',
      'body', E'line one\n\nline three\n',
      'recipient_type', 'other'
    )
  );
  select * into v_row from public.notification_logs
   where id = (v_result->>'log_id')::uuid;
  v_log := array_append(
    v_log,
    case when v_row.body = E'line one\n\nline three\n' then 'PASS' else 'FAIL' end
      || ': 5. the body is stored verbatim, edge whitespace and all ('
      || length(v_row.body) || ' chars)'
  );

  -- ------------------------------------------------------------ 6. the settle path
  update public.notification_logs
     set status = 'sent',
         provider = 'whatsapp',
         provider_message_id = 'ZZTEST-provider-1'
   where id = v_log_id;
  get diagnostics v_n = row_count;

  select * into v_row from public.notification_logs where id = v_log_id;
  v_log := array_append(
    v_log,
    case
      when v_n = 1 and v_row.status = 'sent'
        and v_row.provider = 'whatsapp'
        and v_row.provider_message_id = 'ZZTEST-provider-1'
      then 'PASS' else 'FAIL'
    end
      || ': 6. the caller settles their own queued row: queued -> sent with the provider''s answer (rows '
      || v_n || ')'
  );

  update public.notification_logs set status = 'sent' where id = v_foreign;
  get diagnostics v_n = row_count;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 6. another tenant''s queued dispatch is not theirs to settle (rows ' || v_n || ')'
  );

  select count(*) into v_n from public.notification_logs where id = v_foreign;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 6. and it is not even visible to them (found ' || v_n || ')'
  );

  execute 'reset role';

  -- ------------------------------------------------------- 7. the function's own contract
  select p.prosecdef, p.provolatile, p.proconfig
    into v_prosecdef, v_provolatile, v_proconfig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'queue_notification';

  v_log := array_append(
    v_log,
    case when v_prosecdef then 'PASS' else 'FAIL' end
      || ': 7. queue_notification is SECURITY DEFINER, so the pair commits or neither does'
  );

  v_log := array_append(
    v_log,
    case when v_provolatile = 'v' then 'PASS' else 'FAIL' end
      || ': 7. it is VOLATILE - it writes, and a stable claim would be a lie (got '
      || coalesce(v_provolatile::text, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when exists (
      select 1 from unnest(coalesce(v_proconfig, array[]::text[])) c
       where c like 'search_path=%' and c like '%public%'
    ) then 'PASS' else 'FAIL' end
      || ': 7. its search_path is pinned'
  );

  select pg_get_function_identity_arguments(p.oid) into v_identity
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'queue_notification';
  v_log := array_append(
    v_log,
    case when v_identity not like '%pharmacy%' then 'PASS' else 'FAIL' end
      || ': 7. the tenant is not an argument (' || coalesce(v_identity, 'missing') || ')'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('authenticated', 'public.queue_notification(jsonb)', 'EXECUTE')
      then 'PASS' else 'FAIL' end
      || ': 7. authenticated may queue a notification'
  );

  v_log := array_append(
    v_log,
    case when has_function_privilege('anon', 'public.queue_notification(jsonb)', 'EXECUTE')
      then 'FAIL' else 'PASS' end
      || ': 7. anon may not - there is no tenant behind it'
  );

  -- The other tenant's row, read as postgres: still queued, so the refused update
  -- really did nothing rather than merely reporting nothing.
  select count(*) into v_n
    from public.notification_logs
   where id = v_foreign and status = 'queued';
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 6. the foreign row is still queued afterwards (postgres can see it, the caller could not)'
  );

  -- Section 2's other half, read without RLS in the way: the defaults, and the
  -- keys `jsonb_strip_nulls` left out, inside the colleague's row.
  select * into v_notif from public.notifications where id = v_notif_id;
  v_log := array_append(
    v_log,
    case
      when v_notif.user_id = v_colleague
        and v_notif.type = 'message'
        and v_notif.title = 'ZZTEST subject two'
      then 'PASS' else 'FAIL'
    end
      || ': 2. type defaults to ''message'' and title falls back to the subject (got '
      || coalesce(v_notif.type, 'null') || '/'
      || coalesce(v_notif.title, 'null') || ')'
  );

  v_log := array_append(
    v_log,
    case when not (v_notif.data ? 'recipient_id') then 'PASS' else 'FAIL' end
      || ': 2. a key nobody supplied is absent rather than null in data ('
      || coalesce(v_notif.data::text, 'null') || ')'
  );

  -- Section 4's other half, read without RLS in the way: the pharmacy_id the
  -- payload named received nothing, in either table.
  select count(*) into v_n
    from public.notifications where pharmacy_id = v_other;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 4. nothing was written into the tenant the payload named (found ' || v_n || ' in-app rows)'
  );

  select count(*) into v_n
    from public.notification_logs
   where pharmacy_id = v_other and id <> v_foreign;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 4. and no dispatch record either (found ' || v_n || ' beyond the fixture)'
  );

  select count(*) into v_pass from unnest(v_log) l where l like 'PASS%';
  select count(*) into v_fail from unnest(v_log) l where l like 'FAIL%';
  v_log := array_append(
    v_log,
    'SUMMARY: ' || v_pass || ' PASS / ' || v_fail || ' FAIL of '
      || (array_length(v_log, 1) + 1) || ' assertions'
  );

  raise exception E'PHASE5 NOTIFICATIONS TEST\n%', array_to_string(v_log, chr(10));
end $$;
