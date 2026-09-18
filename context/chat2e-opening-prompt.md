# Chat 4 — Phase 5: AI OCR + Smart Matching + Notifications

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built
with Flutter + Supabase (hosted).

**Phases 0, 1, 2, 3 and 4 are complete and gated.** This chat builds the AI layer
and notifications — the last feature work before Phase 6's production readiness.
Do **not** re-do anything already delivered, and do not start Phase 6.

---

## STEP 0 — READ FIRST (do NOT skip)

Read in this exact order:

1. `PROGRESS.md`
2. `MASTER_PLAN.md`
3. `DECISIONS.md`
4. `HANDOFF_PROTOCOL.md`
5. `context/chat2d-summary.md` (what the previous session built)
6. `context/chat2e-opening-prompt.md` (this file)

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
the end.

**Analyzer note (learned the hard way):** `flutter analyze` covers `test/**`, and
`avoid_redundant_argument_values` fires on fixtures that repeat a builder's or a
constructor's own defaults — `DateTime(2026, 1)` must be `DateTime(2026)`, and
`buildSupplier(name, isActive: true)` is flagged because `true` is the default.
Write fixtures without redundant defaults from the start.

**Docker note:** `supabase functions serve` runs functions in containers. With no
Docker on this machine, expect to develop Edge Functions by deploying them
(`supabase functions deploy`) and invoking the deployed one — or find the CLI's
non-container path — and say plainly which you did. Do not print or commit
secrets; function secrets go in `supabase secrets set`, never in the repo.

---

## WHAT THE PREVIOUS SESSIONS DELIVERED

**Phase 0** — schema (22 tables, 2 views, RLS on every business table), auth,
the dashboard shell.

**Phase 1** — products (multi-batch FEFO view, aliases, schedule badges,
search/filters), suppliers and customers masters, at full CRUD.

**Phase 2** — purchase (list, order form, GRN, detail), inventory (stock, low
stock, expiry dashboard and calendar, stock adjustments) and purchase returns.
Migrations `00015`-`00016`.

**Phase 3** — sales/POS, sale returns, GST billing. Migration `00019` enables the
sale-side automation and puts the whole sale behind `checkout_sale(jsonb)`;
migration `00020` corrects two defects `00019` shipped with. **Phase 3 added no
Dart tests** — see T-2 below.

**Phase 4** — ledger, payments, expenses and reports. `00020` posts the purchase
return's credit note and puts a payment and its ledger row behind
`record_payment(...)`; `00021` adds `report_summary(date, date)`. Migration list:
21/21 local and remote match. Gate result at handoff: `custom_lint` clean,
`analyze` clean, `flutter test` +291.

Read `context/chat2d-summary.md` for what the last chat did in detail, the one
spec conflict it raised, and its two findings (a failed *rebuild* keeps the
previous value; a one-shot failure flag is unreliable in a widget test).

---

## SCOPE — Phase 5: AI OCR + Smart Matching + Notifications

Per `MASTER_PLAN.md` Phase 5. The service seams already exist as stubs in
`app/lib/services/` with `TODO(phase-5)` markers; implementing them is part of
this phase.

### A) DATABASE (a new migration, 00022 or later)

- Enable `pgvector`.
- `products.embedding` — the vector the fuzzy match searches.
- `device_tokens` — one row per device a notification can reach.
- `notification_logs` — what was sent, to whom, and what happened to it.

Every new table carries `pharmacy_id` and RLS scoped by `get_my_pharmacy_id()`
(D-004), and the migration is a **new file**, never an edit to an applied one —
D-013 established that, `00016` and `00020` followed it, and `00021` is the
current head.

### B) EDGE FUNCTIONS (~5, per the plan)

`supabase/functions/` does not exist yet — this phase creates it:

- `ocr-purchase-bill` — a supplier bill image in, structured data out (Gemini
  Vision);
- `save-purchase-from-ocr` — turn that data into a purchase through the same
  write path the screens use;
- `match-product` — fuzzy/vector match of an OCR line to a catalogue product;
- `send-notification` — WhatsApp/FCM/Email dispatch, writing
  `notification_logs`;
- `chat-sql-agent` — natural-language questions over the pharmacy's own data.

**Contract:** functions act as the signed-in user. They read the user's JWT and
let RLS scope the query — never `service_role` for reads (D-004).

### C) FLUTTER

- `features/purchase_ocr/` — capture (or pick) a bill image, show what the OCR
  read, let the user correct it, then create the purchase.
- `features/notifications/` — the device-token registration and the in-app list.
- Implement the stubs: `OcrService`, `WhatsappService`, `EmailService`,
  `NotificationService` (whose markers still say `TODO(phase-2)` — stale; this is
  the phase that owns them).

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, taken synchronously from
  `requirePharmacyIdProvider`. Never `await …requirePharmacyIdProvider.future`
  (D-015).
- **Stock moves through triggers, never through the client.** Quantity is
  `product_batches.qty`; a purchase moves it only by reaching `received` through
  `PurchasesRepository.receive` (D-011/D-012/D-013), and a sale only through
  `checkout_sale` (D-023). An OCR flow that creates a purchase must go through
  that same repository — not insert rows itself.
- **Money is computed once, by a pure helper, and both the screen and the write
  use it** — `PurchaseTotals`, `PurchaseReturnTotals`, `SaleTotals`/`PosCart`,
  with `PurchaseTotals.round2` as the shared rounding rule.
- **A document that has posted stock is corrected by a return, never by an
  edit** (D-013, D-019, D-023). An "OCR got it wrong, let me fix the invoice"
  path must therefore create a corrected document or a return, not rewrite a
  received one.
- **A report is one server-side aggregate, never rows summed in Dart** (D-025).
  If `chat-sql-agent` answers with figures, they come from the database.
- **A screen that is not a shell destination nests under the one that owns it**
  (D-022) — `/purchase/ocr`, not `/ocr`.
- **`check_violation` (23514) messages reach the user verbatim.** Do not swallow
  them.
- `products.embedding` is a **new column on a table**, so the `product_stock` and
  `batch_status` views are unaffected (they are `select b.*` expanded at creation
  — D-021's trap). Do not assume a new column is visible through a view.

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
- A class that is not a table row (an RPC envelope, a cart) is a plain class, not
  Freezed — `ReportSummary` and `PosCart` are the precedents.
- Consumer method names are `<verb><Entity>` (`createProduct`) — the generated
  base class already defines `update`.
- State that must outlive navigation needs `@Riverpod(keepAlive: true)`; a
  kept-alive provider may only depend on kept-alive providers.
- Riverpod 3 has no `AsyncValue.valueOrNull`, and `copyWithPrevious` is
  `@internal` — a failed `loadMore` restores the previous page and rethrows.
- A failed *rebuild* keeps the previous value: `hasError && !hasValue` is only
  true on a first read, so a screen that wants a retry control on every failure
  must not treat "nothing selected yet" as an empty value (T-3).
- `Override` is declared in `riverpod`, not re-exported by `flutter_riverpod`:
  provider override lists in tests must be inferred.
- Render provider failures through `describeError()`; the raw error reaches a
  screen wrapped in `ProviderException`.
- No business logic in widgets. A write that must not be reordered lives in the
  repository, and the invalidation of everything a write changes lives in the
  controller — anything that moves stock calls `refreshStockReaders` from
  `features/inventory/application/stock_readers.dart` (D-023).
- A controller owns its `TextEditingController`s and reports every change up
  through a **listener**, not only `onSubmitted` — a browser and a desktop have
  no submit key.
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
  viewport.

---

## OPEN ITEMS PHASE 5 SHOULD NOT MAKE WORSE

| ID | Issue |
|---|---|
| T-2 | Phase 3 has **no Dart tests** — `test/features/sales/` does not exist. Medium; the obvious first task of any chat that touches sales. |
| T-3 | The ledger's failure path offers a retry only on a first read. Low. |
| I-1 | `lowStock` decides `total_qty < min_stock_level` in Dart over at most 500 candidates. Low. |
| I-2 | A purchase return is two statements, so a refused line set can leave a header with no lines. Low. |
| I-3 | A return form offers at most 200 received purchases. Low. |
| R-1 | `README.md` still describes the project as "Phase 0 (scaffold)". Phase 6 owns documentation. |
| W-1 | Windows build fails (STL1011). Phase 6. |
| A-1 | `anonKey` is deprecated in `supabase_flutter` 2.17. Phase 6. |

---

## END-OF-CHAT HANDOFF

This is the last chat with a planned successor, so there is no `chat5` brief to
write. When Phase 5 and Phase 6 are complete (or context ~600k):

1. Run all gates, paste raw output.
2. Update `PROGRESS.md` — Phase 5 and Phase 6 COMPLETE, pruning resolved open
   items.
3. Create `context/chat4-summary.md`.
4. Add any new decision to `DECISIONS.md` (next free id after **D-025** is
   **D-026**).
5. Output a numbered list of every file created / modified / deleted.

If you finish Phase 5 and the context is healthy, carry straight on into Phase 6
rather than handing off mid-plan.

## BEGIN

Start with the migration: `pgvector`, `products.embedding`, `device_tokens` and
`notification_logs`, with a `supabase/tests/*.sql` script that is atomic, rolls
itself back and asserts the numbers — the way `phase2_stock_triggers.sql`,
`phase3_sale_triggers.sql` and `phase4_report_summary.sql` do. Verify the
extension and the embedding column against the live project before building
anything on them, then build `features/purchase_ocr/` against a deployed
`ocr-purchase-bill` function.
