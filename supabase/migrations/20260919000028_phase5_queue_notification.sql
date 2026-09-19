-- Migration: 20260919000028_phase5_queue_notification | Purpose: the one
-- transaction that opens a notification - the delivery record, and the in-app row
-- it points at when the message also belongs in someone's inbox.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace function + guarded grants.
--
-- What this migration is
-- ----------------------
-- One function and its grant. No table, no column, no view, no trigger, and
-- nothing that moves stock.
--
--   queue_notification(p_payload jsonb) -> { log_id, notification_id }
--
-- Why one function rather than two inserts from the Edge Function
-- ---------------------------------------------------------------
-- `send-notification` (D-029) records **every** attempt in `notification_logs`,
-- and when the message also belongs in someone's in-app list it writes a
-- `notifications` row and points the log at it (`notification_logs.notification_id`).
-- The two belong together - a log row that says "we told them" with no in-app row
-- behind it is a different claim from one with a row - so they are **one
-- transaction**. That is D-024's rule (a payment and its ledger row) applied to the
-- pair that points at each other. Two PostgREST inserts from the function would be
-- two statements, and the tolerant ordering would leave a `queued` log row whose
-- notification silently never arrived on the second failure.
--
-- It is SECURITY DEFINER so the pair commits or neither does. That has a second
-- consequence the function has to pay for honestly: **definer skips RLS**, so the
-- guess the `notifications` insert policy states -
-- `user_id = auth.uid() or pharmacy_id = get_my_pharmacy_id()` (migration 00012) -
-- is restated below rather than inherited. The SQL test asserts the restatement
-- refuses a colleague from another pharmacy.
--
-- Why it does not settle anything
-- -------------------------------
-- The provider call cannot be inside a transaction - a transaction held open across
-- a network round trip to Meta or SendGrid is a lock held for as long as their
-- latency - so the honest sequence is **queue -> call -> settle**, and `queued` is
-- the state that means "we started". This function is the queue: it returns the two
-- ids, and the row it wrote stays `queued` until the function updates it with the
-- caller's own token. The log table's update policy is tenant-scoped, so the settle
-- needs no definer help and does not get one.
--
-- The tenant is never an argument (D-004/D-026). It comes from
-- get_my_pharmacy_id(), read from the caller's own profile row, and a
-- `pharmacy_id` in the payload is ignored - the SQL test sends one and asserts it
-- is not the one that lands.
--
-- Verified by supabase/tests/phase5_notifications.sql (atomic, self-rolling-back:
-- the pair and the link between them, the `queued` state, the payload in the in-app
-- row, the option to write no in-app row at all, the caller-scoped tenant, a
-- cross-tenant recipient refused, the guard sentences, the settle path under RLS,
-- and the function's own contract).

-- ---------------------------------------------------------------------------
-- 1. Opening a notification
--
--    `p_payload` is one object, for the reason `checkout_sale` and
--    `set_product_embeddings` take one: a queue step that grows a column should not
--    grow an argument list the caller has to keep in step. The keys are the
--    function's request, minus anything the caller could lie about:
--
--      channel         required, a `notification_channel` label
--      body            required, the message verbatim
--      recipient_type  required, a `notification_recipient_type` label
--      destination     optional, the phone number or address
--      subject         optional, the email subject
--      recipient_id    optional uuid - a customer's, a supplier's, a colleague's
--      notify_user_id  optional uuid - also put it in this user's in-app list
--      type            optional, defaults to 'message' (the column is NOT NULL)
--      title           optional, defaults to the subject
--
--    A refusal here is `check_violation` (23514) with a sentence, the way a schema
--    CHECK is refused elsewhere in this project: the app shows the sentence
--    verbatim, and the Edge Function maps the same code to `invalid_request`. These
--    guards are the second line of defence - the function validates first - but
--    this RPC is reachable directly through PostgREST by any signed-in user, so it
--    keeps its own.
-- ---------------------------------------------------------------------------
create or replace function public.queue_notification(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_pharmacy       uuid := public.get_my_pharmacy_id();
  v_channel        text;
  v_recipient      text;
  v_destination    text;
  v_subject        text;
  v_body           text;
  v_title          text;
  v_type           text;
  v_recipient_id   uuid;
  v_notify_user_id uuid;
  v_notification   uuid;
  v_log            uuid;
begin
  -- An account still onboarding has no inbox to write and no tenant to log
  -- against, so the pair cannot be written at all. The same sentence
  -- `requirePharmacyId` uses, because it is the same situation.
  if v_pharmacy is null then
    raise exception 'This account is not linked to a pharmacy yet.'
      using errcode = 'check_violation';
  end if;

  -- The closed sets are the enums themselves rather than a list copied here, so a
  -- new channel is one migration in one place and this stays in step for free.
  v_channel := nullif(btrim(coalesce(p_payload->>'channel', '')), '');
  if v_channel is null
     or v_channel not in (
       select label::text
         from unnest(enum_range(null::public.notification_channel)) as label
     ) then
    raise exception 'A notification needs a channel: push, whatsapp, email or in_app.'
      using errcode = 'check_violation';
  end if;

  v_recipient := nullif(btrim(coalesce(p_payload->>'recipient_type', '')), '');
  if v_recipient is null
     or v_recipient not in (
       select label::text
         from unnest(enum_range(null::public.notification_recipient_type)) as label
     ) then
    raise exception 'A notification needs a recipient: customer, supplier, user or other.'
      using errcode = 'check_violation';
  end if;

  -- Kept verbatim - it is the message that gets delivered - so only a body that is
  -- empty or nothing but whitespace is refused, and an edge newline survives. The
  -- test is "no non-whitespace character anywhere" rather than `btrim`, because
  -- `btrim(x)` removes spaces and would let a body of one newline through.
  v_body := nullif(coalesce(p_payload->>'body', ''), '');
  if v_body is null or v_body !~ '[^[:space:]]' then
    raise exception 'A notification needs a body.'
      using errcode = 'check_violation';
  end if;

  v_destination := nullif(coalesce(p_payload->>'destination', ''), '');
  v_subject     := nullif(coalesce(p_payload->>'subject', ''), '');
  v_type        := coalesce(nullif(coalesce(p_payload->>'type', ''), ''), 'message');
  v_title       := nullif(coalesce(p_payload->>'title', ''), '');
  -- An in-app row wants a headline, and an email's subject is the nearest thing a
  -- caller has to one; WhatsApp has neither, so the title stays null there.
  v_title := coalesce(v_title, v_subject);

  begin
    v_recipient_id   := nullif(btrim(coalesce(p_payload->>'recipient_id', '')), '')::uuid;
    v_notify_user_id := nullif(btrim(coalesce(p_payload->>'notify_user_id', '')), '')::uuid;
  exception
    when invalid_text_representation then
      raise exception 'A recipient_id or notify_user_id in this notification is not a uuid.'
        using errcode = 'check_violation';
  end;

  -- The insert policy restated, because definer skips it: a colleague in this
  -- pharmacy, or the caller themselves. Without this, a caller could open an
  -- inbox row addressed to any user id in the database.
  if v_notify_user_id is not null
     and v_notify_user_id <> auth.uid()
     and not exists (
       select 1
         from public.profiles p
        where p.id = v_notify_user_id
          and p.pharmacy_id = v_pharmacy
     ) then
    raise exception 'That user is not in this pharmacy, so the notification would not reach them.'
      using errcode = 'check_violation';
  end if;

  -- ------------------------------------------------------------- the in-app row
  -- Written first only because the log row wants to point at it. Its own `channel`
  -- is `in_app` whatever went out - the row *is* the in-app copy - and the dispatch
  -- channel rides in `data`, which is the column's documented purpose
  -- (deep-linking / channel rendering).
  if v_notify_user_id is not null then
    insert into public.notifications (
      user_id, pharmacy_id, type, title, message, channel, data
    )
    values (
      v_notify_user_id,
      v_pharmacy,
      v_type,
      v_title,
      v_body,
      'in_app',
      jsonb_strip_nulls(
        jsonb_build_object(
          'dispatch_channel', v_channel,
          'recipient_type', v_recipient,
          'recipient_id', v_recipient_id
        )
      )
    )
    returning id into v_notification;
  end if;

  -- ------------------------------------------------------- the delivery record
  -- `queued`, never `sent`: nothing has been sent yet, and the honest state at this
  -- point in the sequence is "we started". `provider` stays null for the same
  -- reason - nobody has been reached - and the settle fills it in when somebody is.
  -- `created_by` is the caller, so an operator reading the log can see who asked.
  insert into public.notification_logs (
    pharmacy_id, notification_id, recipient_type, recipient_id, channel,
    destination, subject, body, status, provider, created_by
  )
  values (
    v_pharmacy,
    v_notification,
    v_recipient::public.notification_recipient_type,
    v_recipient_id,
    v_channel::public.notification_channel,
    v_destination,
    v_subject,
    v_body,
    'queued',
    null,
    auth.uid()
  )
  returning id into v_log;

  return jsonb_build_object(
    'log_id', v_log,
    'notification_id', v_notification
  );
end;
$$;

comment on function public.queue_notification(jsonb) is
  'Opens one notification: a queued notification_logs row, plus the notifications row it points at when the message also belongs in a user''s in-app list - both in one transaction, so a log that says "we told them" always has the in-app row it claims. Returns {log_id, notification_id}; the row stays queued until the caller settles it with the provider''s answer. The tenant comes from get_my_pharmacy_id(), never from the payload, and the in-app guard restates the insert policy because a definer function is not subject to RLS (D-024, D-004, D-029).';

-- ---------------------------------------------------------------------------
-- 2. Grants
--    authenticated only; anon has no tenant identity, and a notification is
--    addressed to somebody. `revoke ... from anon, public` is not redundant with
--    the absence of a grant - Supabase grants EXECUTE to anon and authenticated
--    directly, so removing the PUBLIC grant leaves their own in place (D-017's
--    lesson, migration 00018).
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.queue_notification(jsonb) to authenticated';
  execute 'revoke execute on function public.queue_notification(jsonb) from anon, public';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
