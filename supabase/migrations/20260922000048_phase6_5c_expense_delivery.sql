-- Migration: 20260922000048_phase6_5c_expense_delivery | Purpose: the delivery half of the
-- expense notification - the address the email leg needs, and what "queued" now means
-- (Phase 6.5c chunk 6).
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: add-column-if-not-exists, create-or-replace functions, guarded grant, comments.
--
-- The position this chunk starts from (D-085, D-086)
-- ------------------------------------------------
-- Chunk 5a-c built the notification: a TRIGGER on `expenses` tells the owner instead of asking him,
-- because D-085 settled that recording an expense is free for every role. It queues the in-app row
-- into his own inbox, and a WhatsApp delivery-log row when his profile carries a number - and then
-- stops. **Nothing dispatches it**, and that is the half this chunk has to answer.
--
-- What was verified before designing anything, rather than assumed
-- -------------------------------------------------------------
--   1. `send-notification` is deployed and records every attempt (D-029/D-049) in the rail's own
--      shape - queue -> call -> settle - and it answers `skipped` naming the missing credential
--      until N-1 resolves. Its own doc says so: "There is no automatic dispatch of the Phase 5
--      alerts (D-046): this function is built and reachable, and nothing calls it on a schedule."
--   2. **There is no scheduler anywhere in this project.** A repository-wide search finds no
--      `pg_cron`, no `pg_net`, no `net.http_post`, no `cron.schedule`, no `[functions.*]` or cron
--      section in `supabase/config.toml`, and no code path that calls `send-notification` except a
--      human running the deployment probe in `docs/DEPLOYMENT.md`. The ONLY caller of
--      `queue_notification()` on a business write is the trigger below.
--
-- WHERE THE DISPATCHER LIVES: nowhere yet, and this migration says why
-- -------------------------------------------------------------------
-- The call cannot be inside the transaction that writes the row (a transaction held open across a
-- round trip to Meta is a lock held for their latency), so the honest dispatcher is OUTSIDE the
-- database. Each of the three candidates was costed, and each one pays with something this project
-- does not have:
--
--   * **A `pg_net` trigger fired from the queue row** needs a caller identity for the function it
--     posts to. `send-notification` authenticates the CALLER and builds its client from that
--     caller's own token (D-004), so a trigger - which has no user - could only reach it by holding
--     the `service_role` key in the database. That is a credential this project has deliberately
--     never used, and `pg_net` is not enabled here either. Cost: **a credential the project does
--     not have.**
--   * **A scheduled Edge Function** needs a schedule to run it, and there is none: no `pg_cron`,
--     no cron entry in `config.toml`, nothing on the hosted project. Building a dispatcher that
--     nothing runs would move the same lie one layer down. Cost: **a schedule nothing runs.**
--   * **The app calling it after a write** is a screen, and a session holding a token can bypass a
--     screen - the same reasoning the trigger exists for. Worse, it would not even settle this row:
--     `send-notification` opens its OWN log row through `queue_notification` before it calls the
--     provider, so a client that dispatched a queued row would leave two rows claiming one message.
--     Cost: **a screen a session can bypass, and a second row for one attempt.**
--
-- And behind all three stands the real blocker: with no `WHATSAPP_TOKEN` and no `SENDGRID_API_KEY`
-- (N-1), every attempt answers `skipped` and names the missing secret. A dispatcher built today
-- would fill the log with `skipped` rows and reach nobody.
--
-- **So the answer is: this waits on N-1's credentials, and this chunk builds the part that does not
-- wait.** The part that does not wait is the one thing that was actually missing on this side of the
-- seam: **an address for the email leg.** `profiles` carried a phone and no email, so an email
-- delivery-log row would have had nowhere to go - which is why chunk 5a-c queued no email row. With
-- the address on the profile (section 1) and copied on signup (section 2), the trigger queues the
-- email leg honestly (section 3), and the two legs sit in the log exactly as the WhatsApp one does:
-- `queued`, owed and not yet sent, waiting on the same credential as the WhatsApp leg.
--
-- What this migration does NOT do
-- ------------------------------
-- It does NOT gate anything, add a request path, or revoke anything: D-085 settled that an expense
-- is free for every role, and a notification is the control instead. It does not add a scheduler,
-- because there is nothing for one to reach yet. It does not touch `queue_notification()`, whose
-- queue/call/settle shape is the rail and is correct as built.

-- ---------------------------------------------------------------------------
-- 1. profiles.email - the address the email leg was missing
-- The column `phone` has been on this table since 00003 and `handle_new_user()` has copied it
-- from `auth.users` since 00010. The notification rail could reach the owner over WhatsApp for
-- exactly that reason and could not reach him by email for exactly the opposite one. This adds
-- the missing half of the same pair, backfills it from the account that already knows it, and
-- keeps it in step for every account created afterwards.
--
-- **Granted to `authenticated` on purpose, and the row set is not widened by it.** 00017 revoked
-- table-level UPDATE here and granted back the three columns a user owns about themselves
-- (full_name, phone, avatar_url). An address he is told at belongs in that list beside his phone,
-- so this grants `email` the same way. Which ROWS a caller may write is 00012's pair of policies
-- and neither is touched: `profiles_update_self` (his own row) and
-- `profiles_update_pharmacy_owner` (the owner's, over the profiles in his pharmacy). So this adds
-- a column to the set a caller may change on a row he could already reach - a colleague's phone
-- was already in that set, and his address now is too - and reaches no row he could not.
-- ---------------------------------------------------------------------------

alter table public.profiles add column if not exists email text;

comment on column public.profiles.email is
  'The address this user is reached at by email - the email leg of the notification rail reads it (20260922000048). Backfilled from auth.users.email and kept in step for new signups by handle_new_user(), and updatable by authenticated on the same rows profiles.phone already is (a user''s own, or an owner''s over his pharmacy), so it is the NOTIFICATION address rather than a copy of the login identity. NULL means the account was never given one, and no email delivery-log row is opened for it.';

-- Backfilled from the account that already carries it, so no existing user has to set anything.
-- Normalised only by trimming: Supabase already lowercases the auth email, and an address is the
-- provider's string to validate, not this schema's (the same reason queue_notification does not
-- validate a phone number).
update public.profiles p
   set email = nullif(btrim(u.email), '')
  from auth.users u
 where u.id = p.id
   and p.email is null;

-- The column grant, in the same idiom 00017 used for the three it re-granted.
do $$
begin
  execute 'grant update (email) on public.profiles to authenticated';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;

-- ---------------------------------------------------------------------------
-- 2. handle_new_user() - replaced: the new profile carries the address too
-- One clause changed. 00010's body is reproduced byte for byte and patched by its own anchor, so
-- the only difference is the fourth column and the value that fills it - the email is copied
-- exactly as the phone always has been.
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, email, role)
  values (
    new.id,
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    new.phone,
    nullif(btrim(new.email), ''),
    'viewer'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. notify_owner_of_expense() - replaced: the email leg, queued honestly
-- The trigger's own body travels again and gains one leg. The rule it already followed - "one log
-- row per channel this account can be addressed on, and none for a channel it cannot" - is now
-- applied to both channels he named, so the two legs read the same profile row in the same
-- transaction and cannot drift apart.
-- ---------------------------------------------------------------------------

create or replace function public.notify_owner_of_expense()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := coalesce(new.pharmacy_id, old.pharmacy_id);
  v_owner    public.profiles;
  v_actor    text;
  v_title    text;
  v_body     text;
begin
  -- The tenant of the row that moved, and only when it is the caller's own. This is not decoration:
  -- queue_notification() raises when its caller has no pharmacy, so a fixture written by a
  -- superuser (no auth.uid()) would fail the INSERT rather than skip the notification - and a
  -- notification that cannot say who recorded the expense is not the control he asked for.
  if v_pharmacy is null or v_pharmacy is distinct from public.get_my_pharmacy_id() then
    return null;
  end if;

  select * into v_owner
    from public.profiles p
   where p.pharmacy_id = v_pharmacy
     and p.role = 'owner'::public.app_role
     and p.is_active
   order by p.created_at, p.id
   limit 1;

  if not found then
    return null;
  end if;

  select nullif(btrim(coalesce(p.full_name, '')), '')
    into v_actor
    from public.profiles p
   where p.id = auth.uid();

  v_actor := coalesce(v_actor, 'A member of staff');

  if TG_OP = 'INSERT' then
    v_title := 'Expense recorded';
    v_body := v_actor || ' recorded an expense of '
      || to_char(coalesce(new.amount, 0), 'FM9999999990.00') || ' under "'
      || coalesce(new.category, '?') || '" on '
      || to_char(coalesce(new.expense_date, current_date), 'DD Mon YYYY') || '.';
  elsif TG_OP = 'UPDATE' then
    v_title := 'Expense changed';
    v_body := v_actor || ' changed an expense to '
      || to_char(coalesce(new.amount, 0), 'FM9999999990.00') || ' under "'
      || coalesce(new.category, '?') || '" on '
      || to_char(coalesce(new.expense_date, current_date), 'DD Mon YYYY') || '.';
  else
    v_title := 'Expense deleted';
    v_body := v_actor || ' deleted an expense of '
      || to_char(coalesce(old.amount, 0), 'FM9999999990.00') || ' under "'
      || coalesce(old.category, '?') || '" recorded on '
      || to_char(coalesce(old.expense_date, current_date), 'DD Mon YYYY') || '.';
  end if;

  -- The in-app row - the one he reads today - and the delivery log it points at, in ONE transaction
  -- through the rail Phase 5 built (D-024/D-029). `notify_user_id` is what puts it in HIS inbox; the
  -- recipient is him and not a party, because an expense has no counterparty.
  perform public.queue_notification(jsonb_build_object(
    'channel',        'in_app',
    'recipient_type', 'user',
    'recipient_id',   v_owner.id,
    'notify_user_id', v_owner.id,
    'type',           'expense',
    'title',          v_title,
    'body',           v_body
  ));

  -- One delivery-log row per channel this account can actually be REACHED on, and none for a
  -- channel it cannot: a row for a destination that does not exist would claim an attempt that
  -- could never happen. WhatsApp and email are the two channels he named (D-085), and each is one
  -- `queue_notification` call - the same seam the in-app row uses, so the three legs cannot drift
  -- apart. The row it opens is `queued`: the message is OWED, not sent. See
  -- `notification_status`'s own comment for what dispatches it and what that waits on.
  if nullif(btrim(coalesce(v_owner.phone, '')), '') is not null then
    perform public.queue_notification(jsonb_build_object(
      'channel',        'whatsapp',
      'recipient_type', 'user',
      'recipient_id',   v_owner.id,
      'destination',    v_owner.phone,
      'title',          v_title,
      'body',           v_body
    ));
  end if;

  -- The email leg reads an address off the SAME row, so the two legs are one query and one rule.
  -- The `subject` is the title because that is the only headline this message has, and email is the
  -- one channel that carries one.
  if nullif(btrim(coalesce(v_owner.email, '')), '') is not null then
    perform public.queue_notification(jsonb_build_object(
      'channel',        'email',
      'recipient_type', 'user',
      'recipient_id',   v_owner.id,
      'destination',    v_owner.email,
      'subject',        v_title,
      'body',           v_body
    ));
  end if;

  return null;
end;
$$;

comment on function public.notify_owner_of_expense() is
  'Tells the owner that an expense was recorded, changed or deleted, instead of asking his permission for it (D-085). Queues the in-app row into his own inbox, plus a delivery-log row for every channel his profile can be reached on - WhatsApp when it carries a number, email when it carries an address (chunk 6) - and none for a channel it cannot, because a log row with no destination would claim an attempt that could never happen. Every row it opens is queued: the dispatch half is send-notification''s and waits on N-1''s provider credentials, which is what notification_status''s own comment says. Fires on INSERT, UPDATE and DELETE - the three acts D-085 retired from the enum, and the three a session can still perform on this table. Internal trigger function, not executable by a session.';

drop trigger if exists notify_owner_of_expense on public.expenses;
create trigger notify_owner_of_expense
  after insert or update or delete on public.expenses
  for each row execute function public.notify_owner_of_expense();

-- ---------------------------------------------------------------------------
-- 4. What "queued" means now - the dispatcher decision, in the schema's own words
-- `notification_status` has carried four values since Phase 5 and has never had a comment. It is
-- the exact place a reader asks "what does queued mean, and who sends it?" - so the answer to
-- chunk 6's design question lives here, where the value is, rather than in a chat or a commit
-- message nobody re-opens.
-- ---------------------------------------------------------------------------

comment on type public.notification_status is
  'The state of one delivery attempt. QUEUED: the message is owed and not yet sent - the row is opened in the same transaction as the business write that produced it (queue_notification, migration 00028), and it stays queued until a dispatcher calls the provider. SENT: the provider accepted it. FAILED: the provider refused it, or could not be reached; its own words are in notification_logs.error. SKIPPED: nothing was attempted - the deliberate answer when a credential or a destination is missing, which is a decision rather than a failure (D-046). WHO DISPATCHES IT: nothing yet, and that is recorded rather than implied (D-088). The call cannot happen inside the transaction that opens the row, so the dispatcher is outside the database; the three candidates are a pg_net trigger (needs the service_role key, a credential this project does not use), a scheduled Edge Function (needs a schedule, and this project has no pg_cron, no pg_net and no cron entry anywhere), and the app calling it after a write (a screen a session can bypass, and it would open a SECOND log row for one message, because send-notification queues its own). send-notification is deployed and answers skipped naming the missing secret until WHATSAPP_TOKEN / SENDGRID_API_KEY exist (N-1). Until then a queued row means the message is owed, and no row is written for a channel the account cannot be addressed on.';

comment on column public.notification_logs.status is
  'queued until a provider answers; sent or failed once it has; skipped when the send was deliberately not attempted (no channel configured, recipient opted out), which is a decision rather than a failure. queued means the message is OWED, not sent: nothing dispatches it yet, because the dispatch waits on the provider credentials in N-1 (see the comment on the notification_status type, D-088).';

-- ---------------------------------------------------------------------------
-- 5. Grants
-- No new executable surface: the trigger function is fired by the table, not called by a session.
-- The one privilege this migration changes is the profile column in section 1, and it is granted
-- there beside the migration that revoked the table-level grant.
-- ---------------------------------------------------------------------------

do $$
begin
  -- Internal: fired by the trigger on public.expenses, never called by a session. Restated so a
  -- cluster that never had the Phase 5 revoke still has it.
  execute 'revoke execute on function public.notify_owner_of_expense() from anon, authenticated, public';
exception
  when undefined_object then
    -- Role or function missing in a bare (non-Supabase) cluster: nothing to revoke.
    null;
end $$;
