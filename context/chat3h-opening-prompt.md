# Chat 4 / Chunk D — Phase 5: the notifications

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **ninth** chunk brief of Chat 4. Chat 4's overall brief is
> `context/chat3-opening-prompt.md`; the chunk accounts are `chat3a-summary.md` (the
> database), `chat3b-summary.md` (the OCR Edge Function), `chat3c-summary.md` (the
> Dart seam), `chat3d-summary.md` (chunk B complete), `chat3e-summary.md` (C1), and
> `chat3f-summary.md` / `chat3g-summary.md` (**C2 and C3 — read `chat3g` first**).
> `PROGRESS.md`'s Chat Strategy table is the authority: **Chat 4 = Phase 5 +
> Phase 6**.
>
> The handoff files after this chunk are `context/chat3h-summary.md` and
> `context/chat3i-opening-prompt.md`. New decisions continue at **D-045** (D-038 to
> D-044 are taken).

---

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — authority on what is done, the gates, the open items
2. `context/chat3g-summary.md` — **the important one**: C3's contracts and the live run
3. `DECISIONS.md` — especially **D-029** (push is Phase 6's; Phase 5 dispatches over
   WhatsApp/Email and stores tokens), **D-030** (a model name is verified live),
   **D-031** (no recent JS built-ins; debug by deploy-and-probe), **D-004** (the
   caller's JWT, never `service_role`), **D-013/D-023** (stock moves through triggers),
   and **D-043/D-044** for the shape of a C-chunk's work
4. `HANDOFF_PROTOCOL.md` — the gate list, one `deno check` per entry point
5. `MASTER_PLAN.md` — Phase 5's remaining scope
6. `context/chat3h-opening-prompt.md` — this file

Then output a 5-line understanding check (what Chunk D covers, what A–C already made
work, environment, two load-bearing dependency pins, what you are about to build).

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`, no `db reset`
- Migrations: `supabase db push --yes` (the `--yes` matters: without it the command
  waits on an interactive prompt and looks like a hang). `supabase db query --linked
  --file <path>` runs a migration file or a test against the live database.
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
deno check supabase/functions/send-notification/index.ts        <- NEW if the function lands
```

(plus `supabase db push --dry-run` before pushing, and a new `supabase/tests/*.sql`
if a migration lands — atomic, self-rolling-back, asserting its numbers and printing
them. `make test-functions` runs the Deno lines; a new function adds a line there and
in `HANDOFF_PROTOCOL.md`.)

**Edge Functions without Docker**: develop by deploying and invoking the deployed
function (B1's practice, D-031). This CLI has no `functions logs` (N-4), so a
temporary `detail` on an internal error, one deploy, one invocation, then removed, is
the established way to see inside. **A live invocation needs a signed-in user** (N-7):
ask the user for a session token from the app, use it while it lasts, and never print
it.

**A third-party credential is not available**: no WhatsApp Cloud API token, no
SendGrid key. Chunk D must therefore be built so that **the missing secret is a
sentence, not a crash** (`not_configured`, the way every function here already
answers), and its tests must be runnable with no secret at all — the whole handler
exercised through stubs, the way `match-product`'s is. Decide deliberately what a
live probe can prove without credentials (the envelope, the refusal, the log row)
and what it cannot (an actual message), and say so.

---

## WHAT CHUNKS A–C LEFT YOU (do not re-do)

- **The database substrate is done**: `device_tokens` and `notification_logs` exist
  (migration 00022, D-029), with the `device_platform` enum and
  `notification_logs.channel = 'push'` already allowed. Nothing needs reinterpreting
  when push arrives.
- **Three Edge Functions are deployed and live-verified**: `ocr-purchase-bill`,
  `match-product`, `backfill-embeddings`. `_shared/` carries the error vocabulary
  (`FunctionError` + `failJson`'s status map), the JSON envelope and CORS, the
  caller-scoped client (`userClient`, `requirePharmacyId`, `env`), the hand-written
  base64 and the shared Gemini poster. **92 Deno tests** are gates.
- **The client-side vocabulary is shared too**: `lib/core/errors/function_error.dart`
  reads any function's `{error:{code,message}}` envelope in one place (D-042), and a
  feature keeps its own fallback sentence and retry policy.
- **`NotificationService` is still the stub it always was**:
  `getFcmToken()` returns `null`, and `init()` / `showLocal()` have no push SDK to
  talk to (D-029). `features/notifications/` exists. **Chunk D decides what those
  three methods mean without FCM** — the in-app list is the surface that carries the
  message either way.
- **The app's own conventions that bite**: `ref.mounted` after every await before
  writing state (D-034); a platform capability gets a seam and a fake (D-035); a
  controller test keeps its provider alive with `container.listen(...)`; provider
  override lists are inferred (`Override` is not exported by `flutter_riverpod`).

---

## SCOPE — Chunk D: notifications

Phase 5's second half, and the last of the phase. The shape the earlier decisions
already fixed: **no FCM in Phase 5** (D-029), dispatch over **WhatsApp (Cloud API)**
and **email (SendGrid)**, and **`notification_logs` written for every attempt**, so
an operator asking "did we tell this supplier" gets the same answer before and after
push exists.

### 1. `send-notification` (Edge Function)

- One function, deployed with `verify_jwt` on, acting as the caller (D-004).
- It takes *what* to send and *to whom* (a phone number, an email address, or a
  `device_tokens` row), not a free-form channel decision: the channel is a parameter
  the caller knows and the function validates.
- **Every attempt is logged** in `notification_logs` — sent, refused and
  not-configured alike — with the channel, the template and the outcome. That log is
  the deliverable's evidence, and it is what makes "we told them" auditable.
- **A missing secret is `not_configured`**, not a crash, and the message says which
  secret. That is the same rule the reader and the backfill already follow.
- Reuse `_shared/errors.ts`, `_shared/response.ts` and `_shared/client.ts`. Do not
  invent a second envelope.

### 2. The in-app list

- A screen (or the smallest surface that fits the shell) listing this pharmacy's
  notifications, newest first, tenant-scoped by `pharmacy_id` like everything else
  (D-015).
- It reads the rows the dispatch writes, so a notification that failed to *deliver*
  is still visible in the app — which is the honest behaviour when WhatsApp or email
  is not configured yet.

### 3. The alerts that justify it

- Low stock and expiring batches are the two the phase named. Both are **computed in
  SQL, not in Dart**: I-1 records exactly this trap (`lowStock` compares two columns
  in Dart over at most 500 candidates, and D-026 already plans
  `low_stock_products`/`expiring_batches` RPCs for the chatbot). If a screen needs
  one of those, it is an RPC, and it is the same one the chatbot will call.
- Decide deliberately whether the alerts *dispatch* anything in Phase 5 or only
  surface in the list. Dispatching a WhatsApp message needs an operator's phone
  number and a paid account; say what you chose and why.

### 4. What this chunk is not

- Not push. Not a Firebase project, not a service worker, not a VAPID key (D-029 —
  Phase 6 owns the deploy target those credentials must be registered against).
- Not a scheduling engine. If something needs to run periodically, that is a
  decision to record, not a cron to invent.

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, read synchronously from
  `requirePharmacyIdProvider` (D-015). Server-side, from `get_my_pharmacy_id()`.
- **Functions act as the signed-in user** — the caller's JWT, never `service_role`
  (D-004).
- **Stock moves through triggers, never through the client** (D-011/D-013, D-023):
  an alert *reads* stock and never writes it.
- **`check_violation` (23514) messages reach the user verbatim.**
- Freezed for table rows; **plain classes** for an RPC envelope, a payload, a result.
- A new column on a table is not visible through a view (D-021's trap) — if you add
  one, say so in the SQL test.
- `ref.mounted` after every await before writing state (D-034); a platform capability
  (a phone dialler, a share sheet) gets a seam and a fake (D-035).
- A platform for this feature means **Web first** (D-005).
- Code under `supabase/functions/` stays language-core JavaScript (D-031).

## OPEN ITEMS THIS CHUNK SHOULD NOT MAKE WORSE

| ID | Issue | Why it matters here |
|---|---|---|
| N-1 | Push is not wired: `device_tokens` stays empty, `getFcmToken()` returns `null` | Chunk D must work *without* it, and still write the log row |
| N-7 | A live invocation needs a session from the app; a throwaway account cannot sign in | Ask the user; never work around it |
| N-4 | No `functions logs` | Debug by deploy-and-probe (D-031) |
| N-2 | The Gemini key is free-tier and shared | Irrelevant to D, but do not add model calls to a notification path |
| N-9, N-8, N-5 | The floor's one-product measurement; the re-read's supplier reset; the alias NULL-supplier trap | All untouched by Chunk D |
| I-1 | `lowStock` compares two columns in Dart over at most 500 candidates | If an alert reads low stock, it is the RPC, not the Dart comparison |
| D-027's residual | Whether to hide `products.embedding` behind column grants is unresolved | Nothing here touches that column |

---

## CONTEXT MANAGEMENT

1. **The chunk ends in a working, gated state.** Run every gate, including the new
   `deno check` line if a function lands.
2. **Hand off at ~60-70% context**, or earlier if quality degrades.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3h-summary.md` and `context/chat3i-opening-prompt.md`; add decisions
   at **D-045+**; leave the tree commit-ready.
4. **Never compress.** Do not skip the SQL test for a migration, do not stub the
   function, do not skip widget tests. If a chunk would need to cut corners, split
   it.
5. **Phase 5 ends when Chunk D is done.** After that, Phase 6 (testing, deployment,
   documentation, the Windows build fix W-1, the README refresh R-1, push registration
   for N-1) is the next chat's business, and `PROGRESS.md`'s phase table should say so.

## BEGIN

Read the files in STEP 0, output the 5-line understanding check, then say how you
intend to build Chunk D — the function's exact request/response contract and what it
does with a missing secret, what the log row carries and when it is written, where the
in-app list lives in the shell and what it reads, whether the low-stock/expiry alerts
dispatch or only surface, and what you will verify (including what a live probe can
and cannot prove without a WhatsApp or SendGrid credential) — plus anything you need
from the user. **Wait for approval before writing the migration or the function.**
