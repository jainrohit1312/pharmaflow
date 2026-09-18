# Chat 2c — Phase 2 (continued): Inventory + Batch Tracking + Purchase Returns

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built
with Flutter + Supabase (hosted).

**The purchase module is complete.** This chat finishes Phase 2: the inventory
half of it, plus one deferred purchase-module fix (P-1). Do **not** re-do
purchase screens, and do not start Phase 3.

---

## STEP 0 — READ FIRST (do NOT skip)

Read in this exact order:

1. `PROGRESS.md`
2. `MASTER_PLAN.md`
3. `DECISIONS.md`
4. `HANDOFF_PROTOCOL.md`
5. `context/chat2b-summary.md` (what the previous session built)
6. `context/chat2c-opening-prompt.md` (this file)

Then output a 5-line understanding check:

- What is left of Phase 2
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

---

## WHAT THE PREVIOUS SESSION DELIVERED

The purchase module's full presentation layer, on top of the data and
application layers that were already complete:

- `features/purchase/presentation/` — list, order form, goods receipt, detail
- `features/purchase/presentation/widgets/` — `purchase_line_editor.dart`,
  the shared card / filter bar / status badge / locked view
- `supplier_options.dart` (`supplierOptions`) in `features/suppliers/application/`
- `core/widgets/app_date_field.dart` (`AppDateField`) — **reuse this** for any
  date you need; do not write another picker field
- Routes `/purchase`, `/purchase/new`, `/purchase/grn`,
  `/purchase/:id`, `/purchase/:id/edit`, `/purchase/:id/grn`, wired into
  `app_router.dart`; `purchase_placeholder.dart` deleted
- 21 widget tests over a shared fake (`test/support/fake_purchases_repository.dart`)
  and a mini-router pump helper (`test/support/purchase_test_app.dart`)
- Gate result: `custom_lint` clean, `analyze` clean, `flutter test` +191

Read `context/chat2b-summary.md` for the two bugs that were found and fixed, the
three open items (O-1 to O-3), and why the receipt totals are displayed from
storage rather than recomputed.

---

## SCOPE — the rest of Phase 2

### A) INVENTORY

`features/inventory/` — currently only `presentation/inventory_placeholder.dart`.
`Routes.inventory` (`/inventory`) already exists and the shell already lists
"Inventory", so no `routes.dart` / `dashboard_shell.dart` change is needed to
reach a screen — only to add child routes.

- **Stock view** — read the `product_stock` view. Columns of interest:
  `qty` (sum over batches) and `stock_value_at_cost`, which is
  `sum(qty * coalesce(landed_cost_per_unit, purchase_rate))` (D-012).
- **Low-stock list** — `products.min_stock_level` against the stock rollup.
- **Expiry dashboard** — read the `batch_status` view. The `BatchStatus` and
  `ExpiryStatus` models already exist in `data/models/`.
- **Stock adjustments** — write `stock_adjustments` rows. The live trigger
  `stock_apply_adjustment()` moves the batch in the same transaction and **raises
  `check_violation` on a decrease that would drive the batch negative**. Surface
  that as a real error, not a generic one.
- **FEFO display** — `ProductsRepository.batchesFor` already returns batches
  first-expiry-first-out; the products detail screen shows it.

### B) BATCH TRACKING

- Batch list per product (the products detail "Batches" tab already exists — do
  not duplicate it; link to it or extend it).
- Expiry calendar view.
- Near-expiry alerts at 30 and 90 days, from `batch_status`.

### C) PURCHASE RETURNS

- Extend `features/returns/` (currently only a placeholder). Only the purchase
  side belongs to Phase 2; sale returns are Phase 3.
- `stock_update_on_purchase_return()` is live: return lines decrement their
  batch and **refuse to oversell**.
- Outbound movements change quantity only. The remaining units keep the batch's
  cost basis — that is correct for a write-off (D-012), so do not "fix" it.
- `purchase_returns` / `purchase_return_items` already exist; no new tables.

### D) PURCHASE MODULE — P-1 FIX (deferred from chat2b)

`PurchasesRepository.updateDraft` writes `status = 'draft'` unconditionally.
This means saving an `ordered` purchase silently returns it to `draft` — the
form's "Save" button quietly undoes the transition to `ordered`.

**Decide and implement the correct behavior.** Two options, and the choice
depends on what "update" means semantically:

1. **Lines changed → revert to draft; metadata-only change → keep status.**
   Rationale: an `ordered` purchase has been sent to the supplier. If the
   user edits line quantities or rates, the previous order is stale and needs
   re-confirmation. If they only change notes / invoice date / reference,
   the order stands.
2. **Never revert status on update.** Rationale: `ordered` is a user-initiated
   state, not a derived one. Any explicit status change goes through
   `setStatus` (which already exists and is used by the receive flow).
   Reverting should be a separate, deliberate action.

**Recommended: option 1** — it matches the D-013 "received is immutable"
philosophy one level up: editing a document that has left draft should not
silently proceed.

**Implementation requirements:**

- Detect whether any line changed vs. metadata-only. A cheap approach: compare
  line id set + qty + rate + mrp + batch_no + expiry_date per line against what
  is loaded. Or compute a normalized hash of lines.
- If lines changed and current status was `ordered`, revert to `draft` and
  surface a SnackBar explaining the revert ("Order returned to draft because
  lines changed — review and re-confirm").
- If metadata-only, keep current status.
- Add a unit test in `test/features/purchase/` covering both branches.
- Document the decision in `DECISIONS.md` as **D-019**:

```
## D-019 — Editing an Ordered Purchase Reverts to Draft When Lines Change

**Decision:** `updateDraft` reverts `status` to `draft` only when line items
change (qty, rate, mrp, batch, expiry). Metadata-only edits (notes, invoice
date, reference) preserve the current status.

**Rationale:** An `ordered` purchase has been sent to the supplier. If lines
change, the supplier's confirmed order is stale and needs re-confirmation.
Metadata changes do not invalidate the order.

**Consequences:** UI must surface the revert with a clear message. If the user
wants to cancel an order entirely, `setStatus` is the explicit path.
```

### Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, taken synchronously from
  `requirePharmacyIdProvider`. Never `await …requirePharmacyIdProvider.future`
  (D-015).
- A purchase reaches `received` exactly once as far as stock is concerned, and
  moving it back out does **not** reverse stock or the ledger (D-013).
- Scheme/free goods count as physical stock (D-011).
- `product_batches.landed_cost_per_unit` is a **moving weighted average**, not a
  per-line overwrite (D-012).

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

Rules that this repo has already learned the hard way:

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
- No business logic in widgets. A write that must not be reordered (like the
  receipt's batch → lines → status sequence) lives in the repository.
- `DropdownButtonFormField` takes `initialValue`, not `value`, after Flutter
  3.33.
- Shared widgets to reuse rather than re-create: `AppScaffold`, `AppButton`,
  `AppTextField`, `AppDropdownField`, `AppDateField`, `AppSearchField`,
  `SectionCard`, `StatusBadge`, `AppEmptyView`, `ErrorView`, `LoadingView`,
  `showConfirmDialog`, `AppBackButton`, `PurchaseLockedView` (rename or
  generalise it if you need the same "this document is closed" message).

---

## END-OF-CHAT HANDOFF

When Phase 2's remaining scope is complete (or context ~600k):

1. Run all gates, paste raw output.
2. Update `PROGRESS.md` — Phase 2 COMPLETE, and prune the open items that are
   now resolved (including P-1).
3. Create `context/chat2c-summary.md`.
4. Create `context/chat2d-opening-prompt.md` (Phase 3 + Phase 4).
5. Add any new decision to `DECISIONS.md` (P-1 should become D-019; next free
   id after that is D-020).
6. Output a numbered list of every file created / modified / deleted.

Do **not** proceed to Phase 3 in this chat.

## BEGIN

Start with the P-1 fix (it touches the data layer and is prerequisite for a
clean `updateDraft` contract), then the inventory repository and its stock-view
controller, then the screens. Run `flutter analyze` after each module and fix
everything immediately.