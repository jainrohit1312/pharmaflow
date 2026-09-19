# Chat 4 / Chunk E — Phase 5: the chatbot, and the last two aggregates

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **eleventh** chunk brief of Chat 4. Chat 4's overall brief is
> `context/chat3-opening-prompt.md`; the chunk accounts are `chat3a` (database),
> `chat3b` (OCR function), `chat3c` (Dart seam), `chat3d` (chunk B complete),
> `chat3e` (C1), `chat3f` (C2), `chat3g` (C3), `chat3h` (**chunk D part 1**),
> `chat3i` (**chunk D part 2 — read it first**). `PROGRESS.md`'s Chat Strategy table
> is the authority: **Chat 4 = Phase 5 + Phase 6**.
>
> The handoff files after this chunk are `context/chat3j-summary.md` and
> `context/chat3k-opening-prompt.md`. New decisions continue at **D-052** (D-038 to
> D-051 are taken).
>
> **This chunk closes Phase 5.** `chat-sql-agent` is the last of the five Phase 5
> functions the master plan lists, and two of the four aggregates D-026 promised it
> are not built yet.

---

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — authority on what is done, the gates, the open items
2. `context/chat3i-summary.md` — **the important one**: what chunk D part 2 built
3. `DECISIONS.md` — especially **D-026** (**the chatbot answers through RPCs, never
   free-form SQL** — read it in full, it names this chunk and the four aggregates),
   **D-025** (a report is one server-side aggregate), **D-004** (the caller's JWT),
   **D-030** (the model is named in code and a model change is verified live), **D-041**
   (the embedding budget is not the reader's 5/minute, measured), **D-042** (one reader
   of a function's error envelope), **D-047** (an alert is a question, a notification
   is an event), **D-048** (notifications are a top-level utility), **D-049** (a
   dispatch answers 200 once the queue row lands), **D-051** (a derived `AsyncValue` is
   mapped by hand)
4. `HANDOFF_PROTOCOL.md` — the gate list, one `deno check` per entry point
5. `MASTER_PLAN.md` — Phase 5/6 scope (`chat-sql-agent` is the fifth function)
6. `context/chat3j-opening-prompt.md` — this file

Then output a 5-line understanding check (what this chunk covers, what parts A–D left
you, environment, two load-bearing dependency pins, what you are about to build).

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
deno check supabase/functions/send-notification/index.ts
deno check supabase/functions/chat-sql-agent/index.ts    <- NEW, when the function lands
```

(plus `supabase db push --dry-run` before pushing, and a new `supabase/tests/*.sql`
if a migration lands — atomic, self-rolling-back, asserting its numbers and printing
them. `make test-functions` runs the Deno lines; a new function adds a line there and
in `HANDOFF_PROTOCOL.md`.)

**A live invocation needs a signed-in user** (N-7): ask the user for a session token
from the app, use it while it lasts, never print it, and never work around the guard.
**Two live constraints to plan around, not discover**: the Gemini key is on a **free
tier of 5 requests a minute shared with the bill reader** (N-2), so a chat turn that
retries can starve the reader; and a live probe can prove the classification, the RPC
it chose and the numbers that came back — it **cannot** prove an answer is *useful*.
Say which is which. **D-045 governs every measurement**: a measurement that would
modify a live function, constant or table happens on a temporary tenant, and what can
be read without mutating anything (the RPCs' own reported numbers, a `select`) is
reached for first.

---

## WHAT PARTS A–D LEFT YOU (do not re-do)

- **28 migrations applied**, 28/28 local and remote match; **24 tables, 2 views**,
  RLS on every business table.
- **Four Edge Functions deployed and live-verified or live-probed**:
  `ocr-purchase-bill` (against the live vision model), `match-product`,
  `backfill-embeddings`, and `send-notification` (probed below the credential — it
  answers `skipped` naming the missing `WHATSAPP_TOKEN` and writes both rows).
  `supabase/functions/_shared/` carries `FunctionError` + the status map in
  `failJson`, `okJson`/`preflight`, `userClient`/`requirePharmacyId`/`env`, the
  hand-written base64, **`gemini.ts`** (the shared poster `postGemini` +
  `providerMessage`) and `embedding.ts`. **129 Deno tests** are gates; every handler is
  exercised through stubs with no secret.
- **Two of D-026's four aggregates exist and are asserted**: `low_stock_products()`
  and `expiring_batches()` (migration 00027, `supabase/tests/phase5_alerts.sql`, 25
  PASS), both `stable security definer`, tenant from `get_my_pharmacy_id()`,
  `jsonb` array envelope, each shipped with the number a screen wants (`shortfall`,
  `days_left`). **`top_products` and `dead_stock` do not exist** — they are this
  chunk's migration.
- **`report_summary()` exists** (D-025, migration 00021) and is the shape the other
  aggregates copy.
- **The Dart vocabulary is shared**: `lib/core/errors/function_error.dart` reads any
  function's error envelope (D-042); `PostgrestException → AppException` is
  `mapPostgrestException`; plain classes are what an RPC envelope is read into
  (`ReportSummary`, `ProductMatches`, and now `LowStockProduct`/`ExpiringBatch`).
  The app's conventions that bite: `ref.mounted` after every await (D-034), a platform
  capability gets a seam and a fake (D-035), a controller test keeps its provider alive
  with `container.listen(...)`, provider override lists are inferred (`Override` is not
  exported by `flutter_riverpod`), and **Riverpod 3 retries a failed provider build** —
  so a test asserts a state, not a read count (D-051).
- **The shell has twelve destinations** and `dashboard_shell_test.dart` +
  `widget_test.dart` assert the rail, the router and `shellPaths` agree (D-048).

---

## SCOPE — Chunk E: `chat-sql-agent`, and the two aggregates it needs

### 1. The migration: `top_products` and `dead_stock`

D-026 promised the chatbot four aggregates and built two. The other two are this
chunk's first deliverable, and they are **not chatbot-only work** — that is the whole
point of D-026's last consequence ("the four RPCs are the aggregates the reports
screens want too"):

- **`top_products(...)`** — what actually sells, ranked. The window and the ranking
  metric are the design decisions to make and record; the honest default is a date
  range and units sold, with revenue available, because "top" means different things
  to a counter and an owner.
- **`dead_stock(...)`** — what has stock and has not moved. The mirror of
  `low_stock_products` (which knows only about *levels*), and the question a pharmacy
  actually asks when cash is tight.
- Both: `stable security definer`, tenant from `get_my_pharmacy_id()` and carried
  explicitly (the views are `security_invoker = true`, so inside a definer function
  "the invoker" is the owner — 00027's reasoning), a `jsonb` envelope, `authenticated`
  only with `revoke ... from anon, public`, and a **`stable`** claim that is true: they
  read, they never move stock (D-011/D-013).
- Asserted by a new `supabase/tests/phase5_chat_aggregates.sql` that prints its
  numbers. **The boundary cases are the point**: a product with no sales at all, a
  product with sales outside the window, a return inside the window (does it subtract?
  decide), and — for `dead_stock` — a product whose only batch has expired and a
  product with no batches at all. Tenant isolation both ways, as 00027's test does.

### 2. `chat-sql-agent` (Edge Function)

- Deployed with `verify_jwt` on, acting as the caller (D-004). The contract shape is
  yours to set, but the shape the project already uses is a POST with a question and a
  bounded conversation, answered with the aggregate that was chosen, its parameters and
  the numbers — the app has to be able to show *what was asked* and *where the answer
  came from*, because D-026's fifth consequence is that the model never invents a
  figure.
- **The model classifies the question and extracts parameters. It never emits SQL**
  (D-026). A question that maps to none of the RPCs is answered "I cannot answer
  that" — a sentence, not a guess.
- **Naming the model in code and verifying it live** is D-030's rule applied to the
  text model; `_shared/gemini.ts`'s `postGemini` is the poster, and `env()` already
  turns a missing key into `not_configured` naming the secret.
- **The answer's numbers come from the RPC, never from the model.** Whatever shape you
  choose, make that structurally true rather than a matter of prompting — the model
  chooses from a closed set and fills declared parameters, and the figures are read out
  of the `jsonb` the RPC returned.
- Reuse `_shared/errors.ts`, `_shared/response.ts`, `_shared/client.ts`. No second
  envelope, no second error vocabulary.
- **One request makes one model call**, and the free tier is shared with the bill
  reader (N-2): a chat that retries once per turn is a chat that starves the OCR flow.
  Decide the policy deliberately (D-032/D-039 are the two precedents) and say so.
- **The function reads and never writes** (no stock, no ledger, no notification). If a
  question needs a new aggregate, that is a migration in this chunk's style, not a
  statement.

### 3. The Dart surface

A chat screen, its repository and its controller — and **placement is a decision to
make, not to inherit**: `MASTER_PLAN.md` does not say where it lives, and D-048's
reasoning cuts both ways. A chatbot that answers about stock, sales, payables and
expiry spans every domain as widely as notifications do (which is why `/notifications`
is top-level), but it is also the one screen whose *output* is prose, so it may belong
under the destination its commonest question is about. Decide, record it as a
decision, and let the shell's own agreement test carry the consequence.

- The three sentences rule applies to the first turn: *"still waiting"*, *"no answer
  to that"* and *"could not ask"* must not look alike (T-5's lesson).
- A question that maps to nothing is a **successful** answer that says so, not an
  error state.
- Widget tests for the screen, the controller and the answer's rendering, and a fake
  for whatever the platform-shaped part is (D-035).

### 4. What this chunk is not

- Not a SQL console. There is no code path in which the model's output is executed.
- Not a write path. The chatbot cannot move stock, post a ledger entry, or send a
  message (D-046 keeps dispatch in Phase 6, and D-011/D-013 keep stock in triggers).
- Not the reports screens. If the chatbot and the reports screen want the same number,
  they both call the same RPC — that is the design, not a duplication.
- Not Phase 6's work: the Windows build fix (W-1), the README (R-1), push (N-1), the
  WhatsApp/SendGrid credentials and the alert triggers (D-046) all wait.

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, read synchronously from
  `requirePharmacyIdProvider` (D-015). Server-side, from `get_my_pharmacy_id()`.
- **Functions act as the signed-in user** — the caller's JWT, never `service_role`
  (D-004). A chatbot that could reach past RLS would be another way in, not a feature.
- **Stock moves through triggers, never through the client** (D-011/D-013, D-023), and
  an aggregate reads it.
- **`check_violation` (23514) messages reach the user verbatim.**
- Freezed for table rows; **plain classes** for an RPC envelope, a payload, a result.
- A new column on a table is not visible through a view (D-021's trap) — if you add
  one, say so in the SQL test.
- A platform for this feature means **Web first** (D-005).
- Code under `supabase/functions/` stays language-core JavaScript (D-031).

## OPEN ITEMS THIS CHUNK SHOULD NOT MAKE WORSE

| ID | Issue | Why it matters here |
|---|---|---|
| I-1 | The low-stock comparison still runs in Dart over a 500-row scan in `InventoryRepository` | The RPC it should call is the same one the chatbot will call; switching the inventory screen onto it is a small client change and closes I-1 properly |
| N-2 | The reader's key is 5 requests a minute on a free tier, and a burst is shed as `503` | A chat turn is a model call on **the same key**: decide the retry policy deliberately |
| N-7 | A live invocation needs a session from the app | Ask the user; never work around it |
| N-9 | The vector floor (0.78) was measured against a one-product catalogue | Untouched here; the chatbot's aggregates will show the same thin catalogue |
| N-1, N-4, N-5, T-3, T-4, T-5 | push not wired, no `functions logs`, the alias NULL-supplier trap, and the three older UI items | All untouched by this chunk |
| D-027's residual | Whether to hide `products.embedding` behind column grants is unresolved | Nothing here touches that column |

**Two things chunk D left in production on purpose**: one `notification_logs` row and
one in-app notification, both marked as probes. Do not delete them; `notification_logs`
has no delete policy and the pair is the D-049 evidence.

---

## CONTEXT MANAGEMENT

1. **The chunk ends in a working, gated state.** Run every gate, including the new
   `deno check` line when the function lands.
2. **Hand off at ~60-70% context**, or earlier if quality degrades. This chunk splits
   naturally the way chunk D did — **the aggregates first, then the function and the
   screen** — and splitting there is better than a rushed screen.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3j-summary.md` and `context/chat3k-opening-prompt.md`; add decisions at
   **D-052+**; leave the tree commit-ready.
4. **Never compress.** Do not stub the function, do not skip its Deno tests, do not
   skip a SQL test for a migration, do not ship a screen with no widget tests.
5. **Phase 5 ends when this chunk is done.** Then Phase 6: the Windows build fix (W-1),
   the README refresh (R-1), push registration (N-1), the SendGrid/WhatsApp credentials
   and the alert triggers (D-046), N-9's re-measurement with a real catalogue, N-5's
   index, and I-1's client change if it is still open.

## BEGIN

Read the files in STEP 0, output the 5-line understanding check, then say how you
intend to build chunk E — the two aggregates and the boundary cases each one has to
answer, the function's request/response contract, how the model is kept to choosing an
RPC and filling its parameters rather than describing a number, the retry policy for a
key shared with the bill reader, where the chat screen lives in the shell and why, and
what you will verify (including what a live probe can and cannot prove) — plus anything
you need from the user. **Wait for approval before writing the migration or the
function.**
