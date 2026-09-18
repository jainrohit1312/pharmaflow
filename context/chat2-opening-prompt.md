# Chat 2 — Phase 1 + Phase 2: Masters + Purchase/Inventory

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP
built with Flutter + Supabase (hosted).

This chat covers TWO phases because the model has 1M token context:

- **Phase 1:** Product + Supplier + Customer Masters
- **Phase 2:** Purchase + Inventory + Batch Tracking

---

## STEP 0 — READ FIRST (do NOT skip)

Read in this exact order:

1. `PROGRESS.md`
2. `MASTER_PLAN.md`
3. `DECISIONS.md`
4. `HANDOFF_PROTOCOL.md`
5. `context/phase0-summary.md`
6. `context/chat2-opening-prompt.md` (this file)

After reading, output a 5-line summary confirming you understand:

- Phases to do (Phase 1 + Phase 2)
- Phase 0 deliverables
- Environment (hosted Supabase, no Docker, Web-first)
- Two load-bearing dependency pins
- What you're about to build

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`
- Migrations: `supabase db push`
- Platform priority: Web -> Windows -> Android -> iOS
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0
- DO NOT modify: `riverpod_lint` range, `custom_lint`, `freezed`, `sdk` pins

---

## PHASE 1 SCOPE — Masters

Three complete modules with full CRUD.

### A) PRODUCTS

- Products CRUD: `name`, `generic_name`, `brand`, `manufacturer`, `hsn_code`,
  `category`, `schedule_type`, `pack_size`, `unit`, `min_stock_level`,
  `rack_location`, `barcode`
- Multi-batch view per product (FEFO sorted)
- Schedule badges (OTC/H/H1/X/narcotic)
- Search by name/generic/barcode
- Filter by `schedule_type`
- Low stock indicator
- Expiry status badges from the `batch_status` view
- Product aliases tab

### B) SUPPLIERS

- CRUD: `name`, `gstin`, `drug_license_no`, `contact_person`, `phone`,
  `email`, `address`, `city`, `state`, `pincode`, `credit_days`,
  `opening_balance`
- List + search + active filter
- Detail: contact info, purchase history placeholder, ledger balance

### C) CUSTOMERS

- CRUD: `name`, `phone`, `email`, `address`, `gstin`, `opening_balance`,
  `loyalty_points`
- List + search + active filter
- Detail: contact info, purchase history placeholder, ledger balance

### PHASE 1 ARCHITECTURE PATTERN

For each module `<X>`:

```
app/lib/features/<X>/
  data/<X>_repository.dart
  application/<X>_list_controller.dart    @riverpod AsyncNotifier
  application/<X>_form_controller.dart
  application/<X>_detail_controller.dart
  presentation/<X>_screen.dart
  presentation/<X>_form_screen.dart
  presentation/<X>_detail_screen.dart
  presentation/widgets/<X>_card.dart
  presentation/widgets/<X>_filter_bar.dart
```

Rules:

- `@riverpod` codegen only
- Freezed models already exist — extend if needed
- Use AppButton, AppTextField, LoadingView, ErrorView
- GoRouter for navigation
- No business logic in widgets
- SnackBar via `ref.listen` for success/error
- Confirmation dialog for delete

### PHASE 1 ROUTES

Update `app/lib/core/router/routes.dart` and `app_router.dart`:

- products, productForm, productEdit, productDetail
- suppliers, supplierForm, supplierEdit, supplierDetail
- customers, customerForm, customerEdit, customerDetail

Add suppliers + customers to the dashboard nav.

---

## PHASE 2 SCOPE — Purchase + Inventory + Batch Tracking

### A) PURCHASE

- Purchase Order creation (draft, ordered status)
- Goods Receipt Note (GRN) entry — manual
- Batch auto-creation from GRN
- Purchase return with reason
- Supplier-wise purchase history

### B) INVENTORY

- Real-time stock view (from the `product_stock` view)
- Low stock alerts
- Expiry dashboard (safe/warning/critical/expired)
- FEFO display in product detail
- Stock adjustment (audit trail via `stock_adjustments` table)
- Dead stock + fast-moving report

### C) BATCH TRACKING

- Batch list per product
- Expiry calendar view
- Near-expiry alerts (30/90 day thresholds)

### PHASE 2 SUPABASE NOTES

- No new tables — all exist from Phase 0.
- The ledger/stock/audit trigger functions are commented in
  `20260918000010_triggers.sql` with `TODO(phase-2)` markers (lines 150, 200,
  266, 298, 340). You may need to uncomment + activate them now.
- If schema changes are needed, add migration
  `20260918000015_phase2_extras.sql` (idempotent) and push via
  `supabase db push`.

### PHASE 2 ARCHITECTURE

Same pattern as Phase 1:

```
app/lib/features/purchase/
  data/purchase_repository.dart
  application/purchase_list_controller.dart, purchase_form_controller.dart,
    grn_controller.dart
  presentation/purchase_screen.dart, purchase_form_screen.dart,
    grn_screen.dart, purchase_detail_screen.dart

app/lib/features/inventory/
  data/inventory_repository.dart
  application/stock_controller.dart, expiry_controller.dart,
    adjustment_controller.dart
  presentation/inventory_screen.dart, expiry_dashboard_screen.dart,
    stock_adjustment_screen.dart

app/lib/features/returns/
  (purchase returns portion only — sale returns are Phase 3)
```

---

## DELIVERABLES

1. Supabase: any new migrations (idempotent)
2. Flutter: ~160 files across both phases
3. Tests: unit + widget for both phases
4. Verification gates:

```
flutter pub get
dart run build_runner build --delete-conflicting-outputs
dart run custom_lint
flutter analyze
flutter test
supabase db push --dry-run
```

All must pass with **ZERO warnings and ZERO INFOs**.

---

## WORKFLOW RULES

- Write FULL file contents, never truncate
- `@riverpod` codegen for all providers
- Freezed: `abstract class X with _$X`
- Every DB query scoped by `pharmacy_id`
- No business logic in widgets
- Run `flutter analyze` after each module
- Stop after Phase 1, run gates, output summary, then continue to Phase 2
- Stop after Phase 2, run gates, output summary, do handoff

---

## END-OF-CHAT HANDOFF (mandatory)

When both phases complete (or context ~600k tokens):

1. Run all verification gates, paste raw output
2. Update `PROGRESS.md` (Phase 1 + Phase 2 COMPLETE)
3. Create `context/chat2-summary.md`
4. Create `context/chat3-opening-prompt.md` (Phase 3 + Phase 4)
5. Update `DECISIONS.md` if new decisions
6. Output a numbered list of all files created/modified

Do NOT proceed to Phase 3 in this chat.

---

## BEGIN

Start with Phase 1 (products module first: data -> controller -> UI).
After Phase 1 completes and gates pass, continue directly to Phase 2.
Run `flutter analyze` after each module and fix all issues immediately.
