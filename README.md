# PharmaFlow

A production-grade, multi-tenant **Pharmacy ERP** for Indian retail pharmacies —
GST-compliant billing, batch/expiry-aware inventory, purchase entry with OCR
assist, supplier/customer ledgers, and reporting.

The system is a monorepo: a **Flutter** client for Android, iOS, Web and
Windows, backed by **Supabase** (PostgreSQL + Auth + Row Level Security).

> **Status: Phase 0 (scaffold).** Authentication, the multi-tenant schema, RLS
> and the responsive shell are real. Every business feature (purchase, sales,
> inventory, ledger, reports) is a labelled placeholder for Phase 1+.

> **Supabase is hosted-only.** There is no local stack, no containers and no
> `supabase start`. The database lives in a hosted Supabase project on free
> tier, and migrations reach it with `supabase link` + `supabase db push`.

---

## Overview

Multi-tenancy is enforced in the database, not the client. Every business row
carries a `pharmacy_id`, and Row Level Security restricts all reads and writes
to the caller's own pharmacy via `get_my_pharmacy_id()` — a `SECURITY DEFINER`
helper resolved from `public.profiles`. A user belongs to exactly one pharmacy;
`app_role` (`owner` / `pharmacist` / `cashier` / `viewer`) decides what they may
do beyond tenancy.

Phase 0 delivers:

- The **complete database schema** — Phase 1 tables included up front so no
  migration ever needs rewriting.
- **Auth** — email/password sign-up and sign-in, session stream, profile
  hydration, and route guards driven by `onAuthStateChange`.
- A **responsive shell** — bottom navigation on mobile, an extended navigation
  rail on desktop/web, with the secondary modules in a drawer.
- **Freezed models** for the core entities, and a cross-platform-safe plugin
  boundary (nothing mobile-only is imported unconditionally).

---

## Tech Stack

| Concern | Choice |
| --- | --- |
| Client | Flutter 3.x / Dart 3.8+ |
| State | `flutter_riverpod` + `riverpod_annotation` + `riverpod_generator` (Riverpod 3.x) |
| Routing | `go_router` with a session-backed `refreshListenable` |
| Models | `freezed` + `json_serializable` (`fieldRename: FieldRename.snake`) |
| Backend | `supabase_flutter` — hosted PostgreSQL 17, Auth, RLS |
| Local DB | `drift` + `sqlite3_flutter_libs` — **scaffold only, no tables yet** |
| Documents | `pdf` + `printing`, `fl_chart` |
| Scanning | `mobile_scanner` (guarded — not available on Windows/Web) |
| Config | `flutter_dotenv` |
| Lint | `very_good_analysis` + `custom_lint` + `riverpod_lint` |

Platforms: **Android, iOS, Web, Windows.**

### Two load-bearing dependency constraints

Both are commented in `app/pubspec.yaml`. Do not "tidy" them away:

- `environment.sdk: ^3.8.0` — `json_serializable` emits null-aware elements
  (`?instance.field`), which need language version 3.8+. With a lower bound the
  generator cannot parse its own output.
- `riverpod_lint: '>=3.0.0 <3.1.0'` — from 3.1.8 the package renamed its public
  entrypoint to `lib/main.dart`, while `custom_lint` 0.8.1 still generates a
  plugin client importing `package:riverpod_lint/riverpod_lint.dart`. Allowing
  3.1.8 makes `dart run custom_lint` fail with "Failed to start the plugins".

---

## Workspace Layout

```
PharmaFlow/
├── app/                         Flutter client
│   ├── lib/
│   │   ├── main.dart            entrypoint → bootstrap()
│   │   ├── bootstrap.dart       dotenv → env assert → Supabase.initialize → runApp
│   │   ├── app.dart             MaterialApp.router + theming
│   │   ├── core/                constants, theme, router, errors, utils, widgets
│   │   ├── data/                models (freezed), datasources, repositories, mappers
│   │   ├── domain/              entities, usecases
│   │   ├── features/            auth, dashboard, products, inventory, purchase,
│   │   │                        sales, returns, ledger, reports, settings
│   │   └── services/            notification, OCR, WhatsApp, email (stubs)
│   ├── test/                    unit tests
│   └── pubspec.yaml
└── supabase/
    ├── config.toml              retained for `supabase link` compatibility
    └── migrations/              the full schema, 14 ordered migrations
```

### Migration order

| # | File | Contents |
| --- | --- | --- |
| 01 | `extensions` | `pgcrypto`, `pg_trgm` (pgvector deferred to Phase 3) |
| 02 | `enums` | 9 enum types (`app_role`, `schedule_type`, `payment_mode`, …) |
| 03 | `core_tables` | `pharmacies`, `profiles` |
| 04 | `master_tables` | `suppliers`, `customers`, `products`, `product_batches`, `product_aliases` |
| 05 | `purchase_tables` | `purchases`, `purchase_items`, `purchase_returns`, `purchase_return_items` |
| 06 | `sales_tables` | `sales`, `sale_items`, `sale_returns`, `sale_return_items` |
| 07 | `ledger_tables` | `payments`, `ledger_entries`, `expenses` |
| 08 | `ops_tables` | `stock_adjustments`, `notifications`, `audit_logs` |
| 09 | `indexes` | FK, tenant and trigram indexes |
| 10 | `triggers` | `set_updated_at()`, `handle_new_user()`; Phase 2 hooks commented |
| 11 | `helper_functions` | `get_my_pharmacy_id()`, `get_my_role()`, `normalize_product_name()` |
| 12 | `rls_policies` | RLS on all 21 tables; tenant loop + special cases |
| 13 | `views` | `product_stock`, `batch_status` (`security_invoker = true`) |
| 14 | `seed` | opt-in examples only — inserts nothing by default |

Every migration is **idempotent and re-runnable**.

---

## Prerequisites

- **Flutter** 3.x stable (Dart **3.8+**; developed against Flutter 3.44 / Dart 3.12)
- **Supabase CLI** 2.x
- Optional: `make` — on Windows use `mingw32-make`, WSL, or run the commands directly

Verify the toolchain:

```powershell
flutter doctor -v
supabase --version
```

---

## Setup

### 1. Clone and install client dependencies

```powershell
cd app
flutter pub get
```

### 2. Create `app/.env` from the hosted project

Copy the example, then fill it in with the **hosted** project's values
(Supabase Dashboard → Project Settings → API):

```powershell
Copy-Item app\.env.example app\.env
```

```dotenv
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_ANON_KEY=<the anon / publishable key>
```

`app/.env` is gitignored, and `.env` is declared under `assets:` in
`pubspec.yaml` because `flutter_dotenv` loads it as a bundled asset at runtime.
Use the **anon** key only — a `service_role` key in a client app bypasses RLS.

### 3. Generate the codegen layer

The models and providers use `freezed`, `json_serializable` and
`riverpod_generator`. Their `.freezed.dart` / `.g.dart` outputs are
**gitignored** — every clone must generate them before the app compiles:

```powershell
cd app
dart run build_runner build --delete-conflicting-outputs
# or, while developing:
dart run build_runner watch --delete-conflicting-outputs
```

---

## Running Migrations

### One-time setup

```powershell
supabase login
supabase link --project-ref <project-ref>
```

### Applying migrations

```powershell
supabase db push
```

Preview what would be applied without touching the database:

```powershell
supabase db push --dry-run
```

### Verify

Open **Supabase Dashboard → Table Editor**. All 21 tables should appear
(`pharmacies`, `profiles`, `suppliers`, `customers`, `products`,
`product_batches`, `product_aliases`, `purchases`, `purchase_items`,
`purchase_returns`, `purchase_return_items`, `sales`, `sale_items`,
`sale_returns`, `sale_return_items`, `payments`, `ledger_entries`, `expenses`,
`stock_adjustments`, `notifications`, `audit_logs`), plus the two views
`product_stock` and `batch_status`. Check **Authentication → Policies** to
confirm RLS is on.

### Onboarding the first tenant

Sign-up creates a `public.profiles` row automatically (via the
`handle_new_user()` trigger) with `role = 'viewer'` and `pharmacy_id = NULL`.
That user can see nothing until a pharmacy is created and they are attached to
it. Run this in the Supabase **SQL Editor** after the first user registers:

```sql
insert into pharmacies (name, gstin) values ('Demo Pharmacy', '27AAAAA0000A1Z5');

update profiles
   set pharmacy_id = '<pharmacy-uuid>', role = 'owner'
 where id = '<auth-user-uuid>';
```

`supabase/migrations/20260918000014_seed.sql` carries the same statements as
comments — the file intentionally inserts nothing, because it also runs during
`db push`.

### Future: Edge Functions and secrets

```powershell
supabase functions deploy <name>
supabase secrets set KEY=value
```

---

## Running the App

```powershell
cd app
flutter run -d windows     # desktop
flutter run -d chrome      # web
flutter run                # attached Android/iOS device
```

Quality gates:

```powershell
cd app
dart run custom_lint       # riverpod_lint diagnostics (fatal on info)
flutter analyze
dart format lib test
flutter test
```

With `make` available, the same commands are wrapped — see `Makefile`
(`make setup`, `make gen`, `make lint`, `make test`, `make migrate-dry`, …).

### Cross-platform notes

Plugin availability differs per platform, so the client never imports a
mobile-only plugin unconditionally:

- `isWeb` / `isDesktop` / `isMobile` live in `lib/core/utils/platform.dart`.
  Every `dart:io` `Platform` reference is short-circuited behind `!kIsWeb` —
  `Platform` throws `UnsupportedError` on the web.
- `mobile_scanner`, `image_picker` (camera) and `permission_handler` are
  reachable only through guarded paths. Barcode scanning on Windows/web needs a
  keyboard-wedge or camera-API fallback, tracked for Phase 1.
- All paths are built with `package:path` — no hardcoded `/` or `\`.

---

## Phase Roadmap

Seven phases, two per chat, tracked in [`MASTER_PLAN.md`](MASTER_PLAN.md) and
[`PROGRESS.md`](PROGRESS.md); chats hand off at ~600k tokens following
[`HANDOFF_PROTOCOL.md`](HANDOFF_PROTOCOL.md).

| Phase | Scope | State |
| --- | --- | --- |
| **0** | Schema + RLS, auth, models, shell, cross-platform guards | **COMPLETE** (2026-09-18) |
| 1 | Master data CRUD (products, suppliers, customers), barcode | placeholders in place (`TODO(phase-1)`) |
| 2 | Purchase + GRN + inventory + batch/expiry tracking | design hooks commented as `TODO(phase-2)` |
| 3 | Sales/POS + returns + GST billing | placeholders in place |
| 4 | Ledger + payments + reports | placeholders in place |
| 5 | AI OCR + smart matching + notifications | `TODO(phase-5)` stubs |
| 6 | Testing + deployment + documentation | not started |

Chat plan: Chat 2 = Phases 1-2, Chat 3 = Phases 3-4, Chat 4 = Phases 5-6.

Deferred hooks already exist in the schema: the ledger/stock/audit trigger
functions are written but left commented with `TODO(phase-2)` markers so
enabling them is a migration, not a rewrite.

---

## License

Proprietary — all rights reserved. Not licensed for redistribution or
commercial use without written permission.
