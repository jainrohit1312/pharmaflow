# Chat 4 / Chunk D part 2 — Phase 5: the notifications themselves

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **tenth** chunk brief of Chat 4. Chat 4's overall brief is
> `context/chat3-opening-prompt.md`; the chunk accounts are `chat3a` (database),
> `chat3b` (OCR function), `chat3c` (Dart seam), `chat3d` (chunk B complete),
> `chat3e` (C1), `chat3f` (C2), `chat3g` (C3) and `chat3h` (**chunk D part 1 — read it
> first**). `PROGRESS.md`'s Chat Strategy table is the authority: **Chat 4 = Phase 5
> + Phase 6**.
>
> The handoff files after this chunk are `context/chat3i-summary.md` and
> `context/chat3j-opening-prompt.md`. New decisions continue at **D-049** (D-038 to
> D-048 are taken).

---

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — authority on what is done, the gates, the open items
2. `context/chat3h-summary.md` — **the important one**: what part 1 built, and what
   it deliberately left
3. `DECISIONS.md` — especially **D-029** (no FCM in Phase 5), **D-046** (alerts
   surface in-app, dispatch in Phase 6), **D-047** (an alert is a question, a
   notification is an event), **D-048** (**notifications are a top-level utility**:
   the route, the rail entry, the dashboard widget — settle nothing here, it is
   decided), **D-045** (measurements never mutate production), **D-004** (the
   caller's JWT), and **D-042** (one reader of a function's error envelope)
4. `HANDOFF_PROTOCOL.md` — the gate list, one `deno check` per entry point
5. `MASTER_PLAN.md` — Phase 5/6 scope
6. `context/chat3i-opening-prompt.md` — this file

Then output a 5-line understanding check (what part 2 covers, what parts A–D1 already
made work, environment, two load-bearing dependency pins, what you are about to
build).

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`, no `db reset`
- Migrations: `supabase db push --yes` (the `--yes` matters). `supabase db query
  --linked --file <path>` runs a migration file or a test against the live database.
- Platform priority: Web → Windows → Android → iOS
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0
- **DO NOT modify**: the `riverpod_lint` range, `custom_lint`, `freezed`, or the
  `sdk` pin (D-007)

### Gates — all must pass before any handoff

```
dart format lib test
dart run build_runner build --delete-conflicting-outputs
dart run custom_lint
flutter analyze
flutter test
deno test supabase/functions
deno check supabase/functions/ocr-purchase-bill/index.ts
deno check supabase/functions/match-product/index.ts
deno check supabase/functions/backfill-embeddings/index.ts
deno check supabase/functions/send-notification/index.ts    <- NEW, if the function lands
```

(plus `supabase db push --dry-run` before pushing, and a new `supabase/tests/*.sql`
if a migration lands — atomic, self-rolling-back, asserting its numbers and printing
them. `make test-functions` runs the Deno lines; a new function adds a line there and
in `HANDOFF_PROTOCOL.md`.)

**A live invocation needs a signed-in user** (N-7): ask the user for a session token
from the app, use it while it lasts, never print it, and never work around the guard.
**A third-party credential does not exist** (no WhatsApp token, no SendGrid key, no
recipient numbers — D-046), so plan what a live probe can prove (the envelope, the
`not_configured` refusal, the log row) and what it cannot (a delivered message). Say
which is which rather than implying more. **D-045 governs every measurement**: if a
measurement would modify a live function, constant or table, it happens on a temporary
tenant, not on production.

---

## WHAT PARTS A–D1 LEFT YOU (do not re-do)

- **The two tables already exist** (migrations 00008 and 00022) and are the whole
  storage story:
  - **`notifications`** — the in-app inbox: `user_id` (the recipient), `pharmacy_id`
    (a routing hint, nullable), `type`, `title`, `message`, `channel` (default
    `in_app`), `data jsonb`, **`read_at`** (the read state), timestamps. RLS is
    **user-addressed**: `notifications_select_own` / `_update_own` use
    `user_id = auth.uid()`, and insert allows `user_id = auth.uid()` or
    `pharmacy_id = get_my_pharmacy_id()` (so a pharmacy can notify a colleague).
  - **`notification_logs`** — the operator's delivery record: `pharmacy_id`,
    `notification_id` (links to the in-app row when there is one), `recipient_type`,
    `recipient_id`, `channel`, `destination`, `subject`, `body`, `status`
    (`queued`/`sent`/`failed`/`skipped`), `provider`, `provider_message_id`, `error`,
    `created_by`. RLS is tenant-scoped, and there is deliberately **no delete
    policy** — "a log a client can erase is not a log".
- **The enums are closed sets already**: `notification_channel` (`push`, `whatsapp`,
  `email`, `in_app`), `notification_status`, `notification_recipient_type`.
- **The alert sources are done**: `low_stock_products(p_limit)` and
  `expiring_batches(p_days, p_limit)` are live, `stable`, tenant-scoped, and asserted
  by `supabase/tests/phase5_alerts.sql` (25 PASS). The list screen reads them; do not
  re-derive an alert in Dart (D-047).
- **`_shared/` carries everything a function needs**: `FunctionError` + the status map
  in `failJson`, `okJson`/`preflight`, `userClient`/`requirePharmacyId`/`env`, and the
  hand-written base64. **92 Deno tests** are gates; every handler is exercised through
  stubs with no secret.
- **The Dart vocabulary is shared**: `lib/core/errors/function_error.dart` reads any
  function's error envelope (D-042), and a feature keeps its own fallback sentence and
  retry policy. The app's conventions that bite: `ref.mounted` after every await
  (D-034), a platform capability gets a seam and a fake (D-035), a controller test
  keeps its provider alive with `container.listen(...)`, and provider override lists
  are inferred (`Override` is not exported by `flutter_riverpod`).
- **`NotificationService` is still the `UnimplementedNotificationService` stub** whose
  three methods throw `UnimplementedError`, with a hand-written
  `notificationServiceProvider` (one of D-1's remaining manual providers). Part 2
  decides what those three methods mean in Phase 5 (D-029: `getFcmToken()` returns
  `null`) and gives them a seam with a fake.

---

## SCOPE — Chunk D part 2: the notifications themselves

### 1. `send-notification` (Edge Function)

- Deployed with `verify_jwt` on, acting as the caller (D-004).
- Contract shape (adjust if the implementation argues for it, and record why):

```
POST { "channel": "whatsapp" | "email",
       "to": "<phone or email>",           // or a device token, later
       "subject": "…" | null,              // email only
       "body": "…",
       "recipient_type": "customer" | "supplier" | "user" | "other",
       "recipient_id": "<uuid>" | null,
       "notify_user_id": "<uuid>" | null } // when it also belongs in an in-app list
→ 200 { "log_id", "notification_id" | null, "status": "sent"|"failed"|"skipped",
        "provider", "error" | null }
→ 4xx/5xx { "error": { "code", "message" } }
```

- **Every attempt is logged, always** — sent, refused, failed **and**
  not-configured. That log row is the deliverable's evidence and the operator's audit
  trail, and it is what makes "we told them" answerable.
- **A missing secret is `not_configured`, naming the secret**, and the log row still
  lands with `status = 'skipped'`. That is the shape the reader and the backfill
  already use one layer up.
- **The in-app row and its log row are one transaction.** They belong together (the
  log points at the notification when there is one), so either a `security definer`
  RPC writes both or the function writes them in an order whose failure mode is
  tolerable — decide, and say why. Note that the *provider call* cannot be inside any
  transaction: the honest sequence is **queue → call → settle**, with `queued` being
  the state that means "we started".
- Reuse `_shared/errors.ts`, `_shared/response.ts`, `_shared/client.ts`. No second
  envelope, no second error vocabulary.

### 2. The in-app list — **the placement is decided (D-048); do not re-open it**

- **`/notifications` is a top-level shell destination**, not nested under a domain
  module: `Routes.notifications = '/notifications'`, declared in `app_router.dart` as
  a shell child.
- **A twelfth entry in `_navDestinations`**, placed **after Reports and before
  Settings**, with `inBottomBar: false` — and the matching path in `Routes.shellPaths`.
  The two lists move together and `dashboard_shell_test.dart` already asserts they
  agree, so a half-added destination fails there.
- **The bottom bar stays at four**: `_bottomBarDestinations` filters on
  `inBottomBar`, so nothing leaks into it.
- **The dashboard widget** shows the unread count — *Notifications (N)* — tappable
  through to the route, and **always visible**: at zero it reads *No new
  notifications* rather than hiding. (A surface that vanishes when it has nothing to
  say is one the user forgets exists.)
- **A bell in `AppScaffold` is deferred to Phase 6** (a scaffold change touches twenty
  screens; the rail entry already carries the affordance).
- The screen itself: this user's `notifications` (user-addressed; RLS enforces
  `user_id = auth.uid()`), newest first, the unread state visible and markable read
  through `read_at`, plus the two **alert sections** rendered live from
  `low_stock_products()` and `expiring_batches()` (D-047 — never re-derive an alert in
  Dart). Anything read from a tenant table keeps the `pharmacy_id` scope (D-015).
- The empty and failure states must be distinguishable (T-5's lesson): *"still
  loading"*, *"nothing yet"* and *"could not load"* are three different sentences
  with three different affordances.

### 3. The Dart seams

- A repository over the two tables + the two RPCs, plain classes for the alert
  payloads (an RPC envelope — not Freezed; `ReportSummary`/`ProductMatches` are the
  precedent), and a controller with `ref.mounted` after every await (D-034).
- `NotificationService`: give the three methods their Phase 5 meaning, with a seam and
  a fake for anything platform-shaped (D-035). `getFcmToken()` stays `null`.
- Widget tests for the screen: an unread row, marking read, an empty list that says
  *which* empty it is (T-5's lesson: "still loading" and "nothing here" must not look
  the same), a failure with a retry, and the alerts rendering from a fake.

### 4. What this chunk is not

- Not push (D-029 — Firebase, the service worker the VAPID key and the registration
  call are Phase 6's).
- Not automatic dispatch of the alerts (D-046 — Phase 6, with the credentials and the
  recipient numbers).
- Not a scheduler. If something needs to run periodically, that is a decision to
  record, not a cron to invent.

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, read synchronously from
  `requirePharmacyIdProvider` (D-015). Server-side, from `get_my_pharmacy_id()`.
- **Functions act as the signed-in user** — the caller's JWT, never `service_role`
  (D-004).
- **Stock moves through triggers, never through the client** (D-011/D-013, D-023): an
  alert reads stock, and so does anything this chunk adds.
- **`check_violation` (23514) messages reach the user verbatim.**
- Freezed for table rows; **plain classes** for an RPC envelope, a payload, a result.
- A new column on a table is not visible through a view (D-021's trap) — if you add
  one, say so in the SQL test.
- A platform for this feature means **Web first** (D-005).
- Code under `supabase/functions/` stays language-core JavaScript (D-031).

## OPEN ITEMS THIS CHUNK SHOULD NOT MAKE WORSE

| ID | Issue | Why it matters here |
|---|---|---|
| N-1 | Push is not wired: `device_tokens` empty, `getFcmToken()` returns `null` | The list must work without it, and the log row must still be written |
| I-1 | The low-stock comparison still runs in Dart over a 500-row scan in `InventoryRepository` | The RPC exists now (D-047); switch the screen onto it, or leave the plan as it stands |
| N-7 | A live invocation needs a session from the app | Ask the user; never work around it |
| N-4 | No `functions logs` | Debug by deploy-and-probe (D-031) |
| N-9, N-8, N-5, T-3, T-4, T-5 | the floor's one-product measurement, the re-read's supplier reset, the alias NULL-supplier trap, and the three older UI items | All untouched by this chunk |
| D-027's residual | Whether to hide `products.embedding` behind column grants is unresolved | Nothing here touches that column |

---

## CONTEXT MANAGEMENT

1. **The chunk ends in a working, gated state.** Run every gate, including the new
   `deno check` line if a function lands.
2. **Hand off at ~60-70% context**, or earlier if quality degrades. This chunk
   naturally splits again — **the function first, then the list** — and splitting there
   is better than a rushed screen.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3i-summary.md` and `context/chat3j-opening-prompt.md`; add decisions
   at **D-048+**; leave the tree commit-ready.
4. **Never compress.** Do not stub the function, do not skip its Deno tests, do not
   skip a SQL test for a migration, do not ship a screen with no widget tests.
5. **Phase 5 ends when this chunk is done.** Then Phase 6: the Windows build fix
   (W-1), the README refresh (R-1), push registration (N-1), the SendGrid/WhatsApp
   credentials and the alert triggers (D-046), N-9's re-measurement with a real
   catalogue, N-5's index, and I-1's client change.

## BEGIN

Read the files in STEP 0, output the 5-line understanding check, then say how you
intend to build part 2 — the function's exact request/response contract, the order in
which the log row, the in-app row and the provider call happen and what each state
means, what the list screen shows in each of loading/empty/failed and where it lives
in the shell, what `NotificationService`'s three methods mean in Phase 5, and what you
will verify (including what a live probe can and cannot prove with no credential) —
plus anything you need from the user. **Wait for approval before writing the migration
or the function.**
