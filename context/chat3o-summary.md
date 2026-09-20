# Chat 3o Summary — Phase 7a, the Flutter side (C1a, C1b)

**Status:** PARTIAL (Phase 7a's app is two thirds done: C1a and C1b complete and gated; C2 and C3
remain)
**Date:** 2026-09-20
**Phases done:** Phase 7a — the Flutter slices C1a (money layer, models, the nullable-expiry fix)
and C1b (the patient-first write, then its screens). The durable layer (migrations 00033–00038) was
already on hosted when this chat began.

---

## Supabase Changes

**None.** This chat changed no migration, no function and no SQL test — deliberately: the brief
forbids touching migrations 00033–00038 and modifying `checkout_sale`. The one SQL change Phase 7a's
app still needs is **migration `00039`, `sale_document(p_sale_id uuid) returns jsonb`**, whose
signature the owner approved and which is **not written yet** (see What's Next). It belongs to C3
with the receipt.

## Flutter Files Created (21)

**Money, models and the batch fix (C1a):** none — C1a changed existing files only, plus four new
test files (`test/data/models/sale_test.dart`, `product_batch_test.dart`, `customer_test.dart`,
`pharmacy_test.dart`).

**The patient-first write (C1b/1):**
- `lib/data/models/admission.dart`, `lib/data/models/doctor.dart`
- `lib/features/customers/data/patients_repository.dart`
- `lib/features/sales/data/doctors_repository.dart`
- `lib/features/sales/application/sale_requirements.dart`
- `test/data/models/admission_test.dart`, `doctor_test.dart`
- `test/features/sales/application/sale_requirements_test.dart`
- `test/features/sales/data/sale_checkout_test.dart`
- `test/support/fake_patients_repository.dart`, `fake_doctors_repository.dart`,
  `fake_pharmacy_repository.dart`

**The screens (C1b/2):**
- `lib/features/customers/application/patient_lookup.dart`,
  `patient_registration_controller.dart`
- `lib/features/customers/presentation/patients/patient_registration_sheet.dart`
- `lib/features/sales/application/admission_controller.dart`, `doctor_options.dart`
- `lib/features/sales/presentation/patients/patient_step.dart`
- `lib/features/sales/presentation/widgets/sale_type_selector.dart`, `sale_identity_fields.dart`
- `test/features/customers/presentation/patients/patient_registration_sheet_test.dart`
- `test/features/sales/presentation/patients/patient_step_test.dart`

## Flutter Files Modified (26)

**Models:** `data/models/sale.dart` (the `SaleType` enum and the 14 identity columns),
`customer.dart` (the patient fields), `pharmacy.dart` (`hospital_id`, nullable
`package_markup_percent`), `product.dart` (nullable `gst_percent`), `product_batch.dart` and
`batch_status.dart` (**nullable expiry** and `is_unknown_batch`), `sale_cart_line.dart` (`mrp`).
**Sales:** `data/sale_totals.dart` (the tax-inclusive basis and the per-type helpers),
`data/sale_checkout.dart` (the typed payload), `application/pos_controller.dart` (the cart's
identity, the sale type, the idempotency key, the type-switch guard),
`application/sale_checkout_controller.dart` (validation, the key, the markup read),
`presentation/pos_screen.dart` (the Patient → Type → details → items → payment order),
`presentation/widgets/batch_chooser_sheet.dart`.
**Others:** `features/products/data/products_repository.dart` (`gst_percent` in the projection),
`features/products/presentation/products_detail_screen.dart`,
`features/inventory/presentation/widgets/expiry_batch_card.dart`,
`features/inventory/application/expiry_calendar_controller.dart` (the four forced null-expiry
ripples).
**Tests:** `sale_totals_test`, `pos_controller_test`, `sale_checkout_controller_test`,
`pos_screen_test`, `batch_status_test`, `products_repository_columns_test`,
`support/fake_customers_repository.dart`, `support/fake_sales_repository.dart`,
`support/fake_inventory_repository.dart`, `support/fake_products_repository.dart`,
`support/sales_test_app.dart`.

## Verification Evidence (raw, at `fe8bd3a`)

```
dart format lib test                              → 491 files, 0 changed
dart run build_runner build --delete-conflicting-outputs → exit 0
dart run custom_lint                              → No issues found!
flutter analyze                                   → No issues found!
flutter test                                      → 02:33 +898: All tests passed!   (from 758)
deno test supabase/functions                      → ok | 181 passed | 0 failed (2s)
deno check (all five entry points)                → exit 0
```

Count history, each the gate's own output: **758 → 808 (`925630c`) → 870 (`c8fa615`) → 898
(`fe8bd3a`)**, 0 failures at every step. **178 new tests**, none deleted, skipped, loosened or
weakened; every changed assertion is documented before → after in its commit message.

## Key Decisions Made

1. **The money basis is the server's (D-075).** `SaleTotals` extracts tax from the tax-inclusive
   rate, so `sub_total = grand_total − tax_total` — the identity `checkout_sale()` writes. Money
   stays `double` with the shared half-away-from-zero `round2` (integer-paise-exact at these
   magnitudes) rather than a paise type; the two figures the committed SQL suite asserts are
   asserted in Dart as the round trip this client can honestly prove without writing to production.
2. **The type must be chosen before the medicines.** A package or transfer line is priced from the
   batch's cost, which the cart does not carry, so `setSaleType` refuses to change the basis under a
   rung-up basket (and the selector goes quiet).
3. **The typed payload is built per type**, because `checkout_sale()` copies several fields straight
   into the row and refuses a `customer_id` on a transfer.
4. **Idempotency, as the brief's premise corrected.** `checkout_sale()` does **not** reject a
   changed-payload retry — it returns the *original sale*. So the client mints one key per
   submission, reuses it on a retry, and **clears it on every edit**; three tests pin the lifecycle.
   This is the client-side rule the owner's item 5 asked to see.
5. **A patient is a `customers` row (D-074)**, so `PatientsRepository` is a second repository over
   the same table — its identity columns are RPC-only since migration 00038.
6. **No GSTIN on the counter's registration** (the owner's F4): `save_patient()` has no parameter for
   it and the customers screen owns that column.
7. **The duplicate mobile is a question, not a dedupe** — "use that patient" hands the id back,
   "register anyway" registers a second patient, because a family shares a number.
8. **A package sale is the hospital buying**, so it asks for the account and the patient as text and
   records **no prescriber**.
9. **The batch expiry fix (F5) is the four forced ripples plus the models**: a null `expiry_date`
   used to throw on the way in, which broke the POS's own batch read for 145 of the owner's
   batches.

## Open Risks / Blockers

- **Migration `00039` is unwritten.** The receipt (C3) must not print from client-side cart state;
  the owner approved the exact `sale_document` signature in this chat's approval message.
- **The receipt needs the patient's *code*, which is not on `sales`.** `sale_document` must return it
  (or the client must read the customer row) — otherwise the receipt cannot print "Patient Code".
- **C2's keyboard contract is not built** (Enter/Tab/Esc, auto-add search, compact lines), and the
  screen is not yet tested at 360×800.
- **`sale_totals_test`'s exclusive-basis assertions were re-expressed** on the inclusive basis with
  the count preserved — worth a second pair of eyes if the owner wants the old wording kept anywhere
  for history.
- **The category strip (C2) matches no live data**: the owner's ~315 imported products have
  `category` NULL (the import writes only name and the GST slab), and every one of them is
  `schedule_type = 'OTC'`, so the Schedule H/H1/X prescription rule is currently unreachable through
  the catalogue. Both are recorded in the C1a report.
- **N-18 stands**: the hosted SQL suite has 7 pre-existing failures in three Phase 5 files.
- Nothing was pushed and nothing deployed; the three commits are local on `main`.

## What's Next

`context/chat3p-opening-prompt.md` — **C2 (the POS UX refactor)**, then **C3 (payment, the receipt
with `00039`, and the balance views)**.
