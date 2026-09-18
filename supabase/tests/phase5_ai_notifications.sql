-- Phase 5 AI substrate - functional test for migration
-- 20260919000022_phase5_ai_notifications.
--
-- Run:
--   supabase db query --linked --file supabase/tests/phase5_ai_notifications.sql
--
-- HOW TO READ THE RESULT
--   Every line is "PASS: ..." or "FAIL: ...". A non-zero exit code is expected and
--   means the script ran to completion. It ends by raising, so the whole DO block
--   (one statement, one transaction) rolls back: no ZZTEST product, batch, device
--   token, dispatch row or stored object survives.
--
-- WHY IT IMPERSONATES
--   Row level security is about the *caller's* identity, so the assertions that
--   matter set the JWT claims `auth.uid()` reads and switch to `authenticated` -
--   the way profile_privileges.sql and phase4_report_summary.sql do. The fixtures
--   are written as `postgres`, which owns the tables and is not subject to RLS:
--   the test has to be able to create the second tenant it is proving isolation
--   against, and there is no other way to get one inside a transaction.
--
-- WHAT IT PROVES
--   1.  The vector extension, the column's type and dimension, and the index the
--       matcher will search - including that a wrong-dimension vector is refused
--       by the type rather than by a convention.
--   2.  The two inventory views still resolve and correctly do NOT carry the new
--       column (a view's `b.*` is expanded when it is created - D-021's trap).
--   3.  The three new closed sets hold exactly the labels the app will send.
--   4.  device_tokens: the caller's own token round-trips and the same token
--       cannot be registered twice; neither another tenant's row nor another
--       user's row in the same pharmacy is writable or visible.
--   5.  notification_logs: a dispatch round-trips with its default status, an
--       unknown label is refused, a foreign tenant's row is invisible, the
--       notification link is a real foreign key, and a client cannot delete a
--       delivery record.
--   6.  The bucket is private with its size and mime limits, its four policies
--       exist, and an object is readable and writable only under the caller's own
--       pharmacy folder.

do $$
declare
  v_log        text[] := array[]::text[];
  v_pharmacy   uuid;
  v_user       uuid;
  v_other      uuid;
  v_second     uuid := gen_random_uuid();
  v_product    uuid;
  v_batch      uuid;
  v_supplier   uuid;
  v_notif      uuid;
  v_typmod     int;
  v_deleted    int;
  v_schema     text;
  v_typename   text;
  v_indexdef   text;
  v_indexam    text;
  v_labels     text[];
  v_public     boolean;
  v_limit      bigint;
  v_mimes      text[];
  v_status     text;
  v_n          int;
begin
  select id into v_pharmacy from public.pharmacies order by created_at limit 1;
  if v_pharmacy is null then
    raise exception 'PHASE5 TEST ABORTED: no pharmacy row exists to test against';
  end if;

  select id into v_user
    from public.profiles
   where pharmacy_id = v_pharmacy
   order by created_at
   limit 1;
  if v_user is null then
    raise exception 'PHASE5 TEST ABORTED: no profile linked to the test pharmacy';
  end if;

  -- ------------------------------------------------------------------ fixtures
  -- Written as postgres. The second tenant is what RLS is proven against, and the
  -- second user (in *this* tenant) is what the device-token user scope needs.
  insert into public.pharmacies (name)
  values ('ZZTEST phase5 other pharmacy')
  returning id into v_other;

  insert into auth.users (id, email)
  values (v_second, 'zztest-phase5-second@example.com');
  update public.profiles set pharmacy_id = v_pharmacy where id = v_second;

  insert into public.products (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST phase5 product')
  returning id into v_product;

  insert into public.product_batches (
    pharmacy_id, product_id, batch_no, expiry_date, qty, purchase_rate, mrp
  ) values (
    v_pharmacy, v_product, 'ZZTEST-PHASE5-B1', current_date + 200, 5, 100, 200
  ) returning id into v_batch;

  insert into public.suppliers (pharmacy_id, name)
  values (v_pharmacy, 'ZZTEST phase5 supplier')
  returning id into v_supplier;

  -- One row that belongs to the other tenant, and one that belongs to another
  -- user of this tenant. Both carry a token of their own so a count scoped to a
  -- token is unambiguous.
  insert into public.device_tokens (pharmacy_id, user_id, platform, token)
  values (v_other, v_user, 'android', 'ZZTEST-foreign-tenant-token');

  insert into public.device_tokens (pharmacy_id, user_id, platform, token)
  values (v_pharmacy, v_second, 'web', 'ZZTEST-other-user-token');

  insert into public.notification_logs (
    pharmacy_id, recipient_type, channel, destination, status
  ) values (
    v_other, 'other', 'email', 'zztest@example.com', 'sent'
  );

  -- ------------------------------------------------- 1. the vector substrate
  select count(*) into v_n
    from pg_extension
   where extname = 'vector'
     and extnamespace = 'extensions'::regnamespace;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 1. the vector extension is installed in the extensions schema (found '
      || v_n || ')'
  );

  select a.atttypmod, n.nspname, t.typname
    into v_typmod, v_schema, v_typename
    from pg_attribute a
    join pg_type t on t.oid = a.atttypid
    join pg_namespace n on n.oid = t.typnamespace
   where a.attrelid = 'public.products'::regclass
     and a.attname = 'embedding'
     and not a.attisdropped;

  v_log := array_append(
    v_log,
    case
      when v_schema = 'extensions' and v_typename = 'vector' and v_typmod = 768
        then 'PASS'
      else 'FAIL'
    end
      || ': 1. products.embedding is extensions.vector(768) (got '
      || coalesce(v_schema, 'missing') || '.' || coalesce(v_typename, 'missing')
      || '(' || coalesce(v_typmod::text, 'null') || '))'
  );

  -- The dimension is enforced by the type, not by a convention: a 769-vector must
  -- be refused. This is the assertion that would catch a re-embed at the wrong
  -- width, which the column would otherwise store happily.
  begin
    update public.products
       set embedding = array_fill(0.1::real, array[768])::extensions.vector
     where id = v_product;
    v_log := array_append(
      v_log, 'PASS: 1. a 768-dimension vector is accepted by the column'
    );
  exception
    when others then
      v_log := array_append(
        v_log, 'FAIL: 1. a 768-dimension vector was refused (' || sqlerrm || ')'
      );
  end;

  begin
    update public.products
       set embedding = array_fill(0.1::real, array[769])::extensions.vector
     where id = v_product;
    v_log := array_append(
      v_log, 'FAIL: 1. a 769-dimension vector was accepted into a vector(768) column'
    );
  exception
    when others then
      v_log := array_append(
        v_log, 'PASS: 1. a 769-dimension vector is refused (' || sqlstate || ')'
      );
  end;

  select am.amname, pg_get_indexdef(i.indexrelid)
    into v_indexam, v_indexdef
    from pg_index i
    join pg_class c on c.oid = i.indexrelid
    join pg_am am on am.oid = c.relam
   where c.relname = 'products_embedding_idx';

  v_log := array_append(
    v_log,
    case
      when v_indexam = 'hnsw'
        and position('vector_cosine_ops' in v_indexdef) > 0
        and position('IS NOT NULL' in v_indexdef) > 0
        then 'PASS'
      else 'FAIL'
    end
      || ': 1. products_embedding_idx is hnsw/cosine and partial on not-null ('
      || coalesce(v_indexdef, 'index missing') || ')'
  );

  -- ------------------------------------------------------- 2. the views hold
  -- A view's `b.*` is expanded when the view is created, so a column added to the
  -- table afterwards is invisible through it (D-021). Here that is the correct
  -- outcome - but it must be *asserted*, not assumed, because a matcher that read
  -- the vector through product_stock would silently find nothing.
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public'
     and table_name = 'product_stock'
     and column_name = 'embedding';
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 2. product_stock does not carry embedding (found ' || v_n || ' column)'
  );

  perform set_config('request.jwt.claims', json_build_object('sub', v_user::text)::text, true);
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  select count(*) into v_n
    from public.product_stock
   where product_id = v_product and total_qty = 5;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 2. product_stock still resolves for the caller and reports the batch ('
      || v_n || ')'
  );

  select count(*) into v_n from public.products where id = v_product;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 2. products is still readable by the caller after the new column ('
      || v_n || ')'
  );

  -- ------------------------------------------------- 4. device_tokens, as the user
  insert into public.device_tokens (pharmacy_id, user_id, platform, token)
  values (v_pharmacy, v_user, 'web', 'ZZTEST-own-token');
  get diagnostics v_n = row_count;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 4. a user registers their own device token (rows ' || v_n || ')'
  );

  begin
    insert into public.device_tokens (pharmacy_id, user_id, platform, token)
    values (v_pharmacy, v_user, 'web', 'ZZTEST-own-token');
    v_log := array_append(
      v_log, 'FAIL: 4. the same token was registered twice (expected a unique violation)'
    );
  exception
    when unique_violation then
      v_log := array_append(
        v_log, 'PASS: 4. registering the same token twice is refused (23505)'
      );
    when others then
      v_log := array_append(
        v_log, 'FAIL: 4. the duplicate token was refused for the wrong reason ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  begin
    insert into public.device_tokens (pharmacy_id, user_id, platform, token)
    values (v_other, v_user, 'web', 'ZZTEST-cross-tenant-token');
    v_log := array_append(
      v_log, 'FAIL: 4. a token could be registered against another tenant'
    );
  exception
    when insufficient_privilege then
      v_log := array_append(
        v_log, 'PASS: 4. a token claimed for another tenant is refused (42501)'
      );
    when others then
      v_log := array_append(
        v_log, 'FAIL: 4. the cross-tenant token was refused for the wrong reason ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  begin
    insert into public.device_tokens (pharmacy_id, user_id, platform, token)
    values (v_pharmacy, v_second, 'web', 'ZZTEST-cross-user-token');
    v_log := array_append(
      v_log, 'FAIL: 4. a token could be registered on behalf of another user'
    );
  exception
    when insufficient_privilege then
      v_log := array_append(
        v_log, 'PASS: 4. a token claimed for another user is refused (42501)'
      );
    when others then
      v_log := array_append(
        v_log, 'FAIL: 4. the cross-user token was refused for the wrong reason ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  -- The caller's own rows: exactly the one just registered. The foreign-tenant
  -- row carries this user's id, so a count of 2 would mean the tenant predicate
  -- is not filtering.
  select count(*) into v_n from public.device_tokens where user_id = v_user;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 4. the caller sees only their own token, not the other tenant''s ('
      || v_n || ' rows)'
  );

  select count(*) into v_n from public.device_tokens where user_id = v_second;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 4. another user''s token in the same pharmacy is invisible (' || v_n
      || ' rows)'
  );

  update public.device_tokens
     set last_seen_at = now() + interval '1 minute'
   where token = 'ZZTEST-own-token';
  get diagnostics v_n = row_count;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 4. a user refreshes their own token''s timestamp (rows ' || v_n || ')'
  );

  delete from public.device_tokens where token = 'ZZTEST-own-token';
  get diagnostics v_n = row_count;
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 4. a user can unregister their own device (rows ' || v_n || ')'
  );

  -- ------------------------------------------------ 5. notification_logs, as the user
  insert into public.notifications (user_id, pharmacy_id, type, message)
  values (v_user, v_pharmacy, 'zztest', 'ZZTEST phase5 notification')
  returning id into v_notif;

  insert into public.notification_logs (
    pharmacy_id, notification_id, recipient_type, recipient_id,
    channel, destination, subject
  ) values (
    v_pharmacy, v_notif, 'supplier', v_supplier,
    'whatsapp', '+910000000000', 'ZZTEST purchase order'
  );

  select status::text into v_status
    from public.notification_logs
   where pharmacy_id = v_pharmacy and notification_id = v_notif;
  v_log := array_append(
    v_log,
    case when v_status = 'queued' then 'PASS' else 'FAIL' end
      || ': 5. a dispatch starts queued and round-trips for the caller (got '
      || coalesce(v_status, 'nothing') || ')'
  );

  begin
    insert into public.notification_logs (
      pharmacy_id, recipient_type, channel, status
    ) values (
      v_pharmacy, 'supplier', 'email', 'delivered'
    );
    v_log := array_append(
      v_log, 'FAIL: 5. an unknown status label was accepted'
    );
  exception
    when invalid_text_representation then
      v_log := array_append(
        v_log, 'PASS: 5. an unknown status label is refused (22P02)'
      );
    when others then
      v_log := array_append(
        v_log, 'FAIL: 5. the unknown status was refused for the wrong reason ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  begin
    insert into public.notification_logs (pharmacy_id, recipient_type, channel)
    values (v_other, 'other', 'email');
    v_log := array_append(
      v_log, 'FAIL: 5. a dispatch could be logged against another tenant'
    );
  exception
    when insufficient_privilege then
      v_log := array_append(
        v_log, 'PASS: 5. a dispatch for another tenant is refused (42501)'
      );
    when others then
      v_log := array_append(
        v_log, 'FAIL: 5. the cross-tenant dispatch was refused for the wrong reason ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  begin
    insert into public.notification_logs (
      pharmacy_id, notification_id, recipient_type, channel
    ) values (
      v_pharmacy, gen_random_uuid(), 'user', 'in_app'
    );
    v_log := array_append(
      v_log, 'FAIL: 5. a dispatch linked to a non-existent notification was accepted'
    );
  exception
    when foreign_key_violation then
      v_log := array_append(
        v_log, 'PASS: 5. notification_id is a real foreign key (23503)'
      );
    when others then
      v_log := array_append(
        v_log, 'FAIL: 5. the dangling notification_id was refused for the wrong reason ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  -- No delete policy: RLS makes the row invisible to DELETE, so the statement is
  -- silently a no-op rather than an error - which is exactly why the assertion is
  -- "still there afterwards" and not "raised".
  delete from public.notification_logs
   where pharmacy_id = v_pharmacy and notification_id = v_notif;
  get diagnostics v_deleted = row_count;

  select count(*) into v_n
    from public.notification_logs
   where pharmacy_id = v_pharmacy and notification_id = v_notif;
  v_log := array_append(
    v_log,
    case when v_deleted = 0 and v_n = 1 then 'PASS' else 'FAIL' end
      || ': 5. a delivery record cannot be deleted by a client (deleted ' || v_deleted
      || ', still ' || v_n || ' row)'
  );

  select count(*) into v_n
    from public.notification_logs
   where pharmacy_id = v_other;
  v_log := array_append(
    v_log,
    case when v_n = 0 then 'PASS' else 'FAIL' end
      || ': 5. another tenant''s dispatch history is invisible (' || v_n || ' rows)'
  );

  -- ----------------------------------------------------------- 6. the bucket
  -- Still authenticated: an object under the caller's own pharmacy folder is
  -- allowed, and one under a foreign folder is not.
  begin
    insert into storage.objects (bucket_id, name)
    values ('purchase-bills', v_pharmacy::text || '/2026/zztest-bill.jpg');
    v_log := array_append(
      v_log, 'PASS: 6. an object under the caller''s own pharmacy folder is accepted'
    );
  exception
    when others then
      v_log := array_append(
        v_log, 'FAIL: 6. an object under the caller''s own folder was refused ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  select count(*) into v_n
    from storage.objects
   where bucket_id = 'purchase-bills'
     and name = v_pharmacy::text || '/2026/zztest-bill.jpg';
  v_log := array_append(
    v_log,
    case when v_n = 1 then 'PASS' else 'FAIL' end
      || ': 6. the caller can read back their own uploaded bill (' || v_n || ' rows)'
  );

  begin
    insert into storage.objects (bucket_id, name)
    values ('purchase-bills', v_other::text || '/2026/zztest-bill.jpg');
    v_log := array_append(
      v_log, 'FAIL: 6. an object was written into another tenant''s folder'
    );
  exception
    when insufficient_privilege then
      v_log := array_append(
        v_log, 'PASS: 6. writing into another tenant''s folder is refused (42501)'
      );
    when others then
      v_log := array_append(
        v_log, 'FAIL: 6. the foreign-folder write was refused for the wrong reason ('
          || sqlstate || ' ' || sqlerrm || ')'
      );
  end;

  execute 'reset role';

  -- ------------------------------------------------- 3. the closed sets, and the bucket's own shape
  select array_agg(e.enumlabel order by e.enumsortorder) into v_labels
    from pg_enum e
    join pg_type t on t.oid = e.enumtypid
   where t.typname = 'device_platform';
  v_log := array_append(
    v_log,
    case
      when v_labels = array['web', 'android', 'ios', 'windows', 'macos', 'linux']
        then 'PASS'
      else 'FAIL'
    end
      || ': 3. device_platform labels (got ' || coalesce(v_labels::text, 'none') || ')'
  );

  select array_agg(e.enumlabel order by e.enumsortorder) into v_labels
    from pg_enum e
    join pg_type t on t.oid = e.enumtypid
   where t.typname = 'notification_status';
  v_log := array_append(
    v_log,
    case
      when v_labels = array['queued', 'sent', 'failed', 'skipped'] then 'PASS'
      else 'FAIL'
    end
      || ': 3. notification_status labels (got ' || coalesce(v_labels::text, 'none') || ')'
  );

  select array_agg(e.enumlabel order by e.enumsortorder) into v_labels
    from pg_enum e
    join pg_type t on t.oid = e.enumtypid
   where t.typname = 'notification_recipient_type';
  v_log := array_append(
    v_log,
    case
      when v_labels = array['customer', 'supplier', 'user', 'other'] then 'PASS'
      else 'FAIL'
    end
      || ': 3. notification_recipient_type labels (got '
      || coalesce(v_labels::text, 'none') || ')'
  );

  select public, file_size_limit, allowed_mime_types
    into v_public, v_limit, v_mimes
    from storage.buckets
   where id = 'purchase-bills';
  v_log := array_append(
    v_log,
    case
      when v_public is false
        and v_limit = 10485760
        and v_mimes = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
        then 'PASS'
      else 'FAIL'
    end
      || ': 6. the bucket is private, capped at 10 MB and mime-restricted (got public='
      || coalesce(v_public::text, 'missing') || ', limit=' || coalesce(v_limit::text, 'null')
      || ', mimes=' || coalesce(v_mimes::text, 'null') || ')'
  );

  select array_agg(p.cmd order by p.cmd) into v_labels
    from pg_policies p
   where p.schemaname = 'storage'
     and p.tablename = 'objects'
     and p.policyname like 'purchase_bills%';
  v_log := array_append(
    v_log,
    case
      when v_labels = array['DELETE', 'INSERT', 'SELECT', 'UPDATE'] then 'PASS'
      else 'FAIL'
    end
      || ': 6. the four storage policies exist (got '
      || coalesce(v_labels::text, 'none') || ')'
  );

  raise exception E'PHASE5 AI NOTIFICATIONS TEST\n%', array_to_string(v_log, chr(10));
end $$;
