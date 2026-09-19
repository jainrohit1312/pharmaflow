# Chat 4 / Chunk E (PART 2 of 2) — Phase 5: the `/chatbot` surface

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **twelfth** chunk brief of Chat 4. Chat 4's overall brief is
> `context/chat3-opening-prompt.md`; the chunk accounts are `chat3a` (database),
> `chat3b` (OCR function), `chat3c` (Dart seam), `chat3d` (chunk B complete),
> `chat3e` (C1), `chat3f` (C2), `chat3g` (C3), `chat3h` (chunk D part 1),
> `chat3i` (chunk D part 2), and `chat3j` (**Chunk E part 1 — read its summary
> first**). `PROGRESS.md`'s Chat Strategy table is the authority: **Chat 4 = Phase
> 5 + Phase 6**.
>
> The handoff files after this chunk are `context/chat3k-summary.md` and
> `context/chat3l-opening-prompt.md`. New decisions continue at **D-054** (D-038
> to D-053 are taken).
>
> **This chunk closes Phase 5.** The server side of the chatbot is already built,
> deployed and live-probed; what is missing is the screen a person types into.

---

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — authority on what is done, the gates, the open items
2. `context/chat3j-summary.md` — **the important one**: what E-part-1 built, and the
   probe output
3. `DECISIONS.md` — especially **D-026** (the chatbot answers through RPCs, never
   free-form SQL), **D-053** (phrasing is templated, never model-generated), **D-052**
   (auto-send PO deferred), **D-048** (notifications are a top-level utility — the
   precedent for where a cross-cutting screen lives), **D-015** (the tenant comes from
   `requirePharmacyIdProvider`), **D-034** (`ref.mounted` after every await), **D-035**
   (a platform capability gets a seam and a fake), **D-042** (one reader of a function's
   error envelope), **D-051** (a derived `AsyncValue` is mapped by hand)
4. `HANDOFF_PROTOCOL.md` — the gate list, one `deno check` per entry point
5. `MASTER_PLAN.md` — Phase 5/6 scope
6. `context/chat3k-opening-prompt.md` — this file

Then output a 5-line understanding check (what this chunk covers, what E-part-1 left
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
deno check supabase/functions/chat-sql-agent/index.ts
```

(`make test-functions` runs the Deno lines.) No migration is expected in this chunk —
the server is done. If one is added after all, it needs a new `supabase/tests/*.sql`
that is atomic, self-rolling-back, asserts its numbers and prints them.

---

## WHAT E-PART-1 LEFT YOU (do not re-do)

- **29 migrations applied**, 29/29 local and remote match; 24 tables, 2 views.
- **`chat-sql-agent` is deployed, `verify_jwt` on, and live-probed.** Five Edge
  Functions now; **181 Deno tests** are gates.
- **The last two aggregates exist**: `top_products(...)` and `dead_stock(...)`
  (migration 00029), asserted by `supabase/tests/phase5_chat_aggregates.sql` (**36
  PASS / 0 FAIL of 37**). Both return `{meta, rows}`; `low_stock_products` and
  `expiring_batches` still return a **bare array** (00027) and the app already parses
  that.
- **The function's contract, exactly** (`chat-sql-agent/index.ts`):

  ```
  POST { "question": "…", "history": [ { "role": "user"|"model", "text": "…" } ]? }
    -> 200 { "answer":  "a sentence, rendered in code from the report",
             "rpc":     "top_products" | "low_stock_products" | "expiring_batches"
                        | "dead_stock" | "report_summary" | null,
             "params":  { … the arguments the report actually ran with … },
             "data":    <the report's jsonb envelope, verbatim, or null>,
             "meta":    { "model": "gemini-3.6-flash", "warnings": [ … ] } }
    -> 4xx/5xx { "error": { "code", "message" } }
  ```

  **`rpc: null` is a success, not a failure**: it is the answer to a question no report
  covers, and `answer` is the sentence "I cannot answer that…". The three sentences
  rule applies to it directly.
- **The Dart vocabulary that already exists and must be reused**: the app reads a
  function's error envelope in exactly one place — `functionException` in
  `lib/core/errors/function_error.dart` (D-042); `OcrService` and `MatchService` are
  the two existing examples of a service that calls `functions.invoke` and maps its
  failures (`sb.FunctionsFetchException` → `NetworkException`, `sb.FunctionException` →
  `functionException`); plain classes are what an RPC/function envelope is read into
  (`ReportSummary`, `ProductMatches`, `LowStockProduct`, `ExpiringBatch`), while Freezed
  is for table rows.
- **The shell has twelve destinations** and `dashboard_shell_test.dart` +
  `widget_test.dart` assert the rail, the router and `shellPaths` agree (D-048).

---

## SCOPE — Chunk E part 2: the `/chatbot` screen

### 1. The service and the model

- **A `ChatService`** over `functions.invoke`, in the shape `OcrService`/`MatchService`
  already use: an interface, a `SupabaseChatService`, and a fake for tests. It sends the
  question (and the bounded history) and decodes the envelope.
- **The answer is an envelope, so a plain class, not Freezed** (the `ReportSummary`
  precedent): the sentence, the `rpc` (nullable), the params, the raw `data`, the model
  and the warnings. Keep `data` as a decoded `Object?` rather than re-modelling five
  report shapes — the sentence is what the screen shows, and `data` is what it shows
  *beside* the sentence.
- **A shape check, the way the alerts have one**: an answer that is not an object, or
  carries no `answer` string, is a failure and must not render as an empty answer. That
  is the one wrong answer this feature could give.
- Follow `MatchService.decodeProductMatches`'s pattern: a pure `decodeChatAnswer` that a
  test can drive with the bodies that matter.

### 2. The screen

- A message list and an input. A message is a question or an answer, so the screen has
  its own state (the conversation), not just an `AsyncValue`.
- **The three sentences rule is the heart of this chunk** (T-5's lesson): *"still
  waiting"*, *"no answer to that"* and *"could not ask"* must not look alike. In
  particular an `rpc: null` answer is **a successful answer that says so**, rendered as
  prose, while a `provider_unavailable` is a failure with a **visible retry** — they must
  never share a rendering.
- **Loading vs empty**: before the first question the screen says something that invites
  one (a few example questions is a good use of the closed set, since the reports are
  known), and it must not look like a failure. A history that is empty is not an error.
- The answer's rendering should surface **what was asked and where it came from** — the
  `rpc` and the params are in the envelope for exactly this (D-026's fifth consequence).
  A one-line note under an answer is the shape; `top_products`' `data.meta`
  (`returns_not_netted`) is the case that motivated the rule in D-053.
- **Nothing in the widget computes a figure.** The sentence comes from the server; a
  widget that formatted its own number would be a second implementation of D-053 on the
  wrong side of the wire.
- Widget tests for: the invitation/empty state, sending a question, an answer rendering,
  the `rpc: null` answer, a failure with its retry, and the loading state. Plus a fake
  service (D-035).

### 3. The shell

- **`/chatbot` is a top-level shell destination** — the **thirteenth** rail entry,
  `inBottomBar: false`, placed after Reports and before Settings (alongside
  `/notifications`). This is D-048's reasoning applied again: a chatbot that answers about
  stock, sales, payables and expiry spans every domain, so nesting it under whichever
  module was chosen first would make the others look second-class. **Record it as a
  decision (D-054)** and say why in one sentence.
- Adding the destination means **three lists move together**, and a test already enforces
  two of them: `Routes.chatbot` and the `Routes.shellPaths` path, the
  `_navDestinations` entry, and then `dashboard_shell_test.dart` and `widget_test.dart`
  (12 → 13).
- `app_router.dart` declares the route as a shell child.

### 4. What this chunk is not

- **Not a new server capability.** If the screen wants a number the function cannot give,
  that is a migration and a new report — not a client-side calculation and not prompt
  engineering.
- **Not a write path.** The chatbot cannot move stock, post a ledger entry or send a
  message.
- **Not Phase 6.** The Windows build fix (W-1), the README (R-1), push (N-1), the
  WhatsApp/SendGrid credentials and the alert triggers (D-046), N-9's re-measurement and
  N-5's index all wait. Auto-send PO is Phase 6's too (D-052).

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, read synchronously from
  `requirePharmacyIdProvider` (D-015). (The chatbot itself sends no tenant: the function
  derives it from the caller's JWT, D-004.)
- **Functions act as the signed-in user** — the caller's JWT, never `service_role`.
- Freezed for table rows; **plain classes** for an RPC/function envelope.
- **`ref.mounted` after every await** (D-034), and a controller test keeps its provider
  alive with `container.listen(...)`.
- **Riverpod 3 retries a failed provider build by itself** — assert a *state*, never a
  read count (D-051). A derived `AsyncValue` is mapped by hand, in the order
  value → error → loading.
- Provider override lists are inferred (`Override` is not exported by
  `flutter_riverpod`).
- `flutter analyze` is stricter than `dart run custom_lint` and analyzes `test/**` too:
  `avoid_redundant_argument_values` and `unused_element_parameter` bite test fixtures, so
  run `dart format` then `flutter analyze` before declaring a file done.
- A platform for this feature means **Web first** (D-005).
- Code under `supabase/functions/` stays language-core JavaScript (D-031) — you should not
  need to touch it.

## A note on the live probe (N-7)

**The endpoint is already live-probed**, in E-part-1: the classification, the parameters,
the model name, the numbers and the refusal path were all verified with a session token,
and the raw output is in `context/chat3j-summary.md`. So this chunk does **not** need a
token to prove the server.

What a token *could* add is an end-to-end run of the Flutter web build, where the app
itself calls the function. If you want that, **ask the user for a fresh session token**
(N-7: signup on the hosted project returns no session, so a throwaway account cannot sign
in), use it while it lasts, **never print it**, and never work around the guard. A
shoulder-tap: verifying HTTP is done with `curl`, not with a driven browser.

---

## OPEN ITEMS THIS CHUNK SHOULD NOT MAKE WORSE

| ID | Issue | Why it matters here |
|---|---|---|
| I-1 | The low-stock comparison still runs in Dart over a 500-row scan | The chatbot now calls `low_stock_products` live; the inventory screen is the last caller still comparing in Dart |
| N-2 | The Gemini key is 5 requests a minute, shared with the bill reader | The screen must not fire a second model call to "retry" a turn on its own: the retry is the user's, one at a time |
| N-4 | No `functions logs` in this CLI | Unchanged; a chat failure is diagnosed by the sentence the function returns |
| N-7 | A live invocation needs a session from the app | Ask; never work around it |
| N-9 | The vector floor was measured against a one-product catalogue | Untouched |
| D-027's residual | Whether to hide `products.embedding` behind column grants is unresolved | Nothing here reads `products` |
| N-1, N-5, T-3, T-4, T-5 | push, the alias index, and the three older UI items | All untouched. T-5 is the *rule* this screen must obey, not an item it fixes |

**Two things earlier chunks left in production on purpose**: one `notification_logs` row
and one in-app notification, both marked as probes (D-049's evidence). Do not delete them.

---

## CONTEXT MANAGEMENT

1. **The chunk ends in a working, gated state.** Run every gate.
2. **Hand off at ~60-70% context**, or earlier if quality degrades.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3k-summary.md` and `context/chat3l-opening-prompt.md`; add decisions at
   **D-054+**; leave the tree commit-ready.
4. **Never compress.** Do not stub the service, do not skip the widget tests, do not ship
   a screen that cannot show its three states.
5. **Phase 5 ends when this chunk is done.** Then Phase 6: the Windows build fix (W-1),
   the README refresh (R-1), push registration (N-1), the SendGrid/WhatsApp credentials
   and the alert triggers (D-046), auto-send PO (D-052), N-9's re-measurement with a real
   catalogue, N-5's index, and I-1's client change if it is still open.

## BEGIN

Read the files in STEP 0, output the 5-line understanding check, then say how you intend
to build E-part-2 — the service's shape and where it lives, what the answer model carries,
how the screen renders the three sentences so they cannot be confused, where the note
under an answer comes from, the conversation's state and where it lives, the exact shell
changes and the tests that move with them, and what you will verify (and what a live run
can and cannot prove). **Wait for approval before writing the service or the screen.**
