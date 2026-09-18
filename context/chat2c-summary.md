# Chat 2c Summary — Phase 2 completed: Inventory, Batch Tracking, Purchase Returns

**Status:** COMPLETE — Phase 2 is finished
**Date:** 2026-09-18
**Phase:** Phase 2 (`Purchase + Inventory + Batch Tracking`)
**Started from:** commit `b425f18` (the purchase module complete; chat2b's summary
carried the brief, including the deferred P-1 fix)

---

## Supabase Changes

**None.** No migration was added, applied or needed, so `supabase db push` was
not part of this gate run. Phase 2's automation (migrations `00015`, `00016`) was
already live and verified by `supabase/tests/phase2_stock_triggers.sql` and
`supabase/tests/grn_write_order.sql` in the previous chat, and everything built
here writes through it:

- `stock_apply_adjustment()` — moves a `stock_adjustments` row's batch, raises
  `check_violation` on a decrease that would take it below zero;
- `stock_update_on_purchase_return()` — decrements a return line's batch and
  refuses to oversell.

One schema detail turned out to matter and is recorded as D-021: `batch_status`
does **not** carry `product_batches.landed_cost_per_unit`. A view's `select b.*`
is expanded when the view is created, and migration 00016 added that column to
the table afterwards. The expiry screens therefore show value at MRP, not at cost
(and never `qty x purchase_rate`, which would breach D-011/D-012 on scheme stock).

---

## Flutter Files Created

### Shared / models

```
app/lib/data/models/stock_adjustment.dart
  AdjustmentType (increase | decrease), the literal parser and the sign. No row
  model on purpose: nothing reads the table back yet - the row *is* the audit
  trail, and the batch balance it moved is read from the views.

app/lib/data/models/purchase_return.dart
app/lib/data/models/purchase_return_item.dart
  The two `purchase_returns` tables. `status` stays a plain String: the column
  has one value in use, and an enum now would guess at Phase 3's sale-return
  states.

app/lib/core/widgets/expiry_badge.dart
  ExpiryBadge + its tone mapping, moved out of
  `features/products/presentation/widgets/product_badges.dart` when the inventory
  expiry dashboard became its second caller. Two mappings of one enum would
  eventually disagree about which bucket is urgent.
```

### Inventory

```
app/lib/features/inventory/data/inventory_repository.dart
  stockList (paged, searched, in/out-of-stock), lowStock, expiringBatches,
  batchesExpiringBetween, namesFor, adjustStock. Cross-product questions; the
  per-product ones stay in ProductsRepository (D-021).

app/lib/features/inventory/application/expiry_batch.dart
  ExpiryBatch - a batch plus the product name the view does not carry.

app/lib/features/inventory/application/stock_list_controller.dart
  StockFilterController (kept alive: search, availability, clear) + the paged
  StockListController with loadMore, the same shape as the purchase list.

app/lib/features/inventory/application/low_stock_controller.dart
  lowStockList - a plain provider; no filter, no paging, no writes.

app/lib/features/inventory/application/expiry_dashboard_controller.dart
  ExpiryBucketController (kept alive, opens on `critical`) and the board: one
  read of all three buckets, the selected bucket's rows, and the counts the chips
  need.

app/lib/features/inventory/application/expiry_calendar_controller.dart
  firstOfMonth/lastOfMonth, ExpiryCalendarState (month + selected day),
  ExpiryMonth (rows + units per day), and the month's reader.

app/lib/features/inventory/application/stock_adjustment_controller.dart
  The write, plus `_refreshStockReaders()` - the one place the four stock-reading
  providers are invalidated.

app/lib/features/inventory/presentation/inventory_screen.dart
  Three tabs: Stock, Low stock, Expiry.

app/lib/features/inventory/presentation/expiry_calendar_screen.dart
  A month grid with units per day, the month's batches below, and a tapped day
  filtering that list.

app/lib/features/inventory/presentation/widgets/product_stock_card.dart
app/lib/features/inventory/presentation/widgets/expiry_batch_card.dart
app/lib/features/inventory/presentation/widgets/expiry_bucket_bar.dart
app/lib/features/inventory/presentation/widgets/stock_level_badge.dart
app/lib/features/inventory/presentation/widgets/stock_adjustment_sheet.dart
  The sheet is shown from the expiry list *and* from the product detail's Batches
  tab, and resolves to `bool` so each caller reloads its own providers - which
  keeps the dependency one way (products knows about inventory's sheet; inventory
  knows nothing about products).
```

### Purchase returns

```
app/lib/features/returns/data/purchase_return_totals.dart
  The money: a line is a proportional slice of the invoice line's stored tax and
  total (D-020), so a discounted line is not credited at list price.

app/lib/features/returns/data/purchase_returns_repository.dart
  list, byId, itemsFor, returnableFor (the four reads behind "how much of this
  line can still go back"), and create.

app/lib/features/returns/application/purchase_returns_list_controller.dart
app/lib/features/returns/application/purchase_return_form_controller.dart
  returnablePurchases (received only, most recent 200), returnableLines(id), and
  the write.
app/lib/features/returns/application/purchase_return_detail_controller.dart
  The return, its lines, and the invoice the names come from.

app/lib/features/returns/presentation/returns_screen.dart
app/lib/features/returns/presentation/purchase_return_form_screen.dart
app/lib/features/returns/presentation/purchase_return_detail_screen.dart
app/lib/features/returns/presentation/widgets/purchase_return_card.dart
```

### Tests

```
app/test/features/purchase/purchase_edit_status_test.dart            (11)
app/test/features/inventory/inventory_screen_test.dart                (8)
app/test/features/inventory/expiry_calendar_test.dart                 (8)
app/test/features/returns/purchase_return_totals_test.dart            (5)
app/test/features/returns/presentation/purchase_return_form_screen_test.dart (6)
app/test/features/returns/presentation/returns_screen_test.dart       (5)

app/test/support/fake_inventory_repository.dart
app/test/support/fake_purchase_returns_repository.dart
  Both run the real rules (the return fake computes its amounts with
  PurchaseReturnTotals), so a screen cannot pass against friendlier behaviour
  than the write applies.
app/test/support/inventory_test_app.dart
app/test/support/returns_test_app.dart
```

---

## Flutter Files Modified

```
app/lib/core/router/routes.dart
  + inventoryCalendar (`/inventory/calendar`), returnsForm (`/returns/new`),
    returnsDetailPattern and `Routes.returnDetail(id)`.

app/lib/core/router/app_router.dart
  InventoryPlaceholder -> InventoryScreen, the calendar route, and the three
  returns routes (literal before parameterised). The two placeholder imports are
  gone.

app/lib/core/utils/formatters.dart
  + monthYear, for the calendar heading.

app/lib/core/utils/validators.dart
  + positiveInt, extracted from the purchase line editor's private copy so the
    adjustment sheet and the line editor enforce one "whole number >= 1" rule.

app/lib/features/purchase/data/purchase_totals.dart
  _round2 -> the public `PurchaseTotals.round2`, shared with the return money.

app/lib/features/purchase/data/purchases_repository.dart
  The P-1 fix: updateDraft now derives the status it writes from
  `statusAfterEdit`, and `linesDiffer` is the comparison. `_requireEditable`
  returns the document instead of discarding it.

app/lib/features/purchase/presentation/purchase_form_screen.dart
  Reports the revert with a SnackBar, and its class doc now describes D-019
  rather than the old unconditional reset.

app/lib/features/purchase/presentation/widgets/purchase_line_editor.dart
  Its private `_positiveInt` replaced by `Validators.positiveInt`.

app/lib/features/products/presentation/products_detail_screen.dart
  The Batches tab gained an "Adjust this batch" action (the brief's "extend it,
  do not duplicate it") and reloads its own provider after a write.

app/lib/features/products/presentation/widgets/product_badges.dart
  ExpiryBadge and its tone extension moved to core/widgets/expiry_badge.dart;
  this file keeps ScheduleBadge.

app/test/support/fake_purchases_repository.dart
  updateDraft now calls `PurchasesRepository.statusAfterEdit`, so the fake
  applies the real D-019 rule.

app/test/features/purchase/presentation/purchase_form_screen_test.dart
  Two tests: the revert with its message, and the metadata-only edit that keeps
  the document ordered.

DECISIONS.md
  D-019 (the revert rule), D-020 (a return credits a slice of the invoice line),
  D-021 (inventory reads the views as they are; expiry value is MRP).

PROGRESS.md
  Phase 2 COMPLETE; the open-items table pruned of P-1 and extended with I-1 to
  I-3 and R-1; the Next Action section retargeted at Phase 3.
```

## Flutter Files Deleted

```
app/lib/features/inventory/presentation/inventory_placeholder.dart
app/lib/features/returns/presentation/returns_placeholder.dart
  Both replaced by real screens, exactly as products_placeholder.dart and
  purchase_placeholder.dart were before them.
```

---

## Verification Evidence (raw)

```
dart format lib test
  Formatted 256 files (0 changed) in 1.25 seconds.

dart run build_runner build --delete-conflicting-outputs
  Built with build_runner in 68s with warnings; wrote 127 outputs.
  W SDK language version 3.12.0 is newer than `analyzer` language version 3.11.0.
    Run `flutter packages upgrade`.          <- known issue T-1, cosmetic

dart run custom_lint
  No issues found!

flutter analyze
  No issues found! (ran in 9.6s)

flutter test
  01:37 +237: All tests passed!
```

`+237` is 191 (the purchase module complete) plus 46 new tests. No pre-existing
test changed behaviour, and no migration was added, so `supabase db push` was not
run.

---

## What Was Built

**P-1 (recorded as D-019).** `updateDraft` wrote `status = 'draft'`
unconditionally, so saving an `ordered` purchase silently returned it to draft.
It now reverts **only when the lines changed** and leaves a metadata-only edit
alone. The rule is `PurchasesRepository.statusAfterEdit` / `.linesDiffer` - pure,
public, unit-tested, and the same function the test fake runs. The form reports
the revert with a SnackBar, decided by comparing the status it loaded with the
status it got back.

**Inventory.** Three tabs on `/inventory`. Stock reads `product_stock` and prints
the view's own quantity and value at cost (landed cost, D-012). Low stock is
`min_stock_level > 0` narrowed server-side and compared in Dart. Expiry reads
`batch_status` in one call for all three buckets - expired, within 30 days, within
90 days - with the count on each chip. `/inventory/calendar` is a month grid with
units per day. Adjustments are written from a sheet that caps a decrease at what
the batch holds and surfaces the trigger's own `check_violation` when a concurrent
write gets there first.

**Purchase returns.** `/returns`, `/returns/new`, `/returns/:returnId`. A return
is raised against a received purchase; the form shows, per invoice line, what was
billed, what has already gone back and what is in the batch, and the write
re-derives all three rather than trusting the form.

---

## Key Decisions

1. **D-019** — an edit reverts `ordered` to `draft` only when the lines change;
   the comparison is a multiset of signature strings over the fields a supplier
   would re-confirm, at the precision the columns store, and it deliberately
   ignores line order because `purchase_items.created_at` is a transaction
   timestamp.
2. **D-020** — a return line is worth the same slice of its invoice line as the
   units it takes, from the line's **stored** amounts, because
   `purchase_return_items` has no discount column.
3. **D-021** — no new migration. Inventory reads the two views as they are; the
   expiry value is MRP because `batch_status` has no landed cost and
   `qty x purchase_rate` would breach D-011/D-012.
4. **How much may go back** is `min(billed - already returned, in the batch)`.
   "Already returned" needed a query the brief did not ask for, but without it a
   supplier could be credited twice for the same units whenever the batch held
   stock from more than one receipt.
5. **Stock adjustments are batch-scoped and reachable from two screens** - the
   expiry list and the product detail's Batches tab - because the expiry list can
   only ever show batches that are expiring soon, and a breakage is not always
   near an expiry date.

---

## Two Bugs Found and Fixed While Testing

Both were in code written this session, and both were caught by widget tests
rather than by the analyzer.

1. **A return line's quantity never reached the parent.**
   `_ReturnLineField` reported only through `onSubmitted`, so typing a quantity
   and submitting the form left `_quantities` empty: the credit preview never
   appeared and the write was refused with "enter how many units are going back".
   On a desktop or in a browser there is no submit key at all. The controller now
   carries a listener. Found by
   `purchase_return_form_screen_test.dart` → "previews the credit ...".

2. **A received line with no `batch_id` can never be returned** - which is
   correct, and the form says so, but the first fixture had none, so the line's
   quantity field never rendered. That is what `ReturnableLine.blockedReason` is
   for; the fixture now carries the batch.

(The previous chat's two bugs, recorded in `context/chat2b-summary.md`, are fixed
and still pass.)

---

## Open Risks / Blockers

**I-1 — the low-stock list is bounded.** PostgREST cannot compare two columns, so
`total_qty < min_stock_level` is decided in Dart over at most
`InventoryRepository.lowStockScanLimit` (500) rows that the server has narrowed to
`min_stock_level > 0`. A catalogue past that bound would silently omit rows. The
fix is a column on the view (a migration: `create or replace view` may append one)
or an RPC.

**I-2 — a purchase return is two statements.** The header is written first because
the lines reference it, then every line in one atomic INSERT. Stock therefore
moves for all of the lines or none of them, but a refused set can leave a header
with no lines. It is deliberately **not** rolled back: an item insert that reached
the database but whose response was lost is indistinguishable from one that never
ran, and deleting the header would cascade its lines away while the stock stayed
decremented. An empty header is visible on the list and costs nothing.

**I-3 — a return form offers at most 200 received purchases**
(`returnablePurchaseLimit`), the same trade-off as `supplierOptionsLimit`.

**R-1 — `README.md` is stale.** It still describes the project as "Phase 0
(scaffold)" with the later screens as placeholders. Phase 6 owns documentation, so
it was left alone rather than half-refreshed.

---

## What's Next

Phase 3 and Phase 4, in Chat 3:

1. **Enable the sale-side automation** still commented out in migration `00010`:
   `ledger_auto_entry_sale()`, `stock_update_on_sale()`, `write_audit_log()`. As
   in Phase 2 (D-013) that is a **new migration**, not an uncomment - 00010 is
   already applied.
2. **Sales/POS** — cart, FEFO batch selection, GST invoice, thermal print.
3. **Sale returns** — extend `features/returns/`, which already has the purchase
   side, the routes and the destination.
4. **Ledger, payments and reports** — Phase 4, which is where a purchase return's
   credit note should finally reach the ledger.

`context/chat2d-opening-prompt.md` carries the brief.
