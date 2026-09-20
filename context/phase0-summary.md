# Phase 0 Summary — Foundation

**Status:** COMPLETE
**Date:** 2026-09-18
**Chat sessions:** 2 (initial setup + Riverpod 3 migration)

---

## What Was Built — Supabase

Project: `yeroxzkpmodbzcvjlqwd` (Mumbai region, ap-south-1)

14 migrations applied. All idempotent.

| # | Migration | Contents |
|---|---|---|
| 1 | `20260918000001_extensions` | pgcrypto, pg_trgm |
| 2 | `20260918000002_enums` | 9 enum types |
| 3 | `20260918000003_core_tables` | pharmacies, profiles |
| 4 | `20260918000004_master_tables` | suppliers, customers, products, product_batches, product_aliases |
| 5 | `20260918000005_purchase_tables` | purchases, purchase_items, purchase_returns, purchase_return_items |
| 6 | `20260918000006_sales_tables` | sales, sale_items, sale_returns, sale_return_items |
| 7 | `20260918000007_ledger_tables` | payments, ledger_entries, expenses |
| 8 | `20260918000008_ops_tables` | stock_adjustments, notifications, audit_logs |
| 9 | `20260918000009_indexes` | 52 indexes (incl. GIN trigram on `product_aliases`) |
| 10 | `20260918000010_triggers` | 28 triggers: `set_updated_at` on 21 tables, `handle_new_user` |
| 11 | `20260918000011_helper_functions` | `get_my_pharmacy_id`, `get_my_role`, `normalize_product_name` |
| 12 | `20260918000012_rls_policies` | 82 policies across 21 tables |
| 13 | `20260918000013_views` | `product_stock`, `batch_status` |
| 14 | `20260918000014_seed` | comment-only |

**Totals:** 21 tables, 2 views, 82 RLS policies, 3 helper functions, 52
indexes, 28 triggers, 9 enums.

Multi-tenant isolation verified with two test tenants.

### How the 82 policies break down

Migration 12 wraps 18 business tables in a `foreach` loop emitting 4 policies
each (select/insert/update/delete) = 72, plus 10 hand-written policies:

- `profiles`: select_self, select_pharmacy_owner, update_self,
  update_pharmacy_owner
- `pharmacies`: select_own, update_owner, insert_authenticated
- `notifications`: select_own, insert_own, update_own

### Deferred hooks left in place

`20260918000010_triggers.sql` contains the ledger/stock/audit trigger
functions written but commented out with `TODO(phase-2)` markers at lines
150, 200, 266, 298 and 340:

- `ledger_auto_entry_purchase()`
- `ledger_auto_entry_sale()`
- `stock_update_on_purchase()`
- `stock_update_on_sale()`
- `write_audit_log()`

Enabling them is a migration, not a rewrite.

---

## What Was Built — Flutter App

Stack: Flutter 3.44.8, Dart 3.12.2, SDK ^3.8.0, Riverpod 3.0.3,
Freezed 3.2.3, GoRouter 14.x, supabase_flutter 2.5.6.

Files created: 49 hand-written Dart files (+ generated + platform scaffolding).

- **Root:** `.gitignore`, `README.md`, `Makefile`
- **App config:** `pubspec.yaml`, `analysis_options.yaml`, `.env`,
  `.env.example`
- **Entry:** `lib/main.dart`, `lib/app.dart`, `lib/bootstrap.dart`
- **Core (18):** constants (2), theme (3), router (2), errors (2), utils (4),
  widgets (5)
- **Data:** `supabase_client.dart` + 6 Freezed models (Pharmacy, Profile,
  Supplier, Customer, Product, ProductBatch)
- **Auth (5):** repository, controller, splash, login, register
- **Dashboard (2):** shell, home
- **Feature placeholders (8):** products, inventory, purchase, sales,
  returns, ledger, reports, settings
- **Service stubs (4):** notification, ocr, whatsapp, email
- **Tests (2 files, 29 tests):** `validators_test.dart`, `widget_test.dart`

---

## Verification Evidence

```
flutter pub get                        -> Got dependencies!
dart run build_runner build            -> wrote 121 outputs
dart run custom_lint                   -> No issues found!
flutter analyze                        -> No issues found!
flutter test                           -> +29: All tests passed!
supabase db push                       -> 14 migrations applied
```

---

## Current Working State

**Backend:**

- Auth working (email provider ON, confirm email OFF)
- User `rohit@arihant.com` registered and promoted to `owner`
- Pharmacy "Arihant Pharmacy"
  *(Corrected 2026-09-20: this page recorded the Phase 0 placeholder account and pharmacy
  name, neither of which is in the hosted project today. See `PROGRESS.md`.)*
- All 21 tables ready

**Frontend:**

- Web app builds and runs on Chrome
- Register -> Dashboard flow works
- Sign out / re-login works
- Navigation shell responsive

**Platforms:**

- Web: working
- Windows: fails (`permission_handler_windows`, STL1011)
- Android: configured, untested
- iOS: configured, untested

---

## Key Decisions Made in Phase 0

See `DECISIONS.md`. Highlights: D-001 (Riverpod 3), D-002 (Freezed 3
abstract), D-003 (hosted only), D-004 (RLS), D-007 (pins).

---

## What's Next

Chat 2 — Phase 1 + Phase 2 combined.
See `context/chat2-opening-prompt.md`.
