# PharmaFlow

A production-grade, multi-tenant **Pharmacy ERP** for Indian retail pharmacies —
GST-compliant billing, batch/expiry-aware inventory, purchase entry with OCR
assist, supplier/customer ledgers, reporting, alerts and a chatbot that answers
questions about the pharmacy.

A monorepo: a **Flutter** client for Web, Android, iOS and Windows, backed by
**Supabase** (PostgreSQL + Auth + Row Level Security + Edge Functions).

> **Status: Phases 0–5 complete; Phase 6 (testing, deployment, documentation) in
> progress.** Every business surface is implemented and gated: masters, purchases
> with batch tracking, POS with GST invoices, returns, the ledger and payments,
> reports, the AI bill reader, the product matcher, the notifications inbox and
> the chatbot. See [Phase Status](#phase-status) for exactly what is done and what
> is still outstanding.

> **Supabase is hosted-only.** There is no local stack, no containers and no
> `supabase start`. The database lives in a hosted project, migrations reach it
> with `supabase link` + `supabase db push`, and the Edge Functions are deployed
> with `supabase functions deploy`.

---

## Overview

Multi-tenancy is enforced in the database, not the client. Every business row
carries a `pharmacy_id`, and Row Level Security restricts all reads and writes to
the caller's own pharmacy via `get_my_pharmacy_id()` — a `SECURITY DEFINER` helper
resolved from `public.profiles`. A user belongs to exactly one pharmacy;
`app_role` (`owner` / `pharmacist` / `cashier` / `viewer`) decides what they may do
beyond tenancy.

Three rules shape everything in the codebase:

- **The client never moves stock.** Batch quantities change through database
  triggers attached to the documents that move them (D-011/D-013/D-023), so a
  screen cannot leave stock in a state its own document disagrees with.
- **Money is computed once, by a pure helper, and both the screen and the write
  use it.** A total that was worked out twice can disagree with itself.
- **A figure on a screen about the pharmacy is a server-side aggregate, never
  rows summed in Dart** (D-025/D-047) — the ledger, the reports, the alerts and
  the chatbot all read the same RPCs.

---

## Tech Stack

| Concern | Choice |
| --- | --- |
| Client | Flutter 3.44 / Dart 3.12 (`environment.sdk: ^3.8.0`) |
| State | `flutter_riverpod` + `riverpod_annotation` + `riverpod_generator` (Riverpod 3.0.3) |
| Routing | `go_router`, with a session-backed `refreshListenable` |
| Models | `freezed` 3.x + `json_serializable` (`fieldRename: FieldRename.snake`) |
| Backend | `supabase_flutter` — hosted PostgreSQL 17, Auth, RLS, Edge Functions (Deno) |
| Local DB | `drift` + `sqlite3_flutter_libs` — **declared, unused** (D-010 defers offline-first) |
| Documents | `pdf` + `printing` (80mm thermal receipt), `fl_chart` |
| Scanning | `mobile_scanner` (guarded — not available on Windows/Web) |
| Config | `flutter_dotenv` (`.env` bundled as an asset) |
| Lint | `very_good_analysis` + `custom_lint` + `riverpod_lint` |

### Three load-bearing dependency constraints

All three are commented in `app/pubspec.yaml`. Do not "tidy" them away (D-007):

- `environment.sdk: ^3.8.0` — `json_serializable` emits null-aware elements
  (`?instance.field`), which need language version 3.8+. With a lower bound the
  generator cannot parse its own output.
- `riverpod_lint: '>=3.0.0 <3.1.0'` — from 3.1.8 the package renamed its public
  entrypoint to `lib/main.dart`, while `custom_lint` 0.8.1 still generates a
  plugin client importing `package:riverpod_lint/riverpod_lint.dart`. Allowing
  3.1.8 makes `dart run custom_lint` fail with "Failed to start the plugins".
- `custom_lint: ^0.8.0` + `freezed: ^3.0.0` — the pin pair above forces Freezed 3,
  where models are `abstract class X with _$X`.

---

## What Is Built

**Masters** — products (with multi-batch, GST and drug-schedule fields, aliases and
barcode), suppliers, customers, all with search, filters and CRUD.

**Purchase** — purchase entry and orders, GRN, per-batch landed cost, scheme/free
quantity, purchase returns with credit notes, stock adjustments.

**Inventory** — on-hand and valuation from the `product_stock` rollup, expiry
buckets from `batch_status`, low-stock reorder alerts (`low_stock_products()`), an
expiry calendar.

**Sales** — the POS counter, GST invoicing through `checkout_sale()`, a thermal
80mm receipt, sale returns, and the bill detail screen.

**Ledger & reports** — supplier and customer ledgers with running balances,
payments in both directions, expenses, and the reports built on
`report_summary()`.

**AI (Phase 5)** — `ocr-purchase-bill` reads a photographed bill into a verify
form a human corrects before saving; `match-product` suggests catalogue products
by learned alias, trigram similarity and pgvector embedding; the matcher learns
from what the human confirmed; `send-notification` writes an attempt log for every
WhatsApp/email dispatch and keeps the in-app inbox current; and `chat-sql-agent`
answers questions from five server-side aggregates.

**Shell** — 13 destinations in an extended navigation rail (4 in the mobile bottom
bar): Dashboard, Products, Suppliers, Customers, Inventory, Purchase, Sales,
Returns, Ledger, Reports, Notifications, Chatbot, Settings.

### Phase Status

| Phase | Scope | State |
| --- | --- | --- |
| 0 | Schema + RLS, auth, models, shell, cross-platform guards | **COMPLETE** (2026-09-18) |
| 1 | Master data CRUD (products, suppliers, customers) | **COMPLETE** |
| 2 | Purchase + GRN + inventory + batch/expiry tracking | **COMPLETE** |
| 3 | Sales/POS + returns + GST billing | **COMPLETE** |
| 4 | Ledger + payments + reports | **COMPLETE** |
| 5 | AI OCR + smart matching + notifications + chatbot | **COMPLETE** (2026-09-19) |
| 6 | Testing + deployment + documentation | **IN PROGRESS** |

Phase 6 so far: the Windows build is fixed (W-1), `publishableKey` replaces the
deprecated `anonKey` (A-1), the low-stock list reads the server-side aggregate
(I-1), the alias key treats "no supplier" as a value (N-5), the ledger's failure
path offers a retry (T-3), the sale-return form's dead branches are gone and its
bill picker distinguishes loading from empty (T-4, T-5), the invoice printer's
content is testable and its CGST/SGST halves add up to the tax charged, the bill
screens have widget tests, **an Android release APK builds and ships for
sideloading** (debug-signed — D-061), a re-read of a bill no longer discards the
supplier the human chose (N-8) and is now **offered on the verify screen** with a
three-read limit per bill (D-062), **the Vercel web deploy is configured**
(`app/vercel.json` + [`docs/DEPLOY_VERCEL.md`](docs/DEPLOY_VERCEL.md) — D-063,
written and **not run**), the return form picks its invoice by **searching** —
invoice number, notes or distributor, with a date window (I-3, D-064) — and the
email-confirmation policy is settled (D-060).
**Outstanding**: the Vercel import and first deploy, a Play Store listing (needs a
keystore), and the still-unset Edge Function secrets (WhatsApp, SendGrid, Firebase).

---

## Workspace Layout

```
PharmaFlow/
├── app/                          Flutter client
│   ├── lib/
│   │   ├── main.dart             entrypoint → bootstrap()
│   │   ├── bootstrap.dart        dotenv → env assert → Supabase.initialize → runApp
│   │   ├── app.dart              MaterialApp.router + theming
│   │   ├── core/                 constants, theme, router, errors, utils, widgets
│   │   ├── data/                 models (freezed), datasources, repositories
│   │   ├── features/             auth, dashboard, products, suppliers, customers,
│   │   │                         inventory, purchase, purchase_ocr, sales, returns,
│   │   │                         ledger, reports, expenses, notifications, chatbot,
│   │   │                         settings
│   │   └── services/             OCR, matching, chatbot, notifications, printing
│   ├── test/                     unit + widget tests (664)
│   ├── vercel.json               the web deploy's build config (Root Directory `app`, D-063)
│   └── pubspec.yaml
├── supabase/
│   ├── migrations/               30 ordered migrations
│   ├── functions/                5 Edge Functions + _shared, 181 Deno tests
│   ├── tests/                    SQL tests, one per migration of consequence
│   └── config.toml               retained for `supabase link` (local-stack keys only)
├── docs/                         user manual + deployment runbook + Vercel runbook
├── context/                      per-chunk handoff briefs and summaries
├── Makefile                      the same commands, wrapped
└── DECISIONS.md, PROGRESS.md, MASTER_PLAN.md, HANDOFF_PROTOCOL.md
```

### Migrations

30 migrations, in four groups. `supabase/migrations/` is the authority; the shape
is:

| Range | Contents |
| --- | --- |
| `…0001`–`…0014` | Extensions (`pgcrypto`, `pg_trgm`), enums, core/master/purchase/sales/ledger/ops tables, indexes, triggers, helper functions, RLS policies, views, opt-in seed |
| `…0015`–`…0021` | Phase 2 extras (the stock and ledger automation), landed cost, profile hardening, sale automation, ledger/payments and reporting |
| `…0022`–`…0029` | `pgvector` and the embedding column, `device_tokens`/`notification_logs` and the private `purchase-bills` bucket, the matcher, alias learning, the embedding backfill, the vector floor, the alert sources, `queue_notification`, the chatbot's aggregates |
| `…0030` | Phase 6: the alias unique key becomes `NULLS NOT DISTINCT` (N-5) |

24 tables, 2 views (`product_stock`, `batch_status`), RLS on every business table.
Every migration is idempotent and re-runnable, and every one of consequence has a
test under `supabase/tests/` that is atomic, self-rolling-back, asserts its own
numbers and prints them.

---

## Prerequisites

- **Flutter** 3.x stable (Dart **3.8+**; developed against Flutter 3.44 / Dart 3.12)
- **Supabase CLI** 2.x (`supabase --version`)
- **Deno** 2.x — for the Edge Functions and their tests
- Optional: `make` — on Windows use `mingw32-make`, WSL, or run the commands directly

Verify the toolchain:

```powershell
flutter doctor -v
supabase --version
deno --version
```

---

## Setup

### 1. Install client dependencies

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
SUPABASE_ANON_KEY=<the publishable / anon key>
```

`app/.env` is gitignored, and `.env` is declared under `assets:` in
`pubspec.yaml` because `flutter_dotenv` loads it as a bundled asset at runtime —
which also means **a release build must have the file in place before it is
built**, not at runtime. Use the **publishable** (`anon`) key only: a
`service_role` key in a client app bypasses RLS.

### 3. Generate the codegen layer

The `freezed`, `json_serializable` and `riverpod_generator` outputs are
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
supabase db push --yes
```

`--yes` matters: without it the CLI waits for a confirmation a non-interactive
shell will never send.

### Verifying what is applied

```powershell
supabase migration list        # local and remote versions should match, 1:1
supabase db push --dry-run     # preview without touching the database
```

### Running a SQL test against the live database

```powershell
supabase db query --linked --file supabase/tests/phase6_alias_identity.sql
```

A SQL test ends by raising, so a non-zero exit code means it **ran to completion**
and rolled itself back — not that it failed. Read its `PASS`/`FAIL` lines and its
`SUMMARY`.

### Onboarding the first tenant

Sign-up creates a `public.profiles` row automatically (via `handle_new_user()`)
with `role = 'viewer'` and no pharmacy, so a new user can see nothing until a
pharmacy exists and they are attached to it. The supported path is the in-app
onboarding screen, which calls `onboard_pharmacy()`.

---

## Quality Gates

All of these must pass before any handoff. From the repository root, except the
Dart ones which run in `app/`:

```powershell
cd app
dart format lib test
dart run build_runner build --delete-conflicting-outputs
dart run custom_lint
flutter analyze
flutter test

cd ..
deno test supabase/functions
deno check supabase/functions/ocr-purchase-bill/index.ts
deno check supabase/functions/match-product/index.ts
deno check supabase/functions/backfill-embeddings/index.ts
deno check supabase/functions/send-notification/index.ts
deno check supabase/functions/chat-sql-agent/index.ts
```

`flutter analyze` is stricter than `dart run custom_lint` and analyzes `test/**`
too, so run `dart format` then `flutter analyze` before calling a file done.
`make test-functions` runs the Deno lines, and each needs no Docker and no secret.

With `make` available the rest are wrapped too: `make setup`, `make gen`,
`make lint`, `make format`, `make test`, `make migrate`, `make migrate-dry`,
`make backfill`, `make run`, `make run-android`, `make run-web`.

---

## Running the App

```powershell
cd app
flutter run -d chrome      # web
flutter run                # attached Android/iOS device
flutter run -d windows     # desktop
```

### Building

```powershell
flutter build web --release
flutter build apk --release        # -> app/build/app/outputs/flutter-apk/app-release.apk
flutter build windows --release
```

**The Android APK is the shipping artifact** (D-061): release mode, signed with the
debug key, installed on staff devices by USB or a file share. Publishing on Play later
means generating a keystore and reinstalling on every device once — see
[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) §3.

### Web debugging on this toolchain

`flutter run -d chrome` can fail **after** a successful compile with
*"Failed to establish connection with the web debug service"*. That is Chrome 153
against the `dwds` bundled in Flutter 3.44.8 — upstream
`flutter/flutter#192976`, fixed in Flutter 3.47.5 — not this app, and it does not
affect `flutter build web`. Use `make run-web-server` (the `web-server` device on
port 8090) in the meantime, and delete that target once the SDK is upgraded.

### Cross-platform notes

Plugin availability differs per platform, so the client never imports a
mobile-only plugin unconditionally:

- `isWeb` / `isDesktop` / `isMobile` live in `lib/core/utils/platform.dart`.
  Every `dart:io` `Platform` reference is short-circuited behind `!kIsWeb` —
  `Platform` throws `UnsupportedError` on the web.
- `mobile_scanner`, `image_picker` (camera) and `permission_handler` are reachable
  only through guarded paths.
- All paths are built with `package:path` — no hardcoded `/` or `\`.
- Windows builds need the `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`
  definition in `app/windows/CMakeLists.txt`: `permission_handler_windows` compiles
  through `<experimental/coroutine>`, which MSVC 14.51 (Visual Studio 2026) refuses
  as error C2338/STL1011. Remove it when that plugin moves to C++/WinRT 2.x.

---

## Edge Functions and Secrets

```powershell
supabase functions deploy <name>
supabase secrets set KEY=value
```

| Function | What it does | Secrets |
| --- | --- | --- |
| `ocr-purchase-bill` | Reads a photographed bill into the verify form | `GEMINI_API_KEY` |
| `match-product` | Suggests catalogue products for a bill line | `GEMINI_API_KEY` |
| `backfill-embeddings` | Embeds the catalogue, one batch per invocation | `GEMINI_API_KEY` |
| `send-notification` | Queues, calls and settles a WhatsApp/email dispatch | `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `SENDGRID_API_KEY`, `SENDGRID_FROM_EMAIL` |
| `chat-sql-agent` | Turns a question into one of five aggregate reports | `GEMINI_API_KEY` |

The Gemini key is on a **free tier: 5 requests per minute** (the embedding model
is measured separately and is far more generous). A burst is shed as
`503 UNAVAILABLE`, which the reader reports as retryable rather than retrying by
itself (D-032/D-033). The WhatsApp and SendGrid secrets are **not set**: a
dispatch without them is recorded as `skipped` and names the missing secret.

See [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) for the deploy runbook,
[`docs/DEPLOY_VERCEL.md`](docs/DEPLOY_VERCEL.md) for the web deploy specifically, and
[`docs/USER_MANUAL.md`](docs/USER_MANUAL.md) for how to use the app.

---

## Documentation Map

| File | What it is |
| --- | --- |
| [`docs/USER_MANUAL.md`](docs/USER_MANUAL.md) | How to run a pharmacy on it, screen by screen |
| [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) | Web, Android, iOS, Windows and the Edge Function secrets |
| [`docs/DEPLOY_VERCEL.md`](docs/DEPLOY_VERCEL.md) | The Vercel web deploy, step by step (§2 above points here) |
| [`PROGRESS.md`](PROGRESS.md) | What is done, what is open, and the evidence |
| [`DECISIONS.md`](DECISIONS.md) | Every architecture decision, and why |
| [`MASTER_PLAN.md`](MASTER_PLAN.md) | The phase plan |
| [`HANDOFF_PROTOCOL.md`](HANDOFF_PROTOCOL.md) | The gate list and the handoff contract |
| [`context/`](context) | Per-chunk briefs and summaries |

---

## License

Proprietary — all rights reserved. Not licensed for redistribution or commercial
use without written permission.
