# Chat 2b Summary — Phase 2: Purchase Module Presentation Layer

**Status:** COMPLETE (purchase module only — Phase 2 is not finished)
**Date:** 2026-09-18
**Phase:** Phase 2 (`Purchase + Inventory + Batch Tracking`) — purchase is done,
inventory / batch tracking / purchase returns are not.
**Started from:** commit `69c6d0a` (crash-recovery point) — a previous session
crashed mid-write of `purchase_line_editor.dart`.

---

## Supabase Changes

**None.** No migration was added or pushed, so `supabase db push --dry-run` was
not part of the gate run. The Phase 2 automation the module writes against
(migration `00015`, `00016`) is unchanged and still live on the hosted project.

---

## Flutter Files Created

### Application / shared

```
app/lib/features/suppliers/application/supplier_options.dart
  supplierOptions — every supplier of the pharmacy, for pickers and name
  lookups outside the supplier master. Includes inactive suppliers on purpose:
  history references them, and a dropdown handed a value it does not carry
  asserts.
```

```
app/lib/core/widgets/app_date_field.dart
  AppDateField — the shared date field. Wrapped in a `FormField` so a required
  date is reported by `Form.validate()` at the field, not through a SnackBar
  raised by the write one layer away. Extracted because three places need it:
  the invoice date on both forms, and the manufacturing/expiry date on a
  receipt line.
```

### Purchase presentation

```
app/lib/features/purchase/presentation/purchases_screen.dart       (list)
app/lib/features/purchase/presentation/purchase_form_screen.dart   (order)
app/lib/features/purchase/presentation/grn_screen.dart             (receipt)
app/lib/features/purchase/presentation/purchase_detail_screen.dart (detail)

app/lib/features/purchase/presentation/widgets/purchase_line_editor.dart
app/lib/features/purchase/presentation/widgets/purchase_card.dart
app/lib/features/purchase/presentation/widgets/purchase_filter_bar.dart
app/lib/features/purchase/presentation/widgets/purchase_status_badge.dart
app/lib/features/purchase/presentation/widgets/purchase_locked_view.dart
```

### Tests

```
app/test/support/fake_purchases_repository.dart
app/test/support/purchase_test_app.dart
app/test/features/purchase/presentation/purchases_screen_test.dart       (5)
app/test/features/purchase/presentation/purchase_form_screen_test.dart   (6)
app/test/features/purchase/presentation/grn_screen_test.dart             (6)
app/test/features/purchase/presentation/purchase_detail_screen_test.dart (4)
```

---

## Flutter Files Modified

```
app/lib/core/router/routes.dart
  + purchaseGrnForm (/purchase/grn), purchaseForm (/purchase/new),
    purchaseEditPattern, purchaseGrnPattern, purchaseDetailPattern and the
    three path builders.

app/lib/core/router/app_router.dart
  Routes.purchase now builds PurchasesScreen; five new GoRoutes, declared
  list-first then literal-then-parameterised, so `/purchase/grn` and
  `/purchase/new` are not read as document ids.

app/lib/features/purchase/presentation/widgets/product_picker_field.dart
  + `selectedName`. An existing document stores a line's product id and a
  displayed name, not the catalogue row, so a form seeded from one had a name
  with no `Product` and the field claimed the line was empty.

app/lib/features/purchase/presentation/widgets/purchase_totals_preview.dart
  The two `prefer_int_literals` infos: `fold<double>(0, …)` instead of
  `fold(0.0, …)`.
```

## Flutter Files Deleted

```
app/lib/features/purchase/presentation/purchase_placeholder.dart
  Replaced by the real list screen, exactly as products_placeholder.dart was
  in Phase 1.
```

---

## Verification Evidence (raw)

```
dart format lib test
  Formatted 207 files (0 changed) in 1.12 seconds.

dart run build_runner build --delete-conflicting-outputs
  Built with build_runner in 66s with warnings; wrote 69 outputs.
  W SDK language version 3.12.0 is newer than `analyzer` language version 3.11.0.
    Run `flutter packages upgrade`.          <- known issue T-1, cosmetic

dart run custom_lint
  No issues found!

flutter analyze
  No issues found! (ran in 11.5s)

flutter test
  00:33 +191: All tests passed!
```

`+191` is 170 (the crash-recovery point) plus the 21 new purchase-screen tests.
No pre-existing test changed behaviour.

---

## What Was Built

**List** (`/purchase`) — search over invoice number and notes, a supplier
dropdown, status chips and an invoice-date range; paged with load-more; a
"Receive goods" app-bar action and a "New" FAB.

**Order form** (`/purchase/new`, `/purchase/:id/edit`) — supplier, invoice
number, invoice date, notes, and lines with product, quantity, free quantity,
rates, discount and GST. No batch fields: batches are what a *receipt* creates.
"Save draft" and "Save and mark ordered" when creating, "Save changes" when
editing. Refuses to open for a document whose stock is booked in.

**Goods receipt** (`/purchase/grn`, `/purchase/:id/grn`) — the only write that
posts stock and a supplier payable. Two ways in: receiving an order raised
earlier, and a standalone receipt for goods that arrived with no order behind
them. The standalone case creates the document as a draft and receives it in the
same action, so a failure in between leaves a draft carrying the lines the user
typed — visible on the list, receivable again from its detail screen — rather
than losing them.

**Detail** (`/purchase/:id`) — the invoice, the stored totals (read off the
document's own columns, since those are what `ledger_auto_entry_purchase()`
posted), the lines with their batches, and the next step. Receiving, marking
ordered and cancelling all live here.

---

## Key Decisions

1. **The order form and the receipt are separate screens, and a status change
   never receives.** `PurchasesRepository.setStatus` refuses `received`, which is
   D-013 already; the screens now match, so there is one route into the receipt
   and it cannot be reached by forgetting an order of operations.

2. **One shared date field:** the new `AppDateField` serves the invoice date on
   both forms and the manufacturing/expiry date on a receipt line. It reports
   through `FormField`, so inline validation and `Form.validate()` agree, and a
   missing expiry is named at the field that caused it.

3. **Detail totals are displayed from storage, not recomputed.** `sub_total`,
   `discount_total`, `tax_total` and `grand_total` come off the row so the screen
   cannot disagree with the ledger by a paisa; the tax *head* is summed from the
   lines, because CGST/SGST/IGST are only stored per line.

4. **A new line starts on the 12% GST slab**, documented at the call site. Zero
   asserts nothing but is wrong for almost every medicine; the slab is on screen
   and editable either way.

---

## Two Bugs Found and Fixed While Testing

Both were in code written this session, and both were caught by the widget tests
rather than by the analyzer.

1. **A picked date never reached the draft.** `PurchaseLineEditor` reported every
   text field through its controllers, but `AppDateField.onChanged` only called
   `setState` — so the parent's `PurchaseLineDraft` kept `expiryDate: null`, the
   form validated, and the receipt was then refused by the repository's own
   `validateLines`. Both date handlers now call `_emit()`. Found by
   `grn_screen_test.dart` → "a standalone receipt creates and receives in one
   action".

2. **A stale document provider reached the next screen.** After a successful
   write the form invalidated the list but not `purchaseWithLines(id)`, and a
   document provider still cached against the screen that wrote it handed the
   detail screen the pre-write copy — a received document rendering its "next
   step" panel as if nothing had been posted. Both the form and the receipt now
   invalidate the document as well as the list. Found by
   `grn_screen_test.dart` → "receives an existing document and opens what it
   posted".

---

## Open Risks / Blockers

**O-1 — editing an `ordered` document silently returns it to `draft`.**
`PurchasesRepository.updateDraft` writes
`_totalsPayload(…, status: PurchaseStatus.draft)` unconditionally, so saving
changes to an ordered purchase resets its status. This is in a layer the user
declared complete, so it was **not changed**; it is documented on
`PurchaseFormScreen` and recorded in `PROGRESS.md` as an open item. Either the
reset is deliberate ("an edited order must be re-confirmed") and the UI should
say so, or it is an oversight and the status should be carried through.

**O-2 — the standalone receipt writes a draft before it receives.**
Deliberate (see "What Was Built"), but it means a failed receipt leaves a
document behind. It is recoverable by design, not invisible; no cleanup was
added.

**O-3 — a purchase list shows at most 500 suppliers by name.**
`supplierOptionsLimit` bounds the lookup a card and a picker use, so a pharmacy
with more than 500 suppliers would see an unnamed card for a supplier past the
cut. Not a security or correctness problem, and far past a realistic count; the
fix if it ever matters is a searchable supplier picker, as the product picker
already is.

---

## What's Next

Phase 2 is **not** finished — the purchase third of it is. Remaining, per
`MASTER_PLAN.md` and the Phase 2 scope:

1. **Inventory** — stock view from the `product_stock` view, low-stock list,
   expiry dashboard (safe/warning/critical/expired from `batch_status`), stock
   adjustments (which move batches through `stock_apply_adjustment()` and raise
   `check_violation` rather than going negative), FEFO display.
2. **Batch tracking** — batch list per product, expiry calendar, near-expiry
   alerts at 30/90 days.
3. **Purchase returns** — extend `features/returns/`
   (`stock_update_on_purchase_return()` is already live and refuses to oversell).
4. Phase 2 gate, then the chat handoff.

`context/chat2c-opening-prompt.md` carries the brief.
