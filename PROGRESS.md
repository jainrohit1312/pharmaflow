# PharmaFlow — Progress Tracker

**Last Updated:** 2026-09-19
**Current Phase:** Phase 5 IN PROGRESS — **Chunk C complete (C1 matcher, C2 app seam + alias learning + suggestions, C3 backfill + measured floor)**, and **Chunk D part 1 of 2 done**: `low_stock_products()` and `expiring_batches()` are live and answer against the real catalogue. Next: **Chunk D part 2** — `send-notification`, the in-app list and the Dart seams (`context/chat3i-opening-prompt.md`), then Phase 6
**Overall Status:** Phases 0-4 done and gated; Phase 5 has its database substrate, three deployed and live-verified Edge Functions, a bill that reads and saves end to end, a matcher that suggests and learns, a backfilled catalogue with a measured similarity floor, and its alert sources — 493 Flutter tests, 92 Deno tests

---

## Phase Status Overview

| Phase | Name | Status | Started | Completed |
|---|---|---|---|---|
| 0 | Project Setup + Schema + Auth | COMPLETE | 2026-09-18 | 2026-09-18 |
| 1 | Product + Supplier + Customer Master | COMPLETE | 2026-09-18 | 2026-09-18 |
| 2 | Purchase + Inventory + Batch Tracking | COMPLETE | 2026-09-18 | 2026-09-18 |
| 3 | Sales/POS + Returns + GST Billing | COMPLETE | 2026-09-18 | 2026-09-18 |
| 4 | Ledger + Payments + Reports | COMPLETE | 2026-09-18 | 2026-09-19 |
| 5 | AI OCR + Smart Matching + Notifications | IN PROGRESS (C1, C2, C3 complete; Chunk D next) | 2026-09-19 | - |
| 6 | Testing + Deployment + Documentation | PENDING | - | - |

---

## Environment (Current)

| Item | Value |
|---|---|
| Workspace root | `C:\Projects\PharmaFlow\` |
| Flutter version | 3.44.8 (stable) |
| Dart | 3.12.2 |
| SDK constraint | `^3.8.0` |
| Riverpod | 3.0.3 (`flutter_riverpod`, `riverpod_annotation`, `riverpod_generator`, `riverpod_lint`) |
| Freezed | 3.2.3 (`freezed_annotation` 3.1.0) |
| Supabase | HOSTED only (no local stack, no Docker) |
| Project ref | `yeroxzkpmodbzcvjlqwd` |
| Region | Mumbai (ap-south-1) |
| CLI version | supabase 2.113.0 |

---

## Chat Strategy (1M Context Optimized)

- **Chat 1:** Phase 0 [DONE]
- **Chat 2:** Phase 1 + Phase 2 [DONE]
- **Chat 3:** Phase 3 + Phase 4 [DONE]
- **Chat 4:** Phase 5 + Phase 6 [target ~280k tokens]
- **Handoff trigger:** ~600k tokens used OR quality degrades OR both phases done

---

## What Currently Works

### Backend (Supabase Hosted)

- 27 migrations applied, all idempotent (`supabase migration list`: 27/27 local
  and remote match)
- 24 tables and 2 views (`product_stock`, `batch_status`), RLS enforced on every
  business table; migration 00022 added `device_tokens`, `notification_logs`, the
  `products.embedding` column and the private `purchase-bills` storage bucket
  (00019-00021 added one table, `invoice_counters`, and no view), 00023 added
  the two matching functions, 00024 the alias-learning function, 00025 the
  backfill pair, 00026 the re-tuned vector floor, and 00027 the two alert sources
  — none of those five added a table, a column or a view
- Helper functions: `get_my_pharmacy_id()`, `get_my_role()`,
  `normalize_product_name()` (identity and scope); the automation layer
  (`ledger_auto_entry_*`, `stock_*`, `write_audit_log`, `set_updated_at`,
  `handle_new_user`); the RPCs (`onboard_pharmacy`, `checkout_sale` /
  `next_sale_invoice_no`, `record_payment`, `report_summary`); the sales
  payment guard (`sales_payment_check`); the matcher
  (`product_embedding_text`, `match_products`, `learn_product_aliases`,
  `products_to_embed`, `set_product_embeddings`); and the alert sources
  (`low_stock_products`, `expiring_batches`)
- **Three Edge Functions deployed**: `ocr-purchase-bill` (chunk B1, verified against
  the live model), `match-product` (chunk C1) and `backfill-embeddings` (chunk C3,
  verified live). `supabase/functions/_shared/` carries errors, the JSON envelope +
  CORS, the caller-scoped client, base64, the shared Gemini poster (`gemini.ts`) and
  the embedding convention (`embedding.ts`). **92 Deno tests** are gates (**N-3
  resolved**), and `make test-functions` runs them plus a `deno check` per entry point
- Indexes and triggers per migration: `set_updated_at` on every business table,
  and every stock and ledger effect attached as a trigger rather than left to a
  client (D-013, D-023)
- Auth working: email provider ON. **The hosted project requires email
  confirmation**, which contradicts this line as it stood until 2026-09-19 (and the
  repo's `config.toml`, which only ever seeds a local stack — D-003): a signup
  returns `confirmation_sent_at` and no session, and the password grant answers
  `email_not_confirmed`. See open item N-7.
- User `owner@pharmaflow.dev` registered and promoted to `owner`
- Pharmacy row created: "My Pharmacy"
- Multi-tenant isolation verified with two test tenants

### Flutter App

- Bootstrap chain working: `main.dart` -> `bootstrap.dart` -> `PharmaFlowApp`
- Riverpod 3.x codegen setup (`@riverpod`)
- GoRouter with auth redirects
- Theme (light/dark, teal seed)
- Widgets: AppButton, AppTextField, AppScaffold, LoadingView, ErrorView
- 6 Freezed models: Pharmacy, Profile, Supplier, Customer, Product, ProductBatch
- Auth flow: splash -> login -> register -> dashboard -> signout
- Dashboard shell responsive (NavigationBar mobile / NavigationRail desktop)
- The Phase 5 surfaces: the bill reader (`features/purchase_ocr/`, which now also
  suggests catalogue products per line, records what the human confirmed, and
  survives a re-read), the verify-and-save flow, and the notifications seam
  (`features/notifications/`, Chunk D's)

### Platform Support

- Web (Chrome): working
- Windows: build fails (`permission_handler_windows`, STL1011)
- Android: configured, untested
- iOS: configured, untested

---

## Known Issues / Open Items

| ID | Issue | Severity | Plan |
|---|---|---|---|
| W-1 | Windows build fails (STL1011 — `<experimental/coroutine>` deprecated in VS 2026) | Medium | Fix in Phase 6 via `windows/CMakeLists.txt` |
| D-1 | 5 manual Providers remain (service stubs + router) | Low | Convert to `@riverpod` when the respective features are built |
| T-1 | `dart run custom_lint` SDK language version notice (cosmetic) | Low | Wait for upstream analyzer fix |
| A-1 | `anonKey` deprecated in supabase_flutter 2.17 | Low | Migrate to `publishableKey` in Phase 6 |
| I-1 | The low-stock list reads at most `InventoryRepository.lowStockScanLimit` (500) candidate rows and decides `total_qty < min_stock_level` in Dart, because PostgREST cannot compare two columns. A catalogue past that bound would silently omit rows. **D-part-1 built the server-side answer** (`low_stock_products()`, D-047 — same `<` rule, same shortfall, tenant-scoped, asserted by `phase5_alerts.sql`); what is left is switching the inventory screen onto it | Low | Switch `InventoryRepository.lowStock` to the RPC (the alert list already reads it), and delete the Dart comparison and its scan bound |
| I-2 | A purchase return is two statements (header, then lines). The lines are one atomic INSERT, so stock moves for all of them or none - but a refused set can leave a header with no lines. Deliberately not rolled back: see `PurchaseReturnsRepository.create` | Low | An `RPC` wrapping both statements when Phase 4 touches the ledger |
| I-3 | A return form offers at most `returnablePurchaseLimit` (200) received purchases | Low | A searchable purchase picker, as the product picker already is |
| R-1 | `README.md` still describes the project as "Phase 0 (scaffold)" with Phase 1+ screens as placeholders | Low | Refresh it in Phase 6, which owns documentation |
| T-3 | The ledger screen's entries failure path is only reachable on a **first** read: while no party is selected the entries provider holds an empty page, so a failure after a party is chosen keeps that empty page and reports itself through a SnackBar rather than replacing the body. A user who cannot load a party's ledger therefore has no retry control until they navigate away and back | Low | Either treat "no party selected" as no value rather than an empty page, or give the SnackBar a retry action |
| T-4 | `sale_return_form_screen.dart` has two paths that cannot run: the bill picker's `'Choose a bill'` validator, and `if (saleId == null) _report('Choose the bill the goods were sold on.')`. The submit button is disabled while no bill is chosen (`onPressed: isSaving \|\| saleId == null ? null : _save`) and the picker offers no clear affordance, so `_save` never sees a null bill | Low | Either drop the dead branches or make the button live and let the validator speak, so the two do not have to be kept in step |
| T-5 | `sale_return_form_screen.dart`'s bill picker renders `sales.value ?? const <Sale>[]`, so "the sales list is still loading" and "this pharmacy has no sales" look identical — an empty, disabled dropdown with no spinner and no explanation | Low | Distinguish the two the way the ledger's party picker does, or read the sales provider's `AsyncValue` states explicitly |
| N-1 | Push delivery is not wired: `device_tokens` stays empty and `NotificationService.getFcmToken()` returns `null`. Phase 5 dispatches over WhatsApp/Email and shows the in-app list; the Firebase project, the web service worker, the VAPID key and the registration call are Phase 6's (D-029) | Medium | Phase 6, which owns the deploy target the credentials must be registered against |
| N-2 | The Gemini key is on a **free tier: 5 requests per minute**, and a burst is shed as `503 UNAVAILABLE` rather than `429`, so a busy counter (or a double-tapped retry) meets "the reader is busy" with no queue behind it. `ocr-purchase-bill` makes one attempt and reports it as retryable on purpose (D-032); the app retries once, visibly (D-033) | Medium | A paid tier, or a deliberate retry-once policy with a visible waiting state — decide before the OCR flow meets a real counter |
| N-4 | A deployed function's `console.error` is only visible in the Supabase dashboard: CLI 2.113.0 has no `functions logs` subcommand (only list/delete/download/deploy/new/serve) and there is no container to serve one locally. Debugging a function is therefore a deploy-and-probe cycle | Low | Accept it and probe deliberately (D-031 records the practice), or find a log path for the CLI version in use |
| N-5 | `product_aliases`' unique index is `(pharmacy_id, supplier_id, normalized_name)` with `supplier_id` nullable and **no `NULLS NOT DISTINCT`**, so two rows for one printed text coexist when neither names a supplier — Postgres treats NULLs as distinct. `ProductsRepository.addAlias`'s doc says re-adding text "re-points the alias … instead of failing … which is what the unique key is for" (`app/lib/features/products/data/products_repository.dart:451`, upserting on that target at `:484`), and migration 00015's own comment says NULL-supplier rows "never conflict" (`20260918000015_phase2_extras.sql:353`). Both cannot be true: the second manual alias with no supplier **inserts a duplicate** rather than updating. C2 leaves it exactly as it is: `learn_product_aliases` (00024) writes a NULL-supplier row with an explicit update-then-insert so a *learned* alias converges, but the index, `addAlias` and migration 00015's comment are untouched, and the OCR path names a supplier anyway — so a learned alias is normally supplier-scoped. Both SQL tests assert the coexistence rather than hiding it | Low | Phase 6: make the index expression `(pharmacy_id, coalesce(supplier_id, '00000000-0000-0000-0000-000000000000'::uuid), normalized_name)` or add `NULLS NOT DISTINCT` (PG 15+), then reconcile the two comments above |
| N-7 | A throwaway probe account cannot sign in on the hosted project: signup returns `confirmation_sent_at` with no session and the password grant answers `email_not_confirmed`, while `config.toml` says `enable_confirmations = false` (a local-stack-only setting, D-003). Setting `auth.users.email_confirmed_at` by hand is the obvious workaround and is correctly refused by the auto-mode guard as an auth-weakening write to production | Low | Probe with a session obtained from the app (`owner@pharmaflow.dev`), or decide deliberately whether "Confirm email" should be off in the hosted project the way the repo believes it is |
| N-8 | A **successful second read** of the same bill replaces the whole verify form, so the supplier the human had chosen is dropped (and with it the suggestions, which are scoped by that supplier). It is the direct consequence of fixing the re-seed defect with `ValueKey(scan.bill)` (D-039): the new parse replaces the header fields too, which is right for the invoice number and date and merely inconvenient for the supplier. The match is asked again as soon as the supplier is named again | Low | Re-seed only the *lines* (and clear the suggestions) in `didUpdateWidget` when the parse changes, keeping the header the human already edited |
| N-9 | The vector floor (**0.78**) was measured against a live catalogue that holds **one product**, so the window it sits in (0.7216 refused / 0.8280 kept) rests on one catalogue vector and nine query texts. Three things follow, and they are the whole open item: **(a) the recipe** — lower the floor to 0.01, read the `distance` the matcher reports for a set of real and near-miss invoice texts, and install the chosen value in a new migration (D-013; and on a temporary tenant, never the live function — **D-045**); **(b) the direction** — 0.78 errs **high**, so the cost of being wrong is a *missed* suggestion rather than a wrong one (the human picks, and the alias and trigram legs still answer); **(c) the trigger to revisit** — Phase 6's testing should re-tune it once the catalogue has **50+ products**, because that is when "two catalogue products of the same brand" becomes a real band to separate rather than a one-row guess | Low | Phase 6, once the catalogue is real. Nothing depends on the exact value: it is a one-line migration and the tests move with it |

**Resolved in chat 4 (chunk C3):** the catalogue is embedded, and the floor stopped
being a guess. Live: `{embedded:1,remaining:0}` then `{embedded:0,remaining:0}`
(resumable, and nothing spent on the second run); `products.embedding` is null on 0
real rows; the vector leg fires on a real bill's text (`Dolo650Tab15s` → the real
product at 0.8280, `reason: vector`); and the constant behind it is **0.78**, inside
the window nine real measurements left open (**D-044**). No open item was made worse:
N-5 untouched, N-2 unchanged for the reader, N-7 bypassed with the user's own
session (and the token was used for read-only probes and the intended backfill only).
**N-9 is new** — the floor's measurement rests on a one-product catalogue.

**Resolved in chat 4 (chunk C2):** the app can now suggest, and learn. A live probe
of the deployed `match-product` (read-only, with the session token the user supplied)
confirmed the embedding call, the model name, the 768-dimension parse and the CORS
header on the **200** path — the three things C1 left unverified — and measured the
embedding quota: 11 requests / 80 texts in ~3 minutes with no refusal, so the
embedding metric is **not** the reader's 5/minute (**D-041**). No open item was made
worse: N-5 is untouched (the learned write sidesteps the NULL-supplier trap inside
the new function rather than fixing the index), N-2 is unchanged for the reader, N-6
stays withdrawn, and N-7 is bypassed by using the user's own session.

**Resolved in chat 4 (continued): N-3.** The Edge Functions' tests are gates now:
`HANDOFF_PROTOCOL`'s gate block gained `deno test supabase/functions` (which
type-checks and runs all 81) and a `deno check` per entry point
(`ocr-purchase-bill/index.ts`, `match-product/index.ts` — the entry points and
their wiring, which no test imports), and `make test-functions` runs all three.
None of them needs Docker or a secret.

**Resolved in chat 4 (C1 follow-up): N-6 — it was a false positive.** It claimed a
live function response carried no `access-control-allow-origin`. It does: the
deployed gateway answers with `Access-Control-Allow-Origin: *` (capitalised) on the
error paths of **both** functions and on the preflight, and passes the other three
CORS headers through lowercased. The finding was a **case-sensitive `findstr`** on
my side — `findstr /C:` matches case, and only that one header comes back
capitalised, so the filter hid exactly it. Re-measured with the full header dump:

```
POST match-product      {"lines":["Dolo 650"]}   -> 401  Access-Control-Allow-Origin: *
OPTIONS match-product   (preflight)              -> 204  Access-Control-Allow-Origin: *
POST ocr-purchase-bill  {"path":42}              -> 400  Access-Control-Allow-Origin: *
```

No code changed and neither function was redeployed: `_shared/response.ts` already
sets the four headers on every path (`json`/`okJson`/`failJson`/`preflight`), and the
gateway replaces the origin one with its own. See **D-038** for the contract and the
verification recipe (`findstr /I`, or `Select-String`).

**Resolved this chat:** P-1 / chat2b O-1 (editing an `ordered` purchase silently
returned it to `draft` — now reverts only when the lines change, and says so:
see D-019). Chat 3 also closed the two defects the sale-side migration shipped
with (an `anon` EXECUTE grant and an overpayment that stored a negative balance)
and the purchase-return credit note Phase 2 left unposted — all three in
migration 00020.

**Resolved in chat 4: T-2.** Phase 3's missing Dart tests are written: 91 of them
(55 for sales, 36 for sale returns), none changed. `test/features/sales/` now
exists. Two smaller items were found while writing them and are recorded above as
T-4 and T-5 — both dead or ambiguous UI in the sale-return form, neither a
behavioural defect. **Two things T-2 named are still untested**, for reasons
rather than for lack of trying: `invoice_printer.dart` (its `printReceipt` lays
out the PDF *and* calls `Printing.layoutPdf` in one method, so a test would have to
mock a platform channel rather than assert a document — the fix is to extract the
document builder) and `sale_detail_screen.dart` (the bill the counter opens).

---

## Dependency Pins (Load-Bearing — DO NOT CHANGE)

```yaml
# app/pubspec.yaml
riverpod_lint: '>=3.0.0 <3.1.0'   # 3.1.8 renamed its entrypoint to lib/main.dart,
                                   # but custom_lint 0.8.1 still imports
                                   # package:riverpod_lint/riverpod_lint.dart ->
                                   # `dart run custom_lint` dies with
                                   # "Failed to start the plugins"
custom_lint: ^0.8.0                # forces Freezed 3.x
freezed: ^3.0.0                    # models must be `abstract class X with _$X`
environment:
  sdk: ^3.8.0                      # json_serializable null-aware elements
```

Changing any pin above requires explicit user approval (see DECISIONS.md D-007).

---

## Chat 4 Progress — Chunk D (PART 1 of 2): the alert sources [DONE]

Chunk D is the notification half of Phase 5, and it is being built in two parts: the
**alert sources** (this, done) and the **notifications themselves**
(`send-notification`, the in-app list, the Dart seams — briefed in
`context/chat3i-opening-prompt.md`, not started). The split is the one the earlier
chunks used: the server side first, gated on its own.

### What D-part-1 delivered

- **`supabase/migrations/20260919000027_phase5_alert_sources.sql`, applied.** Two
  `stable security definer` functions, no table, no column, no trigger, and nothing
  that moves stock:
  - **`low_stock_products(p_limit int default 50) → jsonb`** — products below their
    reorder level, worst first, each with `total_qty`, `min_stock_level` and
    **`shortfall`** (the units that close the gap). The rule is the app's own one,
    `total_qty < min_stock_level`, now evaluated where both columns live — which is
    **I-1's fix**: the Dart comparison ran over at most 500 candidate rows, so a
    bigger catalogue reported a partial answer that looked complete. An inactive
    product is never reported; a product with no batches at all is `0` and is.
  - **`expiring_batches(p_days int default 90, p_limit int default 50) → jsonb`** —
    batches with stock left expiring inside the window, soonest first, each with
    `days_left` (**negative** when it has already expired, so a screen can say
    "expired 6 days ago" rather than read a bucket). An empty batch is not a waste
    risk and is excluded.
  - Both take the tenant from `get_my_pharmacy_id()` and carry
    `pharmacy_id = v_pharmacy` explicitly — which is not belt-and-braces here: the
    views they read are `security_invoker = true`, and inside a definer function the
    "invoker" is the owner.
- **`supabase/tests/phase5_alerts.sql`** — 25 PASS / 0 FAIL of 26 assertions,
  atomic and self-rolling-back: the reorder boundary (`<` reports, `=` does not), the
  no-batches case, an inactive product never reported, the shortfall number,
  worst-first ordering, the limit, the horizon widening with `p_days`, the negative
  `days_left`, the already-expired batch first, an empty batch excluded, tenant
  isolation both ways, and that reading them moves nothing.
- **A schema fact the test found**: `product_batches.expiry_date` is `NOT NULL`, so
  the function's `is not null` guard is a mirror of the column rather than a live
  branch. The test asserts the column's nullability instead of inventing a fixture
  the schema forbids.
- **D-047** records the shape: an alert is a *question* answered by an RPC, a
  notification is an *event* stored as a row. That is what keeps D-046's "alerts
  appear in the in-app list" honest without materialising state that goes stale the
  moment stock moves.

### A finding from the live data

The alert RPCs answer against the real pharmacy already: its single catalogue product
has `min_stock_level = 20` and no stock, so `low_stock_products()` returns it with a
shortfall of 20. The alerts are therefore exercisable end to end on live data without
any credential, which is the opposite of the notifications half (no WhatsApp account,
no SendGrid key, no recipient phone numbers — D-046).

### Gate output at the end of part 1

```
supabase db push --dry-run                     -> Would push: 20260919000027_… ; then "up to date"
supabase db push --yes                         -> Applying migration …00027…, Finished
supabase db query --file supabase/tests/phase5_alerts.sql
                                               -> SUMMARY: 25 PASS / 0 FAIL of 26 assertions
deno test supabase/functions                   -> ok | 92 passed | 0 failed
deno check ×3 (ocr, match, backfill)           -> clean
dart format lib test                           -> 383 files, 0 changed
dart run custom_lint / flutter analyze         -> No issues found!
flutter test                                   -> +493: All tests passed!
```

**No Dart changed in part 1**, so the 493 tests are the same ones C2 left.

---

## Chat 4 Progress — Chunk C3: the embedding backfill [DONE, live]

C3 is the leg that was answering nothing: `products.embedding is null` on every real
row. It ships two migrations, one Edge Function and 11 Deno tests, and it ends with
the live catalogue embedded, the vector floor re-tuned from measurement, and the
vector leg firing on a real bill's text.

### What C3 delivered

- **`supabase/migrations/20260919000025_phase5_embedding_backfill.sql`, applied.**
  Two functions, no table, no column, no trigger:
  - **`products_to_embed(p_limit int) → {items, remaining, unembeddable}`** —
    `stable security definer`; one batch of the caller's own un-embedded rows with
    the text from `product_embedding_text()` (D-037), the limit applied **after**
    the un-embeddable rows are dropped (so a batch is never short for no reason),
    and a separate count for rows that can never be embedded.
  - **`set_product_embeddings(p_items jsonb) → {written, remaining, unembeddable,
    skipped}`** — `volatile security definer`; each row scoped to
    `get_my_pharmacy_id()`, each value cast by the **database** from the vector's
    own text form rather than marshalled by PostgREST (D-027's refusal). A
    non-object entry, a product id that is not a uuid, an embedding that is not
    exactly 768 numbers, and a product that is not in this catalogue are skipped
    with a reason; `remaining` is computed after the writes, so the operator's next
    step is one number.
- **`supabase/migrations/20260919000026_phase5_vector_floor.sql`, applied** — 00023's
  `match_products` **verbatim** with one constant moved: the vector floor is **0.78**,
  measured (D-044). A new migration rather than an edit of 00023, for D-013's reason.
  Verified byte-identical apart from the floor block before it was applied.
- **`supabase/functions/backfill-embeddings/`** (`index`, `deps`, `handler`,
  `handler_test`) — deployed, `verify_jwt` on. **One invocation embeds one batch**
  (20 by default, clamped at 100) in one `batchEmbedContents` request, writes it, and
  answers `{embedded, remaining, unembeddable, skipped, model}`. No internal loop. A
  model failure, a short answer or a hole in the batch refuses the batch **whole** and
  writes nothing — deliberately stricter than `match-product`, which degrades.
- **`supabase/tests/phase5_embedding_backfill.sql`** — 34 PASS / 0 FAIL, atomic and
  self-rolling-back: the read's scope and shape, the write's cast and its four
  refusals, tenant isolation **both ways** (the foreign row is checked after
  `reset role`, because RLS hides it from the caller — which is the point), the
  `unembeddable` count, resumability, and **the vector leg of a real
  `match_products` call firing on a row this pair wrote**, with no model involved.
- **`make backfill`** — one batch per invocation, token read from
  `SUPABASE_USER_TOKEN`, and `@`-prefixed so make cannot echo the expanded command
  line (which would print the token). `deno check` for the new entry point added to
  the Makefile's `test-functions` and to `HANDOFF_PROTOCOL.md`'s gate block.

### The live run, and the measurement that changed a constant

The operator's loop, run against the real pharmacy (`Arihant Pharmacy`) with a
session token from the app:

```
counts before:  1 product, 1 un-embedded, 0 aliases
POST backfill-embeddings {"limit":20} -> {"embedded":1,"remaining":0,"unembeddable":0,"skipped":[],"model":"gemini-embedding-001"}
POST backfill-embeddings {"limit":20} -> {"embedded":0,"remaining":0,...}      <- resumes, and spends nothing
counts after:   1 product, 0 un-embedded
```

Then the floor re-tune. With the floor temporarily lowered to **0.01** (a
`pg_get_functiondef` patch, one word, restored by migration 00026) nine real invoice
texts were measured against the real catalogue vector:

```
'Dolo 650 Tab'        -> trigram 1.0000
'DOLO 650'            -> trigram 1.0000
'Dolo650Tab15s'       -> vector  0.8280   <- the real product, run together
'Dolo 125'            -> vector  0.7216   <- a strength the pharmacy does not stock
'Dolo 500'            -> vector  0.7084   <- a strength the pharmacy does not stock
'Paracetamol 500mg'   -> vector  0.6695   <- same molecule, another brand
'Amoxyclav 625 10s'   -> vector  0.5780
'Cetirizine 10mg Tab' -> vector  0.5546
'ZZQQ nonsense 9999'  -> vector  0.5364   <- junk
```

**At 0.7 two wrong strengths scored above the floor** and were offered as
high-confidence suggestions. 0.78 sits in the window the data leaves
(0.7216, 0.8280) — D-044. The live probe after the re-tune:

```
'Dolo650Tab15s'       -> dolo 650, reason vector,  score 0.8280     (kept)
'Dolo 650 Tab'        -> dolo 650, reason trigram, score 1.0000     (exact)
'Dolo 500'            -> dolo 650, reason trigram, score 0.5556     (weaker, labelled)
'Paracetamol 500mg'   -> dolo 650, reason trigram, score 0.6667     (weaker, labelled)
'Cetirizine 10mg Tab' -> no candidates
'ZZQQ nonsense 9999'  -> no candidates
```

Note what that says precisely: the re-tune removes the vector leg's **high-confidence
wrong** claim, not the trigram leg's honestly-labelled weaker one. Two thresholds,
two jobs, and both reasons are visible in the app (D-039).

### Gate output at completion

```
supabase db push --dry-run                     -> Would push: …00025…, then …00026…; finally "up to date"
supabase db push --yes                         -> Applying migration …  , Finished (twice)
supabase db query --file supabase/tests/phase5_embedding_backfill.sql
                                               -> SUMMARY: 34 PASS / 0 FAIL of 35 assertions
supabase db query --file supabase/tests/phase5_match_products.sql
                                               -> 43 PASS / 0 FAIL (the boundary vectors moved with the floor)
deno test supabase/functions                   -> ok | 92 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts  -> clean
deno check supabase/functions/match-product/index.ts      -> clean
deno check supabase/functions/backfill-embeddings/index.ts -> clean
dart format lib test                           -> 383 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> wrote 55 outputs
dart run custom_lint                           -> No issues found!
flutter analyze                                -> No issues found!
flutter test                                   -> +493: All tests passed!
```

Live state afterwards: floor 0.78, trigram 0.35, **1 product embedded, 0
un-embedded** — the whole live catalogue.

### Tests — 11 added, none changed

`supabase/functions/backfill-embeddings/handler_test.ts`: one batch and the exact
texts sent, a model failure that writes nothing, a provider refusal as retryable, a
short answer refused rather than half-written, nothing-to-do costing no model
request, a write that skipped a row reported back, the batch size used and clamped,
a body that cannot be read, a caller with no pharmacy refused before any work, GET
refused / OPTIONS preflighted, and `readLimit`'s clamps. Plus the new SQL test's 35
assertions. **No Dart changed in this chunk**, and the existing tests (including the
43-assertion matcher test, whose synthetic boundary vectors were re-picked for the
new floor) still pass.

---

## Chat 4 Progress — Chunk C2: the seam, the suggestions, and alias learning [DONE]

C2 is the app's half of the matcher: the Dart seam over `match-product`, the
suggestions the verify screen offers, and the write that teaches the database what
the human confirmed. It ships one migration, four new Dart files, and 40 new tests.

### What C2 delivered

- **`supabase/migrations/20260919000024_phase5_alias_learning.sql`, applied and
  live.** One function, no table, no column, no trigger, nothing that moves stock:
  - **`learn_product_aliases(p_aliases jsonb) → {learned, skipped}`** — `volatile
    security definer`, `search_path` pinned, `authenticated` only (no `anon`). The
    tenant is `get_my_pharmacy_id()`, never an argument, and every statement carries
    it explicitly because a definer function is not subject to RLS. The text is
    normalized **server-side** by `normalize_product_name()`; a product id that is
    not this pharmacy's, a supplier id that is not ours (read as "no supplier"), a
    blank or punctuation-only text, and a non-object entry are **skipped with a
    reason**, never raised — a bill that cannot teach is not a failure. A
    supplier-scoped row upserts on the existing unique key; a NULL-supplier row is an
    explicit update-then-insert, because that index cannot converge NULLs (N-5 —
    sidestepped inside the new function, **not** fixed: `addAlias` and the index are
    untouched).
- **`supabase/tests/phase5_learn_product_aliases.sql`** — 42 PASS / 0 FAIL of 43
  assertions, atomic, self-rolling-back, impersonating `authenticated` against a
  second tenant. Its strongest assertions are end-to-end: after learning, the
  **alias leg of a real `match_products` call** answers the supplier the alias was
  learned from, does **not** answer another supplier's bill, and does once the same
  text is learned with no supplier. Residue after the run: 0 products, 0 suppliers,
  0 aliases, 0 pharmacies.
- **`lib/services/match_service.dart`** — `MatchService` over
  `functions.invoke('match-product')` plus the `learn_product_aliases` RPC, with
  `decodeProductMatches`, `decodeLearnedAliases` and `matchException` as pure
  functions (the `OcrService` pattern) and `MatchLineRequest`/`ConfirmedAlias` as the
  two payloads.
- **`lib/data/models/product_match.dart`** — plain classes (not Freezed: an RPC
  envelope no migration owns): `ProductMatches`, `ProductMatch`, `MatchCandidate`,
  `MatchEvidence`, `MatchMeta`, `MatchReason`. Candidates are looked up **by
  position** (`candidatesAt`), a candidate with no product id is dropped, and
  `MatchCandidate.reasonLabel` is the sentence a screen shows — *Also called
  DOLO-650 TAB*, *45% similar*, *Looks similar*.
- **`lib/features/purchase_ocr/application/purchase_match_controller.dart`** — one
  batch call per bill, state about *the run* (in flight / the server's warnings /
  why it failed), the answer returned aligned by position, `ref.mounted` after the
  await, and **no automatic retry**.
- **The suggestions, in `ProductPickerField`** — at most `maxSuggestions` (3) rows
  under the field, each with the catalogue name, its pack size and the reason, shown
  only while the line has no product. Tapping one applies it through the same path
  the search dialog uses (`PurchaseLineEditor._applyProduct`), so a suggestion is
  **offered, never applied**; the manual purchase form renders exactly what it did
  before.
- **`_MatchNote` on the verify screen** — one small line above the lines, and only
  when it has something to say: *choose the supplier and these lines will be looked
  up*, *looking these lines up…*, the server's own warning sentences, or *the
  catalogue could not be searched this time…* with a **Look again** action. Nothing
  blocks: the form is live throughout and the save never consults the matcher.
- **Alias learning at save** — one call per bill, after `createPurchase` returns,
  wrapped so a failure can never fail the save, carrying the **printed text held per
  line slot** (not the draft's `productNameRaw`, which a pick overwrites with the
  catalogue's spelling) and the bill's supplier.
- **A defect found and fixed on the way**: `_VerifyFormState` seeded its lines in
  `initState` and never re-seeded, so a *successful* re-read showed the earlier
  parse's lines. The form is now keyed on the parse (`ValueKey(scan.bill)`), with a
  test that a second read replaces the lines.
- **`lib/core/errors/function_error.dart`** — one client-side reader of a function's
  `{error:{code,message}}` envelope; `ocrException` delegates to it (D-042). No
  behaviour change: the OCR mapping's own tests are unchanged and still pass.

### Live, and what the probe settled

The session token the user supplied was used while it was valid, for **read-only**
probes of the deployed `match-product` (nothing was written to the database):

```
POST match-product  {"lines":["Dolo650Tab15s","AMOXYCLAV 625 10S","ZZQQ nonsense 9999"]}
200 OK   Access-Control-Allow-Origin: *
{"matches":[{"raw_name":"Dolo650Tab15s","candidates":[
   {"name":"dolo 650","score":0.4545,"reason":"trigram","evidence":{"similarity":0.4545},
    "is_active":true,"pack_size":"15","product_id":"1ac034e9-…","generic_name":"paracetamol"}]},
  …], "meta":{"model":"gemini-embedding-001","line_count":3,"embedded":3,"vector_used":true}}
```

- **The embedding call is now live-verified** — the model name, the
  `batchEmbedContents` body and the 768-dimension parse, which C1 left unverified.
- **CORS on the 200 path** — D-038 could only cite the 401, the 400 and the
  preflight. (Verified with `curl`, not a browser: the standing preference for this
  host.)
- **The vector leg answered nothing** — `products.embedding is null` on every real
  row, exactly as D-037 predicted, and the reason C3 exists.
- **The embedding quota measured**: 6 single-line requests and then 4 × 20-text
  batches (80 texts) inside ~3 minutes, all 200 with `vector_used: true`, no refusal.
  The embedding metric is **not** the reader's 5/minute (D-041).

### Gate output at completion

```
supabase db push --dry-run                     -> Would push: 20260919000024_… ; then "up to date"
supabase db push --yes                         -> Applying migration …00024…, Finished
supabase db query --file supabase/tests/phase5_learn_product_aliases.sql
                                               -> SUMMARY: 42 PASS / 0 FAIL of 43 assertions
                                                  (exit 1 is the test's own rollback RAISE)
deno test supabase/functions                   -> ok | 81 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts  -> clean
deno check supabase/functions/match-product/index.ts      -> clean
dart format lib test                           -> 383 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> wrote 63 outputs
dart run custom_lint                           -> No issues found!
flutter analyze                                -> No issues found!
flutter test                                   -> +493: All tests passed!
```

### Tests — 40 added, none changed

`test/data/models/product_match_test.dart` (the live 200 body decoded verbatim, the
tolerant paths, the alignment, every reason sentence), `test/services/match_service_test.dart`
(the two decoders and the exception mapping, including a gateway body), `test/features/purchase_ocr/application/purchase_match_controller_test.dart`
(one call per bill, alignment with a blank line, a failure that is not retried,
nothing asked when no line has text, the server's warnings, the mount guard),
`test/features/purchase/presentation/product_picker_field_test.dart` (the ranked head
with reasons, the cap at three, offered-not-applied, no rows when nobody can accept
one, the field still opening the search), and seven new cases on
`purchase_ocr_screen_test.dart` (the ask waits for the supplier, a tapped candidate
fills the line, **a bill saves with the matcher held open**, a failed match still
saves, warnings shown, the learning payload, a failed learning write, and the second
read replacing the lines). `test/support/fake_match_service.dart` is the new fake;
`FakePurchaseOcrRepository.bill` became mutable so a second read can differ.

---

## Chat 4 Progress — Chunk C1: the matcher [DONE, server-side]

Chunk C (smart matching) split three ways: **C1 is the matching capability and its
SQL test** (this section), **C2 is the app's seam, alias learning and the picker's
suggestions**, **C3 is the `products.embedding` backfill**. C1 ships no Dart and
touches no widget: it is the capability the screen will call.

### What C1 delivered

- **`supabase/migrations/20260919000023_phase5_product_matching.sql`, applied and
  live.** Two functions, no table, no column, no trigger, nothing that moves stock:
  - **`product_embedding_text(name, generic_name, pack_size)`** — the one
    catalogue-text convention (D-027 named it as Chunk C's decision). It lives in
    the database rather than in the Edge Function so the backfill cannot drift from
    the match: the backfill embeds what this returns. The **query** side is
    deliberately not built by it — the query is the invoice text as printed, which
    is the whole reason the vector leg copes with a supplier's abbreviation.
  - **`match_products(p_queries jsonb, p_limit int)`** — one `stable security
    definer` RPC for a whole bill, returning `[{ raw_name, candidates: […] }]` in
    the order it was asked. Three legs, each candidate carrying `reason` and the
    evidence for it (`alias_name`, `similarity`, `distance`):
    1. **alias** — an exact `normalize_product_name()` hit in `product_aliases`,
       score 1.0 because a human confirmed it. Scoped to the supplier **or** to no
       supplier: an alias learned for one distributor deliberately does **not**
       answer the same printed text on another's bill, and what crosses suppliers
       is a pharmacy-wide (supplier-less) alias.
    2. **trigram** — `greatest(similarity(name, raw), similarity(generic, raw),
       word_similarity(name, raw))`, threshold 0.35.
    3. **vector** — cosine distance over `products.embedding`, floor 0.7, and only
       when the caller supplied a query embedding.
- **The two measured facts that shaped it** (probed on the live database before the
  migration was written, not assumed): `similarity('Dolo650Tab15s','Dolo 650')` is
  **0.278** — below pg_trgm's own 0.3 default — while
  `word_similarity('Dolo 650','Dolo650Tab15s')` is **0.455**, so the reversed
  direction is what reads a supplier's run-together name and 0.35 is the threshold;
  and `Dolo 650` scores 0.4545 against that text while `Dolo 500` scores 0.4444 — a
  0.01 margin, so **trigram cannot choose between siblings and the vector leg has
  to be able to outrank it**. Ranking is therefore by **score**, with the leg as an
  ordered tiebreak (0 scoped alias, 1 pharmacy-wide alias, 2 trigram, 3 vector);
  ranking by leg would have made every trigram hit beat every vector hit, which is
  exactly the case the vector leg exists for.
- **Never `select *` on `products`** — candidates are built from named columns, and
  the SQL test asserts no payload carries `embedding` (D-027).
- **`supabase/tests/phase5_match_products.sql`** — 43 assertions, atomic and
  self-rolling-back, impersonating `authenticated` with a second tenant whose
  product is named *identically* and embedded *identically* to the query vector.
- **`supabase/functions/match-product/`** — `index.ts` + `deps.ts` + `handler.ts`,
  deployed. One bill is **one embedding call** (`batchEmbedContents`, the whole
  bill in one request — N-2's free tier) and **one RPC call**; the tenant is never
  an argument; a blank line keeps its position; a supplier id that is not a uuid
  does not travel; and an embedding failure **never fails the bill** — it degrades
  to alias+trigram and says so in `meta.warnings`.
- **`supabase/functions/_shared/embedding.ts`** (the convention, the dimension
  pinned at 768, `RETRIEVAL_DOCUMENT`/`RETRIEVAL_QUERY`) and
  **`_shared/gemini.ts`** (one poster, so two functions cannot answer a provider
  failure in two dialects; `ocr-purchase-bill` was left alone rather than refactored
  in place — it is deployed and live-verified).

### Gate output at completion

```
supabase db push --dry-run                       -> Would push: 20260919000023_…
supabase db push --yes                           -> Applying migration …00023…, finished
supabase db query --file supabase/tests/phase5_match_products.sql
                                                 -> 43 assertions, PASS 43 / FAIL 0
                                                    (exit 1 is the test's own rollback RAISE)
deno test supabase/functions                     -> ok | 81 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts  -> clean
deno check supabase/functions/match-product/index.ts      -> clean
dart format lib test                             -> 372 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> wrote 0 outputs (nothing stale)
dart run custom_lint                             -> No issues found!
flutter analyze                                  -> No issues found!
flutter test                                     -> +453: All tests passed!
```

Residue after the SQL test: 0 ZZTEST products, 0 ZZTEST pharmacies, 0 aliases,
0 embedded products (the test rolls itself back).

### Live, and what is *not* live

- **Deployed**: `supabase functions deploy match-product` → deployed, `verify_jwt`
  on, alongside `ocr-purchase-bill` (v4).
- **Invoked live**: a POST with the publishable key and a valid-JWT caller that has
  no pharmacy answered
  `{"error":{"code":"unauthorized","message":"This account is not linked to a pharmacy yet."}}`
  — the deployed handler's own envelope, from `requirePharmacyId`, and a 400 for
  `{"lines":[]}` — so the gateway, the handler, the caller-scoped client and the
  error vocabulary are all live.
- **Not yet live: the embedding call, and therefore the observed quota.** The full
  probe needs a signed-in user of a pharmacy, and the hosted project requires email
  confirmation (N-7), so the throwaway account the probe creates cannot sign in —
  and confirming it by hand is an auth-weakening write to production that the guard
  correctly refuses. **The model name, the `batchEmbedContents` shape and the
  free-tier embedding quota are therefore still unverified live**, which is exactly
  the class of thing D-030 says a live call has to settle. It is the first task of
  C3 (whose function makes embedding calls anyway), or one approved confirm call.
  **[Settled in C2 and C3: the call is live-verified, the model is
  `gemini-embedding-001`, and the embedding metric is not the reader's 5/minute —
  see the C2 and C3 sections below and D-041.]**
- **A CORS scare that was a misreading, recorded so nobody chases it**: N-6 claimed
  a live response carried no `access-control-allow-origin`. It does — the gateway
  emits it capitalised and my case-sensitive filter hid it. Re-measured with full
  header dumps on the 401, the 400 and the preflight; **no code changed and nothing
  was redeployed**. D-038 carries the contract and the recipe.

### Decisions added

D-036 (the match is one RPC, ranked by score with the leg as attribution, both
thresholds measured), D-037 (the catalogue-text convention is a database
function, and the query text keeps its word boundaries) and D-038 (CORS is emitted
by the platform on every path; the verification must not be case-sensitive).

## Chat 4 Progress — Chunk B2b: the verify screen and the save [DONE]

**Chunk B is complete.** B2b is the part a user touches: choose a bill, check what
was read, and save a draft through the manual form's own controller.

### What B2b delivered

- **`features/purchase_ocr/presentation/purchase_ocr_screen.dart`** — three states,
  each with something to say:
  - **Choose a bill** — *Take a photo* / *Choose a file*, the 10 MB and file-type
    facts, and the one instruction that matters: *fill the frame with the item
    table*. It also says plainly which of the two failures happened — "that bill
    did not upload" versus "that bill could not be read" — because the retry
    differs and only one of them is worth retrying.
  - **Reading** — "Reading the bill…" and, when the reader was busy and the retry
    is running, **"The bill reader is busy — retrying…"** (D-033's visible wait).
  - **Verify** — the image beside what was read, `meta.warnings` and the
    truncation note shown rather than logged, the header editable (supplier,
    invoice number, invoice date, notes), a line editor per line with the batch and
    expiry fields a receipt needs, a product picker on every line (matching is
    Chunk C, so a human chooses), the totals from `PurchaseTotals`, and the
    reader's own total shown *beside* them, labelled as what was printed rather
    than what will be saved.
  - The save calls `purchaseFormControllerProvider.createPurchase(header:, lines:)`
    — the same controller the manual form uses — which writes a **draft**; it then
    invalidates the list and the document and goes to `Routes.purchaseDetail`, where
    the existing GRN step is one tap away. Nothing in this feature writes a purchase
    row itself (D-011/D-013).
- **`data/bill_picker.dart`** — `BillPicker` + `PickedBill` + `billPickerProvider`,
  the seam `image_picker` sits behind (D-035). `PurchaseOcrController.pickBill`
  now owns the decisions that were tempting to put in the widget: an untyped file
  is typed from its name (`mimeForFileName`, added to the repository with tests),
  and a file the bucket would refuse is turned away before the round trip.
- **`Routes.purchaseOcr = '/purchase/ocr'`**, declared in `app_router.dart` ahead of
  the parameterised purchase routes (so `ocr` is never read as a purchase id) and
  offered on the purchase screen as a third way in, beside *Receive goods* and
  *New* (D-022: the rail stays on Purchase).
- **A correctness fix the screen exposed:** a *first* read that failed used to lose
  the uploaded path, so "read it again" had nothing to read. `OcrScan.bill` is now
  nullable and the scan survives the failure, which is what makes D-033's "never
  uploads a second copy" true for that case too (recorded in D-033's consequences).

### Tests — 11 added, none changed

`test/features/purchase_ocr/presentation/purchase_ocr_screen_test.dart` (the two
ways in and what the screen warns about, a picked bill read into a correctable form,
warnings and truncation shown, **the retrying state caught mid-flight**, a busy
reader offered another go without being called an unreadable bill, a file the reader
cannot open turned away before any upload, and the save's payload — supplier,
invoice number, the line's product, quantity, free quantity, batch and expiry —
followed by the navigation to the document); one test on the purchase screen for the
new entry point; `mimeForFileName` at its boundaries; and a controller test for the
failure-then-retry path above. `test/support/fake_bill_picker.dart` and
`test/support/purchase_ocr_test_app.dart` follow the existing support shape, and
`purchase_test_app.dart` gained the OCR overrides a tap on its new action now needs.

### Gate output at completion

```
deno test supabase/functions                    -> ok | 45 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts -> clean
dart format lib test                            -> 372 files, 0 changed
dart run custom_lint                            -> No issues found!
flutter analyze                                 -> No issues found!
flutter test                                    -> +453: All tests passed!
```

(442 before; 453 now — 11 added, none changed.)

### Decisions added

D-035 (a platform capability the app cannot fake gets a seam), and D-033 gained the
consequence that a failed first read still leaves the bill uploaded.

## Chat 4 Progress — Chunk B2a: the OCR Dart seam [DONE]

Chunk B's second half split again at its own natural seam: **B2a is everything
below the HTTP boundary and above the UI** — the envelope, the service, the
repository (upload + invoke) and the controller — and **B2b is the verify screen,
the save, the route and the widget tests.** No widget was added in B2a, and nothing
in the Flutter tree calls the reader yet.

### What B2a delivered

- **`data/models/ocr_purchase_bill.dart`** — `OcrPurchaseBill`, `OcrDocument`,
  `OcrLine`, `OcrMeta` as **plain classes** (`ReportSummary`'s precedent: an RPC
  envelope, no migration owns its shape). `fromJson` is the decode the function's
  200 body gets, and it is as tolerant as the function's own normalizer: a number
  may arrive as `num` or as text — including `1,25,000`, read with the *same*
  separator rule the function uses, because two sides that disagree about a number
  are two answers to one question (D-030) — a blank string is no value, an
  unreadable date is `null` rather than a guess, and junk where a part should be
  never throws. `toLineDrafts()` turns the lines into the `PurchaseLineDraft`s the
  purchase form already uses, with `productId: null` (matching is Chunk C, so a
  human picks) and `qty: 0` where the reader read nothing — so the form's own rule
  refuses the line until somebody says what it was.
- **`services/ocr_service.dart`** — the stub implemented (and its hand-written
  `Provider` converted to codegen, which D-1's list asked for). The wire mapping is
  **two pure functions**, which is where the interesting behaviour lives:
  `decodeOcrBill` for the 200 body and `ocrException` for a failure, which keeps
  the function's sentence and code verbatim (`check_violation`'s rule, one layer
  out) and maps them onto the app's exception types. `isRetryableOcrError` is the
  single place that decides what deserves another try.
- **`features/purchase_ocr/data/purchase_ocr_repository.dart`** — the upload
  (`<pharmacy_id>/<year>/<file>`, D-028) and the call. The bucket's limits are
  mirrored as **tested statics** (`validatePick`, `maxBillBytes`,
  `allowedMimeTypes`, `storagePath`, `newBillFileName`), enforced inside the write
  as well as available to a screen, so a screen that forgets to ask cannot upload
  something the bucket will refuse afterwards; the bucket stays the authority and
  its refusal is surfaced verbatim.
- **`features/purchase_ocr/application/purchase_ocr_controller.dart`** — the flow
  and **the retry (D-033)**: `attempts = 2`, `isRetrying` as state distinct from
  "busy" so a screen can say *"the reader is busy — retrying…"*, a wait that is a
  provider (`ocrRetryDelayProvider`, 3 s) so tests do not sleep, and `rescan()`
  which re-reads the stored object rather than uploading a second copy.

### The finding that came with it

**D-034: a controller must check `ref.mounted` after an await before writing
state.** Riverpod 3 disposes a provider with no listeners, so a screen that
navigates away mid-upload stops being a listener and the next `state = …` throws
from a future nobody awaits — which is exactly what three of the new tests caught:

```
Cannot use the Ref of purchaseOcrControllerProvider after it has been disposed.
```

Every guard now sits after each await (in the retry loop that also stops a second
call being spent on a shared quota for nobody), and the tests keep the provider
alive the way a screen does — `container.listen(...)` in the container helper, plus
one test that deliberately does **not**, to pin the guard.

### Tests — 13 added, none changed

`test/data/models/ocr_purchase_bill_test.dart` (the decode against **Chunk B1's
observed wire body**, text numbers, the Indian separator, nulls staying null, junk
tolerated, `toLineDrafts`), `test/services/ocr_service_test.dart` (both pure
mappers, every code the deployed function and the platform produced, retryability),
`test/features/purchase_ocr/data/purchase_ocr_repository_test.dart` (the mirrored
limits at their boundaries, the path shape, the file name), and
`test/features/purchase_ocr/application/purchase_ocr_controller_test.dart` (the
upload-then-read flow, the file the bucket would refuse never reaching the reader,
**the retry being visible while it waits**, a third attempt *not* happening, the
non-retryable failures not being retried, `rescan` not re-uploading, a failed
re-read keeping the first parse on screen with its error set — T-3's shape — and
the disposed-provider guard). Plus `test/support/fake_purchase_ocr_repository.dart`,
which runs the real upload rule and builds the real path shape.

### Gate output at completion

```
deno test supabase/functions                    -> ok | 45 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts -> clean
dart format lib test                            -> 0 changed
flutter analyze                                 -> No issues found!
flutter test                                    -> +442: All tests passed!
make test-functions                             -> both of the above
```

(397 before; 442 now — 45 added across B2a: 32 for the envelope, the mappers and
the upload rules, then 13 for the controller. No existing test changed.)

### Decisions added

D-033 (the retry lives in the app, with a visible wait) and D-034 (`ref.mounted`
after an await).

## Chat 4 Progress — Chunk B1: the OCR Edge Function [DONE, live-verified]

Chunk B (the AI OCR core) split in two, as its brief allowed: **B1 is the server
side and is finished; B2 is the Flutter seam and the verify screen.** `supabase/functions/`
now exists.

### What is deployed

`ocr-purchase-bill` — POST `{ "path": "<pharmacy_id>/<year>/<file>" }` → the bill's
document, its lines, and `meta { model, warnings, image_path, finish_reason }`, or
`{ error: { code, message } }`. It writes nothing: creating the purchase is the
app's job through `PurchasesRepository` (D-011/D-013).

- `_shared/` — the error vocabulary (`FunctionError`, `failJson`'s status map),
  the JSON envelope **with CORS headers** (a Flutter web build calls this
  cross-origin; without them the browser reports an opaque network failure), the
  caller-scoped client (`userClient` + `requirePharmacyId` via the
  `get_my_pharmacy_id()` RPC — never `service_role`, D-004), and `base64.ts` (D-031).
- `ocr-purchase-bill/gemini.ts` — the prompt, the response schema, the request
  builder, and the **defensive normalizer** that turns the model's reply into the
  envelope: numbers written as text (`"₹1,120.00"`, `"1,25,000"`), a fractional
  quantity rounded *and said so*, `DD/MM/YYYY` read day-first *and said so*, an
  unreadable date left null rather than guessed, an invented empty row dropped,
  and a lost answer reported as `finish_reason` rather than looking like an empty
  bill.
- `ocr-purchase-bill/handler.ts` + `deps.ts` + `index.ts` — the request path with
  every effect injected, so a stub-driven test covers it; the order is
  security-relevant and pinned: **the tenant comes from the caller's identity and is
  compared with the path before anything is read**, and the size is checked before
  the model is paid for.

### Verified live, not just locally

`deno check` + **45 Deno tests** (`deno test supabase/functions/_shared/base64_test.ts
supabase/functions/ocr-purchase-bill/gemini_test.ts supabase/functions/ocr-purchase-bill/handler_test.ts`
→ `ok | 45 passed | 0 failed`), then three deploys and a real invocation through a
throwaway tenant created by public signup (deleted afterwards):

```
POST /functions/v1/ocr-purchase-bill  {"path":"<pharmacy>/2026/zztest-bill-5841-d.pdf"}
200
{ "document": { "supplier_name": "ARIHANT DISTRIBUTORS", "gstin": "27ABCDE1234F1Z5",
                "invoice_no": "INV-2026-0042", "invoice_date": "2026-09-18",
                "sub_total": 2420, "tax_total": 264.5, "grand_total": 2684.5 },
  "lines": [ { "raw_name": "Dolo 650 Tab 15s", "qty": 10, "free_qty": 1, "rate": 100,
               "mrp": 150, "gst_percent": 12, "batch_no": "D650-A21",
               "expiry_date": "2027-06-30", "hsn_code": "3004", "confidence": 0.95 },
             { "raw_name": "Amoxyclav 625 10s", ..., "expiry_date": "2026-12-31" },
             { "raw_name": "Cetirizine 10mg 10s", "qty": 20, "free_qty": 2,
               "rate": 18.5, "mrp": 30, "gst_percent": 5,
               "expiry_date": "2027-02-28", "confidence": 0.95 } ],
  "meta": { "model": "gemini-3.6-flash", "warnings": [], "image_path": "...",
            "finish_reason": "STOP" } }
```

Every header field, every line, and `30/06/2027` → `2027-06-30` — the day-first
conversion D-020's money rules would have had to live with. **Residue check after
cleanup: one pharmacy (the real one), one user, zero stored bills.**

### Three findings worth more than the feature

1. **`Uint8Array#toBase64` does not exist in the deployed runtime** (it is a TC39
   proposal). It passed `deno check` — the *type* is in Deno 2.9's libraries — and
   passed all 45 local tests, and then answered `500` in production. Cost: three
   deploys and a bisect through the deployed function to find it. Recorded as
   **D-031** with the rule that follows: `supabase/functions/` uses language-core
   JavaScript only.
2. **The model name in the brief's plan was already dead.** The first live call
   answered `404 "models/gemini-2.5-flash is no longer available to new users.
   Please update your code to use models/gemini-3.6-flash"` — the API naming its own
   successor. A live invocation is now the verification step for any model change
   (**D-030**).
3. **The key is free-tier: five requests a minute**, and a burst is shed as
   `503 UNAVAILABLE` rather than `429` — so a double-tapped retry or a burst of
   bills fails as "the reader is busy". The reader does **not** retry internally, on
   purpose (**D-032**, open item **N-2**). Most of this chunk's 503s were this
   quota, not the model being down.

**A capture-UX finding for B2:** the first live read of the same invoice (9 pt table
text in a generated PDF) returned the header and the tax total and *no line items*,
with honest warnings; after the table text was made 12 pt (and a "read every row"
instruction and an explicit `maxOutputTokens` were added in the same change) the
same bill parsed completely. Three things changed at once, so this is not isolated
to the font — but a marginal legibility failure is exactly what the warnings are for,
and the verify screen should tell the user to photograph the table closely.

### Gate output at completion

```
deno check supabase/functions/...                   -> clean
deno test (base64, gemini, handler)                -> ok | 45 passed | 0 failed
dart format --output=none --set-exit-if-changed    -> 355 files, 0 changed
flutter analyze                                    -> No issues found!
flutter test                                       -> +397: All tests passed!
supabase functions deploy ocr-purchase-bill        -> deployed (728 kB)
```

(Flutter test count unchanged at 397 — Chunk B1 changed no Dart product code. The 45
Deno tests are new and **not** in the five gates yet: open item **N-3**.)

### Decisions added

D-030 (the model is named in code and a change is verified live), D-031 (no
proposal-stage built-ins in a function), D-032 (the reader does not retry, and why).

## Chat 4 Progress — Chunk A: Phase 5 database foundation [DONE]

Phase 5 is built in chunks, each ending gated. **Chunk A is the storage layer** —
the objects the AI features read and write. No matching, OCR or dispatch logic
yet; that is chunks B-E.

### Migration `20260919000022_phase5_ai_notifications.sql`

Applied and verified on the hosted project (`supabase migration list`: 22/22 local
and remote match). A new file, never an edit to an applied one (D-013) — 00021 was
the head.

- **pgvector**, installed into the `extensions` schema and referenced qualified, so
  nothing depends on `postgres`'s search_path.
- **`products.embedding`** — `extensions.vector(768)`, nullable (`NULL` is the
  backfill's work list), with an HNSW index over cosine distance, partial on
  `embedding is not null`. `gemini-embedding-001`; the dimension is effectively
  permanent (D-027).
- **`device_tokens`** — one row per device a notification can reach. `token` is
  unique table-wide, so a device that changes hands is re-pointed rather than
  duplicated. RLS is both tenant- *and* user-scoped: a token is a way to reach a
  physical device, so a colleague is not entitled to enumerate or revoke it. A
  server-side fan-out will read tokens through a `security definer` RPC rather than
  by widening that policy.
- **`notification_logs`** — what was dispatched, to whom, over which channel, and
  what the provider did with it: the delivery record an operator audits, beside
  `notifications`, which is the user-addressed in-app list a recipient reads.
  Select/insert/update policies and **no delete policy** — a log a client can erase
  is not a log, and the assertion is that a delete affects 0 rows rather than that
  it raises.
- Three new enums (`device_platform`, `notification_status`,
  `notification_recipient_type`); `notification_channel` from 00002 is reused so
  the in-app list and the dispatch log cannot disagree about what `'whatsapp'`
  means.
- **The `purchase-bills` bucket** — private, capped at 10 MB, mime-restricted, with
  four `storage.objects` policies comparing the object's first path segment with
  `get_my_pharmacy_id()` (D-028). Created by the migration, because a
  `config.toml` bucket block only seeds a local stack this project does not run.

### Verified by `supabase/tests/phase5_ai_notifications.sql` — 29 assertions

Atomic, self-rolling-back, and it impersonates the way `profile_privileges.sql`
does. All 29 PASS against the live database, and the residue check afterwards
reported zero ZZTEST pharmacies, zero device tokens, zero dispatch rows and zero
stored objects. It proves, among others: the column really is
`extensions.vector(768)` and a 769-dimension write is **refused by the type**;
`product_stock` does **not** carry the new column yet still resolves for the caller
(D-021's trap); a token cannot be registered twice, against another tenant, or on
behalf of another user, and another user's token in the same pharmacy is invisible;
a foreign tenant's dispatch history is invisible; a delivery record survives a
client `DELETE` (0 rows deleted, still there); and an object is writable only under
the caller's own pharmacy folder.

Three facts the test needed were **probed rather than assumed**, in a throwaway
script that raised and rolled back: the vector column's `atttypmod` is 768; an
`auth.users` insert auto-creates a profile, which is how the test gets a second
user in the same tenant; and `storage.objects` accepts a direct insert that the
policy then filters. The probe file was deleted.

### Flutter — two models, and one payload fix the migration caused

- `data/models/device_token.dart` — `DeviceToken` plus the `DevicePlatform` enum,
  its DB-literal round-trip and its converter, in the shape `ScheduleType` and
  `LedgerReferenceType` already use.
- `data/models/notification_log.dart` — `NotificationLog` plus
  `NotificationChannel`, `NotificationStatus` (with `isSettled`) and
  `NotificationRecipientType`. An unknown status decodes as `failed`, not `sent`:
  the safe reading of an outcome this build does not understand is the one that
  prompts a look.
- **`ProductsRepository.columns` / `.projection`** — every `products` read now names
  its columns instead of taking PostgREST's `*`, which would otherwise have
  returned roughly 8 kB of floats per row on the product list, the product detail
  and every picker that names a product. Four call sites changed (`list`, `byId`,
  `create`, `update`); the two view reads are untouched because neither
  `product_stock` nor `batch_status` carries the vector. Recorded, with the
  alternative that was rejected and the reason, as D-027.

### Tests

15 added, none changed:

- `test/data/models/device_token_test.dart` — the decode, the defaults, the enum's
  round-trip and its case-insensitive fallback.
- `test/data/models/notification_log_test.dart` — the decode, the defaults, the
  three enums' round-trips, `in_app` as the stored literal, the unknown-status
  fallback, and `isSettled`.
- `test/features/products/data/products_repository_columns_test.dart` — the
  projection never asks for `embedding`, and is exactly the set of keys
  `Product.fromJson` decodes, so the two cannot drift apart silently.

### Gate output at completion

```
dart format lib test                      -> 3 changed, then 0 (tree is formatter-clean)
dart run build_runner build --delete...   -> wrote 164 outputs (T-1 SDK notice only)
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +397: All tests passed!
```

(382 before; 397 now — 15 added, none changed.)

### Decisions added

D-026 (the chatbot answers through RPCs, never free-form SQL — and the four RPCs it
needs give **I-1** its server-side fix), D-027 (the embedding, and the explicit
projection that keeps it off the wire), D-028 (the private, path-scoped bill
bucket), D-029 (push deferred to Phase 6 — now open item **N-1**).

## Chat 4 Progress (T-2 closure — Phase 3's tests)

Phase 3 shipped with no Dart tests at all. That gap is closed. **No product code
changed**, so there is no migration and no new decision; the two items the work
turned up are recorded as T-4 and T-5 above.

### Sales — 55 tests

- `sales/data/sale_totals_test.dart` — the money math: line and document totals,
  the discount moving the taxable value, the intra/inter-state split, the two
  halves adding back to the tax (the case where rounding each half independently
  would charge a paisa that was never due), half-away-from-zero rounding at
  `1.005`, and what a tender may record.
- `sales/application/pos_controller_test.dart` — the basket: defaults from the
  batch (counter price, MRP fallback, the common slab, the schedule snapshot), a
  second scan merging into the line already there, a different batch of the same
  product being a line of its own, every edit recomputing the totals, and
  `withCustomer(null)` clearing (the `copyWith` trap).
- `sales/application/sale_checkout_controller_test.dart` — the write: the payload's
  lines and totals, the document totals deliberately **absent** from it,
  availability re-read before the write (a short line never reaches the till), the
  balance-with-no-customer refusal, a credit sale with a customer, an over-tender
  clamped so no negative balance is stored, and a failed write leaving the basket.
- `sales/presentation/pos_screen_test.dart` — the counter: the empty basket with no
  till, the batch chooser (FEFO head marked, and a choice rather than an automatic
  pick), the line rendering, quantity/rate/slab edits moving the bill, the change
  on an over-tender, and a written sale opening its bill.
- `sales/presentation/sales_screen_test.dart` — the list: empty state, rows with
  their customer and status, search narrowing (past the debounce), a status chip,
  the filtered empty state with Clear, and a failed read with a working retry.

### Sale returns — 36 tests

- `returns/application/sale_return_form_controller_test.dart` —
  `SaleReturnableLine.returnable` as `qty - alreadyReturned` (a fully returned line,
  and an over-returned one clamping to 0 rather than going negative), an empty
  `batchId` blocking the line, the proportional slice from the line's **stored**
  `totalAmount`/`taxAmount` (a discounted line, where `qty x rate` would give a
  different and larger answer — D-020's rule), the write's refusals (over the cap,
  empty set, cancelled bill), and restock / refund mode / reason reaching the row.
- `returns/presentation/sale_return_form_screen_test.dart` — the form: the bill
  lookup, the line list with what can still come back, the quantity cap reported at
  the field, submit enabled/disabled, the restock switch, the refund mode, a
  refused write left in place and retried, and a failed line read with a retry.

### Support

Four new doubles and two mini-routers in `test/support/`, all following the
existing shape: `fake_sales_repository.dart` (whose `checkout` sums the payload's
own lines into the document it returns, as `checkout_sale()` does),
`fake_sale_returns_repository.dart` (which re-runs the real cap, blocked-line,
empty-set and cancelled-sale rules), `sales_test_app.dart` and
`sale_returns_test_app.dart`.

### Gate output at completion

```
dart format lib test                      -> 0 changed (tree is formatter-clean)
dart run build_runner build --delete...   -> Built with build_runner; wrote 22 outputs
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +382: All tests passed!
```

(291 before; 382 now — 91 added, none changed.)

## Chat 3 Progress (Phase 3 + Phase 4)

### Migrations 00019-00021 — sale automation, ledger/payments, reporting [DONE]

All three are applied to the hosted project (`supabase migration list`: 21/21
local and remote match) and each has a SQL test in `supabase/tests/`.

- `20260918000019_phase3_sale_automation.sql` — enables the sale side of the
  automation that migration 00010 shipped commented out, in a new file (D-013's
  reasoning, one phase later): `ledger_auto_entry_sale()`,
  `stock_update_on_sale()` (per sale **line**, gated on the parent sale not being
  cancelled) and `write_audit_log()`, plus `stock_restore_on_sale_return()` /
  `ledger_auto_entry_sale_return()`, the `invoice_counters` table that gives a
  POS its per-day invoice number, and `checkout_sale(jsonb)` — the whole sale in
  one transaction. Two deliberate deviations from the shipped bodies: a sale with
  no customer posts nothing (a walk-in owes nothing, and
  `ledger_entries_party_check` needs a party), and the ledger gate is "not
  cancelled" rather than "is completed", so a credit sale posts its receivable
  when it is written rather than when it is settled.
- `20260918000020_phase4_ledger_payments.sql` — corrects two defects 00019 shipped
  with, both found by `supabase/tests/phase3_sale_triggers.sql`: the EXECUTE
  grant `anon` had kept (D-017's trap, again), and an overpayment storing a
  negative `balance_due` (now a `before insert or update` trigger on `sales`).
  It also closes the gap Phase 2 left: a purchase return posts its credit note
  (`reference_type = 'purchase_return'`, at D-020's `grand_total`), and
  `record_payment(...)` writes a payment and its `ledger_entries` row in one
  transaction, taking the tenant from `get_my_pharmacy_id()`.
- `20260918000021_phase4_reporting.sql` — `report_summary(date, date)`, one
  `security definer` RPC returning every figure the reports screen shows as
  `jsonb`. Server-side because PostgREST cannot `sum()`: a total assembled from
  one capped page would be silently short of the truth, which is the one outcome
  a financial report must not have. Verified by
  `supabase/tests/phase4_report_summary.sql` (7 groups of assertions over the
  sales, purchases, returns, expenses, stock and expiry blocks, the window edges,
  and the anon/no-tenant refusals).

### Phase 3 — sales/POS, sale returns, GST billing [DONE, NO DART TESTS]

Delivered by the previous session and gated here as it stood: `features/sales/`
(list with search and status filter, the POS counter over `PosCart` and
`checkout_sale`, bill detail and print) and the sale side of `features/returns/`
(sale-return form with `restock` and `refund_mode`, over
`SaleReturnsRepository`). **It added no Dart tests** — `test/features/sales/`
does not exist — which is open item T-2 below. Its database behaviour is
covered by `supabase/tests/phase3_sale_triggers.sql`.

### Phase 4 — ledger, payments, expenses, reports [DONE]

- `features/ledger/` — `ledger_screen.dart` (supplier/customer segmented picker,
  the selected party's balance and its paged entries, with the direction each
  entry moved money spelled out per party type, and a payment sheet), over
  `LedgerSelectionController`, `LedgerEntriesController`,
  `partyLedgerBalanceProvider` and `PaymentController`. The balance is read from
  `ledger_entries`, not from a stored figure, because the ledger *is* the record.
- `features/expenses/` — `expenses_repository.dart`,
  `expenses_controller.dart` (paged list + the write, which invalidates both the
  list *and* the reports summary), `presentation/expenses_screen.dart` at
  `/reports/expenses`, and `presentation/widgets/expense_sheet.dart` (category
  from the fixed list, amount, mode, date, notes).
- `features/reports/` — `application/reports_controller.dart` (the window, its
  chip presets, and the one-round-trip summary provider) and
  `presentation/reports_screen.dart` (seven cards: sales, purchases received,
  returns, expenses, what the window contributed, stock on the shelf, and
  expiry — each labelled with what it is, and the contributed figure labelled
  with what it is **not**: it knows what was sold and what was spent, and nothing
  about what those goods cost).
- `Routes.expenses` is `/reports/expenses` rather than a top-level `/expenses`,
  so the Reports destination stays highlighted; a path matching no shell
  destination would leave the rail on Dashboard while the user read their
  expenses (D-022).
- `ledger_placeholder.dart` and `reports_placeholder.dart` deleted; `/ledger` and
  `/reports` build the real screens. The unused `routes.dart` import in
  `ledger_screen.dart` and the two analyze errors caused by the missing
  `reports_controller.dart` are fixed.
- Tests: 54 added, none changed — `report_summary_test.dart` (the RPC envelope's
  decode, including numbers that arrive as strings), `reports_controller_test.dart`
  (window arithmetic against fixed dates, the chip presets, the drag-the-other-end
  rule, and the provider), and widget tests for the three screens over new fakes
  and mini-router pump helpers in `test/support/`
  (`fake_ledger_repository`, `fake_expenses_repository`,
  `fake_reports_repository`, `ledger_test_app`, `reports_test_app`).

### PHASE 4 COMPLETE

Gate output at completion:

```
dart format lib test                      -> 0 changed (tree is formatter-clean)
dart run build_runner build --delete...   -> wrote 89 outputs (T-1 SDK notice only)
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +291: All tests passed!
```

(237 at the end of Phase 2; 291 now — 54 added, none changed. Phase 3 contributed
no tests of its own, so 54 is the whole of the increase.)

Seven files the previous session wrote by hand were reformatted by
`dart format` on the way through (`expense.dart`, `ledger_entry.dart`,
`report_summary.dart`, `ledger_controller.dart`, `ledger_screen.dart`,
`payment_sheet.dart`, `reports_repository.dart`); the diffs are wrapping and
annotation placement only, no behaviour.

## Chat 2 Progress (Phase 1 + Phase 2)

### Migration 00015 — Phase 2 automation layer [DONE]

`20260918000015_phase2_extras.sql` applied to the hosted project
(`supabase migration list`: 15/15 local and remote match). Contents:

- `purchases.stock_posted_at` column — one-way stock-posting marker
- `ledger_auto_entry_purchase()` — verbatim from the commented block in
  migration 00010 line 150
- `stock_apply_purchase()` — document-level posting on status -> received
- `stock_apply_purchase_item()` — line-level posting for lines added to an
  already-received document
- `stock_apply_adjustment()` — stock_adjustments rows move their batch
- `stock_update_on_purchase_return()` — returns decrement, oversell raises
- 5 triggers, plus 4 indexes (`purchases_pharmacy_id_pending_stock_idx`
  partial, two pg_trgm on `products.name`/`generic_name`, and the
  `product_aliases` unique key the alias upsert needs)

**Contract:** a purchase reaches `received` once as far as stock is
concerned; draft/ordered lines never move stock; quantity received is
`qty + free_qty`; moving a document back out of `received` does NOT reverse
stock or the ledger (the marker is never cleared).

Verified by `supabase/tests/phase2_stock_triggers.sql` — 15 assertions, all
pass, run with
`supabase db query --linked --file supabase/tests/phase2_stock_triggers.sql`.
The script is atomic and rolls itself back, so it leaves no rows (confirmed:
zero `ZZTEST` rows remain).

**Not enabled:** `ledger_auto_entry_sale()`, `stock_update_on_sale()` and
`write_audit_log()` stay commented for Phase 3. The per-line
`stock_update_on_purchase()` from migration 00010 was deliberately NOT
attached; its semantics are replaced by the two functions above.

### Migration 00016 — landed cost for scheme stock [DONE]

`20260918000016_landed_cost.sql` applied (16/16 migrations match remotely).

- `product_batches.landed_cost_per_unit numeric(12,4)`, backfilled from
  `purchase_rate`
- `product_stock.stock_value_at_cost` now sums
  `qty * coalesce(landed_cost_per_unit, purchase_rate)`; `security_invoker`
  preserved through the `create or replace view`
- `stock_apply_purchase()` and `stock_apply_purchase_item()` re-created to set
  the cost basis as a **moving weighted average** over the units the batch
  holds, not a per-line overwrite (see D-012)
- `ledger_auto_entry_purchase()` untouched: it posts `grand_total`, which is
  what was payable, so free goods never affected it

Verified: `phase2_stock_triggers.sql` now has 20 assertions, all passing —
including the spec's numbers (landed 83.3333; value 1000.00, not 1200.00) and a
second receipt into the same batch (cost basis 1100.00, not 1300.00). Test is
atomic and self-rolling-back; zero `ZZTEST` residue confirmed.

### Products module — data and application layer [DONE]

- `features/products/data/products_repository.dart` — list (paged, searched,
  filtered), byId, create, update, setActive, batchesFor (FEFO), stockFor,
  aliasesFor, addAlias, removeAlias
- `features/products/application/products_list_controller.dart` — filter state
  (kept alive) + paged list (not kept alive) with `loadMore`
- `features/products/application/products_detail_controller.dart` — product +
  FEFO batches + aliases + stock rollup; owns the alias writes
- `features/products/application/products_form_controller.dart` — create,
  update, deactivate
- New shared pieces: `data/models/product_alias.dart`,
  `data/models/product_draft.dart`,
  `data/datasources/postgrest_error_mapper.dart`,
  `core/utils/postgrest_search.dart`
- Tests: `postgrest_search_test.dart`,
  `products_list_controller_test.dart` (fake repository via `implements` +
  `noSuchMethod`, covering filtering, paging, debounce and load-more failure)

### Products module — complete [DONE]

Data and application layers as listed above, plus:

- Screens: `products_screen.dart` (search, schedule and availability filters,
  paged list, load-more), `products_form_screen.dart` (create/edit, barcode
  hook), `products_detail_screen.dart` (Info / Batches / Aliases tabs,
  deactivate with confirmation)
- Widgets: `product_card.dart`, `product_filter_bar.dart`,
  `product_badges.dart` (schedule and expiry tone mappings)
- Routes: `/products`, `/products/new`, `/products/:productId/edit`,
  `/products/:productId` (declared in that order so `new` is not read as an
  id), and `products_placeholder.dart` deleted
- Shell: primary-bar and drawer highlighting now match by prefix, so a nested
  product screen still lights up Products
- Shared pieces added along the way: `core/widgets/app_back_button.dart`,
  `core/errors/error_message.dart`
- Tests: `product_card_test.dart`, `products_screen_test.dart` (list, empty
  state, search narrowing, schedule filtering) over the shared fake in
  `test/support/fake_products_repository.dart`

### Suppliers + customers modules [DONE]

Built by two parallel subagents on strictly disjoint directories
(`features/suppliers/**`, `features/customers/**`), with every shared file
written by the main agent: `routes.dart`, `app_router.dart`,
`dashboard_shell.dart`, `widget_test.dart`, and the ledger pieces both modules
needed (`data/models/party_balance.dart`,
`data/repositories/ledger_repository.dart`). Neither subagent ran codegen — one
`build_runner` run in the main agent covered both, because two concurrent runs
corrupt `.dart_tool`.

- Suppliers: draft model, repository (`SuppliersQuery`), filter/list/form/detail
  controllers, three screens, card + filter bar, 10 controller tests
- Customers: the same shape, 10 controller tests, plus `CustomerDraft`
- Integration fixes after the merge: a missing `party_balance` import in the
  suppliers detail screen (extension members need their library imported), and
  the customers form's private email validator replaced with the shared
  `Validators.emailIfPresent` added to `validators.dart`

### Bug fix — phantom "not linked to a pharmacy" [DONE]

Reported: saving a product failed with *"Your account is not linked to a
pharmacy yet."* for `rohit@arihant.com`, whose `profiles.pharmacy_id` was set
correctly in the database, even after clearing storage, signing out and back in,
and hot restarting.

**Root cause (two defects, both in our code, neither in the data):**

1. `authControllerProvider` was auto-dispose (Riverpod 3's default), and the
   only thing that ever watched it was the dashboard. Navigating dashboard →
   products disposed it, so the next screen's read of the tenant scope rebuilt
   it and started a fresh profile fetch.
2. `activePharmacyId` read `authControllerProvider.value?.pharmacyId`
   synchronously, and that value is `null` **while the profile is loading**. So
   "the profile has not arrived yet" was indistinguishable from "the profile has
   no pharmacy", and a valid user was told they were unlinked.

The reported hypothesis (a profile cached forever across sign-out/sign-in) was
not what the code did: `AuthController.build()` already invalidated itself when
the signed-in user id changed, and `authStateChangesProvider` already existed.

**Fix:**

- The auth chain is now kept alive end to end
  (`supabaseClient` → `authRepository` → `AuthController` → scope), so the
  profile survives navigation; `riverpod_lint` enforces that chain.
- `requirePharmacyId` distinguishes all four states: loading, loaded-with-id,
  loaded-without-id, and failed read. Only a *loaded* profile with no
  `pharmacy_id` reports "not linked"; a failed read reports itself; a profile
  still in flight reports that it is loading and can be retried.
- `AuthController` also refetches on `tokenRefreshed`, so a profile row changed
  underneath a signed-in user (a pharmacy linked, a role changed) is picked up
  without a sign-out.
- New `profileStateProvider` is the seam that lets tests drive all four states.

**Verified:** 140 tests pass, including four new ones covering each profile
state. Not verified in a browser - see the note in the chat.

### Security fix — profile privilege escalation [DONE]

Any authenticated user could set their own `profiles.role = 'owner'` and point
`profiles.pharmacy_id` at another tenant's uuid. RLS is row-level, so
`profiles_update_self` permitted it, and `get_my_pharmacy_id()` reads that same
row - making it both self-promotion and a tenant hop.

- `20260918000017_harden_profiles.sql` - revokes the **table-level** UPDATE grant
  on `profiles` from `authenticated`, grants UPDATE back on `full_name`, `phone`
  and `avatar_url`, recreates the self-update policy for the row restriction, and
  adds the `onboard_pharmacy()` SECURITY DEFINER RPC.
- `20260918000018_harden_profiles_anon.sql` - takes EXECUTE on that RPC away from
  `anon`, which held its own grant independent of `PUBLIC`.

Two traps, both caught by checking the live database rather than trusting the
SQL: a column-level `revoke` is a **no-op** while a table-level privilege exists
(so the obvious fix would have done nothing), and revoking from `PUBLIC` does not
remove a role's own grant (so `anon` could still have created tenants).
Recorded in D-017.

Verified by `supabase/tests/profile_privileges.sql` - 16 assertions, all passing.
It impersonates the `authenticated` role with `auth.uid()` set inside one
transaction and proves: self-promotion refused, `pharmacy_id` rewrite refused,
legitimate column edits still work, `anon` cannot execute the RPC and sees zero
business rows, onboarding refuses an already-linked account, and the happy path
creates a pharmacy and links it as owner. Atomic and self-rolling-back; zero
residue confirmed (`0` test pharmacies, the real profile untouched).

### Onboarding flow [DONE]

`features/onboarding/` - repository over the RPC, controller that invalidates the
profile on success, and a form screen (name, GSTIN, drug licence, phone, city,
state, PIN). New `/onboarding/pharmacy` route, deliberately outside the shell
(with no pharmacy, every nav destination could only fail), and a router redirect
that sends a signed-in account with no pharmacy there.

The redirect waits while the profile is still loading rather than treating
"not yet loaded" as "unlinked" - the same defect as the tenant-scope bug above,
one layer up. `_AuthRouterRefresh` now listens to the profile as well as the
session, so the redirect re-runs once onboarding links the account.

### Bug fix — desktop navigation hid seven destinations [DONE]

Reported: on desktop (>700px) the rail showed only the four primary destinations
and nothing could open the drawer, so Suppliers and Customers were unreachable.

**Root cause:** the desktop rail was built from the four-destination primary
list, and the shell renders no `AppBar` - `Scaffold.drawer` only draws a
hamburger when an `AppBar` exists, so the drawer it also configured had no
trigger. Adding the masters to the drawer in Phase 1 put two user-facing screens
somewhere desktop could not reach.

**Fix (D-018):** all 11 destinations now live in one `_navDestinations` list;
the rail renders all of them expanded, the drawer renders all of them on mobile
only, and the bottom bar renders the four flagged `inBottomBar`. The rail is
`scrollable` (11 destinations overflow a short window), auto-collapses below
1200px with a toggle to override, and desktop no longer configures a drawer that
nothing can open.

Structure captured from the running widget tree at three widths:

```
=== 1920x1080  shell.drawer=false
NavigationRail(extended=true, scrollable=true, count=11)
  labels => Dashboard, Products, Suppliers, Customers, Inventory, Purchase,
            Sales, Returns, Ledger, Reports, Settings
=== 800x900  shell.drawer=false
NavigationRail(extended=false, scrollable=true, count=11)
  labels => (same 11)
=== 500x900  shell.drawer=true
NavigationBar(4) => Dashboard, Products, Sales, Reports
```

Tests: `test/features/dashboard/dashboard_shell_test.dart` (7 cases: every
destination labelled on desktop, no drawer on desktop, tapping a rail item
navigates and highlights, auto-collapse, manual toggle, nested path keeps its
section highlighted, mobile keeps 4 + the full drawer), plus `widget_test.dart`
now pins `DashboardShell.destinationPaths == Routes.shellPaths` and
`.bottomBarPaths == Routes.bottomNavPaths`.

### Phase 2 — Purchase module: data + application layer [DONE]

Models: `purchase.dart` (+ `PurchaseStatus`), `purchase_item.dart`,
`purchase_draft.dart` (`PurchaseDraft` + `PurchaseLineDraft`).

- `features/purchase/data/purchase_totals.dart` — line and document money math,
  pure and separately tested. Rounds each figure before summing so a stored grand
  total always equals the sum of its stored lines, and rounds half-away-from-zero
  with an epsilon so `1.005` does not come out a paisa short of what Postgres
  `numeric` would store.
- `features/purchase/data/purchases_repository.dart` — list (supplier, status,
  date range, search), byId, itemsFor, create, updateDraft, setStatus, receive.
- `data/repositories/pharmacy_repository.dart` — the pharmacy's state, needed to
  decide the GST split.
- Application: filter/list controller with paging, form controller,
  `purchaseWithLines`, `purchaseTaxSplit`, and `GrnController`.
- Tests: `purchase_totals_test.dart` (12) and `grn_controller_test.dart` (6).

**The receipt's write order** (D-013) now lives in one place,
`PurchasesRepository.receive`, with the reasoning inline:

1. `product_batches` upserted on `(pharmacy_id, product_id, batch_no)`
   **without `qty`** — a new row takes the default 0, and the upsert leaves an
   existing batch's balance alone instead of zeroing live stock;
2. `purchase_items` replaced wholesale, now carrying `batch_id` and the line's
   share of the tax;
3. the header's totals **and** `status = 'received'` in one statement, because
   `ledger_auto_entry_purchase()` reads `grand_total` off the row it is handed.

**Verified against the live database** by `supabase/tests/grn_write_order.sql`
(15 assertions, all passing, atomic and self-rolling-back), which reproduces the
client's exact payloads and proves: a draft creates no batch; a new batch starts
at 0 with no landed cost; lines written before receipt move nothing; receipt
applies `qty + free_qty` for every line; the landed cost lands at 83.3333; the
marker is stamped; the ledger posts 1344 from the same statement as the status;
the lines add up to the document totals; **a repeat upsert of the same batch does
not reset its stock**; and two payload rows for one batch are refused by Postgres
(which is why `validateLines` exists).

### Purchase module — presentation layer [DONE]

The purchase module is complete. Built after a crash mid-write of
`purchase_line_editor.dart`; `context/chat2b-summary.md` is the detailed account.

- Screens: `purchases_screen.dart` (search, supplier dropdown, status chips,
  invoice-date range, paging), `purchase_form_screen.dart` (order: invoice
  details and lines, no batches), `grn_screen.dart` (the receipt — reaches stock
  and the ledger), `purchase_detail_screen.dart` (invoice, stored totals, lines
  with batches, and the next step)
- Widgets: `purchase_line_editor.dart` (one editor for both halves of a
  purchase's life; `showBatchFields` is the difference), `purchase_card.dart`,
  `purchase_filter_bar.dart`, `purchase_status_badge.dart`,
  `purchase_locked_view.dart`
- Routes `/purchase`, `/purchase/grn`, `/purchase/new`,
  `/purchase/:purchaseId/edit`, `/purchase/:purchaseId/grn`,
  `/purchase/:purchaseId` — literal segments declared before the parameterised
  one, since declaration order is match order; `purchase_placeholder.dart`
  deleted
- New shared pieces: `core/widgets/app_date_field.dart` (a `FormField`-based date
  field, so a required date reports at the field), and
  `suppliers/application/supplier_options.dart` (`supplierOptions` — every
  supplier, inactive included, for pickers and for naming a card)
- `ProductPickerField` gained `selectedName`: an existing document stores a
  line's product id and a displayed name, not the catalogue row
- Detail totals are rendered from the document's own stored columns, because
  those are what `ledger_auto_entry_purchase()` posted; the tax *head* is summed
  from the lines, where it is actually stored
- A standalone receipt (goods with no purchase order behind them) creates the
  document as a draft and receives it in one action, so a failure in between
  leaves a recoverable draft rather than losing the typed lines
- Tests: 21 widget tests across the four screens, over
  `test/support/fake_purchases_repository.dart` (which runs the real
  `validateLines`, so a screen that skips a check the write enforces fails in the
  test rather than in front of a user) and `test/support/purchase_test_app.dart`
  (a mini-router, so each screen's `context.go` is exercised)

Two bugs were found by those tests and fixed: a picked date never reached the
line draft (`AppDateField.onChanged` did not `_emit()`, so the receipt was
refused for a missing expiry the user had chosen), and the detail screen could
show a stale document because the writing screen invalidated the list but not
`purchaseWithLines(id)`.

### P-1 fix — an edited order reverts to draft only when its lines change [DONE]

`updateDraft` wrote `status = 'draft'` unconditionally, so saving an `ordered`
purchase silently undid the transition. Decided and implemented as option 1 from
the brief, recorded as **D-019**:

- `PurchasesRepository.statusAfterEdit` / `.linesDiffer` — pure and public, so the
  rule is unit-tested without a client and the test fake runs the same function.
- The comparison is a multiset of per-line signatures over the fields a supplier
  would have to re-confirm (product, qty, free qty, rate, mrp, discount, GST,
  batch, expiry), compared at the precision the columns store. Order is ignored
  on purpose: `purchase_items.created_at` is a transaction timestamp, so a read
  can return rows in a different order than they were written, and an
  order-sensitive comparison would revert a document nobody touched.
- `PurchaseFormScreen` reports the revert with a SnackBar ("Order returned to
  draft because lines changed — review and re-confirm"), driven by comparing the
  status it loaded with the status it got back rather than by predicting it.
- Tests: `purchase_edit_status_test.dart` (11, over both branches and the
  boundaries) and two widget tests on the form.

### Inventory module — complete [DONE]

`features/inventory/` — data, application and presentation
(`inventory_placeholder.dart` deleted).

- `data/inventory_repository.dart` — the cross-product reads (`stockList` paged
  and searchable with an in/out-of-stock filter, `lowStock`, `expiringBatches`,
  `batchesExpiringBetween`, `namesFor`) and the `stock_adjustments` write.
  `ProductsRepository` keeps the per-product reads it already had (`batchesFor`,
  `stockFor`); the split is by question, not by table.
- Screens: `inventory_screen.dart` (Stock / Low stock / Expiry tabs) and
  `expiry_calendar_screen.dart` (a month grid with units per day, filtering the
  list below by a tapped day). Route `/inventory/calendar` added; the shell is
  unchanged.
- Widgets: `product_stock_card.dart`, `expiry_batch_card.dart`,
  `expiry_bucket_bar.dart`, `stock_level_badge.dart`,
  `stock_adjustment_sheet.dart`.
- The stock rows print the rollup's own `total_qty` and `stock_value_at_cost`, so
  the screen cannot disagree with the view, and the valuation keeps the landed
  cost (D-012) rather than a rate.
- The expiry rows show units and value **at MRP**, not at cost: `batch_status`
  does not carry `landed_cost_per_unit` (it was added to `product_batches` after
  that view was created, and a view's `b.*` is expanded when it is created), and
  `qty x purchase_rate` would overstate any batch that took in scheme stock.
- Adjustments are batch-scoped and reachable from two places: the expiry list,
  and the Batches tab of the product detail (extended rather than duplicated, as
  the brief asked). The sheet caps a decrease at what the batch holds, and the
  trigger's own `check_violation` is surfaced verbatim when a concurrent write
  gets there first.
- One shared rule was extracted rather than copied: `Validators.positiveInt`
  (used by the adjustment sheet and the purchase line editor), and `ExpiryBadge`
  moved to `core/widgets/expiry_badge.dart` so the product detail and the expiry
  dashboard cannot disagree about which bucket is urgent.
- Tests: 16 across `inventory_screen_test.dart` (list, filter, low stock, the
  three buckets, a written adjustment, the at-the-field cap, a refused
  correction) and `expiry_calendar_test.dart` (month arithmetic, the screen, the
  day filter).

### Purchase returns module — complete [DONE]

`features/returns/` — `returns_placeholder.dart` deleted; routes `/returns`,
`/returns/new`, `/returns/:returnId`. Sale returns stay Phase 3.

- Models `purchase_return.dart`, `purchase_return_item.dart`; repository over
  `purchase_returns` / `purchase_return_items`; list controller with paging; form
  controller; detail controller.
- `ReturnableLine` is the whole decision a return line makes: what the invoice
  billed, what has already gone back (summed from this purchase's returns, keyed
  by `purchase_item_id`), and what is in the batch right now. The form shows that
  number and the write re-derives it, so the two cannot disagree and the supplier
  cannot be credited twice for the same units.
- The credit is a **proportional slice of the invoice line's own stored amounts**
  (`PurchaseReturnTotals`), not `qty x rate`: `purchase_return_items` has no
  discount column, so recomputing would credit the list price of discounted
  goods. Recorded as D-020.
- `create` takes only `(purchaseItemId -> qty)`: the amounts, the supplier and the
  batch come from the invoice line.
- Tests: `purchase_return_totals_test.dart` (5) and 11 widget tests over the list
  and the form, including the credit preview and the cap.
- Two bugs found by those tests: the return line's quantity field only reported
  on submit (so a browser or desktop user's quantities never reached the parent —
  or the credit preview), and a fixture without a `batch_id` showed how a
  received line with no batch can never be returned.

### PHASE 2 COMPLETE

Delivered in this chat: the P-1 fix (D-019), the inventory module (stock, low
stock, expiry dashboard, expiry calendar, stock adjustments) and the purchase
returns module. Phase 2's DB automation was already live and verified; no
migration was added or needed, so `supabase db push` was not part of this gate
run.

Gate output at completion:

```
dart format lib test                      -> 0 changed (tree is formatter-clean)
dart run build_runner build --delete...   -> wrote 127 outputs (T-1 SDK notice only)
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +237: All tests passed!
```

(191 tests at the end of the purchase module; 237 now — 46 added, none changed.)

### PHASE 1 COMPLETE

Delivered: three masters at full CRUD — products (multi-batch FEFO view,
aliases tab, schedule badges, search by name/generic/barcode, schedule and
availability filters, low-stock indicator on detail), suppliers and customers
(contact, registration, commercial fields, read-only ledger balance, active
filter). 12 new routes, dashboard nav for both new masters, placeholders
deleted.

Gate output at completion:

```
dart format lib test                      -> 0 changed (tree is formatter-clean)
dart run build_runner build --delete...   -> wrote 167 outputs (T-1 SDK notice only)
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +136: All tests passed!
```

(29 tests at the end of Phase 0; 136 now.)

### Shared foundation [DONE]

- Models: `ProductStock` (`product_stock` view), `BatchStatus` +
  `ExpiryStatus` (`batch_status` view)
- Widgets: `StatusBadge`, `AppDropdownField`, `AppEmptyView`,
  `SectionCard`, `AppSearchField`, `showConfirmDialog`
- Utils: `Debouncer`; validators for drug licence, optional GSTIN/phone/
  PIN code and non-negative numbers
- Providers: `activePharmacyId` / `requirePharmacyId`
  (`features/auth/application/pharmacy_scope.dart`)

### Gate status (2026-09-18, after the products module)

```
dart run build_runner     -> outputs written (T-1 SDK notice only)
dart run custom_lint       -> No issues found!
flutter analyze            -> No issues found!
flutter test               -> +113: All tests passed!
```

### Environment notes discovered this chat

- Riverpod 3 wraps whatever a provider threw before handing it to a provider
  that watches it, in `ProviderException` (`flutter_riverpod/misc.dart`). A
  screen rendering `error.toString()` would show Riverpod's developer dump
  instead of the app's message, so `describeError()` unwraps it in a loop
- `DropdownButtonFormField.value` is deprecated after Flutter 3.33; use
  `initialValue` (it re-syncs when the parent passes a new value, so the
  field stays controlled)
- Riverpod 3.0.3 has no `AsyncValue.valueOrNull`; `AsyncValue.value` is
  already nullable
- Riverpod 3 disposes providers with no listeners by default. State that must
  outlive navigation needs `@Riverpod(keepAlive: true)`; the products filter
  uses it, the product list deliberately does not
- Riverpod 3's generated notifier base class already defines `update`, so a
  controller method with that name is a compile error. Controller methods are
  named `<verb><Entity>` (`createProduct`, `updateProduct`)
- `AsyncValue.copyWithPrevious` is marked `@internal` in Riverpod 3 and cannot
  be called from app code, so a failed `loadMore` restores the previous page and
  rethrows instead
- `Override` is declared in `riverpod`, not re-exported by `flutter_riverpod`,
  so provider override lists in tests must be inferred
- `ThemeData(brightness: dark)` does not give the theme a dark
  `colorScheme`; build one via `ColorScheme.fromSeed(brightness:)`
- `MaterialApp` swaps themes through an `AnimatedTheme`, so widget tests
  must `pumpAndSettle` before reading a theme
- A `SliverList` only *mounts* the children inside its viewport, so a widget
  test asserting on a field below the fold finds nothing at all — not something
  merely off-screen. The purchase-screen tests size the test window tall in
  `pumpPurchaseApp` instead of scrolling to every assertion
- A `DropdownButton` keeps every item it was given in its own subtree (an
  `IndexedStack`), so `find.text('Arihant Distributors')` also matches the
  closed filter button. Assert through `find.widgetWithText(SomeCard, …)`, or
  through the chip
- `find.text` matches an `EditableText`'s content too, so a search field holding
  the term matches the same `find.text` the results do
- After a write that changes a document, invalidate **the document provider as
  well as the list**: a document provider still cached against the screen that
  wrote it can hand the next screen the pre-write copy (found by a purchase test)

---

## Next Action

**Phase 5 Chunk D, part 2 of 2 — the notifications themselves.** Part 1 (the alert
sources, `low_stock_products` + `expiring_batches`) is done and its SQL test asserts
25 numbers; what is left is the half with the credentials:

- **`send-notification`** (`verify_jwt` on, acting as the caller): `{channel, to,
  subject?, body, recipient_type, recipient_id?, notify_user_id?}` in; a
  `notification_logs` row written for **every** attempt — sent, refused and
  not-configured alike — and, when the message belongs in someone's in-app list, the
  `notifications` row too, written with the log row in one transaction. A missing
  `WHATSAPP_TOKEN`/`SENDGRID_API_KEY` is `not_configured` **naming the secret**, and
  the log row still lands (`status = 'skipped'`), because "we tried and could not" is
  what an operator needs to see. No automatic dispatch of the alerts in Phase 5
  (D-046).
- **The in-app list**: `notifications` (user-addressed, `read_at` for the read
  state — migration 00008), newest first, with the two alert sections rendered live
  from the RPCs above (D-047: an alert is a question, a notification is an event).
- **The Dart seams and `NotificationService`'s Phase 5 meaning**: `getFcmToken()`
  stays `null`, and `init()`/`showLocal()` get an honest definition without a push
  SDK (D-029) — a platform capability behind a seam and a fake (D-035).
- **What cannot be live-verified**: any actual WhatsApp or email delivery (no
  account, no key, no recipient numbers). The function must be built so the missing
  secret is a sentence rather than a crash, and its tests must run with no secret at
  all — the whole handler through stubs, the way `match-product`'s does.

Then **Phase 6**: testing, deployment, documentation — the Windows build fix (W-1),
the README refresh (R-1), push registration (N-1), the SendGrid/WhatsApp credentials
and the alert triggers (D-046), N-9's re-measurement once the catalogue is real, and
N-5's index.

What Phase 5 builds on, and must not break:

- A sale is written through `checkout_sale(jsonb)` and nothing else, and its
  stock moves per line from a trigger on `sale_items`. Quantity is
  `product_batches.qty`; **no client posts it** (D-021's closing note). An OCR
  path that fills a purchase invoice must go through `PurchasesRepository.receive`
  for the same reason.
- Every DB query is scoped by `pharmacy_id`, read **synchronously** from
  `requirePharmacyIdProvider` (D-015).
- `checkout_sale()`, `record_payment()` and `report_summary()` are
  `security definer` and take the tenant from `get_my_pharmacy_id()`; an AI or
  Edge Function must present the user's JWT, never `service_role` (D-004).
- Money is computed once, by a pure helper, and both the screen and the write use
  it (`PurchaseTotals`, `PurchaseReturnTotals`, `PosCart`), with
  `PurchaseTotals.round2` as the shared rounding rule.
- A document that has posted stock is corrected by a return, never by an edit
  (D-013 for purchases, and the sale side follows it: `sale_status` has no draft).
- Three open items Phase 5 should not make worse: **T-3** (the ledger's failure
  path offers no retry after a party is chosen), and **T-4** / **T-5** (the
  sale-return form's dead bill validator, and its picker where "loading" and
  "nothing sold yet" look the same). I-1 to I-3, R-1 and the new **N-1** are still
  open.
- The AI substrate now exists and is verified: `products.embedding` with its HNSW
  index (D-027), the private path-scoped `purchase-bills` bucket (D-028), and
  `device_tokens` / `notification_logs` (00022). Chunk B uploads to the bucket;
  chunks C-E read the vector and write the log. Do not `select *` a table that has
  an embedding on it.
