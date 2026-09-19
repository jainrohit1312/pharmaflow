# Chat 4 — Phase 5: AI OCR + Smart Matching + Notifications + Chatbot

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built
with Flutter + Supabase (hosted).

> Naming: the chat titles and the `chatN…` file names drifted apart after Phase 0
> (this file's predecessor was `chat2d-opening-prompt.md`, titled "Chat 3").
> `PROGRESS.md`'s Chat Strategy table is the authority: **Chat 4 = Phase 5 +
> Phase 6**, and this is its brief.

**Phases 0 through 4 are complete and gated**, and the Phase 3 test gap (T-2) is
closed: the counter, the checkout write and the sale-return form now have Dart
tests. This chat builds the AI layer — the last feature work before Phase 6's
production readiness. Do **not** re-do anything already delivered, and do not
start Phase 6.

> Note: `context/chat2e-opening-prompt.md` is an earlier draft of this same brief.
> This file supersedes it where they differ.

---

## STEP 0 — READ FIRST (do NOT skip)

Read in this exact order:

1. `PROGRESS.md`
2. `MASTER_PLAN.md`
3. `DECISIONS.md`
4. `HANDOFF_PROTOCOL.md`
5. `context/chat2d-summary.md` (what the previous sessions built)
6. `context/chat3-opening-prompt.md` (this file)

Then output a 5-line understanding check:

- What Phase 5 covers
- What the previous sessions delivered
- Environment (hosted Supabase, no Docker, Web-first)
- Two load-bearing dependency pins
- What you are about to build

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`, no `db reset`
- Migrations: `supabase db push` (the ONLY migration command)
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
```

`dart format` is not itself a gate, but the committed tree *is* formatter output,
so run it after writing Dart and before the gates; a "Changed" verdict means the
new code drifted, not that the repo is dirty. (T-1's SDK language notice from
`build_runner` and `custom_lint` is known and cosmetic.)

**Never run two `build_runner` processes at once** — concurrent runs corrupt
`.dart_tool`. If you use parallel subagents, the main agent runs codegen once at
the end. (Two concurrent `flutter test` runs are also best avoided.)

**Analyzer note (learned the hard way):** `flutter analyze` covers `test/**` too,
and `avoid_redundant_argument_values` fires on arguments equal to a parameter's
own default *including inside test fixtures* — `DateTime(2026, 1)` must be
`DateTime(2026)`, and a fixture that passes `buildBatch(qty: 10)` is flagged
because 10 is that builder's default. `find.text` also matches an `EditableText`'s
content, so a search field holding `INV-8` matches the same finder the results do —
scope such assertions to the card.

**Docker note:** `supabase functions serve` runs functions in containers. With no
Docker on this machine, develop Edge Functions by deploying them
(`supabase functions deploy`) and invoking the deployed one, or find the CLI's
non-container path — and say plainly which you did. Never print or commit
secrets; function secrets go through `supabase secrets set`.

---

## WHAT THE PREVIOUS SESSIONS DELIVERED

**Phase 0** — schema (22 tables, 2 views, RLS on every business table), auth,
the dashboard shell.

**Phase 1** — products (multi-batch FEFO view, aliases, schedule badges,
search/filters), suppliers and customers masters, full CRUD.

**Phase 2** — purchase (list, order form, GRN, detail), inventory (stock, low
stock, expiry dashboard and calendar, stock adjustments), purchase returns.
Migrations `00015`-`00016`.

**Phase 3** — sales/POS, sale returns, GST billing. `00019` enables the sale-side
automation and puts the whole sale behind `checkout_sale(jsonb)`; `00020` corrects
two defects `00019` shipped with.

**Phase 4** — ledger, payments, expenses and reports. `00020` posts the purchase
return's credit note and puts a payment and its ledger row behind
`record_payment(...)`; `00021` adds `report_summary(date, date)`.

Migration list: 21/21 local and remote match. For the delivered detail, the open
items and the two findings from the last session, read
`context/chat2d-summary.md`; `PROGRESS.md` carries the test count and the gate
output at handoff.

---

## SCOPE — Phase 5: AI OCR + Smart Matching + Notifications + Chatbot

Per `MASTER_PLAN.md` Phase 5. The service seams already exist as stubs in
`app/lib/services/` with `TODO(phase-5)` markers (`OcrService`, `WhatsappService`,
`EmailService`, `NotificationService`); implementing them is part of this phase.
`notification_service.dart`'s markers still say `TODO(phase-2)` — stale; this is
the phase that owns them.

### A) DATABASE (a new migration, 00022 or later)

- Enable `pgvector`.
- `products.embedding` — the vector the fuzzy match searches.
- `device_tokens` — one row per device a notification can reach.
- `notification_logs` — what was sent, to whom, and what happened to it.

Every new table carries `pharmacy_id` and RLS scoped by `get_my_pharmacy_id()`
(D-004), and the migration is a **new file**, never an edit to an applied one:
D-013 established that, `00016` and `00020` followed it, and `00021` is the
current head. Verify it with a `supabase/tests/*.sql` script that is atomic, rolls
itself back and asserts the numbers, the way `phase2_stock_triggers.sql`,
`phase3_sale_triggers.sql` and `phase4_report_summary.sql` do.

### B) EDGE FUNCTIONS (~5, per the plan)

`supabase/functions/` does not exist yet — this phase creates it:

- `ocr-purchase-bill` — a supplier bill image in, structured data out (Gemini
  Vision);
- `save-purchase-from-ocr` — turn that data into a purchase through the same
  write path the screens use;
- `match-product` — fuzzy/vector match of an OCR line to a catalogue product;
- `send-notification` — WhatsApp/FCM/Email dispatch, writing
  `notification_logs`;
- `chat-sql-agent` — the chatbot: natural-language questions answered over the
  pharmacy's own data.

**Contract:** functions act as the signed-in user. They read the user's JWT and
let RLS scope the query — never `service_role` for reads (D-004).

### C) FLUTTER

- `features/purchase_ocr/` — capture or pick a bill image, show what the OCR
  read, let the user correct it, then create the purchase.
- `features/notifications/` — device-token registration and the in-app list.
- Implement the four service stubs.
- A chatbot surface for `chat-sql-agent` (its own feature directory, or the one
  the plan names).

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, taken synchronously from
  `requirePharmacyIdProvider`. Never `await …requirePharmacyIdProvider.future`
  (D-015).
- **Stock moves through triggers, never through the client.** Quantity is
  `product_batches.qty`; a purchase moves it only by reaching `received` through
  `PurchasesRepository.receive` (D-011/D-012/D-013), and a sale only through
  `checkout_sale` (D-023). An OCR flow that creates a purchase must go through that
  same repository — not insert rows itself.
- **Money is computed once, by a pure helper, and both the screen and the write
  use it** — `PurchaseTotals`, `PurchaseReturnTotals`, `SaleTotals`, with
  `PurchaseTotals.round2` as the shared rounding rule.
- **A document that has posted stock is corrected by a return, never by an edit**
  (D-013, D-019, D-023). An "OCR got it wrong, let me fix the invoice" path must
  therefore create a corrected document or a return, not rewrite a received one.
- **A report is one server-side aggregate, never rows summed in Dart** (D-025). If
  the chatbot answers with figures, they come from the database.
- **A screen that is not a shell destination nests under the one that owns it**
  (D-022) — `/purchase/ocr`, not `/ocr`.
- **`check_violation` (23514) messages reach the user verbatim.** Do not swallow
  them.
- `products.embedding` is a new column on a table, so the `product_stock` and
  `batch_status` views are unaffected (a view's `b.*` is expanded when it is
  created — D-021's trap). Do not assume a new column is visible through a view.

---

## ARCHITECTURE PATTERN

Same as every module so far:

```
app/lib/features/<X>/
  data/<X>_repository.dart
  application/<X>_controller.dart          @riverpod (codegen only)
  presentation/<X>_screen.dart
  presentation/widgets/…
app/test/features/<X>/…
app/test/support/fake_<X>_repository.dart
```

Rules this repo has learned the hard way:

- `@riverpod` codegen only; a hand-written `Provider` only for a stub.
- Freezed: `abstract class X with _$X`, with `// ignore:
  invalid_annotation_target` on the factory constructor.
- A class that is not a table row (an RPC envelope, a cart, a payload) is a plain
  class, not Freezed — `ReportSummary`, `PosCart` and `SaleCheckout` are the
  precedents.
- Consumer method names are `<verb><Entity>` (`createProduct`) — the generated
  base class already defines `update`.
- State that must outlive navigation needs `@Riverpod(keepAlive: true)`; a
  kept-alive provider may only depend on kept-alive providers.
- Riverpod 3 has no `AsyncValue.valueOrNull`, and `copyWithPrevious` is
  `@internal` — a failed `loadMore` restores the previous page and rethrows.
- A failed *rebuild* keeps the previous value, so `hasError && !hasValue` is only
  true on a first read; a screen that wants a retry control on every failure must
  not treat "nothing selected yet" as an empty value (T-3).
- Awaiting `.future` on a provider that *failed* never completes in Riverpod 3,
  and reading an auto-dispose provider once can be disposed mid-build: keep it
  alive with `container.listen` when a test has to observe an error state.
- `Override` is declared in `riverpod`, not re-exported by `flutter_riverpod`:
  provider override lists in tests must be inferred.
- Render provider failures through `describeError()`; the raw error reaches a
  screen wrapped in `ProviderException`.
- No business logic in widgets. A write that must not be reordered lives in the
  repository, and the invalidation of everything a write changes lives in the
  controller — anything that moves stock calls `refreshStockReaders` from
  `features/inventory/application/stock_readers.dart` (D-023).
- A controller owns its `TextEditingController`s and reports every change up
  through a **listener**, not only `onSubmitted` — a browser and a desktop have no
  submit key.
- Shared widgets to reuse rather than re-create: `AppScaffold`, `AppButton`,
  `AppTextField`, `AppDropdownField`, `AppDateField`, `AppSearchField`,
  `SectionCard`, `StatusBadge`, `ExpiryBadge`, `AppEmptyView`, `ErrorView`,
  `LoadingView`, `showConfirmDialog`, `AppBackButton`, `Validators`,
  `Formatters.currency/dateDdMmmYyyy/monthYear`, `Debouncer`.
- `test/support/` has fakes that **run the real rules** and mini-router pump
  helpers. Follow that shape: a screen test should fail when a screen skips a
  check the write enforces. Make a fake's failure **persistent** rather than
  one-shot, or GoRouter's double build will retry it into a success before your
  assertion runs.
- A test window is made tall in the pump helper (`tester.view.physicalSize`)
  rather than scrolled, because a `SliverList` only mounts what is inside the
  viewport; a button below the fold needs `ensureVisible` before `tap`.

---

## OPEN ITEMS PHASE 5 SHOULD NOT MAKE WORSE

Read the table in `PROGRESS.md` for the current list. The ones this phase can
plausibly collide with:

| ID | Issue | Why it matters here |
|---|---|---|
| T-3 | The ledger's failure path offers a retry only on a first read. Low. | The same "an error with a stale value" shape will bite an OCR flow that shows a parse result. |
| I-1 | `lowStock` compares `total_qty < min_stock_level` in Dart over at most 500 candidates. Low. | A notification about low stock would report from the same bounded read. |
| I-2 | A purchase return is two statements, so a refused line set can leave a header with no lines. Low. | An "OCR + auto-create purchase" path would multiply that window. |
| I-3 | A return form offers at most 200 received purchases. Low. | A searchable picker is the same fix an OCR match would want. |
| R-1 / W-1 / A-1 | README, the Windows build, and the deprecated `anonKey`. | Phase 6 owns all three. |

---

## CONTEXT MANAGEMENT — YOUR CALL

Phase 5 is large: a migration with four new objects, five Edge Functions, a new
Flutter feature for OCR, a chatbot surface, notification plumbing, and the four
service stubs. It will not fit cleanly into a single session if compressed.

**You decide the split.** You have access to the codebase, the file sizes, and
the context meter. Work through Phase 5 in logical chunks that let you ship
each piece at production quality — not the maximum amount that fits.

**Rules for splitting:**

1. **Each chunk ends in a working, gated state.** Run all five gates at the
   end of every chunk. If a chunk's work is not shippable, don't end the chunk
   there.
2. **Hand off at ~60-70% context**, or earlier if response quality visibly
   degrades (forgetting earlier files, needing re-reads of the same file,
   losing track of the current chunk's plan). Do not push to 90%.
3. **Each chunk gets its own handoff files:**
   - Update `PROGRESS.md` — mark exactly what is done, what is next, and
     current test count.
   - Create `context/chat3a-summary.md` (or `chat3b-…`, `chat3c-…` — next
     letter in sequence) describing what this chunk delivered.
   - Create `context/chat3b-opening-prompt.md` (or next letter) as the brief
     for the next chunk. Same shape as this file, scoped to that chunk.
   - Add new decisions to `DECISIONS.md` with the next free id (D-026+).
   - Leave the tree commit-ready.
4. **Never compress.** Do not skip SQL tests to save context. Do not skip
   Flutter tests. Do not stub an Edge Function. Do not leave a partial
   migration. If a chunk would need to cut corners, split it into two.
5. **If you finish a chunk and context has room**, you may start the next
   chunk in the same session — but re-run all gates first, and stop at the
   same 60-70% rule. Do not silently continue past the handoff threshold.

**Suggested chunk sequence** (adjust as you see fit — this is a starting
point, not a mandate):

1. **Chunk A — Database foundation:** migration 00022 (pgvector, `products.embedding`,
   `device_tokens`, `notification_logs`) + atomic SQL test + Dart model for
   `DeviceToken` and `NotificationLog`. Verify the migration on the live
   project before writing any app code that depends on it.
2. **Chunk B — AI OCR core:** `supabase/functions/ocr-purchase-bill/` (Gemini
   Vision) + `features/purchase_ocr/` (capture/pick, verify UI, save flow).
   This is the biggest single feature — it may itself need to split into B1
   (edge function) and B2 (Flutter verify UI).
3. **Chunk C — Smart matching:** `match-product` edge function (pg_trgm +
   pgvector) + `save-purchase-from-ocr` + alias-learning (write to
   `product_aliases` on manual match). Also populate `products.embedding` for
   existing products — a backfill job.
4. **Chunk D — Notifications:** `send-notification` edge function + FCM +
   WhatsApp Cloud API + SendGrid + `features/notifications/` + implement the
   four service stubs.
5. **Chunk E — Chatbot:** `chat-sql-agent` edge function + chatbot surface
   (natural-language → SQL SELECT → RLS-scoped answer). **This is the last
   Phase 5 chunk.**

Auto-send PO — hook into the approval flow, and on approve send the PO PDF to the
supplier via their `preferred_channel` — was a candidate sixth chunk and is
**deferred to Phase 6 add-ons** (D-052): it needs a WhatsApp Meta account, a
SendGrid key and supplier channel preferences, none of which exist yet, and
manual sending is adequate until they do.

Realistically, chunks B and D are each likely to need their own split. You
decide.

**When Phase 5 is fully done** (all five chunks, A–E), the last chunk's handoff
should also preview Phase 6. Do not start Phase 6 in the same session as a
Phase 5 chunk.

**If a chunk cannot be finished before context runs low** — for example, the
Flutter UI is half-built when you hit 70% — hand off mid-chunk with a clear
"PARTIAL" status: what's done, what's not, what the next chat must do first.
A clean PARTIAL handoff is far better than a rushed finish.

---

## BEGIN

Start by reading the files listed in STEP 0, output the 5-line understanding
check, and then **propose your chunk split** — how many chunks you plan, what
each covers, and roughly how much context each will take. Wait for my approval
before starting the migration.

Once approved, begin with Chunk A: migration 00022 with an atomic
`supabase/tests/*.sql` script that rolls itself back and asserts the numbers,
then the Dart models for the new tables.