# Chat 3 — Phase 3 + Phase 4: Sales/POS, Returns & GST Billing + Ledger, Payments & Reports

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built
with Flutter + Supabase (hosted).

**Phases 0, 1 and 2 are complete and gated.** This chat builds the counter side
of the business — what a sale does to stock and to the ledger — and then the
ledger reports that read it. Do **not** re-do purchase, inventory or master
screens, and do not start Phase 5.

---

## STEP 0 — READ FIRST (do NOT skip)

Read in this exact order:

1. `PROGRESS.md`
2. `MASTER_PLAN.md`
3. `DECISIONS.md`
4. `HANDOFF_PROTOCOL.md`
5. `context/chat2c-summary.md` (what the previous session built)
6. `context/chat2d-opening-prompt.md` (this file)

Then output a 5-line understanding check:

- What Phase 3 and Phase 4 cover
- What the previous session delivered
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

`dart format` is not itself a gate, but the committed tree *is* formatter
output, so run it after writing Dart and before the gates; a "Changed" verdict
means the new code drifted, not that the repo is dirty. (T-1's SDK language
notice from `build_runner` and `custom_lint` is known and cosmetic.)

**Never run two `build_runner` processes at once** — concurrent runs corrupt
`.dart_tool`. If you use parallel subagents, the main agent runs codegen once at
the end.

**Analyzer note (learned the hard way):** `avoid_redundant_argument_values` and
`unused_element_parameter` fire on test helpers whose arguments equal the
built-in defaults (`DateTime(2026, 1)`, `buildItem(id: 'item-1', …)`, a fixture
parameter nothing passes). `flutter analyze` must be clean, so write fixtures
without redundant defaults from the start: `DateTime(2026)` not `DateTime(2026, 1)`.

---

## WHAT THE PREVIOUS SESSIONS DELIVERED

**Phase 0** — schema (21 tables, 2 views, RLS on every business table), auth,
the dashboard shell.

**Phase 1** — products (multi-batch FEFO view, aliases, schedule badges,
search/filters), suppliers and customers masters, at full CRUD.

**Phase 2** — purchase, inventory, batch tracking and purchase returns:

- `features/purchase/` — list, order form, GRN and detail, over
  `PurchasesRepository` (`create`, `updateDraft`, `setStatus`, `receive`) and
  `PurchaseTotals` (the money math both the write and the screens use).
- `features/inventory/` — Stock / Low stock / Expiry tabs on `/inventory`, an
  expiry calendar on `/inventory/calendar`, and a stock-adjustment sheet
  reachable from the expiry list and from the product detail's Batches tab.
- `features/returns/` — the **purchase** side of returns: list, form and detail
  over `PurchaseReturnsRepository`.
- Migrations `00015` (the Phase 2 automation) and `00016` (landed cost) are live
  on the hosted project. Nothing was added in the last chat.
- Gate result: `custom_lint` clean, `analyze` clean, `flutter test` +237.

Read `context/chat2c-summary.md` for the two bugs found and fixed, the three open
items (I-1 to I-3) and the one documentation item (R-1).

---

## SCOPE — Phase 3: Sales/POS + Returns + GST Billing

### A) FIRST, THE MIGRATION (before any screen)

The sale-side automation is **still commented out** in
`supabase/migrations/20260918000010_triggers.sql` with `TODO(phase-2)` markers:

- `ledger_auto_entry_sale()` — line 200 (posts the customer's debit)
- `stock_update_on_sale()` — line 296 (decrements `sale_items.batch_id`, raises
  `check_violation` rather than overselling)
- `write_audit_log()` — line 340 (generic audit trigger)

Enabling them is **a new migration, not an uncomment**, for the reason D-013
records: 00010 is already applied on the hosted project, and `supabase db push`
only applies versions missing from `supabase_migrations.schema_migrations`.
Editing an applied file would leave the repo looking enabled while the database
stayed inert.

What the new migration must also cover, because the shipped blocks do not:

- a **restock path for `sale_return_items`**. `sale_returns.restock boolean`
  exists and is documented as "false when goods are damaged/not resellable, so
  the later trigger skips stock restoration" — that later trigger does not exist
  yet, and neither does a sale-return ledger entry
  (`ledger_reference_type` already has `'sale_return'`);
- the same idempotency thinking the purchase side needed: a sale reaches
  `completed` once as far as stock is concerned (D-013's shape, and
  `purchases.stock_posted_at` is the precedent for a one-way marker);
- indexes any new read path needs (see migration 00015 for the pattern).

Verify the migration the way Phase 2 did: a `supabase/tests/*.sql` script that
is atomic, rolls itself back, and asserts the numbers
(`supabase db query --linked --file …`).

### B) SALES / POS

`features/sales/` — currently only `presentation/sales_placeholder.dart`.
`Routes.sales` (`/sales`) exists and the shell lists "Sales" in both the rail and
the bottom bar, so reaching a screen needs no `dashboard_shell.dart` change.

Tables (already exist, migration 00006): `sales` (`sale_status`, `payment_mode`,
`amount_paid`, `balance_due`, `place_of_supply`, unique
`(pharmacy_id, invoice_no)`), `sale_items` (`batch_id` **not null**,
`discount_percent`, `discount_amount`, the tax heads, and a `schedule_type`
snapshot).

- **Cart + checkout** — search/pick a product, choose the batch, quantity,
  discount and slab; the totals must be computed by a pure, tested helper the
  way `PurchaseTotals` is, and the row written by the repository must equal what
  the screen showed.
- **FEFO** — a sale must come out of the earliest-expiring batch that has stock.
  `batch_status` already orders by `expiry_date` (and `ProductsRepository.
  batchesFor` already returns it FEFO), and `features/inventory` owns the reads.
- `sale_items.batch_id` is `not null` and `on delete restrict`: a sale line
  always names its batch, so the batch has to be chosen (or defaulted FEFO)
  before the write, not after.
- `sale_items.schedule_type` is a **snapshot** for the statutory register, not a
  join — take it from the product at sale time.
- Schedule H/H1/X sales are what the drug register reports on; a prescription
  reference is not in the schema, so do not invent a column for it.

### C) GST BILLING + PRINT

- GST invoice layout from the `sales` and `sale_items` columns: intra-state
  (CGST+SGST) vs inter-state (IGST) from `sales.place_of_supply` and the
  pharmacy's own state — `PurchaseTotals.splitFor` is the existing precedent for
  deciding that, and `pharmacy_repository` already reads the pharmacy's state.
- Thermal print: web uses PDF, Windows uses native (D-005).
- `amount_paid` / `balance_due` / `payment_mode` are on `sales`; a credit sale is
  `status = 'credit'`. **Payments against a customer belong to Phase 4** — a
  credit sale records the debt, and `payments` in Phase 4 settles it.

### D) SALE RETURNS — extend `features/returns/`, do not rebuild it

The purchase side is done and lives in the same feature directory, behind the
same `/returns` destination:

- `/returns` lists purchase returns today; it must list or tab sale returns too,
  without breaking the purchase list;
- `sale_returns` (with `restock`, `refund_mode`) and `sale_return_items` (with
  `sale_item_id`, `batch_id`, `rate`) already exist — no new tables;
- **restock only when `restock` is true**, and take the units back into the batch
  the sale came from, which is on the sale line;
- the money has the same question to answer as D-020's purchase return: credit
  the customer from the sale line's own stored amounts (it stores
  `discount_amount` and the tax heads) rather than recomputing from the rate.

---

## SCOPE — Phase 4: Ledger + Payments + Reports

### A) LEDGER

`features/ledger/` — currently only `presentation/ledger_placeholder.dart`.
`Routes.ledger` exists.

- `ledger_entries` is append-only and ready:
  `party_type` + exactly one of `supplier_id`/`customer_id` (a DB check enforces
  it), `reference_type` (`'opening'`, `'purchase'`, `'purchase_return'`,
  `'sale'`, `'sale_return'`, `'payment'`, `'expense'`, `'adjustment'`),
  `reference_id` (polymorphic, **not** FK-enforced), `debit`, `credit`.
- A purchase already posts its supplier credit automatically
  (`ledger_auto_entry_purchase()`, migration 00015). **A purchase return does
  not post yet** — that is a gap this phase should close, with
  `reference_type = 'purchase_return'` and the credit note's `grand_total`
  (D-020 defines that number).
- `data/repositories/ledger_repository.dart` and `party_balance.dart` already
  exist (built in Phase 1 for the supplier/customer detail screens). Extend
  them; do not add a second ledger repository.
- A party's balance is `sum(credit) - sum(debit)` shaped for suppliers and the
  reverse for customers — read the existing screens' expectations before
  changing the shape.

### B) PAYMENTS

- `payments` (migration 00007) — `party_type` + exactly one party id, `amount >
  0`, `mode`, `reference_no`, `payment_date`. Recording a payment should write a
  `ledger_entries` row with `reference_type = 'payment'`, in the same
  transaction as the payment itself (one statement, or an RPC if you cannot).
- Payments appear on the supplier/customer detail screens, which already show a
  read-only balance.

### C) REPORTS

`features/reports/` — currently only `presentation/reports_placeholder.dart`.

- `expenses` (migration 00007) has no UI at all yet; a simple expense entry form
  is the smallest thing that makes a P&L meaningful.
- Reports worth having, all readable from what exists: day-book / sales summary,
  GST summary (output tax from `sale_items`, input tax from `purchase_items`),
  gross margin by product, stock valuation (from `product_stock`, which already
  values at landed cost — D-012), expiry loss (from `batch_status`).
- Keep report queries server-side and paged; a report that loads every sale
  ever made will not survive a year of trading.

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, taken synchronously from
  `requirePharmacyIdProvider`. Never `await …requirePharmacyIdProvider.future`
  (D-015).
- **Stock moves through triggers, never through the client.** Quantity is
  `product_batches.qty` and nothing else; a sale, a return restock and an
  adjustment are the writes that change it (see D-021's closing note).
- **`batch_status` carries no `landed_cost_per_unit`** — a view's `select b.*` is
  expanded when the view is created, and migration 00016 added that column to the
  table afterwards. If a report needs cost per batch, that is a migration
  (appending a column to a view is allowed) or a read of `product_batches`.
- **`check_violation` (23514) messages reach the user verbatim.** The triggers
  name the batch and the item, and `mapPostgrestException` deliberately keeps
  that message for `23514` rather than inventing a vaguer one. Do not swallow it.
- **Money is computed once, by a pure helper, and both the screen and the write
  use it** — `PurchaseTotals` (purchase), `PurchaseReturnTotals` (purchase
  return). A sale needs the same treatment, and `PurchaseTotals.round2` is the
  shared rounding rule (half away from zero, with an epsilon).
- A document that has posted stock may not be silently edited: "received is
  immutable" (D-013) is the purchase shape, and D-019 is its one-level-up
  consequence for `ordered` documents. Sales and sale returns need the same
  thinking before they get an edit screen.

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
- Consumer method names are `<verb><Entity>` (`createProduct`) — the generated
  base class already defines `update`.
- State that must outlive navigation needs `@Riverpod(keepAlive: true)`; a
  kept-alive provider may only depend on kept-alive providers.
- Riverpod 3 has no `AsyncValue.valueOrNull`, and `copyWithPrevious` is
  `@internal` — a failed `loadMore` restores the previous page and rethrows.
- `Override` is declared in `riverpod`, not re-exported by `flutter_riverpod`:
  provider override lists in tests must be inferred.
- Render provider failures through `describeError()`; the raw error reaches a
  screen wrapped in `ProviderException`.
- No business logic in widgets. A write that must not be reordered lives in the
  repository, and the invalidation of everything a write changes lives in the
  controller (see `StockAdjustmentController._refreshStockReaders`).
- `DropdownButtonFormField` takes `initialValue`, not `value`, after Flutter
  3.33.
- A controller owns its `TextEditingController`s and reports every change up
  through a **listener**, not only `onSubmitted` — a browser and a desktop have
  no submit key (this cost a bug in the returns form; see chat2c's summary).
- Shared widgets to reuse rather than re-create: `AppScaffold`, `AppButton`,
  `AppTextField`, `AppDropdownField`, `AppDateField`, `AppSearchField`,
  `SectionCard`, `StatusBadge`, `ExpiryBadge`, `AppEmptyView`, `ErrorView`,
  `LoadingView`, `showConfirmDialog`, `AppBackButton`, `Validators`
  (`positiveInt`, `nonNegativeInt`, `nonNegativeDecimal`),
  `Formatters.currency/dateDdMmmYyyy/monthYear`, `Debouncer`.
- `test/support/` has fakes that **run the real rules** (`fake_purchases_
  repository`, `fake_inventory_repository`, `fake_purchase_returns_repository`),
  and mini-router pump helpers (`purchase_test_app.dart`,
  `inventory_test_app.dart`, `returns_test_app.dart`). Follow that shape: a
  screen test should fail when a screen skips a check the write enforces.
- A test window is made tall in the pump helper (`tester.view.physicalSize`)
  rather than scrolled, because a `SliverList` only mounts what is inside the
  viewport.

---

## END-OF-CHAT HANDOFF

When both phases are complete (or context ~600k):

1. Run all gates, paste raw output.
2. Update `PROGRESS.md` — Phase 3 and Phase 4 COMPLETE, pruning resolved open
   items (I-1 to I-3 and R-1 are still open unless this chat closes them).
3. Create `context/chat3-summary.md`.
4. Create `context/chat4-opening-prompt.md` (Phase 5 + Phase 6).
5. Add any new decision to `DECISIONS.md` (next free id after D-021 is **D-022**).
6. Output a numbered list of every file created / modified / deleted.

Do **not** proceed to Phase 5 in this chat.

## BEGIN

Start with the migration that enables the sale-side automation (it is
prerequisite for every screen that follows, and D-013 is the precedent for how
to do it), verify it with an atomic SQL test, then build sales/POS against it,
then sale returns in the existing `features/returns/`, then the ledger work. Run
`flutter analyze` after each module and fix everything immediately.
