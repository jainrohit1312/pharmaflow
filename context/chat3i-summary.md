# Chat 4 / Chunk D (PART 2 of 2) — the notifications themselves (COMPLETE)

**Status:** **COMPLETE** — Chunk D is done: `send-notification` is deployed and
live-probed, the `/notifications` list and the dashboard card are built, the two alert
sources are rendered live, and `NotificationService` has its Phase 5 meaning. **Phase
5's last piece is Chunk E, the chatbot**, briefed in `context/chat3j-opening-prompt.md`.
**Date:** 2026-09-19

## What part 2 ships

**`supabase/migrations/20260919000028_phase5_queue_notification.sql`** (applied). One
function and its grant; no table, no column, no view, no trigger. The part-1 summary
guessed 00028 would most likely be unused — it is one RPC instead of two PostgREST
inserts:

- **`queue_notification(p_payload jsonb) → {log_id, notification_id}`** — `volatile
  security definer`. Opens **one attempt in one transaction**: the
  `notification_logs` row (`status='queued'`, `provider` null, `created_by` =
  `auth.uid()`) and, when `notify_user_id` is present, the `notifications` row it
  points at. That is **D-024's rule** (a payment and its ledger row) applied to the
  pair that points at each other.
- Because definer **skips RLS**, the `notifications` insert policy's own rule is
  restated by hand (`user_id = auth.uid() or pharmacy_id = get_my_pharmacy_id()`); the
  SQL test proves a colleague from another pharmacy is refused. The tenant comes from
  `get_my_pharmacy_id()` and a `pharmacy_id` in the payload is ignored (the test sends
  one and asserts it does not land).
- Refusals are `check_violation` (23514) with a sentence — a bad channel, a bad
  recipient type, a whitespace-only body, an id that is not a uuid — which the handler
  maps to `invalid_request` and the app shows verbatim.
- **The settle is deliberately not in it.** The provider call cannot be inside a
  transaction, so the sequence is **queue → call → settle** and `queued` means "we
  started". The settle is one tenant-scoped `update` with the caller's own token.

**`supabase/tests/phase5_notifications.sql`** — **32 PASS / 0 FAIL of 33
assertions**, atomic and self-rolling-back. Two assertions had to move to `postgres`
to be worth anything: RLS answers 0 for another user's `notifications` rows even when
they exist, so "nothing was written elsewhere" is not an assertion with RLS in the
way.

**`supabase/functions/send-notification/`** (`index`, `deps`, `handler`, `providers`,
`handler_test`, `providers_test`) — deployed, `verify_jwt` on, acting as the caller.
**37 of the 129 Deno tests are its own.** The two provider posters are separate
functions because the APIs disagree about where the id lives (WhatsApp names the
sender in the URL and returns the id in the body; SendGrid names the sender in the
body and returns the id in a **header**), and the token travels in an `Authorization`
header in both — never in a URL.

**The app side** — new `features/notifications/`:

- `NotificationsRepository` (the inbox newest-first, marking one read, the two alert
  RPCs), with a **shape check** on each alert answer: an answer that is not a list must
  not read as "nothing is low on stock", because that is the one wrong answer a
  pharmacy would act on.
- `NotificationsController` (mark-read optimistic and reversible, `ref.mounted` after
  the await), `unreadNotificationCount`, and `lowStockAlerts` / `expiringAlerts` as two
  providers so one failing section does not blank the other.
- `AppNotification` (Freezed) and `LowStockProduct` / `ExpiringBatch` (plain RPC
  envelopes). Not named `Notification`: that is Flutter's own widget class.
- `NotificationsScreen` — three sections, each with its own loading / empty /
  failed+retry sentences, alerts rendered live from the RPCs (never re-derived in
  Dart, D-047).
- `NotificationSummaryCard` — the dashboard widget (D-048), always visible, with
  **four** readings: checking, could not check, nothing new, `Notifications (N)`.
- The twelfth shell destination after Reports and before Settings, `inBottomBar:
  false`; `dashboard_shell_test.dart`, `widget_test.dart` and the shell's agreement
  test all moved with it.
- `NotificationService` → `UnavailableNotificationService` (D-050): `init()` and
  `showLocal()` complete, `getFcmToken()` answers `null`, and `showLocal()` prints one
  **debug** line rather than dropping a message silently. The provider is codegen now,
  closing one of D-1's five manual providers.

## The probe (one invocation, with a session from the app — N-7)

```
POST send-notification  {channel: whatsapp, to: +910000000000, recipient_type: user,
                         notify_user_id: <the owner>, type: probe, title: …}
  -> 200 {"log_id":"60ee8b0c-34a8-4c27-b4ca-aa7250a5785e",
          "notification_id":"7a909348-01f1-49fa-8e63-2681bd165a72",
          "status":"skipped","provider":null,
          "error":"This function is missing its WHATSAPP_TOKEN secret."}
```

Both rows landed and the link holds: the log row `status='skipped'`, `provider` and
`provider_message_id` null, `channel='whatsapp'`, `recipient_type='user'`,
`destination='+910000000000'`, `body` verbatim, `created_by` = the caller, pointing at
an **unread** `notifications` row in the caller's own inbox, same pharmacy,
`data = {dispatch_channel: whatsapp, recipient_type: user}` with no `recipient_id` key
(`jsonb_strip_nulls` doing what the SQL test asserted). Both tables held one row before
the probe and one after it.

The caller is the **only** profile in the database (`Rohit Jain`, role `owner`) and is
the token's holder, so the caller, the owner and the recipient are one user — which is
why the in-app row is visible in the app.

**What it cannot prove, and does not claim to:** that any WhatsApp message was
delivered. There is no Meta account, no SendGrid key and no recipient number (D-046).
The two rows are permanent on purpose — `notification_logs` has no delete policy — and
are marked as probes in the body and the title. **They are production data and should
not be deleted by hand.**

## A finding worth keeping

**Riverpod 3's build-retry is a loading state that carries the error.** A read that
threw and is being retried is exposed as `AsyncLoading(error: …, retrying)`, and
`AsyncValue.whenData`'s loading branch hands back a plain `AsyncLoading` — dropping the
error. The dashboard card would have said *Checking…* for ever instead of *Could not
check*, which is the one lie D-048 forbids. It is now mapped by hand (value → error →
loading) and **D-051** records it. The same retry makes a *read count* useless as
evidence: three assertions of the form `expect(reads, 2)` after tapping a retry were
written, failed, and were removed in favour of asserting the state.

Two smaller things worth knowing: `btrim(x)` trims **spaces only**, so the body guard is
`v_body !~ '[^[:space:]]'` (a body of one newline got through the first version and the
SQL test caught it); and `flutter analyze` is stricter than `dart run custom_lint` —
`sort_constructors_first`, `always_put_required_named_parameters_first`,
`avoid_redundant_argument_values` and `prefer_const_constructors` all fire only in the
analyze gate, which cost a full format → generate → analyze cycle.

## Files

```
supabase/migrations/20260919000028_phase5_queue_notification.sql   (new, applied)
supabase/tests/phase5_notifications.sql                            (new, 33 assertions)
supabase/functions/send-notification/index.ts                      (new, deployed)
supabase/functions/send-notification/deps.ts                       (new)
supabase/functions/send-notification/handler.ts                    (new)
supabase/functions/send-notification/providers.ts                  (new)
supabase/functions/send-notification/handler_test.ts               (new, 25 tests)
supabase/functions/send-notification/providers_test.ts             (new, 12 tests)
app/lib/data/models/app_notification.dart                          (new, Freezed)
app/lib/data/models/alert_payloads.dart                            (new, plain classes)
app/lib/features/notifications/data/notifications_repository.dart  (new)
app/lib/features/notifications/application/notifications_controller.dart (new)
app/lib/features/notifications/application/alert_providers.dart    (new)
app/lib/features/notifications/presentation/notifications_screen.dart (new)
app/lib/features/notifications/presentation/notification_summary_card.dart (new)
app/test/data/models/app_notification_test.dart                    (new)
app/test/data/models/alert_payloads_test.dart                      (new)
app/test/features/notifications/application/notifications_controller_test.dart (new)
app/test/features/notifications/presentation/notifications_screen_test.dart (new)
app/test/features/notifications/presentation/notification_summary_card_test.dart (new)
app/test/services/notification_service_test.dart                   (new)
app/test/support/fake_notifications_repository.dart                (new)
app/test/support/notifications_test_app.dart                       (new)
context/chat3j-opening-prompt.md                                   (Chunk E's brief)
```

**Modified:** `Makefile` (the fourth `deno check`), `HANDOFF_PROTOCOL.md` (the same
line in the gate block), `app/lib/core/router/routes.dart` (`Routes.notifications` +
`shellPaths`), `app/lib/core/router/app_router.dart` (the shell child),
`app/lib/features/dashboard/presentation/dashboard_shell.dart` (the twelfth
destination), `app/lib/features/dashboard/presentation/dashboard_home.dart` (the card),
`app/lib/services/notification_service.dart` (rewritten: D-050),
`app/test/features/dashboard/dashboard_shell_test.dart`, `app/test/widget_test.dart`
(11 → 12 destinations), `PROGRESS.md`, `DECISIONS.md` (**D-049**, **D-050**, **D-051**).

## Verification evidence

```
supabase db push --dry-run   -> Would push: 20260919000028_… ; then "Remote database is up to date"
supabase db push --yes       -> Applying migration …00028…, Finished
supabase db query --file supabase/tests/phase5_notifications.sql
                             -> SUMMARY: 32 PASS / 0 FAIL of 33 assertions
deno test supabase/functions -> ok | 129 passed | 0 failed
deno check ×4 (ocr, match, backfill, send-notification) -> clean
dart format lib test         -> 404 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> no errors
dart run custom_lint         -> No issues found!
flutter analyze              -> No issues found!
flutter test                 -> +544: All tests passed!
```

Migration count: **28/28 local and remote.** Flutter tests: **493 → 544**. Deno tests:
**92 → 129**.

## Open risks / blockers

- **Nothing was made worse, and nothing new was opened.** N-1 (push) gained the
  app-side meaning D-050 settled but is still open; N-2, N-5, N-7, N-9, T-3, T-4, T-5
  and D-027's residual are untouched; I-1's server half was already done in part 1 and
  the inventory screen still decides low stock in Dart.
- **Two permanent production rows** from the probe (one dispatch, one in-app) — by
  design, since `notification_logs` has no delete policy. The in-app one is visible in
  the owner's inbox; nothing dispatches it anywhere (D-046).
- **N-4** applies to this function like the others: no `functions logs`, so debugging
  is a deploy-and-probe cycle.
- The session token used for the probe is the owner's and **was rotated by the user**
  (sign-out) after the probe.

## What's next

**`context/chat3j-opening-prompt.md`** — Chunk E, the chatbot (`chat-sql-agent`), the
last Phase 5 function. Then Phase 6.
