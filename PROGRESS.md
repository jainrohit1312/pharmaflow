# PharmaFlow — Progress Tracker

**Phase 7a status, in four parts (2026-09-20)** — kept distinct on purpose, because "implemented",
"verified", "in the app" and "deployed" are four different things here:

- **Backend implemented: YES.** Six additive migrations, `20260920000033`…`…000038`: the four sale
  types (D-067), patients and admissions (**D-074**), the tax-inclusive rate basis (**D-075**),
  allocation integrity under a row lock, and a server-gated patient-master edit (**D-076**).
- **Locally verified: YES.** All 38 migrations apply clean to a fresh Postgres 17 + pgvector
  container, and the whole committed SQL suite passes with **zero failures** —
  `supabase/tests/phase7a_sale_types.sql` at **75 PASS / 0 FAIL of 75 assertions**, and the repaired
  `phase5_alerts.sql` at **27 PASS / 0 FAIL** (it was 24 / 1, red since migration 00031 — see N-16).
- **Flutter implemented: NO.** No Dart file has changed. The POS flow, its controllers, the
  keyboard contract, the receipt and the Android layout are the next slice; nothing about the app's
  behaviour is different yet.
- **Hosted deployment: PENDING.** Nothing is pushed and nothing is deployed.

**A contradiction in the continuation brief, recorded rather than resolved by guessing.** Its item 9
authorises *"Push migrations to the hosted Supabase project"*, while its item 3.F says *"Keep hosted
deployment prohibited"* and the required final report asks for *"Explicit confirmation that nothing
was pushed or deployed."* Both cannot hold, and pushing to a hosted project is not reversible, so
**nothing was pushed** — the prohibition won and the question is open for the owner.

**Baseline correction, measured 2026-09-20.** A syntactic count of `test(`/`testWidgets(` in
`app/test` is **760** (758 collectable by `flutter test`: one `@TestOn('browser')` file with two
tests is never collected — see the browser-only-tests note). This file has carried **729** since
chunk 3, so that figure is stale; the authoritative number is whatever `flutter test` prints, which
this slice did not re-run because it changed **no Dart file** (SQL, docs and one SQL test only).

**Last Updated:** 2026-09-20
**Current Phase:** **PHASE 6.5a DONE** (2026-09-20 — the opening stock import, D-065/D-066; see
below). **PHASE 6 IN PROGRESS** (chunk 3 of n, done; `context/chat3n-summary.md`). Phase 5 is complete. Phase 6 chunk 1 closed everything needing no account (W-1, A-1, I-1, N-5, T-3/T-4/T-5/T-6, the printer and bill-screen coverage, R-1, `docs/`); chunk 2 shipped the **Android APK** and settled **N-7**/**N-8**; **chunk 3 wrote the Vercel deploy** (`app/vercel.json` + `docs/DEPLOY_VERCEL.md` — configured and **not run**) and **exposed the re-read** the N-8 fix made safe (D-062), and then **implemented I-3** in a commit of its own (D-064) once it turned out the chunk-2 message had claimed it against no diff at all. Next: **import the repo into Vercel and run the first deploy** (the account exists; the project does not), then the credentials behind D-046/D-052/N-1, N-9's re-measurement, and the manual's screenshot pass (`context/chat3o-opening-prompt.md`)
**Overall Status:** Phases 0-5 done and gated; Phase 6 chunks 1-3 done and gated — Phase 5 closed with its database substrate, **five deployed Edge Functions**, a bill that reads and saves end to end, a matcher that suggests and learns, a backfilled catalogue with a measured similarity floor, its alert sources, the notification function and inbox, and a chatbot a person can type into. Phase 6 added one migration since Phase 5 closed (the alias key, N-5), the Android sideload APK (D-061), a Vercel build config for the web app, the bill re-read with its three-read limit (D-062), and the purchase picker's three-way search (I-3, D-064) — **729 Flutter tests, 181 Deno tests**

**Phase 6.5a — the opening stock import — is DONE (2026-09-20).** The one-time Marg
migration the owner has been preparing: 314 rows, one product and one batch each, written by
`commit_opening_stock_import()` in one transaction, with `preview_opening_stock()` behind the
screen that shows what would happen (D-065, D-066). Files:
`supabase/migrations/20260920000031_phase6_5a_opening_stock_import.sql` (and `…000032_…`, which
corrects one expression in it — see D-065 on `extensions.digest`),
`supabase/tests/opening_stock_import.sql` (65 assertions, all passing),
`app/lib/features/import/opening_stock/`. **Measured against the owner's real export, read-only:**
314 rows, 61,360 units, ₹6,04,832.90 at cost, 53 rows with no stock, 138 with no batch number,
145 with no expiry, 3 already expired, **314 new products and no refusals** — so the catalogue
as it stands has no name in that file, which is what the preview is for. **Nothing has been
imported**: the owner runs it from `/settings/import/opening-stock`.

---

## Phase Status Overview

| Phase | Name | Status | Started | Completed |
|---|---|---|---|---|
| 0 | Project Setup + Schema + Auth | COMPLETE | 2026-09-18 | 2026-09-18 |
| 1 | Product + Supplier + Customer Master | COMPLETE | 2026-09-18 | 2026-09-18 |
| 2 | Purchase + Inventory + Batch Tracking | COMPLETE | 2026-09-18 | 2026-09-18 |
| 3 | Sales/POS + Returns + GST Billing | COMPLETE | 2026-09-18 | 2026-09-18 |
| 4 | Ledger + Payments + Reports | COMPLETE | 2026-09-18 | 2026-09-19 |
| 5 | AI OCR + Smart Matching + Notifications | COMPLETE | 2026-09-19 | 2026-09-19 |
| 6 | Testing + Deployment + Documentation | IN PROGRESS (chunks 1-3 done) | 2026-09-19 | - |
| 6.5a | Opening stock import (the Marg import) | COMPLETE | 2026-09-20 | 2026-09-20 |
| 6.5b | The receiver app | not started | - | - |
| 6.5c | The approval RBAC (with an `action_type` enum and a `payload` jsonb) | not started | - | - |
| 7a | The four sale types + patient/admission identity (patient-first billing) | **DURABLE LAYER BUILT, not pushed**; the Flutter flow is not started | 2026-09-20 | - |

---

## Recorded for Later Phases (not built)

### Phase 7 — the business model

**Revised three times on 2026-09-20. Nothing below is built.** The full requirement record is
`MASTER_PLAN.md` → **Phase 7** (with **Phase 6.5** for the receiver, the approval RBAC and the
Marg import). The decisions are **D-067** (four sale types), **D-068** (hospital profit
sharing), **D-069** (expense categories), **D-070** (the package service markup), **D-071**
(the discount cap and its approval) and **D-072** (the doctors master).

#### The four sale types (D-067)

| Type | Rate | Hospital share | Discount |
|---|---|---|---|
| `counter` — a walk-in, hospital or outside patient | MRP − discount | **yes** | capped at 10% (D-071) |
| `ipd_admission` — an admitted patient | MRP − discount | **yes** | capped at 10% |
| `package` — the hospital buying for its own package patients | purchase rate + `package_markup_percent` | **no** — the hospital is the *buyer* | n/a |
| `transfer` — stock moving between locations | purchase rate, no markup | **no** | n/a |

"**Pharmacy sale**" is the business's umbrella name for **counter + `ipd_admission`**. An IPD
sale is **not** a package sale: it is a retail-priced sale to an admitted patient.

#### The pharmacy ↔ hospital mapping, and the shares (D-068)

| Pharmacy | Hospital | Share |
|---|---|---|
| Arihant Pharmacy | Rohit Kidney & Stone Hospital (Dr. Rohit Singhal) | **50%** |
| Erika Prime Pharmacy | Govardhan Hospital | **60%** |
| Medicotraders | Jain Hospital | **0%** |
| Sudha Pharmacy | Pandey Hospital | **0%** |

A pharmacy belongs to **exactly one** hospital — which is why `pharmacies.hospital_id` is a
column and not a join table. Each share is a **dated** rule (`hospital_profit_sharing`), and
these four values are what the Phase 7 seed writes.

**0% is a value, not an absence.** Medicotraders and Sudha have a real 0% deal — no share
transaction is written and the whole gross profit is the owner's. **Nothing may read a 0% rule
as "no rule configured."**

A hospital's share applies to **`counter` and `ipd_admission` sales only**; a package sale and
a transfer carry none. The owner bears the expenses, and a hospital's share is **not** reduced
by them. **The GST basis is settled (2026-09-20):** the share is calculated on **GST-inclusive**
gross profit and the **owner bears the GST out of their own share** — an accepted business
model, so the tax reduces the owner's net and never the hospital's share (D-068).

#### The discount policy (D-071)

On a counter or IPD sale the discount is **capped at 10%** without approval. Above 10% the
staff **cannot apply it**: it must be requested and the **owner approves** it, through Phase
6.5c's `approval_requests`. The sale carries `discount_above_limit_request_id`. Package and
transfer sales have no discount concept. The flow is **blocking, confirmed 2026-09-20** — the
sale cannot be recorded until the approval exists.

**`approval_requests` does not exist yet, and Phase 7a cannot be built before Phase 6.5c
lands:** `discount_above_limit_request_id` is a **real foreign key** to it, not a soft
reference (D-071).

**Doctors appear on sales for prescription compliance only and take no share** (D-072); a
Schedule H/H1/X bill requires the prescriber's name.

#### The sequence (owner, 2026-09-20)

```
Phase 6 chunk 4  →  the Vercel deploy            (where the project stands now)
Phase 6.5a       →  the Marg import
Phase 6.5b       →  the receiver app
Phase 6.5c       →  the full approval RBAC, with the schema for every action type
Phase 7a         →  the four sale types          (uses 6.5c's approval for the discount)
Phase 7b         →  hospital profit sharing
Phase 7c         →  the reports
```

**HARD DEPENDENCY: Phase 7a needs Phase 6.5c's approval infrastructure before it can be
built.** 6.5c is one unified approval mechanism for every action that needs one — a sale edit,
a purchase delete, a return, a stock adjustment, a discount above 10%, a customer or product
edit. **Its shape so far:** action-type based — a table with an `action_type` enum and a
`payload` jsonb. **The exact list of action types is still to come from the owner**, at 6.5c
design time.

---

## Environment (Current)

| Item | Value |
|---|---|
| Workspace root | `C:\Projects\PharmaFlow\` |
| Flutter version | 3.44.8 (stable) |
| Dart | 3.12.2 |
| SDK constraint | `^3.8.0` |
| Riverpod | 3.0.3 (`flutter_riverpod`, `riverpod_annotation`, `riverpod_generator`, `riverpod_lint`) |
| Freezed | 3.2.3 (`freezed_annotation` 3.1.0) |
| Supabase | HOSTED only (no local stack, no Docker) |
| Project ref | `yeroxzkpmodbzcvjlqwd` |
| Region | Mumbai (ap-south-1) |
| CLI version | supabase 2.113.0 |

---

## Chat Strategy (1M Context Optimized)

- **Chat 1:** Phase 0 [DONE]
- **Chat 2:** Phase 1 + Phase 2 [DONE]
- **Chat 3:** Phase 3 + Phase 4 [DONE]
- **Chat 4:** Phase 5 + Phase 6 [target ~280k tokens]
- **Handoff trigger:** ~600k tokens used OR quality degrades OR both phases done

---

## What Currently Works

### Backend (Supabase Hosted)

- 32 migrations applied, all idempotent (`supabase migration list`: 32/32 local
  and remote match)
- 26 tables and 2 views (`product_stock`, `batch_status`), RLS enforced on every
  business table; `import_jobs` and `import_job_rows` arrived with Phase 6.5a
  (migration 00031 — the opening stock import's two tables, written only by its
  RPC); migration 00022 added `device_tokens`, `notification_logs`, the
  `products.embedding` column and the private `purchase-bills` storage bucket
  (00019-00021 added one table, `invoice_counters`, and no view), 00023 added
  the two matching functions, 00024 the alias-learning function, 00025 the
  backfill pair, 00026 the re-tuned vector floor, 00027 the two alert sources,
  00028 `queue_notification`, and 00029 the chatbot's two aggregates — none of
  those seven added a table, a column or a view
- Helper functions: `get_my_pharmacy_id()`, `get_my_role()`,
  `normalize_product_name()` (identity and scope); the automation layer
  (`ledger_auto_entry_*`, `stock_*`, `write_audit_log`, `set_updated_at`,
  `handle_new_user`); the RPCs (`onboard_pharmacy`, `checkout_sale` /
  `next_sale_invoice_no`, `record_payment`, `report_summary`); the sales
  payment guard (`sales_payment_check`); the matcher
  (`product_embedding_text`, `match_products`, `learn_product_aliases`,
  `products_to_embed`, `set_product_embeddings`); and the five aggregates the
  alerts and the chatbot share (`low_stock_products`, `expiring_batches`,
  `top_products`, `dead_stock`, plus `report_summary`)
- **Five Edge Functions deployed**: `ocr-purchase-bill` (chunk B1, verified against
  the live model), `match-product` (chunk C1), `backfill-embeddings` (chunk C3,
  verified live), `send-notification` (chunk D part 2, live-probed: it answers
  `skipped` naming the missing `WHATSAPP_TOKEN` and writes both rows) and
  `chat-sql-agent` (chunk E part 1, live-probed end to end: the classification, the
  parameters, the model name, the figures and the refusal path). `supabase/functions/_shared/`
  carries errors, the JSON envelope + CORS, the caller-scoped client, base64, the
  shared Gemini poster (`gemini.ts`) and the embedding convention (`embedding.ts`).
  **181 Deno tests** are gates (**N-3 resolved**), and `make test-functions` runs them
  plus a `deno check` per entry point
- Indexes and triggers per migration: `set_updated_at` on every business table,
  and every stock and ledger effect attached as a trigger rather than left to a
  client (D-013, D-023)
- Auth working: email provider ON. **The hosted project requires email
  confirmation**, which contradicts this line as it stood until 2026-09-19 (and the
  repo's `config.toml`, which only ever seeds a local stack — D-003): a signup
  returns `confirmation_sent_at` and no session, and the password grant answers
  `email_not_confirmed`. See open item N-7.
- **The deployed account is `rohit@arihant.com`, owner of "Arihant Pharmacy"** — verified
  2026-09-20 while measuring the import against production. The placeholder account and
  pharmacy name this line recorded until then are not in the hosted project any more, so
  anything that probes production has to find the owner by **role**, not by an address.
- Multi-tenant isolation verified with two test tenants

### Flutter App

- Bootstrap chain working: `main.dart` -> `bootstrap.dart` -> `PharmaFlowApp`
- Riverpod 3.x codegen setup (`@riverpod`)
- GoRouter with auth redirects
- Theme (light/dark, teal seed)
- Widgets: AppButton, AppTextField, AppScaffold, LoadingView, ErrorView
- 7 Freezed models: Pharmacy, Profile, Supplier, Customer, Product, ProductBatch,
  AppNotification (plus `NotificationLog`/`DeviceToken`, and the plain classes the
  RPC envelopes are read into)
- Auth flow: splash -> login -> register -> dashboard -> signout
- Dashboard shell responsive (NavigationBar mobile / NavigationRail desktop)
- The Phase 5 surfaces: the bill reader (`features/purchase_ocr/`, which now also
  suggests catalogue products per line, records what the human confirmed, survives a
  re-read, and offers one on demand — three reads per bill, D-062), the verify-and-save
  flow, and the notifications feature
  (`features/notifications/`, Chunk D) — the `/notifications` list screen with its
  two live alert sections, the dashboard unread card, and `AppNotification` /
  `LowStockProduct` / `ExpiringBatch` models over one repository
- The chatbot (`features/chatbot/`, Chunk E part 2): `/chatbot`, the 13th rail
  entry (D-054). `ChatService` (`lib/services/chat_service.dart`) over
  `functions.invoke('chat-sql-agent')`, with the answer as a plain-class
  `ChatResponse` and `ChatMessage` (`lib/data/models/`), a `ChatController` whose
  conversation is plain state with the tenant never sent (D-004), and a screen whose
  invitation, waiting turn, refusal and failure are four different renderings —
  `describeAnswerOrigin` reads the note under an answer from the envelope's own
  `rpc`, `params` and `data.meta`, so nothing on the client computes a figure (D-053)

### Platform Support

- Web (Chrome): working — and **the Vercel deploy is configured**
  (`app/vercel.json`, `docs/DEPLOY_VERCEL.md`, D-063). Nothing has been imported into
  Vercel and no deploy has been made
- Windows: **builds** — W-1 fixed in Phase 6 (`_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`
  scoped to `permission_handler_windows_plugin`); `flutter build windows --debug`
  produced `build\windows\x64\runner\Debug\app.exe`. The release build was not run
  (deliberately — see D-059). Not a launch target.
- Android: **builds and ships** — `flutter build apk --release` →
  `app/build/app/outputs/flutter-apk/app-release.apk` (80,295,479 bytes), signed with
  the debug key and verified with `apksigner` (`CN=Android Debug`). Sideloading only;
  no keystore and no Play listing (D-061)
- iOS: configured, out of scope this phase (needs a Mac — D-059)

---

## Known Issues / Open Items

| ID | Issue | Severity | Plan |
|---|---|---|---|
| W-1 | Windows build fails (STL1011 — `<experimental/coroutine>` deprecated in VS 2026) | Medium | Fix in Phase 6 via `windows/CMakeLists.txt` |
| D-1 | 4 manual Providers remain (router + the other service stubs) | Low | Convert to `@riverpod` when the respective features are built. **Chunk D closed one**: `notificationServiceProvider` is codegen now (D-050) |
| T-1 | `dart run custom_lint` SDK language version notice (cosmetic) | Low | Wait for upstream analyzer fix |
| A-1 | `anonKey` deprecated in supabase_flutter 2.17 | Low | Migrate to `publishableKey` in Phase 6 |
| I-1 | The low-stock list reads at most `InventoryRepository.lowStockScanLimit` (500) candidate rows and decides `total_qty < min_stock_level` in Dart, because PostgREST cannot compare two columns. A catalogue past that bound would silently omit rows. **D-part-1 built the server-side answer** (`low_stock_products()`, D-047 — same `<` rule, same shortfall, tenant-scoped, asserted by `phase5_alerts.sql`); what is left is switching the inventory screen onto it | Low | Switch `InventoryRepository.lowStock` to the RPC (the alert list already reads it), and delete the Dart comparison and its scan bound |
| I-2 | A purchase return is two statements (header, then lines). The lines are one atomic INSERT, so stock moves for all of them or none - but a refused set can leave a header with no lines. Deliberately not rolled back: see `PurchaseReturnsRepository.create` | Low | An `RPC` wrapping both statements when Phase 4 touches the ledger |
| R-1 | `README.md` still describes the project as "Phase 0 (scaffold)" with Phase 1+ screens as placeholders | Low | Refresh it in Phase 6, which owns documentation |
| T-3 | The ledger screen's entries failure path is only reachable on a **first** read: while no party is selected the entries provider holds an empty page, so a failure after a party is chosen keeps that empty page and reports itself through a SnackBar rather than replacing the body. A user who cannot load a party's ledger therefore has no retry control until they navigate away and back | Low | Either treat "no party selected" as no value rather than an empty page, or give the SnackBar a retry action |
| T-4 | `sale_return_form_screen.dart` has two paths that cannot run: the bill picker's `'Choose a bill'` validator, and `if (saleId == null) _report('Choose the bill the goods were sold on.')`. The submit button is disabled while no bill is chosen (`onPressed: isSaving \|\| saleId == null ? null : _save`) and the picker offers no clear affordance, so `_save` never sees a null bill | Low | Either drop the dead branches or make the button live and let the validator speak, so the two do not have to be kept in step |
| T-5 | `sale_return_form_screen.dart`'s bill picker renders `sales.value ?? const <Sale>[]`, so "the sales list is still loading" and "this pharmacy has no sales" look identical — an empty, disabled dropdown with no spinner and no explanation | Low | Distinguish the two the way the ledger's party picker does, or read the sales provider's `AsyncValue` states explicitly |
| N-1 | Push delivery is not wired: `device_tokens` stays empty and `NotificationService.getFcmToken()` returns `null`. Phase 5 dispatches over WhatsApp/Email and shows the in-app list; the Firebase project, the web service worker, the VAPID key and the registration call are Phase 6's (D-029). **Chunk D settled the app-side meaning**: `init()`/`showLocal()` complete and `getFcmToken()` answers `null` behind a seam (D-050), and `send-notification` is deployed and live-probed as far as a missing credential allows (D-049) | Medium | Phase 6, which owns the deploy target the credentials must be registered against |
| N-2 | The Gemini key is on a **free tier: 5 requests per minute**, and a burst is shed as `503 UNAVAILABLE` rather than `429`, so a busy counter (or a double-tapped retry) meets "the reader is busy" with no queue behind it. `ocr-purchase-bill` makes one attempt and reports it as retryable on purpose (D-032); the app retries once, visibly (D-033) | Medium | A paid tier, or a deliberate retry-once policy with a visible waiting state — decide before the OCR flow meets a real counter |
| N-4 | A deployed function's `console.error` is only visible in the Supabase dashboard: CLI 2.113.0 has no `functions logs` subcommand (only list/delete/download/deploy/new/serve) and there is no container to serve one locally. Debugging a function is therefore a deploy-and-probe cycle | Low | Accept it and probe deliberately (D-031 records the practice), or find a log path for the CLI version in use |
| N-5 | `product_aliases`' unique index is `(pharmacy_id, supplier_id, normalized_name)` with `supplier_id` nullable and **no `NULLS NOT DISTINCT`**, so two rows for one printed text coexist when neither names a supplier — Postgres treats NULLs as distinct. `ProductsRepository.addAlias`'s doc says re-adding text "re-points the alias … instead of failing … which is what the unique key is for" (`app/lib/features/products/data/products_repository.dart:451`, upserting on that target at `:484`), and migration 00015's own comment says NULL-supplier rows "never conflict" (`20260918000015_phase2_extras.sql:353`). Both cannot be true: the second manual alias with no supplier **inserts a duplicate** rather than updating. C2 leaves it exactly as it is: `learn_product_aliases` (00024) writes a NULL-supplier row with an explicit update-then-insert so a *learned* alias converges, but the index, `addAlias` and migration 00015's comment are untouched, and the OCR path names a supplier anyway — so a learned alias is normally supplier-scoped. Both SQL tests assert the coexistence rather than hiding it | Low | Phase 6: make the index expression `(pharmacy_id, coalesce(supplier_id, '00000000-0000-0000-0000-000000000000'::uuid), normalized_name)` or add `NULLS NOT DISTINCT` (PG 15+), then reconcile the two comments above |
| N-7 | A throwaway probe account cannot sign in on the hosted project: signup returns `confirmation_sent_at` with no session and the password grant answers `email_not_confirmed`, while `config.toml` says `enable_confirmations = false` (a local-stack-only setting, D-003). Setting `auth.users.email_confirmed_at` by hand is the obvious workaround and is correctly refused by the auto-mode guard as an auth-weakening write to production | Low | Probe with a session obtained from the app (`rohit@arihant.com`, the only owner — found by **role**, since the address this line used to name is no longer in the project), or decide deliberately whether "Confirm email" should be off in the hosted project the way the repo believes it is |
| N-8 | A **successful second read** of the same bill replaces the whole verify form, so the supplier the human had chosen is dropped (and with it the suggestions, which are scoped by that supplier). It is the direct consequence of fixing the re-seed defect with `ValueKey(scan.bill)` (D-039): the new parse replaces the header fields too, which is right for the invoice number and date and merely inconvenient for the supplier. The match is asked again as soon as the supplier is named again | Low | Re-seed only the *lines* (and clear the suggestions) in `didUpdateWidget` when the parse changes, keeping the header the human already edited |
| N-9 | The vector floor (**0.78**) was measured against a live catalogue that holds **one product**, so the window it sits in (0.7216 refused / 0.8280 kept) rests on one catalogue vector and nine query texts. Three things follow, and they are the whole open item: **(a) the recipe** — lower the floor to 0.01, read the `distance` the matcher reports for a set of real and near-miss invoice texts, and install the chosen value in a new migration (D-013; and on a temporary tenant, never the live function — **D-045**); **(b) the direction** — 0.78 errs **high**, so the cost of being wrong is a *missed* suggestion rather than a wrong one (the human picks, and the alias and trigram legs still answer); **(c) the trigger to revisit** — Phase 6's testing should re-tune it once the catalogue has **50+ products**, because that is when "two catalogue products of the same brand" becomes a real band to separate rather than a one-row guess | Low | Phase 6, once the catalogue is real. Nothing depends on the exact value: it is a one-line migration and the tests move with it |
| N-10 | `flutter run -d chrome` fails **after** a successful compile with "Failed to establish connection with the web debug service" (a 5s timeout in dwds' `WebkitDebugger.enable`). It is Chrome 153 against the dwds 26.2.5 bundled in Flutter 3.44.8 — upstream `flutter/flutter#192976`, fixed by dwds 27.1.2 in Flutter 3.47.5 — so it is the toolchain and not this app, it happens in a bare `flutter create` app on this host too, and it does **not** affect `flutter build web`. Recorded as an item because it was tribal knowledge in the `Makefile`'s `run-web-server` comment rather than a numbered defect | Low | `make run-web-server` (the `web-server` device, port 8090) until the SDK is upgraded; delete that target once it is |
| N-11 | Phase 6's *deploy* work needs accounts, and the ones left do not exist yet: a Vercel project for the web app, and — for anything but sideloading — a Google Play developer account plus an upload keystore. The WhatsApp/SendGrid/Firebase credentials that dispatch (D-046), auto-send PO (D-052) and push (N-1) wait on are the same kind of thing: provider accounts nobody has registered. **Two of the three halves are no longer blocked**: the Android APK builds and ships for sideloading (D-061), and **the Vercel side is configured** — `app/vercel.json` plus `docs/DEPLOY_VERCEL.md` (D-063) — with the account in place and only the project import and the first deploy left. Nothing in the app blocks any of the rest | Medium | Import the repo into Vercel (Root Directory `app`, the two Supabase env vars) and run the first deploy, then do the credential work last |
| N-12 | **A future Flutter upgrade will fail the Android build**, and say so only as advice: `flutter build apk --release` warns *"Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP): mobile_scanner. **Future versions of Flutter will fail to build** if your app uses plugins that apply KGP."* `mobile_scanner` is pinned `^5.2.3`. Today it is a warning and the APK builds (verified 2026-09-19, D-061); the trap is that the failure arrives on a Flutter upgrade as an unrelated-looking Gradle error, in the same shape N-10 has for web debugging | Low | When the SDK is next upgraded: check `mobile_scanner`'s changelog for a Built-in Kotlin release and bump it, or make the scan path switchable if no such release exists. Nothing is blocked until then. **Chunk 3 reviewed it at the user's request and left it deferred** — it is a warning today and the trigger is an SDK upgrade, so there is nothing to do until one happens |
| N-13 | **The three-read limit is enforced where a bill has been *read*, not where it has only been *uploaded*.** `_ChooseBill`'s failure card ("That bill could not be read" → "Read it again") calls `rescan()`, which does not refuse past `PurchaseOcrState.maxReads` — deliberately, because that card is the D-033 recovery for a first read that never succeeded: nothing on that screen can be saved, and refusing the last retry would strand the file. The consequence is that a bill whose reads keep failing can be sent to the reader more than three times, and the cap is a *cost* fence with a gate on one side of it. Found and recorded while building the re-read button (D-062) | Low | Show the same cap on that card — the button disabled with the same sentence the verify form's failure card uses — or decide that an unread bill's recovery is worth unlimited reads and say so where the cap is defined. One screen's worth of work |
| N-14 | **GST on a retail sale: the compliance question is open, the profit-sharing formula is settled.** The owner said *"B2C sale hai to GST ka koi matlab nahi hai"*, which is a probable misunderstanding — GST applies to retail pharmacy sales in India regardless of B2B/B2C (B2C only means no buyer GSTIN is needed). Three readings: **(a)** GST is charged but not shown as its own line on the bill; **(b)** the pharmacy is in a hospital-exempt category (needs a CA to confirm — rare); **(c)** it is a display choice only (safe). **Settled 2026-09-20 and no longer waiting on this:** the hospital's share is computed on **GST-inclusive** gross profit and the **owner bears the GST from their own share** — an accepted business model, not an accounting error (D-068), so the GP basis is decided. Also unstated: whether a `package` sale charges GST (`transfer` is stated as no-GST). **Answered for pharmacy sales (2026-09-20, D-075).** The owner's patient-first billing brief settles the basis: the rate on a line **is the price the customer pays**, GST is **extracted** from it (₹105 at 5% = ₹100 taxable + ₹5 tax), a product's **own slab wins including a recorded zero**, and a missing slab falls back to **one named 5% POS default** — not the old blanket 12%. What is left of this item is the **compliance** reading only (whether the pharmacy is exempt), which no longer blocks any code. A **package** line's treatment is still open (N-15); a **transfer** is no-GST by D-067 | Low | Only the compliance question remains; no further pharmacy-sale GST logic changes are planned |
| N-15 | **A package line's TAX treatment is the one part of the package rule still unstated — the pricing rule itself is settled and built** (owner, 2026-09-20): `rate = batch purchase rate × (1 + pharmacies.package_markup_percent/100)`, where the markup is a **free per-pharmacy percentage chosen through the UI** — **0 is a valid configured value**, never read as "missing", and the percentage is not restricted to a predefined list. The basis is the **purchase rate and deliberately not the landed cost**; the test proves it with a batch whose landed cost (100) differs from its purchase rate (80), so 20% gives 96 rather than 120 (D-070). What remains open is only **what the line charges tax on**: rather than apply the counter's 5% B2C default to a hospital supply, a package line whose product has **no recorded slab is refused**, naming the product. **The four per-pharmacy percentages are also still the owner's to supply** — until one is set, a package sale is refused and names the setting | Medium | Ask the owner: (a) is a package sale a taxed B2B supply, and on what slab; (b) the four markup percentages. Each answer is a seed/setting change, not a redesign |
| N-16 | ~~`phase5_alerts.sql` has one assertion that has been failing since migration 00031~~ **RESOLVED (2026-09-20, built).** The obsolete assertion asserted `expiry_date IS NOT NULL`, which 00031 deliberately dropped so an imported batch with no recorded expiry can be represented honestly. It has been **replaced rather than deleted**: it now asserts that the column *is* nullable, that a batch with **no expiry is not reported as expiring** in a 90-day horizon, and that `batch_status` labels such a batch **`'unknown'`, not `'safe'`** — the behaviour the function's guard became load-bearing for once NULL was allowed. The file's two declarations that had never been used (`v_noexpiry`, `v_b_none`, written when that fixture was impossible) are what the new fixtures use. The file is now **27 PASS / 0 FAIL** and the whole committed suite is green | — | Done. Recorded because the file had been **red since 00031 without any gate noticing**: the SQL tests are run by hand, and re-running them is not part of an automated gate |
| N-17 | **(a) RESOLVED (2026-09-20, built); (b) still deferred.** (a) **A patient master edit is now gated server-side**, not by a hidden control: the patient-identity columns (`patient_code`, demographics, guardian fields, `notes`) are no longer directly writable by `authenticated` — the migration-00017 idiom, table-level UPDATE revoked and the customers form's own eight columns granted back, so **no existing screen changes what it can do** — and `update_patient()` requires the **owner or a pharmacist**, with a cashier refused (asserted in the test, D-076). Creating a patient for a sale stays available to any authorized role, which is what the brief asks for. (b) **`sales.discount_above_limit_request_id` does not exist**, because its target `approval_requests` does not (D-071), so an above-10% discount is **refused** rather than recorded — that branch is **not production-ready**, and a cashier who needs one is blocked until Phase 6.5c lands | (b) Medium | (b) is Phase 6.5c, which D-071/D-067 already make a hard prerequisite |
| T-7 | **An unknown expiry wears the "safe" badge.** Phase 6.5a made `product_batches.expiry_date` nullable and gave `batch_status` a fourth bucket, `'unknown'`, precisely so a batch nobody can date is not reported as having more than ninety days of shelf life. The server side is done and asserted; the app is not — `expiryStatusFromDb` (`app/lib/data/models/batch_status.dart`) maps anything it does not recognise to `ExpiryStatus.safe`, and `ExpiryBadge`'s label for that bucket reads *"More than 90 days of shelf life"*. So the 145 imported rows with no expiry will show a badge that says the opposite of what is known. Nothing crashes and nothing is lost; it is the label that lies | Low | Add an `ExpiryStatus.unknown` member and its label (*"Expiry not recorded"*), map `'unknown'` to it in `expiryStatusFromDb`, and give it a neutral tone — the same shape the `'expired'` bucket already has. Then check the expiry dashboard's bucket counts, which currently cannot include an unknown date |
| T-8 | **The import has never been committed at scale.** `supabase/tests/opening_stock_import.sql` proves the commit on ten rows, and the *preview* has been measured against the owner's real 314-row export (read-only: 314 new products, 61,360 units, no refusals). The 314-row **commit** is unexercised until the owner runs it — by design, since this chunk was told not to import. If it fails it fails safe (one transaction, whole file refused, row-numbered reason), so the cost of finding out is one message rather than half a catalogue | Low | The owner runs it from `/settings/import/opening-stock` after reviewing the preview. Watch for the one thing the ten-row test cannot see: a `(product_id, batch_no)` pair the pharmacy's existing stock already holds, which refuses the file naming that line |

**Resolved in chat 4 (Phase 6, chunk 3 — `context/chat3n-summary.md`):** **I-3**, in a
commit of its own after chunk 3's (the chunk-2 message had claimed it shipped when it had
not — see that section) — the purchase-return form's 200-row dropdown is a **search**
covering the invoice number, the notes and the **distributor's name**, with a date window
and twenty-at-a-time paging (**D-064**). **N-13 was added** by the same chunk (the
three-read cap has a gate on the side of the screen where a bill has been read, and not on
the side where it has only been uploaded), and **N-8 was already closed in chunk 2** —
what chunk 3 did was make it *reachable*: the re-read button (D-062) is the tap that
transition never had. **N-11's Vercel half is configured but not run** (D-063), and
**N-12 was reviewed at the user's request and deliberately left deferred**. Still open
above: I-2, N-1, N-2, N-4, N-9, N-10, N-11, N-13, D-027's residual, and T-1.

**Resolved in chat 4 (Phase 6, chunk 2 — `context/chat3m-summary.md`):** **N-7** —
a decision rather than a workaround: confirmation stays on and accounts are confirmed by
hand (**D-060**) — and **N-8**, closed by keying the verify form on the stored object and
letting `didUpdateWidget` decide what a new parse owns (supplier and notes survive, the
lines and the reader's own header facts are replaced). The **Android APK** shipped
(**D-061**). Still open above: I-2, I-3, N-1, N-2, N-4, N-9, N-10, N-11, D-027's
residual, and T-1.

**Resolved in chat 4 (Phase 6, chunk 1 — `context/chat3l-summary.md`):** **W-1**,
**A-1**, **I-1**, **N-5**, **T-3**, **T-4**, **T-5** and **T-6** (the sale detail
screen's endless spinner for a bill that is gone, found while writing its tests).
R-1's README refresh landed as well, with `docs/USER_MANUAL.md` and
`docs/DEPLOYMENT.md` beside it. Still open above that this chunk did not touch:
I-2, I-3, N-1, N-2, N-4, N-7, N-8, N-9, N-11, D-027's residual, and the
dependency-pin item T-1.

**Resolved in chat 4 (chunk C3):** the catalogue is embedded, and the floor stopped
being a guess. Live: `{embedded:1,remaining:0}` then `{embedded:0,remaining:0}`
(resumable, and nothing spent on the second run); `products.embedding` is null on 0
real rows; the vector leg fires on a real bill's text (`Dolo650Tab15s` → the real
product at 0.8280, `reason: vector`); and the constant behind it is **0.78**, inside
the window nine real measurements left open (**D-044**). No open item was made worse:
N-5 untouched, N-2 unchanged for the reader, N-7 bypassed with the user's own
session (and the token was used for read-only probes and the intended backfill only).
**N-9 is new** — the floor's measurement rests on a one-product catalogue.

**Resolved in chat 4 (chunk C2):** the app can now suggest, and learn. A live probe
of the deployed `match-product` (read-only, with the session token the user supplied)
confirmed the embedding call, the model name, the 768-dimension parse and the CORS
header on the **200** path — the three things C1 left unverified — and measured the
embedding quota: 11 requests / 80 texts in ~3 minutes with no refusal, so the
embedding metric is **not** the reader's 5/minute (**D-041**). No open item was made
worse: N-5 is untouched (the learned write sidesteps the NULL-supplier trap inside
the new function rather than fixing the index), N-2 is unchanged for the reader, N-6
stays withdrawn, and N-7 is bypassed by using the user's own session.

**Resolved in chat 4 (continued): N-3.** The Edge Functions' tests are gates now:
`HANDOFF_PROTOCOL`'s gate block gained `deno test supabase/functions` (which
type-checks and runs all 81) and a `deno check` per entry point
(`ocr-purchase-bill/index.ts`, `match-product/index.ts` — the entry points and
their wiring, which no test imports), and `make test-functions` runs all three.
None of them needs Docker or a secret.

**Resolved in chat 4 (C1 follow-up): N-6 — it was a false positive.** It claimed a
live function response carried no `access-control-allow-origin`. It does: the
deployed gateway answers with `Access-Control-Allow-Origin: *` (capitalised) on the
error paths of **both** functions and on the preflight, and passes the other three
CORS headers through lowercased. The finding was a **case-sensitive `findstr`** on
my side — `findstr /C:` matches case, and only that one header comes back
capitalised, so the filter hid exactly it. Re-measured with the full header dump:

```
POST match-product      {"lines":["Dolo 650"]}   -> 401  Access-Control-Allow-Origin: *
OPTIONS match-product   (preflight)              -> 204  Access-Control-Allow-Origin: *
POST ocr-purchase-bill  {"path":42}              -> 400  Access-Control-Allow-Origin: *
```

No code changed and neither function was redeployed: `_shared/response.ts` already
sets the four headers on every path (`json`/`okJson`/`failJson`/`preflight`), and the
gateway replaces the origin one with its own. See **D-038** for the contract and the
verification recipe (`findstr /I`, or `Select-String`).

**Resolved this chat:** P-1 / chat2b O-1 (editing an `ordered` purchase silently
returned it to `draft` — now reverts only when the lines change, and says so:
see D-019). Chat 3 also closed the two defects the sale-side migration shipped
with (an `anon` EXECUTE grant and an overpayment that stored a negative balance)
and the purchase-return credit note Phase 2 left unposted — all three in
migration 00020.

**Resolved in chat 4: T-2.** Phase 3's missing Dart tests are written: 91 of them
(55 for sales, 36 for sale returns), none changed. `test/features/sales/` now
exists. Two smaller items were found while writing them and are recorded above as
T-4 and T-5 — both dead or ambiguous UI in the sale-return form, neither a
behavioural defect. **Two things T-2 named are still untested**, for reasons
rather than for lack of trying: `invoice_printer.dart` (its `printReceipt` lays
out the PDF *and* calls `Printing.layoutPdf` in one method, so a test would have to
mock a platform channel rather than assert a document — the fix is to extract the
document builder) and `sale_detail_screen.dart` (the bill the counter opens).

---

## Dependency Pins (Load-Bearing — DO NOT CHANGE)

```yaml
# app/pubspec.yaml
riverpod_lint: '>=3.0.0 <3.1.0'   # 3.1.8 renamed its entrypoint to lib/main.dart,
                                   # but custom_lint 0.8.1 still imports
                                   # package:riverpod_lint/riverpod_lint.dart ->
                                   # `dart run custom_lint` dies with
                                   # "Failed to start the plugins"
custom_lint: ^0.8.0                # forces Freezed 3.x
freezed: ^3.0.0                    # models must be `abstract class X with _$X`
environment:
  sdk: ^3.8.0                      # json_serializable null-aware elements
```

Changing any pin above requires explicit user approval (see DECISIONS.md D-007).

---

## Phase 6.5a — the opening stock import [DONE]

**What this chunk delivered.** The one-time import of the owner's existing stock from Marg:
a schema that can represent what that file contains, three RPCs, the screen that previews and
runs it, and a test for each layer.

- **Two migrations.** `20260920000031_phase6_5a_opening_stock_import.sql` adds
  `import_jobs` + `import_job_rows` (RLS: owner-only select, **no write policy** —
  the RPC is the only way in), `products.gst_percent/cgst_percent/sgst_percent`
  (nullable, no default), `product_batches.is_unknown_batch`, drops `expiry_date`'s NOT NULL,
  and replaces `batch_status` with an explicit column list plus the new flag — the view's
  `select b.*` was frozen at creation in 00013, and a naive `create or replace` is refused
  because the new column would land *before* `expiry_status`. It gained a fourth bucket,
  `'unknown'`, because the old CASE would have called an undated batch 'safe'.
  `20260920000032_phase6_5a_opening_stock_digest_schema.sql` corrects one expression in 00031:
  `digest()` is in Supabase's `extensions` schema and every function here pins
  `set search_path = public`, so the fingerprint needed `extensions.digest(...)`. It is a
  second migration rather than an edit because 00031 was already applied (D-013's rule).
- **Three public RPCs and one internal.** `preview_opening_stock(jsonb)` (writes nothing),
  `commit_opening_stock_import(jsonb, text)`, `get_import_job(uuid)`, and the shared
  `opening_stock_classify(uuid, jsonb)` that both of the first two call — granted to no role,
  so a preview cannot classify differently from a commit.
- **The Flutter module** at `app/lib/features/import/opening_stock/`: an RFC 4180 reader that
  sends every value as text, a picker seam, the three envelope models, the repository, the
  controller (stage machine: idle → reading → previewing → preview → committing → success /
  error), the screen and three widgets, and an audit-CSV renderer saved through
  `FilePicker.saveFile`. Routed at `/settings/import/opening-stock` (D-022 — it nests under
  Settings rather than taking a top-level `/import/…` that would leave the rail on Dashboard),
  with the way in offered to an owner only.
- **New dependency: `file_picker: ^13.1.0`** — CSV selection and the audit download, since
  `image_picker` opens a gallery and cannot pick a CSV. It brought six platform packages with
  it, all of them already-pointless-or-used; nothing else in `pubspec.yaml` moved.

**Files.**

- `supabase/migrations/20260920000031_phase6_5a_opening_stock_import.sql` (new)
- `supabase/migrations/20260920000032_phase6_5a_opening_stock_digest_schema.sql` (new)
- `supabase/tests/opening_stock_import.sql` (new — 65 assertions, inline fixtures)
- `app/lib/features/import/opening_stock/{data/{opening_stock_csv,opening_stock_file_picker,opening_stock_models,opening_stock_repository,opening_stock_audit_csv}.dart,application/opening_stock_controller.dart,presentation/opening_stock_import_screen.dart,presentation/widgets/{preview_table,import_summary_card,import_error_row}.dart}` (new)
- `app/test/features/import/opening_stock/{opening_stock_csv_test,opening_stock_models_test,opening_stock_audit_csv_test,presentation/opening_stock_import_screen_test}.dart`, `app/test/features/settings/presentation/settings_placeholder_test.dart`, `app/test/support/{fake_opening_stock_repository,fake_opening_stock_file_picker,opening_stock_test_app}.dart` (new)
- `app/lib/core/router/routes.dart`, `app/lib/core/router/app_router.dart`,
  `app/lib/features/settings/presentation/settings_placeholder.dart`, `app/pubspec.yaml`,
  `app/pubspec.lock` (changed)
- `.gitignore` (changed — `supabase/fixtures/opening_stock/` is the owner's real export,
  kept locally and deliberately **not** committed; the SQL test writes its own rows inline and
  reads no file, so a fresh clone runs the whole suite without it)
- `DECISIONS.md` (D-065, D-066), `PROGRESS.md` (this)

**Verification evidence.** Every gate from the repo root, raw:

- `dart format lib test` → `Formatted 448 files (0 changed)`
- `dart run build_runner build --delete-conflicting-outputs` → `Built with build_runner in 62s; wrote 42 outputs`
- `dart run custom_lint` → `No issues found!`
- `flutter analyze` → `No issues found! (ran in 19.4s)`
- `flutter test` → `01:43 +729: All tests passed!`
- `deno test supabase/functions` → `ok | 181 passed | 0 failed (1s)` (no function touched)
- `deno check` × 5 entry points → exit 0
- `supabase db push --dry-run` → `Remote database is up to date.` (32/32)
- `supabase db query --linked --file supabase/tests/opening_stock_import.sql` →
  `SUMMARY: 65 PASS / 0 FAIL of 67 assertions` (the file ends by raising, so it rolls back)
- **The migration was pushed** (2 new versions, 00031 and 00032). A first push of 00031 failed
  on an unescaped apostrophe in a `comment on table` and **left nothing behind** — a migration
  file is applied in one transaction, verified by querying information_schema afterwards
  (0 columns, 0 tables, 0 functions, no recorded version).
- **A read-only measurement against the owner's real export** (not a test — a probe, since the
  file is not in the repository): `preview_opening_stock` as the real owner answered
  `314 rows, 61,360 units, ₹6,04,832.90 at cost, 53 zero-qty, 138 unknown batch, 145 unknown
  expiry, 3 expired, 314 new products, 0 refused, 0 ambiguous`. Production still holds
  **1 product, 0 batches, 0 import jobs** — the import has not been run and the SQL test wrote
  nothing outside its transaction.

**What this chunk deliberately did not do.**

- **Nothing was imported.** The owner runs it after reviewing the preview (T-8).
- **No xlsx reader.** The column keeps `'xlsx'` as a value; reading a spreadsheet needs a
  parser in an Edge Function, and the owner's file is a CSV (D-065).
- **No collision-resolution UI.** Rule 7's "block and let the owner resolve" is enforced by the
  refusal — the preview lists every ambiguous line with the catalogue products it matches, and
  the owner settles it in the catalogue first. Nothing auto-picks and nothing creates a third
  product.
- **No inventory labels.** The `'unknown'` expiry badge and the "unknown batch" wording in the
  inventory screens are T-7, and this chunk does not own those screens.
- **No billing, stock-trigger or FEFO change.** `checkout_sale` and the Phase 2/3 automation are
  untouched; `supabase/tests/opening_stock_import.sql` asserts no purchase, purchase line,
  payment, ledger entry, sale or stock adjustment is written, and that the batches hold exactly
  the imported quantity.

### Bug fix — the web picker threw the chosen file away [DONE]

Reported from the owner's browser test: the dialog opened, `PharmaFlow_Opening_Stock.csv` was
selected, and nothing happened — no request, no error, no state change, no spinner. The four
reported hypotheses were all about the app's own handling of the answer (`file_picker_web`'s
`withData`, an empty catch, a screen that does not rebuild, a blob URL read without data); none of
them is what the code does, and none of them is the cause.

**Root cause (in the package, one step below the app):** `FilePickerWeb`'s input session registers
a `window` `focus` listener and, **500 ms after any focus event, completes a pick that is still in
progress with `null`** — the value the picker uses for "the user changed their mind". A file that
*was* selected is discarded, and the controller mapped that `null` to "back to the offer", which is
why the screen looked exactly as it had before anything was chosen. Upstream #1833 and #1202 are
the same mechanism with the same symptom. `file_picker` 13.0.0 removed `cancelUploadOnWindowBlur`
from the public `pickFile()` (#2202/#2203), and the `WebOptions` the facade re-exports declares no
fields at all — so the heuristic could not be switched off through `file_picker` alone.

**Fix:** D-073 — the flag is reached through one conditional import, and `file_picker_web` is
promoted from a transitive dependency to a direct one at the version already resolved (no pin
moves). The same round of work rebuilt the screen as six explicit steps with a failure card that
names the step, made the byte decode and the file-name check pure functions so the cases that had
no test now have one, and carried the failing row number on `OpeningStockCsvException` rather than
reading it back out of the message. Module: 91 tests. Suite: 758 (+29). Gates: `flutter analyze`,
`dart run custom_lint`, `flutter test`, the five `deno check` entry points and
`deno test supabase/functions` (181) all pass, and the web branch was checked on the artifact with
`flutter build web --source-maps` rather than argued.

---

## Chat 4 Progress — Phase 6, chunk 3: the Vercel config, the re-read button and I-3 [DONE — PHASE 6 OPEN]

Three jobs of different kinds: **the deploy written but not run** (D-063), **the button
the N-8 fix was waiting for** (D-062), and **I-3**, which turned out never to have been
done at all despite the previous chunk's message saying otherwise — so it landed in a
commit of its own that corrects the record (D-064). The full account is
`context/chat3n-summary.md`.

### What this chunk delivered

- **The Vercel web deploy is configured — and has not been run.** `app/vercel.json` is
  the build config (SPA rewrite, `no-cache` on the service worker, `framework: null`,
  `installCommand` empty, `outputDirectory: build/web`) and `docs/DEPLOY_VERCEL.md` is
  the runbook: import the repo, **Framework Preset Other / Root Directory `app`**, set
  `SUPABASE_URL` and `SUPABASE_ANON_KEY`, deploy, verify with `curl`.
  - **`vercel.json` lives at `app/vercel.json`, not the repository root (D-063).** The
    spec asked for the repository root; Vercel reads the file from **the project's root
    directory** — the Root Directory setting — and with a Root Directory configured the
    build *cannot read files outside it*, so a root-level copy would be silently ignored
    and the build would fail with no Flutter SDK, no `build_runner` step and an empty
    `.env`. The evidence is in D-063, and `docs/DEPLOY_VERCEL.md` §8 tabulates the two
    arrangements that work against the one that does not.
  - **What the build does, and why each step is there**: it downloads the pinned Flutter
    archive (Vercel's Amazon Linux 2023 image ships no Flutter), marks the SDK
    `safe.directory` for git, runs `flutter pub get`, **runs `build_runner`** (the
    `.g.dart`/`.freezed.dart` files are gitignored, so a fresh clone does not compile
    without it), writes `.env` from the two env vars — the bundle's only source of its
    Supabase project, because `pubspec.yaml` declares `.env` as an asset — and then
    `flutter build web --release`.
  - **No secret is in the file or the document.** Both name the variables, never a value.
- **The re-read is exposed (D-062), so N-8 is reachable at last.** The verify screen's
  "What the reader saw" card now carries a small text **"Read it again"**, with the
  counter under it ("Attempt 2 of 3" on a form that was reached through the first read), a
  confirmation dialog — *"Re-read? Uses one AI call."* — a **three-read limit per bill per
  session**, and the button disabled while a read is out and after the third, where it
  reads **"Max attempts reached"**. The count is a property of the bill
  (`PurchaseOcrState.reads`, incremented when a read *starts* and saturating at
  `maxReads`), not of the widget.
  - **The fix from chunk 2 was correct-but-latent: nothing a user could tap produced a
    second read.** That is now a tap, and the test that proves the re-read keeps the
    supplier, the notes and the corrected lines **drives the screen** rather than the
    controller. The harness's `configure:` hook stays, with its comment rewritten: it is
    for triggers no widget offers, not for a re-read.
  - **The verify form's own failure card is capped with it** (a failure does not earn a
    bill a fourth read) and says why when the allowance is spent — two re-read controls on
    one screen disagreeing would have been worse than either choice.
- **I-3 is implemented (D-064), in a commit of its own after this chunk's.** The
  purchase-return form's invoice picker is a **search dialog** on the repository call the
  list screen already pages with: **one box covering the invoice number, the notes and the
  distributor's name**, an invoice-date window, **twenty at a time with "Load more"**, four
  states told apart (rows / nothing matched / nothing there / failed-with-retry), and a
  field that **carries the choice's own label** — so `_purchaseLabel`'s "Another purchase"
  branch, the old code admitting it could not name a purchase outside the page it had
  loaded, is deleted rather than worked around.
  - **Why it needed its own commit**: the chunk-2 message listed I-3 as shipped and the
    diff contains no file under `app/lib/features/returns/`. `returnablePurchaseLimit`
    (200) and its dropdown were both still there. `HANDOFF_PROTOCOL.md` gained a rule so
    the next message is checked against the diff before it is written.
  - **Supplier names are resolved by a second query**, not a join: the term goes to
    `SuppliersRepository.list` and the ids it returns go into `PurchasesQuery.supplierIds`,
    which `PurchasesRepository.list` ORs with the text branches. A filtered join would be
    one round trip, but its PostgREST support varies by version and there is no local stack
    here to try it against.
  - **The filter was then sent live** (read-only, with a signed-in session): the mix of
    `ilike` branches and a `supplier_id.in.(…)` uuid list inside one `or=()` is **accepted —
    200**, with a deliberately malformed `or=()` as the negative control answering **400
    `PGRST100`** so the 200s mean the server parsed the tree. **But the tenant holds zero
    purchase rows and zero suppliers**, so *matching* is unproven: nothing has ever been
    found by any search, and "finds the invoice by distributor name" rests on the builders'
    tests, not on a live hit.
  - **One defect found by reading the path** (the empty tenant cannot show it): a term that
    sanitises to nothing (`%%`, `,`) still ran the supplier lookup, which with an empty
    search returns the first page — so a meaningless term answered with the first 25
    distributors' invoices. Guarded now, with a regression test.

### Files

```
app/vercel.json                                                  the Vercel build config (D-063)
docs/DEPLOY_VERCEL.md                                            the web deploy runbook (new)
docs/DEPLOYMENT.md                                               §2.2 rewritten onto the config; §8/status notes updated
app/lib/features/purchase_ocr/application/purchase_ocr_controller.dart   reads/maxReads/withReadStarted
app/lib/features/purchase_ocr/presentation/purchase_ocr_screen.dart      the button, the dialog, the counter, the cap
app/test/features/purchase_ocr/presentation/purchase_ocr_screen_test.dart   5 new widget tests (one re-reads the whole way)
app/test/features/purchase_ocr/application/purchase_ocr_controller_test.dart  4 new controller tests
app/test/support/fake_purchase_ocr_repository.dart               a `gate` to hold a read in flight
app/test/support/purchase_ocr_test_app.dart                      the `configure:` comment, corrected
app/lib/core/utils/postgrest_search.dart                         buildInFilter + buildAnyOfFilter (I-3)
app/lib/features/purchase/data/purchases_repository.dart         PurchasesQuery.supplierIds, hasSearch, the OR branch
app/lib/features/purchase/application/purchase_picker_controller.dart  the picker's filter + paged results (new)
app/lib/features/returns/presentation/widgets/purchase_picker_field.dart  the field and its search sheet (new)
app/lib/features/returns/presentation/purchase_return_form_screen.dart  on the picker; the 200-row dropdown deleted
app/lib/features/returns/application/purchase_return_form_controller.dart  returnablePurchaseLimit + provider deleted
app/test/core/utils/postgrest_search_test.dart                   8 tests over the three filter builders
app/test/features/purchase/application/purchase_picker_controller_test.dart  10 tests (new)
app/test/features/returns/presentation/widgets/purchase_picker_field_test.dart  9 tests (new)
app/test/features/returns/presentation/purchase_return_form_screen_test.dart  `_choosePurchase` drives the picker
app/test/support/fake_purchases_repository.dart                  the OR branch, sanitised term, lastLimit/lastOffset
app/test/support/returns_test_app.dart                           a suppliers-repository fake for the name lookup
HANDOFF_PROTOCOL.md                                              the commit-message-vs-diff rule
DECISIONS.md                                                     D-062, D-063, D-064
PROGRESS.md, README.md, docs/USER_MANUAL.md, context/chat3n-summary.md, context/chat3o-opening-prompt.md
```

### Verification evidence

```
dart format lib test                      -> 426 files, 1 changed (the new controller test), then 0
dart run build_runner build --delete-conflicting-outputs
                                          -> exit 0; its outputs are the gitignored
                                             .g.dart/.freezed.dart files; only the known
                                             "SDK language version 3.12.0 is newer than analyzer" notice (T-1)
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +665: All tests passed!   (628 -> 665, over this chunk's
                                             three commits: 9 for the re-read, 28 for I-3)
deno test supabase/functions              -> ok | 181 passed | 0 failed (2s)
deno check <each of the five entry points> -> exit 0 (no output)
flutter build web --release               -> exit 0; built build\web in ~5 min, with index.html,
                                             flutter_service_worker.js and assets/.env present
                                             (that last path is what docs/DEPLOY_VERCEL.md §5
                                              reads — it was written as assets/assets/.env and
                                              the real build corrected it)
read-only probe against the hosted REST (node client, both secrets read from
files and never printed; 13 GETs, no write, no RPC, no function invoked)
                                          -> the construct under test is accepted:
                                             or=(invoice_no.ilike.%nope%,notes.ilike.%nope%,
                                             supplier_id.in.(00000000-0000-0000-0000-000000000000))
                                             -> 200; three ids in the list -> 200; the
                                             supplier branch alone -> 200; a malformed
                                             or=() control -> 400 PGRST100 (so the 200s
                                             mean the tree parsed)
                                             term="arihant,650%" -> sanitised "arihant 650",
                                             sent as %25/%20, -> 200, no injection surface
                                             the tenant holds 0 purchases (any status) and
                                             0 suppliers, so no case returned a row:
                                             parsing proven, matching NOT
```

The Vercel side, checked as far as this machine can check it — **the deploy itself was
not run, and neither was a real Vercel build**:

```
node -e JSON.parse(app/vercel.json)       -> parses; keys: $schema,framework,installCommand,
                                             buildCommand,outputDirectory,rewrites,headers;
                                             outputDirectory: build/web
bash -n <the buildCommand, extracted>     -> exit 0 (POSIX shell syntax is valid)
bash <the ".env" step, extracted, SUPABASE_URL/ANON_KEY set>
                                          -> SUPABASE_URL=https://example.supabase.co
                                             SUPABASE_ANON_KEY=example-anon-key
                                             (the two lines the asset needs, and nothing else)
```

### What this chunk deliberately did not do

- **No deploy.** The Vercel account exists; the project does not. `app/vercel.json` has
  never been read by Vercel and `docs/DEPLOY_VERCEL.md` has never been followed — the
  first deploy is the test of both, which is why §7 of that document lists the failures
  worth recognising.
- **I-3 was implemented in a commit of its own, and the earlier draft of this section said
  it had not been touched at all.** ⚠️ *The record, plainly:* the chunk-2 commit message
  lists *"I-3: purchase return form's 200-row limit replaced with a searchable picker"*, but
  `git show --stat 25615b0` touches **no file** under `app/lib/features/returns/`, and the
  code still capped the list at `returnablePurchaseLimit`
  (`purchase_return_form_controller.dart:36`) behind an `AppDropdownField<String>`
  (`purchase_return_form_screen.dart:234`). The same message described N-8 backwards
  ("preserves … invoice date, invoice number") where the code replaces those and preserves
  the supplier and the notes. **Neither inaccuracy changed the tree**, and both were
  believed for a chunk — which is why `HANDOFF_PROTOCOL.md` now requires a commit message
  to be checked against the diff (`git show --stat`) before it is written, and why the
  correction is a commit of its own rather than an amend.
- **N-12 was reviewed and left deferred** (the user's instruction): it is a warning today,
  and its trigger is an SDK upgrade that has not happened. The row above records the review.
- **Nothing was made worse.** N-1, N-2, N-4, N-9, N-10, I-2, T-1 and D-027's residual are
  untouched, and the two permanent probe rows are still in production on purpose (D-049).

## Chat 4 Progress — Phase 6, chunk 2: the APK, N-7 and N-8 [DONE — PHASE 6 OPEN]

The half of Phase 6 that needed decisions rather than accounts. The full account is
`context/chat3m-summary.md`; the decisions are **D-060** (email confirmation) and
**D-061** (the sideload APK).

### What this chunk delivered

- **The Android APK ships.** `flutter build apk --release` →
  `app/build/app/outputs/flutter-apk/app-release.apk`, **80,295,479 bytes**. Release
  mode (AOT, no debug banner), signed with the **debug key** because that is what the
  Flutter template's release `signingConfig` already declares — no keystore, no
  `key.properties`, no signing-config change, and **no Play Store work** (D-061).
  **Independently verified, not assumed**: `apksigner verify --print-certs` exits 0 and
  reports `Signer #1 certificate DN: C=US, O=Android, CN=Android Debug`. The build took
  ~18 minutes on the first run (Gradle downloads the toolchain), and it emits a Flutter
  warning that `mobile_scanner` still applies the Kotlin Gradle Plugin — a deprecation
  notice, not a failure.
  - **Accepted trade, recorded in D-061**: Play identifies an app by its signing key, so
    publishing later means a new keystore and **one uninstall/reinstall per staff
    device**. `docs/DEPLOYMENT.md` §3.1 says so where somebody will read it before
    publishing, and §3.2–3.5 keep the full keystore/signing/Play procedure marked as
    publish-time work rather than deleting it.
- **N-7 settled (D-060).** The hosted project keeps **"Confirm email" ON** and accounts
  are confirmed by hand in the dashboard. No app change, no resend affordance, no
  hand-edited `auth.users` row — the guard that refuses that write is correct and stays.
  The repository's belief that confirmation was off (`config.toml`'s
  `enable_confirmations`) is a local-stack-only key (D-003), and `.env.example`, the
  README and the user manual now state the real policy.
- **N-8 closed.** A successful re-read of a bill used to discard **everything** the
  human had done to the verify form, because the form was keyed on the *parse*: a new
  parse meant a new key, a new `State`, and a fresh `initState`. The key is now the
  **storage path** (the same string for a re-read of the same bill, different for
  another bill), and `didUpdateWidget` decides what a new parse owns: it replaces the
  invoice number, the date and the **lines**, and leaves the **supplier** and the
  **notes** alone. The offers ranked for the old lines are dropped and asked for again
  when a supplier is already known — the same one embedding request the old flow spent
  after the human re-picked the supplier it had thrown away, with one tap fewer.
  - **The test caught a real bug in the fix**: the first version called the matcher from
    `didUpdateWidget`, which runs *during* a build, and Riverpod refuses a provider write
    there ("Tried to modify a provider while the widget tree was building"). It is
    deferred through `WidgetsBinding.instance.addPostFrameCallback` now.
  - **Reachability, stated plainly**: nothing a user can currently tap produces this
    transition. The form's own "Read it again" sits behind a failure card, and a failure
    requires a read to have failed — so a *successful* parse can never be followed by
    another read while the form is up. The fix is therefore correct-but-latent: it makes
    the transition safe the moment a trigger exists (and it is the precondition for
    exposing that button properly). The test drives the controller directly through a
    new `configure:` hook on the OCR harness, which is the only way to reach it.

### Files

```
app/lib/features/purchase_ocr/presentation/purchase_ocr_screen.dart   N-8 (key + didUpdateWidget + _applyParse)
app/test/features/purchase_ocr/presentation/purchase_ocr_screen_test.dart  N-8 test
app/test/support/purchase_ocr_test_app.dart                           the `configure:` container hook
docs/DEPLOYMENT.md                                                    §3 rewritten for the sideload APK (D-061)
DECISIONS.md                                                          D-060, D-061
PROGRESS.md, README.md, context/chat3m-summary.md, context/chat3n-opening-prompt.md
```

**Artifact (gitignored, on disk):**
`app/build/app/outputs/flutter-apk/app-release.apk`.

### Verification evidence

```
dart format lib test                      -> 421 files, 0 changed
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +628: All tests passed!   (627 -> 628)
flutter build apk --release               -> exit 0, ~18 min, no signing config added
apksigner verify --print-certs app-release.apk
                                          -> Signer #1 certificate DN: C=US, O=Android, CN=Android Debug
                                             (verification exit 0; the debug key, as D-061 says)
```

### What this chunk deliberately did not do

- **No keystore, no Play listing, no Play Console account** (the user's instruction, and
  D-061's reasoning). The keystore/signing procedure in `docs/DEPLOYMENT.md` is marked as
  publish-time work.
- **No I-3.** The searchable purchase picker for the returns form is the first item of
  the next chunk — it is a new widget plus its tests, and it was not attempted rather
  than half-built (see `context/chat3n-opening-prompt.md`).
- **No Vercel deploy and no credential work** — still waiting on accounts (N-11).
- **No Windows release build** (D-059) and nothing touched the two probe rows (D-049).

## Chat 4 Progress — Phase 6, chunk 1: the no-external-input half [DONE — PHASE 6 OPEN]

Phase 6 has no server left to build. This chunk took everything in it that needs no
account, no credential and no live session — plus the documentation the phase owns —
and left the deploy half for the next one. The full account is
`context/chat3l-summary.md`; the decisions are **D-056 to D-059**.

### What this chunk delivered

- **W-1 — the Windows build is fixed.** `app/windows/CMakeLists.txt` defines
  `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` for
  `permission_handler_windows_plugin` only, guarded by `if(TARGET …)` so a pubspec
  that ever drops the plugin cannot leave a stale line breaking the build. Reproduced
  first (`error C2338: static assertion failed: 'error STL1011: … <experimental/coroutine>
  … deprecated …'`), then fixed, then `flutter build windows --debug` produced
  `build\windows\x64\runner\Debug\app.exe`. **The release build was deliberately not
  run** at the user's instruction — the debug build already proves the compile fix, and
  the release pass costs minutes of toolchain time for no new information (D-059).
- **A-1 — `publishableKey`.** `bootstrap.dart` passes `publishableKey:` (2.17 deprecated
  `anonKey` for the same public key, checked in the resolved 2.17.2 source). The **env
  var stays `SUPABASE_ANON_KEY`**: that is the contract `.env.example` and the README
  document, and the two names deliberately differ.
- **I-1 — the reorder list is the server's answer.** `InventoryRepository.lowStock`
  calls `low_stock_products()` and returns `LowStockProduct`, the same payload the
  notification list and the chatbot read (D-047). The Dart comparison, the 500-row scan
  and `lowStockScanLimit` are gone; `lowStockLimit` is the server's own ceiling.
- **The trade I-1 forced, and why it is the right one**: the RPC answers in quantities
  (on hand, level, **shortfall**) and not in money, so the low-stock tab renders
  `LowStockCard` over that payload instead of `ProductStockCard`, and the *"₹ at cost"*
  line the old list carried is gone. That figure belongs to the `product_stock` rollup
  (the stock tab and the product detail still show it), and copying it from a
  different query — or rendering a default — would put a wrong rupee amount on a
  reorder list. In exchange the list gained the **shortfall**, which is the number the
  RPC's own comment says it exists to provide. One card, one `.dart` file, and a
  one-line reversion if the review disagrees.
- **N-5 — the alias key treats "no supplier" as a value** (D-056). Migration
  `00030` rebuilds the unique index on `(pharmacy_id, supplier_id, normalized_name)`
  with `NULLS NOT DISTINCT`; the coalesce-expression alternative was rejected because
  PostgREST's `on_conflict` matches an index by *column names* and an expression index
  is not inferrable, so `addAlias`'s upsert would have broken for every pharmacy. A
  read-only probe first: **0 alias rows, 0 colliding keys**, so the index was built
  over an empty table and nothing had to be de-duplicated. Both contradicting comments
  reconciled (00015's points forward at 00030, the way 00010 points at 00015 —
  D-013). `supabase db push --yes` → **30/30 local and remote**.
- **T-3 — the ledger's failure path is a retry** (D-058). The body decides the error
  *before* the retained value, so a party chosen after the first frame whose read fails
  shows the failure and a Retry instead of "Nothing on this ledger"; the duplicate
  SnackBar listener is gone, because one failure had two surfaces and the second one was
  noise.
- **T-4 — the sale-return form's dead branches are gone.** The picker's `'Choose a
  bill'` validator and `_save`'s report of the same thing could never run (the button is
  disabled until a bill is chosen), so the rule now lives in exactly one place: the
  button's `onPressed`. The remaining null check is type narrowing, and says so.
- **T-5 — "loading" and "no bills" are told apart.** The bill picker's hint is a
  three-way `Loading the bills…` / `No sales yet` / `Which bill`, so a pharmacy that has
  not answered yet is no longer told it has never sold anything.
- **T-6 (new, found while writing the bill screen's tests) — a bill that is gone says
  so** instead of spinning for ever. `saleDetailProvider` answers `null` for an id that
  is no longer there, and the screen read that as "still loading"; it now renders
  *Bill not found*, checking `!isLoading` so a retry in flight is not mistaken for a
  missing bill.
- **The coverage gaps Phase 3 named, both closed** (34 tests):
  - `test/services/invoice_printer_test.dart` (**17**) — the printer's **content** is
    extracted into an `InvoiceSheet` (D-057), so the bill is asserted as a document
    rather than through a mocked print channel: the seller block and its placeholder,
    the lines and their pricing, both tax splits, the discount present/absent pair, the
    total's emphasis and rule, how it was settled, and that the layout renders a PDF at
    all. **Writing it found a real defect**: the old split rounded both halves of
    `tax_total` separately, so an odd number of paise printed CGST + SGST that summed to
    one paisa *more* than the tax charged. The split now subtracts the rounded half
    (D-057); only the printed document changed, never a stored figure.
  - `test/features/sales/presentation/sale_detail_screen_test.dart` (**14**) — the bill
    screen's figures come from the document's own columns, the tax head follows the
    split, the line metrics appear (and the ones a line does not have do not), a
    prescription-only line is marked for the drug register, a walk-in and an account
    sale read differently, a part payment shows what is still owed, printing goes
    through the printer seam (and a refused print keeps the bill on screen), and a read
    failure offers a retry.
- **R-1 — the README is current.** It had said "Phase 0 (scaffold)", "14 migrations"
  and "21 tables"; it now carries the real state — 30 migrations, 24 tables/2 views,
  five Edge Functions, 13 destinations, 627 Flutter and 181 Deno tests, the gate block,
  the three load-bearing pins, the platform status (including the W-1 fix and the
  web-debug workaround), and pointers to the new docs.
- **`docs/` — a user manual and a deploy runbook.** `docs/USER_MANUAL.md` is written for
  the person behind the counter (getting in, products and aliases, ordering and
  receiving, the bill reader, inventory and reorder, the counter, the bill and printing,
  returns, the ledger, reports, notifications, the chatbot, day-to-day recipes, and an
  explicit list of what the app deliberately does *not* do).
  `docs/DEPLOYMENT.md` is the runbook: the gates, the `.env`-is-compiled-in fact (which
  is what makes a Vercel deploy a build-time concern), the Vercel steps and the `curl`
  checks that verify them, the Android keystore/signing steps with the exact
  `build.gradle.kts` change still to be made, the iOS runbook for a Mac, the Windows
  release note, the Edge Function secrets, and the honest outstanding list.

### Files

```
supabase/migrations/20260919000030_phase6_alias_identity.sql   (new)
supabase/tests/phase6_alias_identity.sql                       (new, 20 assertions)
app/lib/features/inventory/presentation/widgets/low_stock_card.dart  (new)
app/test/services/invoice_printer_test.dart                    (new, 17 tests)
app/test/features/sales/presentation/sale_detail_screen_test.dart (new, 14 tests)
app/test/support/sale_detail_test_app.dart                     (new)
docs/USER_MANUAL.md                                            (new)
docs/DEPLOYMENT.md                                             (new)
context/chat3l-summary.md                                      (new)
context/chat3m-opening-prompt.md                               (new)
```

**Modified:** `app/lib/bootstrap.dart` (A-1), `app/lib/features/inventory/data/inventory_repository.dart`
and `application/low_stock_controller.dart` and `presentation/inventory_screen.dart`
(I-1), `app/lib/features/ledger/presentation/ledger_screen.dart` (T-3),
`app/lib/features/returns/presentation/sale_return_form_screen.dart` (T-4/T-5),
`app/lib/services/invoice_printer.dart` (D-057), `app/lib/features/sales/presentation/sale_detail_screen.dart`
(T-6), `app/windows/CMakeLists.txt` (W-1), `app/lib/features/products/data/products_repository.dart`
+ `supabase/migrations/20260918000015_phase2_extras.sql` + `supabase/tests/phase5_match_products.sql`
+ `supabase/tests/phase5_learn_product_aliases.sql` (N-5's comment reconciliation),
`app/test/support/fake_inventory_repository.dart`, `fake_sales_repository.dart`,
`app/test/features/inventory/inventory_screen_test.dart`, `app/test/features/ledger/presentation/ledger_screen_test.dart`,
`app/test/features/returns/presentation/sale_return_form_screen_test.dart`,
`README.md`, `PROGRESS.md`, `DECISIONS.md`.

### Verification evidence

```
dart format lib test                                      -> 421 files, 0 changed
dart run build_runner build --delete-conflicting-outputs   -> no errors
dart run custom_lint                                     -> No issues found!
flutter analyze                                          -> No issues found!
flutter test                                             -> +627: All tests passed!  (593 -> 627)
deno test supabase/functions                             -> ok | 181 passed | 0 failed
deno check <each of the five entry points>                -> clean
flutter build windows --debug                             -> Built build\windows\x64\runner\Debug\app.exe
supabase migration list                                   -> 30/30 local and remote match
supabase/tests/phase6_alias_identity.sql                  -> 20 PASS / 0 FAIL of 21 assertions
  (the same file, pre-migration, produced 7 FAILs — see D-056)
supabase/tests/phase5_learn_product_aliases.sql            -> 42 PASS / 0 FAIL (no regression)
supabase/tests/phase5_match_products.sql                  -> all PASS (no regression)
```

### What this chunk deliberately did not do

- **No deploy.** The Vercel web deploy and the Android APK both need accounts that do
  not exist yet (N-11); `docs/DEPLOYMENT.md` is the procedure, written to be runnable,
  and says at the top that nothing in it has been executed.
- **No Windows release build** — the user's instruction, and D-059 records why the
  debug build is enough evidence for the fix.
- **No iOS work** (needs a Mac) and **no Windows features** (desktop is covered by web).
- **Nothing touched the two permanent probe rows** (D-049's evidence).

## Chat 4 Progress — Chunk E (PART 2 of 2): the `/chatbot` surface [DONE — PHASE 5 CLOSED]

The client of the chatbot: the service, the models, the controller, the screen and the
13th shell destination. No migration and no server change — E-part-1 had already
deployed and live-probed `chat-sql-agent`, so this chunk is Dart only. **Phase 5 ends
here.** The full account is `context/chat3k-summary.md`.

### What part 2 delivered

- **`ChatService`** (`lib/services/chat_service.dart`, `@riverpod`) in the
  `OcrService`/`MatchService` shape: an interface, `SupabaseChatService` over
  `functions.invoke('chat-sql-agent')`, a pure `decodeChatAnswer`, and `chatException` —
  a thin name over `functionException` (D-042) carrying only this feature's fallback
  sentence. The tenant never travels (D-004) and **nothing retries** (N-2): a
  `provider_unavailable` reaches the screen as a `ServerException` the user can act on.
  `chatHistoryFor` bounds the context to the last six turns, mirroring the function's
  own `MAX_HISTORY_TURNS`.
- **The answer as plain classes** (`lib/data/models/chat_response.dart`,
  `chat_message.dart`), the `ReportSummary` precedent: `ChatResponse` carries the
  sentence, the nullable `rpc`, the `params` the report was handed, the report's
  `data` **verbatim and un-modelled**, the model and the warnings. **A body that is not
  an object, or carries no `answer` string, is a failure** — the blank bubble is the one
  wrong answer this feature could give. `rpc: null` decodes as a *success*.
- **`describeAnswerOrigin`** — the one line under an answer, read entirely from the
  envelope: the report's name, the non-null arguments it was handed (in words: `within
  90 days`, `at most 5 rows`), and the caveats its own `meta` states — `returns_not_netted`
  being the one that motivated D-053 and has no sentence anywhere else.
- **`ChatController`** (`lib/features/chatbot/application/`) — plain state, not an
  `AsyncValue` (D-055), with `messages` / `asking` / `failure` as three separate fields.
  One model call per ask, a second refused before any call is spent, `ref.mounted`
  checked after the await (D-034), and the only retry a user's tap that re-asks the
  failed question verbatim.
- **The screen** — a transcript, a composer (Enter *and* a button: web is the first
  platform here, D-005), an invitation with example questions drawn from the report set,
  and four situations that cannot be confused: *nothing asked yet*, *still waiting*,
  *no answer to that* (prose, no error, nothing to retry) and *could not ask* (an error
  icon, the server's sentence, one retry). Nothing on it computes a figure.
- **The 13th shell destination** (D-054): `Routes.chatbot`, the `_navDestinations`
  entry, the router's shell child — Notifications → Chatbot → Settings, `inBottomBar:
  false`. Three lists moved and the existing parity tests did the enforcing; nothing new
  had to be added for that.

### Files

```
lib/services/chat_service.dart                              (new)
lib/data/models/chat_response.dart                          (new)
lib/data/models/chat_message.dart                           (new)
lib/features/chatbot/application/chat_controller.dart       (new)
lib/features/chatbot/presentation/chatbot_screen.dart       (new)
lib/features/chatbot/presentation/widgets/message_bubble.dart (new)
test/services/chat_service_test.dart                        (new, 28 tests)
test/features/chatbot/application/chat_controller_test.dart (new, 11 tests)
test/features/chatbot/presentation/chatbot_screen_test.dart (new, 10 tests)
test/support/fake_chat_service.dart                         (new)
test/support/chatbot_test_app.dart                          (new)
context/chat3k-summary.md                                   (new)
context/chat3l-opening-prompt.md                            (new)
```

**Modified:** `lib/core/router/routes.dart` (`Routes.chatbot` + `shellPaths`),
`lib/features/dashboard/presentation/dashboard_shell.dart` (the 13th entry),
`lib/core/router/app_router.dart` (the shell child),
`test/features/dashboard/dashboard_shell_test.dart` and `test/widget_test.dart` (12 → 13),
`DECISIONS.md` (**D-054**, **D-055**), `PROGRESS.md`.

### Verification evidence

```
dart format lib test                    -> 417 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> wrote 2 outputs, no errors
dart run custom_lint                    -> No issues found!
flutter analyze                         -> No issues found!
flutter test                            -> +593: All tests passed!   (544 -> 593)
deno test supabase/functions            -> ok | 181 passed | 0 failed
deno check ×5 (ocr, match, backfill, send-notification, chat-sql-agent) -> clean
```

No migration was added, so no `supabase db push` and no new SQL test. Nothing under
`supabase/` changed at all — the six Deno lines were run to prove that rather than
assert it.

### What this chunk deliberately did not do

- **No live end-to-end run.** E-part-1 probed the endpoint itself with the user's
  session; the widget tests drive the same recorded bodies over the fake. What a live
  run would add is the browser's own `functions.invoke` path on a **200** — it still
  could not prove an answer is *useful*. No token was needed or requested (N-7).
- **No dashboard card** for the chatbot (D-054's note): D-048's unread count is a number
  that changes without the user asking; a chatbot has nothing to say until asked.
- **No server change, no new report, no write path.** A question the five reports cannot
  answer is still answered with a sentence.

---

## Chat 4 Progress — Chunk E (PART 1 of 2): the last two aggregates, and the chatbot function [DONE, live-probed]

The server side of Chunk E: migration 00029 (`top_products`, `dead_stock`) and
`chat-sql-agent`, deployed and probed. **Part 2 — the `/chatbot` Dart surface — is briefed
in `context/chat3k-opening-prompt.md`**; the full account is `context/chat3j-summary.md`.

### What part 1 delivered

- **`supabase/migrations/20260919000029_phase5_chat_aggregates.sql`**, applied — two
  functions and their grants; no table, no column, no trigger, no view. `top_products(...)`
  (30-day rolling window, units by default, revenue available, ranked by either) and
  `dead_stock(...)` (stock on hand that has not sold in `p_days`), both `stable security
  definer`, tenant from `get_my_pharmacy_id()`, `authenticated` only with
  `revoke … from anon, public`. Both return `{meta, rows}`: the `meta` block is D-053's
  no-invisible-semantics rule, and it is why these two carry an envelope while 00027's two
  carry a bare array. The rules recorded in the migration: **a return does not subtract**
  and `returns_not_netted` says so rather than hiding it; dead means the last sale is
  strictly older than `p_days` (exactly `p_days` ago is still moving — the boundary day is
  inside the window); never-sold is dead stock with a null `days_since`; a product whose
  only stock has expired is still dead stock (a different question from `expiring_batches`);
  nothing on the shelf is not; and **neither function filters `is_active`** (what sold,
  sold; and a discontinued product with stock left is the most stuck cash).
- **`supabase/tests/phase5_chat_aggregates.sql`** — **36 PASS / 0 FAIL of 37 assertions**,
  atomic and self-rolling-back (verified: 0 ZZTEST rows survive). The fixtures are real
  sales written through `checkout_sale()` (D-021), so the stock trigger ran and refused to
  oversell; only their dates were moved afterwards.
- **`supabase/functions/chat-sql-agent/`** (`index`, `deps`, `handler`, `schema`, `answer`
  plus three test files) — deployed, `verify_jwt` on, acting as the caller. **The model
  chooses; the database answers** (D-026): one `generateContent` call with a
  `responseSchema` whose `rpc` is an **`enum`** of the five reports plus `unsupported`, and
  **phrasing templated in code** (D-053) — `answer.ts` renders each report's sentence from
  that report's own `jsonb`, so no model output is ever rendered and no invented figure can
  appear. Every parameter is validated before use; **one request makes one model call with
  no internal retry** (N-2); a question no report covers is a **200** with `rpc: null`.
  **52 new Deno tests** (129 → **181**).
- The gate wiring: `Makefile` and `HANDOFF_PROTOCOL.md` gained the fifth `deno check`.

### The probe (4 invocations, one model call each — N-7)

```
POST chat-sql-agent {"question":"what is low on stock?"}
  -> 200 rpc=low_stock_products, answer quoting the RPC's own row
         ("…dolo 650: 20 units short (0 in stock against a level of 20)."),
         data = the live tenant's real row, meta.model = gemini-3.6-flash
POST chat-sql-agent {"question":"what sells best this month?"}
  -> 200 rpc=top_products, data.meta = {window_from 2026-08-21, window_to 2026-09-19,
         metric_used units, returns_not_netted true}, rows [] (no sales yet)
POST chat-sql-agent {"question":"what is the weather in Mumbai?"}
  -> 200 rpc=null, answer = "I cannot answer that. I can answer questions about …"
OPTIONS -> 204 Access-Control-Allow-Origin: *
POST "this is not json" -> 400 {"error":{"code":"invalid_request","message":…}}
```

Proves the classification, the parameters, the model name, the figures coming from the
report, and the refusal path. It cannot prove an answer is *useful*. **D-045 respected** —
every probe is a read, and the function writes nothing.

### Files

```
supabase/migrations/20260919000029_phase5_chat_aggregates.sql   (new, applied)
supabase/tests/phase5_chat_aggregates.sql                       (new, 37 assertions)
supabase/functions/chat-sql-agent/{index,deps,handler,schema,answer}.ts   (new, deployed)
supabase/functions/chat-sql-agent/{schema,answer,handler}_test.ts          (new, 52 tests)
context/chat3j-summary.md                                        (new)
context/chat3k-opening-prompt.md                                 (new, E-part-2's brief)
```

**Modified:** `Makefile`, `HANDOFF_PROTOCOL.md`, `DECISIONS.md` (**D-052**, **D-053**),
`MASTER_PLAN.md`, `context/chat3-opening-prompt.md`, `PROGRESS.md`.

---

## Chat 4 Progress — Chunk D (PART 2 of 2): the notifications themselves [DONE, live-probed]

The half of Chunk D that part 1 deliberately left: `send-notification` and the app
side of the in-app inbox. It ends with the function deployed and probed live, the
list screen and the dashboard widget built, and the gates green.

### What part 2 delivered

**`supabase/migrations/20260919000028_phase5_queue_notification.sql`, applied.** One
function and its grant — no table, no column, no view, no trigger. The brief guessed
00028 would most likely be unused; it is one RPC instead of two PostgREST inserts:

- **`queue_notification(p_payload jsonb) → {log_id, notification_id}`** — `volatile
  security definer`, opening **one attempt in one transaction**: the
  `notification_logs` row (`status='queued'`, `provider` null, `created_by` = the
  caller) and, when `notify_user_id` is present, the `notifications` row it points at.
  That is D-024's rule applied to the pair that points at each other. Because definer
  skips RLS, the `notifications` insert policy's own rule is **restated by hand** —
  `user_id = auth.uid() or pharmacy_id = get_my_pharmacy_id()` — and the SQL test
  asserts a colleague from another pharmacy is refused. The tenant comes from
  `get_my_pharmacy_id()`, and a `pharmacy_id` in the payload is ignored (the test
  sends one and asserts it does not land). Refusals are `check_violation` (23514)
  with a sentence, which the handler maps to `invalid_request` and the app shows
  verbatim.
- **The settle is deliberately not in it.** The provider call cannot be inside a
  transaction, so the sequence is **queue → call → settle** and `queued` means "we
  started"; the settle is one tenant-scoped `update` with the caller's own token. A
  settle that fails leaves the row `queued` and answers 500 — the one non-200 that
  follows a queued attempt.

**`supabase/tests/phase5_notifications.sql`** — **32 PASS / 0 FAIL of 33
assertions**, atomic and self-rolling-back: the pair and the link between them, the
`queued` state with no provider, the in-app row's payload (`type` defaulting to
`message`, `title` falling back to the subject, `data` carrying the dispatch context
with no null keys), the option to write no in-app row, the caller-scoped tenant, a
cross-tenant recipient refused, four guard sentences each writing nothing, the body
stored verbatim (edge newline and all), the settle path under RLS both ways, and the
function's own contract. Two assertions had to move to `postgres` to be worth
anything: RLS answers 0 for another user's `notifications` rows even when they exist,
so "nothing was written elsewhere" is only an assertion without it in the way.

**`supabase/functions/send-notification/`** (`index`, `deps`, `handler`, `providers`,
`handler_test`, `providers_test`) — deployed, `verify_jwt` on, acting as the caller.
**37 of the 129 Deno tests are its own.** No provider call is inside a transaction and
nothing throws from it: a refusal, an unreachable provider and a missing secret are
results, each settled into the log row. The two provider posters are separate
functions because the two APIs disagree about where the id lives (WhatsApp: the URL
names the sender and the body carries the id; SendGrid: the body names the sender and
a **header** carries the id), and the token travels in an `Authorization` header in
both — never in a URL, which is where a provider's own request log would keep it.

**The app side** (new `features/notifications/`, `data` + `application` +
`presentation`):

- `NotificationsRepository` — the inbox (newest first), marking one read, and the two
  alert RPCs. Nothing filters by tenant and one thing filters by nothing at all:
  `notifications` is *user-addressed* (`user_id = auth.uid()`), so the policy is the
  scope and a client-side tenant filter would be a weaker second copy of it.
- `NotificationsController` (mark-read optimistic and reversible, `ref.mounted` after
  the await) and `unreadNotificationCount`; `lowStockAlerts` / `expiringAlerts` as two
  providers, so one failing section does not blank the other.
- `AppNotification` (Freezed) and `LowStockProduct` / `ExpiringBatch` (plain classes —
  an RPC envelope, the `ReportSummary` precedent). The row model is **not** called
  `Notification`: that is Flutter's own abstract widget class.
- `NotificationsScreen` — three sections, each with its own three sentences
  (loading / empty / failed+retry), and the alerts rendered live from the RPCs, never
  re-derived in Dart (D-047). At zero the inbox says *No notifications yet* rather
  than looking like the failure state (T-5's lesson).
- `NotificationSummaryCard` — the dashboard widget, tappable, always visible, with
  **four** readings rather than two: checking, could not check, nothing new, and N.
- The twelfth shell destination after Reports and before Settings, `inBottomBar:
  false`, plus the `Routes.shellPaths` path (D-048) — `dashboard_shell_test.dart`,
  `widget_test.dart` and the shell's own agreement test all moved with it.
- `NotificationService`: `UnavailableNotificationService` completes all three methods,
  `getFcmToken()` answers `null`, and `showLocal()` prints one debug line rather than
  dropping a message silently (D-050).

### The probe, and what it could not prove

One invocation, with a session from the app (N-7), as the owner:

```
POST send-notification  {channel: whatsapp, to: +910000000000, recipient_type: user,
                         notify_user_id: <the owner>, type: probe, title: …}
  -> 200 {"log_id":"60ee8b0c-34a8-4c27-b4ca-aa7250a5785e",
          "notification_id":"7a909348-01f1-49fa-8e63-2681bd165a72",
          "status":"skipped","provider":null,
          "error":"This function is missing its WHATSAPP_TOKEN secret."}
```

Both rows landed and the link holds: the log row `status='skipped'` with `provider`
and `provider_message_id` null, `channel='whatsapp'`, `recipient_type='user'`,
`destination='+910000000000'`, `body` verbatim, `created_by` = the caller, and
`notification_id` pointing at an **unread** `notifications` row in the caller's own
inbox, same pharmacy, `data = {dispatch_channel: whatsapp, recipient_type: user}` —
with no `recipient_id` key, which is `jsonb_strip_nulls` doing what the SQL test
asserted. The two tables held one row each before the probe and one after it.

**What it cannot prove, and does not claim to:** that any WhatsApp message was
delivered. There is no Meta account, no SendGrid key and no recipient number in this
phase (D-046), so what is proven is the wiring *below* the credential. The two rows
are permanent on purpose — `notification_logs` has no delete policy — and they are
marked as probes in both the body and, for the in-app one, the title.

### A finding worth keeping

**Riverpod 3's build-retry is a loading state that carries the error.** A read that
threw and is being retried is exposed as `AsyncLoading(error: …, retrying)`, and
`AsyncValue.whenData`'s loading branch returns a plain `AsyncLoading` — dropping the
error. The dashboard card would have said *Checking…* for ever instead of *Could not
check*, which is the one lie D-048 forbids. It is mapped by hand now (value → error →
loading) and D-051 records it. The same retry also makes a *read count* useless as
evidence: three assertions of the form `expect(reads, 2)` after tapping a retry were
written, failed, and were removed in favour of asserting the state the retry produced.

### Gate output at the end of part 2

```
supabase db push --dry-run                     -> Would push: 20260919000028_… ; then "Remote database is up to date"
supabase db push --yes                         -> Applying migration …00028…, Finished
supabase db query --file supabase/tests/phase5_notifications.sql
                                               -> SUMMARY: 32 PASS / 0 FAIL of 33 assertions
deno test supabase/functions                   -> ok | 129 passed | 0 failed
deno check ×4 (ocr, match, backfill, send-notification) -> clean
dart format lib test                           -> 404 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> wrote outputs, no errors
dart run custom_lint / flutter analyze         -> No issues found!
flutter test                                   -> +544: All tests passed!
```

**Flutter tests: 493 → 544** (51 new: the models, the repository's parsers, the
controller, the screen, the dashboard card, the service). **Deno tests: 92 → 129.**
Migration count: **28/28 local and remote.**

---

## Chat 4 Progress — Chunk D (PART 1 of 2): the alert sources [DONE]

Chunk D is the notification half of Phase 5, and it was built in two parts: the
**alert sources** (part 1, done — below) and the **notifications themselves**
(`send-notification`, the in-app list, the Dart seams — part 2, done above). The split
is the one the earlier chunks used: the server side first, gated on its own.


### What D-part-1 delivered

- **`supabase/migrations/20260919000027_phase5_alert_sources.sql`, applied.** Two
  `stable security definer` functions, no table, no column, no trigger, and nothing
  that moves stock:
  - **`low_stock_products(p_limit int default 50) → jsonb`** — products below their
    reorder level, worst first, each with `total_qty`, `min_stock_level` and
    **`shortfall`** (the units that close the gap). The rule is the app's own one,
    `total_qty < min_stock_level`, now evaluated where both columns live — which is
    **I-1's fix**: the Dart comparison ran over at most 500 candidate rows, so a
    bigger catalogue reported a partial answer that looked complete. An inactive
    product is never reported; a product with no batches at all is `0` and is.
  - **`expiring_batches(p_days int default 90, p_limit int default 50) → jsonb`** —
    batches with stock left expiring inside the window, soonest first, each with
    `days_left` (**negative** when it has already expired, so a screen can say
    "expired 6 days ago" rather than read a bucket). An empty batch is not a waste
    risk and is excluded.
  - Both take the tenant from `get_my_pharmacy_id()` and carry
    `pharmacy_id = v_pharmacy` explicitly — which is not belt-and-braces here: the
    views they read are `security_invoker = true`, and inside a definer function the
    "invoker" is the owner.
- **`supabase/tests/phase5_alerts.sql`** — 25 PASS / 0 FAIL of 26 assertions,
  atomic and self-rolling-back: the reorder boundary (`<` reports, `=` does not), the
  no-batches case, an inactive product never reported, the shortfall number,
  worst-first ordering, the limit, the horizon widening with `p_days`, the negative
  `days_left`, the already-expired batch first, an empty batch excluded, tenant
  isolation both ways, and that reading them moves nothing.
- **A schema fact the test found**: `product_batches.expiry_date` is `NOT NULL`, so
  the function's `is not null` guard is a mirror of the column rather than a live
  branch. The test asserts the column's nullability instead of inventing a fixture
  the schema forbids.
- **D-047** records the shape: an alert is a *question* answered by an RPC, a
  notification is an *event* stored as a row. That is what keeps D-046's "alerts
  appear in the in-app list" honest without materialising state that goes stale the
  moment stock moves.

### A finding from the live data

The alert RPCs answer against the real pharmacy already: its single catalogue product
has `min_stock_level = 20` and no stock, so `low_stock_products()` returns it with a
shortfall of 20. The alerts are therefore exercisable end to end on live data without
any credential, which is the opposite of the notifications half (no WhatsApp account,
no SendGrid key, no recipient phone numbers — D-046).

### Gate output at the end of part 1

```
supabase db push --dry-run                     -> Would push: 20260919000027_… ; then "up to date"
supabase db push --yes                         -> Applying migration …00027…, Finished
supabase db query --file supabase/tests/phase5_alerts.sql
                                               -> SUMMARY: 25 PASS / 0 FAIL of 26 assertions
deno test supabase/functions                   -> ok | 92 passed | 0 failed
deno check ×3 (ocr, match, backfill)           -> clean
dart format lib test                           -> 383 files, 0 changed
dart run custom_lint / flutter analyze         -> No issues found!
flutter test                                   -> +493: All tests passed!
```

**No Dart changed in part 1**, so the 493 tests are the same ones C2 left.

---

## Chat 4 Progress — Chunk C3: the embedding backfill [DONE, live]

C3 is the leg that was answering nothing: `products.embedding is null` on every real
row. It ships two migrations, one Edge Function and 11 Deno tests, and it ends with
the live catalogue embedded, the vector floor re-tuned from measurement, and the
vector leg firing on a real bill's text.

### What C3 delivered

- **`supabase/migrations/20260919000025_phase5_embedding_backfill.sql`, applied.**
  Two functions, no table, no column, no trigger:
  - **`products_to_embed(p_limit int) → {items, remaining, unembeddable}`** —
    `stable security definer`; one batch of the caller's own un-embedded rows with
    the text from `product_embedding_text()` (D-037), the limit applied **after**
    the un-embeddable rows are dropped (so a batch is never short for no reason),
    and a separate count for rows that can never be embedded.
  - **`set_product_embeddings(p_items jsonb) → {written, remaining, unembeddable,
    skipped}`** — `volatile security definer`; each row scoped to
    `get_my_pharmacy_id()`, each value cast by the **database** from the vector's
    own text form rather than marshalled by PostgREST (D-027's refusal). A
    non-object entry, a product id that is not a uuid, an embedding that is not
    exactly 768 numbers, and a product that is not in this catalogue are skipped
    with a reason; `remaining` is computed after the writes, so the operator's next
    step is one number.
- **`supabase/migrations/20260919000026_phase5_vector_floor.sql`, applied** — 00023's
  `match_products` **verbatim** with one constant moved: the vector floor is **0.78**,
  measured (D-044). A new migration rather than an edit of 00023, for D-013's reason.
  Verified byte-identical apart from the floor block before it was applied.
- **`supabase/functions/backfill-embeddings/`** (`index`, `deps`, `handler`,
  `handler_test`) — deployed, `verify_jwt` on. **One invocation embeds one batch**
  (20 by default, clamped at 100) in one `batchEmbedContents` request, writes it, and
  answers `{embedded, remaining, unembeddable, skipped, model}`. No internal loop. A
  model failure, a short answer or a hole in the batch refuses the batch **whole** and
  writes nothing — deliberately stricter than `match-product`, which degrades.
- **`supabase/tests/phase5_embedding_backfill.sql`** — 34 PASS / 0 FAIL, atomic and
  self-rolling-back: the read's scope and shape, the write's cast and its four
  refusals, tenant isolation **both ways** (the foreign row is checked after
  `reset role`, because RLS hides it from the caller — which is the point), the
  `unembeddable` count, resumability, and **the vector leg of a real
  `match_products` call firing on a row this pair wrote**, with no model involved.
- **`make backfill`** — one batch per invocation, token read from
  `SUPABASE_USER_TOKEN`, and `@`-prefixed so make cannot echo the expanded command
  line (which would print the token). `deno check` for the new entry point added to
  the Makefile's `test-functions` and to `HANDOFF_PROTOCOL.md`'s gate block.

### The live run, and the measurement that changed a constant

The operator's loop, run against the real pharmacy (`Arihant Pharmacy`) with a
session token from the app:

```
counts before:  1 product, 1 un-embedded, 0 aliases
POST backfill-embeddings {"limit":20} -> {"embedded":1,"remaining":0,"unembeddable":0,"skipped":[],"model":"gemini-embedding-001"}
POST backfill-embeddings {"limit":20} -> {"embedded":0,"remaining":0,...}      <- resumes, and spends nothing
counts after:   1 product, 0 un-embedded
```

Then the floor re-tune. With the floor temporarily lowered to **0.01** (a
`pg_get_functiondef` patch, one word, restored by migration 00026) nine real invoice
texts were measured against the real catalogue vector:

```
'Dolo 650 Tab'        -> trigram 1.0000
'DOLO 650'            -> trigram 1.0000
'Dolo650Tab15s'       -> vector  0.8280   <- the real product, run together
'Dolo 125'            -> vector  0.7216   <- a strength the pharmacy does not stock
'Dolo 500'            -> vector  0.7084   <- a strength the pharmacy does not stock
'Paracetamol 500mg'   -> vector  0.6695   <- same molecule, another brand
'Amoxyclav 625 10s'   -> vector  0.5780
'Cetirizine 10mg Tab' -> vector  0.5546
'ZZQQ nonsense 9999'  -> vector  0.5364   <- junk
```

**At 0.7 two wrong strengths scored above the floor** and were offered as
high-confidence suggestions. 0.78 sits in the window the data leaves
(0.7216, 0.8280) — D-044. The live probe after the re-tune:

```
'Dolo650Tab15s'       -> dolo 650, reason vector,  score 0.8280     (kept)
'Dolo 650 Tab'        -> dolo 650, reason trigram, score 1.0000     (exact)
'Dolo 500'            -> dolo 650, reason trigram, score 0.5556     (weaker, labelled)
'Paracetamol 500mg'   -> dolo 650, reason trigram, score 0.6667     (weaker, labelled)
'Cetirizine 10mg Tab' -> no candidates
'ZZQQ nonsense 9999'  -> no candidates
```

Note what that says precisely: the re-tune removes the vector leg's **high-confidence
wrong** claim, not the trigram leg's honestly-labelled weaker one. Two thresholds,
two jobs, and both reasons are visible in the app (D-039).

### Gate output at completion

```
supabase db push --dry-run                     -> Would push: …00025…, then …00026…; finally "up to date"
supabase db push --yes                         -> Applying migration …  , Finished (twice)
supabase db query --file supabase/tests/phase5_embedding_backfill.sql
                                               -> SUMMARY: 34 PASS / 0 FAIL of 35 assertions
supabase db query --file supabase/tests/phase5_match_products.sql
                                               -> 43 PASS / 0 FAIL (the boundary vectors moved with the floor)
deno test supabase/functions                   -> ok | 92 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts  -> clean
deno check supabase/functions/match-product/index.ts      -> clean
deno check supabase/functions/backfill-embeddings/index.ts -> clean
dart format lib test                           -> 383 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> wrote 55 outputs
dart run custom_lint                           -> No issues found!
flutter analyze                                -> No issues found!
flutter test                                   -> +493: All tests passed!
```

Live state afterwards: floor 0.78, trigram 0.35, **1 product embedded, 0
un-embedded** — the whole live catalogue.

### Tests — 11 added, none changed

`supabase/functions/backfill-embeddings/handler_test.ts`: one batch and the exact
texts sent, a model failure that writes nothing, a provider refusal as retryable, a
short answer refused rather than half-written, nothing-to-do costing no model
request, a write that skipped a row reported back, the batch size used and clamped,
a body that cannot be read, a caller with no pharmacy refused before any work, GET
refused / OPTIONS preflighted, and `readLimit`'s clamps. Plus the new SQL test's 35
assertions. **No Dart changed in this chunk**, and the existing tests (including the
43-assertion matcher test, whose synthetic boundary vectors were re-picked for the
new floor) still pass.

---

## Chat 4 Progress — Chunk C2: the seam, the suggestions, and alias learning [DONE]

C2 is the app's half of the matcher: the Dart seam over `match-product`, the
suggestions the verify screen offers, and the write that teaches the database what
the human confirmed. It ships one migration, four new Dart files, and 40 new tests.

### What C2 delivered

- **`supabase/migrations/20260919000024_phase5_alias_learning.sql`, applied and
  live.** One function, no table, no column, no trigger, nothing that moves stock:
  - **`learn_product_aliases(p_aliases jsonb) → {learned, skipped}`** — `volatile
    security definer`, `search_path` pinned, `authenticated` only (no `anon`). The
    tenant is `get_my_pharmacy_id()`, never an argument, and every statement carries
    it explicitly because a definer function is not subject to RLS. The text is
    normalized **server-side** by `normalize_product_name()`; a product id that is
    not this pharmacy's, a supplier id that is not ours (read as "no supplier"), a
    blank or punctuation-only text, and a non-object entry are **skipped with a
    reason**, never raised — a bill that cannot teach is not a failure. A
    supplier-scoped row upserts on the existing unique key; a NULL-supplier row is an
    explicit update-then-insert, because that index cannot converge NULLs (N-5 —
    sidestepped inside the new function, **not** fixed: `addAlias` and the index are
    untouched).
- **`supabase/tests/phase5_learn_product_aliases.sql`** — 42 PASS / 0 FAIL of 43
  assertions, atomic, self-rolling-back, impersonating `authenticated` against a
  second tenant. Its strongest assertions are end-to-end: after learning, the
  **alias leg of a real `match_products` call** answers the supplier the alias was
  learned from, does **not** answer another supplier's bill, and does once the same
  text is learned with no supplier. Residue after the run: 0 products, 0 suppliers,
  0 aliases, 0 pharmacies.
- **`lib/services/match_service.dart`** — `MatchService` over
  `functions.invoke('match-product')` plus the `learn_product_aliases` RPC, with
  `decodeProductMatches`, `decodeLearnedAliases` and `matchException` as pure
  functions (the `OcrService` pattern) and `MatchLineRequest`/`ConfirmedAlias` as the
  two payloads.
- **`lib/data/models/product_match.dart`** — plain classes (not Freezed: an RPC
  envelope no migration owns): `ProductMatches`, `ProductMatch`, `MatchCandidate`,
  `MatchEvidence`, `MatchMeta`, `MatchReason`. Candidates are looked up **by
  position** (`candidatesAt`), a candidate with no product id is dropped, and
  `MatchCandidate.reasonLabel` is the sentence a screen shows — *Also called
  DOLO-650 TAB*, *45% similar*, *Looks similar*.
- **`lib/features/purchase_ocr/application/purchase_match_controller.dart`** — one
  batch call per bill, state about *the run* (in flight / the server's warnings /
  why it failed), the answer returned aligned by position, `ref.mounted` after the
  await, and **no automatic retry**.
- **The suggestions, in `ProductPickerField`** — at most `maxSuggestions` (3) rows
  under the field, each with the catalogue name, its pack size and the reason, shown
  only while the line has no product. Tapping one applies it through the same path
  the search dialog uses (`PurchaseLineEditor._applyProduct`), so a suggestion is
  **offered, never applied**; the manual purchase form renders exactly what it did
  before.
- **`_MatchNote` on the verify screen** — one small line above the lines, and only
  when it has something to say: *choose the supplier and these lines will be looked
  up*, *looking these lines up…*, the server's own warning sentences, or *the
  catalogue could not be searched this time…* with a **Look again** action. Nothing
  blocks: the form is live throughout and the save never consults the matcher.
- **Alias learning at save** — one call per bill, after `createPurchase` returns,
  wrapped so a failure can never fail the save, carrying the **printed text held per
  line slot** (not the draft's `productNameRaw`, which a pick overwrites with the
  catalogue's spelling) and the bill's supplier.
- **A defect found and fixed on the way**: `_VerifyFormState` seeded its lines in
  `initState` and never re-seeded, so a *successful* re-read showed the earlier
  parse's lines. The form is now keyed on the parse (`ValueKey(scan.bill)`), with a
  test that a second read replaces the lines.
- **`lib/core/errors/function_error.dart`** — one client-side reader of a function's
  `{error:{code,message}}` envelope; `ocrException` delegates to it (D-042). No
  behaviour change: the OCR mapping's own tests are unchanged and still pass.

### Live, and what the probe settled

The session token the user supplied was used while it was valid, for **read-only**
probes of the deployed `match-product` (nothing was written to the database):

```
POST match-product  {"lines":["Dolo650Tab15s","AMOXYCLAV 625 10S","ZZQQ nonsense 9999"]}
200 OK   Access-Control-Allow-Origin: *
{"matches":[{"raw_name":"Dolo650Tab15s","candidates":[
   {"name":"dolo 650","score":0.4545,"reason":"trigram","evidence":{"similarity":0.4545},
    "is_active":true,"pack_size":"15","product_id":"1ac034e9-…","generic_name":"paracetamol"}]},
  …], "meta":{"model":"gemini-embedding-001","line_count":3,"embedded":3,"vector_used":true}}
```

- **The embedding call is now live-verified** — the model name, the
  `batchEmbedContents` body and the 768-dimension parse, which C1 left unverified.
- **CORS on the 200 path** — D-038 could only cite the 401, the 400 and the
  preflight. (Verified with `curl`, not a browser: the standing preference for this
  host.)
- **The vector leg answered nothing** — `products.embedding is null` on every real
  row, exactly as D-037 predicted, and the reason C3 exists.
- **The embedding quota measured**: 6 single-line requests and then 4 × 20-text
  batches (80 texts) inside ~3 minutes, all 200 with `vector_used: true`, no refusal.
  The embedding metric is **not** the reader's 5/minute (D-041).

### Gate output at completion

```
supabase db push --dry-run                     -> Would push: 20260919000024_… ; then "up to date"
supabase db push --yes                         -> Applying migration …00024…, Finished
supabase db query --file supabase/tests/phase5_learn_product_aliases.sql
                                               -> SUMMARY: 42 PASS / 0 FAIL of 43 assertions
                                                  (exit 1 is the test's own rollback RAISE)
deno test supabase/functions                   -> ok | 81 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts  -> clean
deno check supabase/functions/match-product/index.ts      -> clean
dart format lib test                           -> 383 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> wrote 63 outputs
dart run custom_lint                           -> No issues found!
flutter analyze                                -> No issues found!
flutter test                                   -> +493: All tests passed!
```

### Tests — 40 added, none changed

`test/data/models/product_match_test.dart` (the live 200 body decoded verbatim, the
tolerant paths, the alignment, every reason sentence), `test/services/match_service_test.dart`
(the two decoders and the exception mapping, including a gateway body), `test/features/purchase_ocr/application/purchase_match_controller_test.dart`
(one call per bill, alignment with a blank line, a failure that is not retried,
nothing asked when no line has text, the server's warnings, the mount guard),
`test/features/purchase/presentation/product_picker_field_test.dart` (the ranked head
with reasons, the cap at three, offered-not-applied, no rows when nobody can accept
one, the field still opening the search), and seven new cases on
`purchase_ocr_screen_test.dart` (the ask waits for the supplier, a tapped candidate
fills the line, **a bill saves with the matcher held open**, a failed match still
saves, warnings shown, the learning payload, a failed learning write, and the second
read replacing the lines). `test/support/fake_match_service.dart` is the new fake;
`FakePurchaseOcrRepository.bill` became mutable so a second read can differ.

---

## Chat 4 Progress — Chunk C1: the matcher [DONE, server-side]

Chunk C (smart matching) split three ways: **C1 is the matching capability and its
SQL test** (this section), **C2 is the app's seam, alias learning and the picker's
suggestions**, **C3 is the `products.embedding` backfill**. C1 ships no Dart and
touches no widget: it is the capability the screen will call.

### What C1 delivered

- **`supabase/migrations/20260919000023_phase5_product_matching.sql`, applied and
  live.** Two functions, no table, no column, no trigger, nothing that moves stock:
  - **`product_embedding_text(name, generic_name, pack_size)`** — the one
    catalogue-text convention (D-027 named it as Chunk C's decision). It lives in
    the database rather than in the Edge Function so the backfill cannot drift from
    the match: the backfill embeds what this returns. The **query** side is
    deliberately not built by it — the query is the invoice text as printed, which
    is the whole reason the vector leg copes with a supplier's abbreviation.
  - **`match_products(p_queries jsonb, p_limit int)`** — one `stable security
    definer` RPC for a whole bill, returning `[{ raw_name, candidates: […] }]` in
    the order it was asked. Three legs, each candidate carrying `reason` and the
    evidence for it (`alias_name`, `similarity`, `distance`):
    1. **alias** — an exact `normalize_product_name()` hit in `product_aliases`,
       score 1.0 because a human confirmed it. Scoped to the supplier **or** to no
       supplier: an alias learned for one distributor deliberately does **not**
       answer the same printed text on another's bill, and what crosses suppliers
       is a pharmacy-wide (supplier-less) alias.
    2. **trigram** — `greatest(similarity(name, raw), similarity(generic, raw),
       word_similarity(name, raw))`, threshold 0.35.
    3. **vector** — cosine distance over `products.embedding`, floor 0.7, and only
       when the caller supplied a query embedding.
- **The two measured facts that shaped it** (probed on the live database before the
  migration was written, not assumed): `similarity('Dolo650Tab15s','Dolo 650')` is
  **0.278** — below pg_trgm's own 0.3 default — while
  `word_similarity('Dolo 650','Dolo650Tab15s')` is **0.455**, so the reversed
  direction is what reads a supplier's run-together name and 0.35 is the threshold;
  and `Dolo 650` scores 0.4545 against that text while `Dolo 500` scores 0.4444 — a
  0.01 margin, so **trigram cannot choose between siblings and the vector leg has
  to be able to outrank it**. Ranking is therefore by **score**, with the leg as an
  ordered tiebreak (0 scoped alias, 1 pharmacy-wide alias, 2 trigram, 3 vector);
  ranking by leg would have made every trigram hit beat every vector hit, which is
  exactly the case the vector leg exists for.
- **Never `select *` on `products`** — candidates are built from named columns, and
  the SQL test asserts no payload carries `embedding` (D-027).
- **`supabase/tests/phase5_match_products.sql`** — 43 assertions, atomic and
  self-rolling-back, impersonating `authenticated` with a second tenant whose
  product is named *identically* and embedded *identically* to the query vector.
- **`supabase/functions/match-product/`** — `index.ts` + `deps.ts` + `handler.ts`,
  deployed. One bill is **one embedding call** (`batchEmbedContents`, the whole
  bill in one request — N-2's free tier) and **one RPC call**; the tenant is never
  an argument; a blank line keeps its position; a supplier id that is not a uuid
  does not travel; and an embedding failure **never fails the bill** — it degrades
  to alias+trigram and says so in `meta.warnings`.
- **`supabase/functions/_shared/embedding.ts`** (the convention, the dimension
  pinned at 768, `RETRIEVAL_DOCUMENT`/`RETRIEVAL_QUERY`) and
  **`_shared/gemini.ts`** (one poster, so two functions cannot answer a provider
  failure in two dialects; `ocr-purchase-bill` was left alone rather than refactored
  in place — it is deployed and live-verified).

### Gate output at completion

```
supabase db push --dry-run                       -> Would push: 20260919000023_…
supabase db push --yes                           -> Applying migration …00023…, finished
supabase db query --file supabase/tests/phase5_match_products.sql
                                                 -> 43 assertions, PASS 43 / FAIL 0
                                                    (exit 1 is the test's own rollback RAISE)
deno test supabase/functions                     -> ok | 81 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts  -> clean
deno check supabase/functions/match-product/index.ts      -> clean
dart format lib test                             -> 372 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> wrote 0 outputs (nothing stale)
dart run custom_lint                             -> No issues found!
flutter analyze                                  -> No issues found!
flutter test                                     -> +453: All tests passed!
```

Residue after the SQL test: 0 ZZTEST products, 0 ZZTEST pharmacies, 0 aliases,
0 embedded products (the test rolls itself back).

### Live, and what is *not* live

- **Deployed**: `supabase functions deploy match-product` → deployed, `verify_jwt`
  on, alongside `ocr-purchase-bill` (v4).
- **Invoked live**: a POST with the publishable key and a valid-JWT caller that has
  no pharmacy answered
  `{"error":{"code":"unauthorized","message":"This account is not linked to a pharmacy yet."}}`
  — the deployed handler's own envelope, from `requirePharmacyId`, and a 400 for
  `{"lines":[]}` — so the gateway, the handler, the caller-scoped client and the
  error vocabulary are all live.
- **Not yet live: the embedding call, and therefore the observed quota.** The full
  probe needs a signed-in user of a pharmacy, and the hosted project requires email
  confirmation (N-7), so the throwaway account the probe creates cannot sign in —
  and confirming it by hand is an auth-weakening write to production that the guard
  correctly refuses. **The model name, the `batchEmbedContents` shape and the
  free-tier embedding quota are therefore still unverified live**, which is exactly
  the class of thing D-030 says a live call has to settle. It is the first task of
  C3 (whose function makes embedding calls anyway), or one approved confirm call.
  **[Settled in C2 and C3: the call is live-verified, the model is
  `gemini-embedding-001`, and the embedding metric is not the reader's 5/minute —
  see the C2 and C3 sections below and D-041.]**
- **A CORS scare that was a misreading, recorded so nobody chases it**: N-6 claimed
  a live response carried no `access-control-allow-origin`. It does — the gateway
  emits it capitalised and my case-sensitive filter hid it. Re-measured with full
  header dumps on the 401, the 400 and the preflight; **no code changed and nothing
  was redeployed**. D-038 carries the contract and the recipe.

### Decisions added

D-036 (the match is one RPC, ranked by score with the leg as attribution, both
thresholds measured), D-037 (the catalogue-text convention is a database
function, and the query text keeps its word boundaries) and D-038 (CORS is emitted
by the platform on every path; the verification must not be case-sensitive).

## Chat 4 Progress — Chunk B2b: the verify screen and the save [DONE]

**Chunk B is complete.** B2b is the part a user touches: choose a bill, check what
was read, and save a draft through the manual form's own controller.

### What B2b delivered

- **`features/purchase_ocr/presentation/purchase_ocr_screen.dart`** — three states,
  each with something to say:
  - **Choose a bill** — *Take a photo* / *Choose a file*, the 10 MB and file-type
    facts, and the one instruction that matters: *fill the frame with the item
    table*. It also says plainly which of the two failures happened — "that bill
    did not upload" versus "that bill could not be read" — because the retry
    differs and only one of them is worth retrying.
  - **Reading** — "Reading the bill…" and, when the reader was busy and the retry
    is running, **"The bill reader is busy — retrying…"** (D-033's visible wait).
  - **Verify** — the image beside what was read, `meta.warnings` and the
    truncation note shown rather than logged, the header editable (supplier,
    invoice number, invoice date, notes), a line editor per line with the batch and
    expiry fields a receipt needs, a product picker on every line (matching is
    Chunk C, so a human chooses), the totals from `PurchaseTotals`, and the
    reader's own total shown *beside* them, labelled as what was printed rather
    than what will be saved.
  - The save calls `purchaseFormControllerProvider.createPurchase(header:, lines:)`
    — the same controller the manual form uses — which writes a **draft**; it then
    invalidates the list and the document and goes to `Routes.purchaseDetail`, where
    the existing GRN step is one tap away. Nothing in this feature writes a purchase
    row itself (D-011/D-013).
- **`data/bill_picker.dart`** — `BillPicker` + `PickedBill` + `billPickerProvider`,
  the seam `image_picker` sits behind (D-035). `PurchaseOcrController.pickBill`
  now owns the decisions that were tempting to put in the widget: an untyped file
  is typed from its name (`mimeForFileName`, added to the repository with tests),
  and a file the bucket would refuse is turned away before the round trip.
- **`Routes.purchaseOcr = '/purchase/ocr'`**, declared in `app_router.dart` ahead of
  the parameterised purchase routes (so `ocr` is never read as a purchase id) and
  offered on the purchase screen as a third way in, beside *Receive goods* and
  *New* (D-022: the rail stays on Purchase).
- **A correctness fix the screen exposed:** a *first* read that failed used to lose
  the uploaded path, so "read it again" had nothing to read. `OcrScan.bill` is now
  nullable and the scan survives the failure, which is what makes D-033's "never
  uploads a second copy" true for that case too (recorded in D-033's consequences).

### Tests — 11 added, none changed

`test/features/purchase_ocr/presentation/purchase_ocr_screen_test.dart` (the two
ways in and what the screen warns about, a picked bill read into a correctable form,
warnings and truncation shown, **the retrying state caught mid-flight**, a busy
reader offered another go without being called an unreadable bill, a file the reader
cannot open turned away before any upload, and the save's payload — supplier,
invoice number, the line's product, quantity, free quantity, batch and expiry —
followed by the navigation to the document); one test on the purchase screen for the
new entry point; `mimeForFileName` at its boundaries; and a controller test for the
failure-then-retry path above. `test/support/fake_bill_picker.dart` and
`test/support/purchase_ocr_test_app.dart` follow the existing support shape, and
`purchase_test_app.dart` gained the OCR overrides a tap on its new action now needs.

### Gate output at completion

```
deno test supabase/functions                    -> ok | 45 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts -> clean
dart format lib test                            -> 372 files, 0 changed
dart run custom_lint                            -> No issues found!
flutter analyze                                 -> No issues found!
flutter test                                    -> +453: All tests passed!
```

(442 before; 453 now — 11 added, none changed.)

### Decisions added

D-035 (a platform capability the app cannot fake gets a seam), and D-033 gained the
consequence that a failed first read still leaves the bill uploaded.

## Chat 4 Progress — Chunk B2a: the OCR Dart seam [DONE]

Chunk B's second half split again at its own natural seam: **B2a is everything
below the HTTP boundary and above the UI** — the envelope, the service, the
repository (upload + invoke) and the controller — and **B2b is the verify screen,
the save, the route and the widget tests.** No widget was added in B2a, and nothing
in the Flutter tree calls the reader yet.

### What B2a delivered

- **`data/models/ocr_purchase_bill.dart`** — `OcrPurchaseBill`, `OcrDocument`,
  `OcrLine`, `OcrMeta` as **plain classes** (`ReportSummary`'s precedent: an RPC
  envelope, no migration owns its shape). `fromJson` is the decode the function's
  200 body gets, and it is as tolerant as the function's own normalizer: a number
  may arrive as `num` or as text — including `1,25,000`, read with the *same*
  separator rule the function uses, because two sides that disagree about a number
  are two answers to one question (D-030) — a blank string is no value, an
  unreadable date is `null` rather than a guess, and junk where a part should be
  never throws. `toLineDrafts()` turns the lines into the `PurchaseLineDraft`s the
  purchase form already uses, with `productId: null` (matching is Chunk C, so a
  human picks) and `qty: 0` where the reader read nothing — so the form's own rule
  refuses the line until somebody says what it was.
- **`services/ocr_service.dart`** — the stub implemented (and its hand-written
  `Provider` converted to codegen, which D-1's list asked for). The wire mapping is
  **two pure functions**, which is where the interesting behaviour lives:
  `decodeOcrBill` for the 200 body and `ocrException` for a failure, which keeps
  the function's sentence and code verbatim (`check_violation`'s rule, one layer
  out) and maps them onto the app's exception types. `isRetryableOcrError` is the
  single place that decides what deserves another try.
- **`features/purchase_ocr/data/purchase_ocr_repository.dart`** — the upload
  (`<pharmacy_id>/<year>/<file>`, D-028) and the call. The bucket's limits are
  mirrored as **tested statics** (`validatePick`, `maxBillBytes`,
  `allowedMimeTypes`, `storagePath`, `newBillFileName`), enforced inside the write
  as well as available to a screen, so a screen that forgets to ask cannot upload
  something the bucket will refuse afterwards; the bucket stays the authority and
  its refusal is surfaced verbatim.
- **`features/purchase_ocr/application/purchase_ocr_controller.dart`** — the flow
  and **the retry (D-033)**: `attempts = 2`, `isRetrying` as state distinct from
  "busy" so a screen can say *"the reader is busy — retrying…"*, a wait that is a
  provider (`ocrRetryDelayProvider`, 3 s) so tests do not sleep, and `rescan()`
  which re-reads the stored object rather than uploading a second copy.

### The finding that came with it

**D-034: a controller must check `ref.mounted` after an await before writing
state.** Riverpod 3 disposes a provider with no listeners, so a screen that
navigates away mid-upload stops being a listener and the next `state = …` throws
from a future nobody awaits — which is exactly what three of the new tests caught:

```
Cannot use the Ref of purchaseOcrControllerProvider after it has been disposed.
```

Every guard now sits after each await (in the retry loop that also stops a second
call being spent on a shared quota for nobody), and the tests keep the provider
alive the way a screen does — `container.listen(...)` in the container helper, plus
one test that deliberately does **not**, to pin the guard.

### Tests — 13 added, none changed

`test/data/models/ocr_purchase_bill_test.dart` (the decode against **Chunk B1's
observed wire body**, text numbers, the Indian separator, nulls staying null, junk
tolerated, `toLineDrafts`), `test/services/ocr_service_test.dart` (both pure
mappers, every code the deployed function and the platform produced, retryability),
`test/features/purchase_ocr/data/purchase_ocr_repository_test.dart` (the mirrored
limits at their boundaries, the path shape, the file name), and
`test/features/purchase_ocr/application/purchase_ocr_controller_test.dart` (the
upload-then-read flow, the file the bucket would refuse never reaching the reader,
**the retry being visible while it waits**, a third attempt *not* happening, the
non-retryable failures not being retried, `rescan` not re-uploading, a failed
re-read keeping the first parse on screen with its error set — T-3's shape — and
the disposed-provider guard). Plus `test/support/fake_purchase_ocr_repository.dart`,
which runs the real upload rule and builds the real path shape.

### Gate output at completion

```
deno test supabase/functions                    -> ok | 45 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts -> clean
dart format lib test                            -> 0 changed
flutter analyze                                 -> No issues found!
flutter test                                    -> +442: All tests passed!
make test-functions                             -> both of the above
```

(397 before; 442 now — 45 added across B2a: 32 for the envelope, the mappers and
the upload rules, then 13 for the controller. No existing test changed.)

### Decisions added

D-033 (the retry lives in the app, with a visible wait) and D-034 (`ref.mounted`
after an await).

## Chat 4 Progress — Chunk B1: the OCR Edge Function [DONE, live-verified]

Chunk B (the AI OCR core) split in two, as its brief allowed: **B1 is the server
side and is finished; B2 is the Flutter seam and the verify screen.** `supabase/functions/`
now exists.

### What is deployed

`ocr-purchase-bill` — POST `{ "path": "<pharmacy_id>/<year>/<file>" }` → the bill's
document, its lines, and `meta { model, warnings, image_path, finish_reason }`, or
`{ error: { code, message } }`. It writes nothing: creating the purchase is the
app's job through `PurchasesRepository` (D-011/D-013).

- `_shared/` — the error vocabulary (`FunctionError`, `failJson`'s status map),
  the JSON envelope **with CORS headers** (a Flutter web build calls this
  cross-origin; without them the browser reports an opaque network failure), the
  caller-scoped client (`userClient` + `requirePharmacyId` via the
  `get_my_pharmacy_id()` RPC — never `service_role`, D-004), and `base64.ts` (D-031).
- `ocr-purchase-bill/gemini.ts` — the prompt, the response schema, the request
  builder, and the **defensive normalizer** that turns the model's reply into the
  envelope: numbers written as text (`"₹1,120.00"`, `"1,25,000"`), a fractional
  quantity rounded *and said so*, `DD/MM/YYYY` read day-first *and said so*, an
  unreadable date left null rather than guessed, an invented empty row dropped,
  and a lost answer reported as `finish_reason` rather than looking like an empty
  bill.
- `ocr-purchase-bill/handler.ts` + `deps.ts` + `index.ts` — the request path with
  every effect injected, so a stub-driven test covers it; the order is
  security-relevant and pinned: **the tenant comes from the caller's identity and is
  compared with the path before anything is read**, and the size is checked before
  the model is paid for.

### Verified live, not just locally

`deno check` + **45 Deno tests** (`deno test supabase/functions/_shared/base64_test.ts
supabase/functions/ocr-purchase-bill/gemini_test.ts supabase/functions/ocr-purchase-bill/handler_test.ts`
→ `ok | 45 passed | 0 failed`), then three deploys and a real invocation through a
throwaway tenant created by public signup (deleted afterwards):

```
POST /functions/v1/ocr-purchase-bill  {"path":"<pharmacy>/2026/zztest-bill-5841-d.pdf"}
200
{ "document": { "supplier_name": "ARIHANT DISTRIBUTORS", "gstin": "27ABCDE1234F1Z5",
                "invoice_no": "INV-2026-0042", "invoice_date": "2026-09-18",
                "sub_total": 2420, "tax_total": 264.5, "grand_total": 2684.5 },
  "lines": [ { "raw_name": "Dolo 650 Tab 15s", "qty": 10, "free_qty": 1, "rate": 100,
               "mrp": 150, "gst_percent": 12, "batch_no": "D650-A21",
               "expiry_date": "2027-06-30", "hsn_code": "3004", "confidence": 0.95 },
             { "raw_name": "Amoxyclav 625 10s", ..., "expiry_date": "2026-12-31" },
             { "raw_name": "Cetirizine 10mg 10s", "qty": 20, "free_qty": 2,
               "rate": 18.5, "mrp": 30, "gst_percent": 5,
               "expiry_date": "2027-02-28", "confidence": 0.95 } ],
  "meta": { "model": "gemini-3.6-flash", "warnings": [], "image_path": "...",
            "finish_reason": "STOP" } }
```

Every header field, every line, and `30/06/2027` → `2027-06-30` — the day-first
conversion D-020's money rules would have had to live with. **Residue check after
cleanup: one pharmacy (the real one), one user, zero stored bills.**

### Three findings worth more than the feature

1. **`Uint8Array#toBase64` does not exist in the deployed runtime** (it is a TC39
   proposal). It passed `deno check` — the *type* is in Deno 2.9's libraries — and
   passed all 45 local tests, and then answered `500` in production. Cost: three
   deploys and a bisect through the deployed function to find it. Recorded as
   **D-031** with the rule that follows: `supabase/functions/` uses language-core
   JavaScript only.
2. **The model name in the brief's plan was already dead.** The first live call
   answered `404 "models/gemini-2.5-flash is no longer available to new users.
   Please update your code to use models/gemini-3.6-flash"` — the API naming its own
   successor. A live invocation is now the verification step for any model change
   (**D-030**).
3. **The key is free-tier: five requests a minute**, and a burst is shed as
   `503 UNAVAILABLE` rather than `429` — so a double-tapped retry or a burst of
   bills fails as "the reader is busy". The reader does **not** retry internally, on
   purpose (**D-032**, open item **N-2**). Most of this chunk's 503s were this
   quota, not the model being down.

**A capture-UX finding for B2:** the first live read of the same invoice (9 pt table
text in a generated PDF) returned the header and the tax total and *no line items*,
with honest warnings; after the table text was made 12 pt (and a "read every row"
instruction and an explicit `maxOutputTokens` were added in the same change) the
same bill parsed completely. Three things changed at once, so this is not isolated
to the font — but a marginal legibility failure is exactly what the warnings are for,
and the verify screen should tell the user to photograph the table closely.

### Gate output at completion

```
deno check supabase/functions/...                   -> clean
deno test (base64, gemini, handler)                -> ok | 45 passed | 0 failed
dart format --output=none --set-exit-if-changed    -> 355 files, 0 changed
flutter analyze                                    -> No issues found!
flutter test                                       -> +397: All tests passed!
supabase functions deploy ocr-purchase-bill        -> deployed (728 kB)
```

(Flutter test count unchanged at 397 — Chunk B1 changed no Dart product code. The 45
Deno tests are new and **not** in the five gates yet: open item **N-3**.)

### Decisions added

D-030 (the model is named in code and a change is verified live), D-031 (no
proposal-stage built-ins in a function), D-032 (the reader does not retry, and why).

## Chat 4 Progress — Chunk A: Phase 5 database foundation [DONE]

Phase 5 is built in chunks, each ending gated. **Chunk A is the storage layer** —
the objects the AI features read and write. No matching, OCR or dispatch logic
yet; that is chunks B-E.

### Migration `20260919000022_phase5_ai_notifications.sql`

Applied and verified on the hosted project (`supabase migration list`: 22/22 local
and remote match). A new file, never an edit to an applied one (D-013) — 00021 was
the head.

- **pgvector**, installed into the `extensions` schema and referenced qualified, so
  nothing depends on `postgres`'s search_path.
- **`products.embedding`** — `extensions.vector(768)`, nullable (`NULL` is the
  backfill's work list), with an HNSW index over cosine distance, partial on
  `embedding is not null`. `gemini-embedding-001`; the dimension is effectively
  permanent (D-027).
- **`device_tokens`** — one row per device a notification can reach. `token` is
  unique table-wide, so a device that changes hands is re-pointed rather than
  duplicated. RLS is both tenant- *and* user-scoped: a token is a way to reach a
  physical device, so a colleague is not entitled to enumerate or revoke it. A
  server-side fan-out will read tokens through a `security definer` RPC rather than
  by widening that policy.
- **`notification_logs`** — what was dispatched, to whom, over which channel, and
  what the provider did with it: the delivery record an operator audits, beside
  `notifications`, which is the user-addressed in-app list a recipient reads.
  Select/insert/update policies and **no delete policy** — a log a client can erase
  is not a log, and the assertion is that a delete affects 0 rows rather than that
  it raises.
- Three new enums (`device_platform`, `notification_status`,
  `notification_recipient_type`); `notification_channel` from 00002 is reused so
  the in-app list and the dispatch log cannot disagree about what `'whatsapp'`
  means.
- **The `purchase-bills` bucket** — private, capped at 10 MB, mime-restricted, with
  four `storage.objects` policies comparing the object's first path segment with
  `get_my_pharmacy_id()` (D-028). Created by the migration, because a
  `config.toml` bucket block only seeds a local stack this project does not run.

### Verified by `supabase/tests/phase5_ai_notifications.sql` — 29 assertions

Atomic, self-rolling-back, and it impersonates the way `profile_privileges.sql`
does. All 29 PASS against the live database, and the residue check afterwards
reported zero ZZTEST pharmacies, zero device tokens, zero dispatch rows and zero
stored objects. It proves, among others: the column really is
`extensions.vector(768)` and a 769-dimension write is **refused by the type**;
`product_stock` does **not** carry the new column yet still resolves for the caller
(D-021's trap); a token cannot be registered twice, against another tenant, or on
behalf of another user, and another user's token in the same pharmacy is invisible;
a foreign tenant's dispatch history is invisible; a delivery record survives a
client `DELETE` (0 rows deleted, still there); and an object is writable only under
the caller's own pharmacy folder.

Three facts the test needed were **probed rather than assumed**, in a throwaway
script that raised and rolled back: the vector column's `atttypmod` is 768; an
`auth.users` insert auto-creates a profile, which is how the test gets a second
user in the same tenant; and `storage.objects` accepts a direct insert that the
policy then filters. The probe file was deleted.

### Flutter — two models, and one payload fix the migration caused

- `data/models/device_token.dart` — `DeviceToken` plus the `DevicePlatform` enum,
  its DB-literal round-trip and its converter, in the shape `ScheduleType` and
  `LedgerReferenceType` already use.
- `data/models/notification_log.dart` — `NotificationLog` plus
  `NotificationChannel`, `NotificationStatus` (with `isSettled`) and
  `NotificationRecipientType`. An unknown status decodes as `failed`, not `sent`:
  the safe reading of an outcome this build does not understand is the one that
  prompts a look.
- **`ProductsRepository.columns` / `.projection`** — every `products` read now names
  its columns instead of taking PostgREST's `*`, which would otherwise have
  returned roughly 8 kB of floats per row on the product list, the product detail
  and every picker that names a product. Four call sites changed (`list`, `byId`,
  `create`, `update`); the two view reads are untouched because neither
  `product_stock` nor `batch_status` carries the vector. Recorded, with the
  alternative that was rejected and the reason, as D-027.

### Tests

15 added, none changed:

- `test/data/models/device_token_test.dart` — the decode, the defaults, the enum's
  round-trip and its case-insensitive fallback.
- `test/data/models/notification_log_test.dart` — the decode, the defaults, the
  three enums' round-trips, `in_app` as the stored literal, the unknown-status
  fallback, and `isSettled`.
- `test/features/products/data/products_repository_columns_test.dart` — the
  projection never asks for `embedding`, and is exactly the set of keys
  `Product.fromJson` decodes, so the two cannot drift apart silently.

### Gate output at completion

```
dart format lib test                      -> 3 changed, then 0 (tree is formatter-clean)
dart run build_runner build --delete...   -> wrote 164 outputs (T-1 SDK notice only)
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +397: All tests passed!
```

(382 before; 397 now — 15 added, none changed.)

### Decisions added

D-026 (the chatbot answers through RPCs, never free-form SQL — and the four RPCs it
needs give **I-1** its server-side fix), D-027 (the embedding, and the explicit
projection that keeps it off the wire), D-028 (the private, path-scoped bill
bucket), D-029 (push deferred to Phase 6 — now open item **N-1**).

## Chat 4 Progress (T-2 closure — Phase 3's tests)

Phase 3 shipped with no Dart tests at all. That gap is closed. **No product code
changed**, so there is no migration and no new decision; the two items the work
turned up are recorded as T-4 and T-5 above.

### Sales — 55 tests

- `sales/data/sale_totals_test.dart` — the money math: line and document totals,
  the discount moving the taxable value, the intra/inter-state split, the two
  halves adding back to the tax (the case where rounding each half independently
  would charge a paisa that was never due), half-away-from-zero rounding at
  `1.005`, and what a tender may record.
- `sales/application/pos_controller_test.dart` — the basket: defaults from the
  batch (counter price, MRP fallback, the common slab, the schedule snapshot), a
  second scan merging into the line already there, a different batch of the same
  product being a line of its own, every edit recomputing the totals, and
  `withCustomer(null)` clearing (the `copyWith` trap).
- `sales/application/sale_checkout_controller_test.dart` — the write: the payload's
  lines and totals, the document totals deliberately **absent** from it,
  availability re-read before the write (a short line never reaches the till), the
  balance-with-no-customer refusal, a credit sale with a customer, an over-tender
  clamped so no negative balance is stored, and a failed write leaving the basket.
- `sales/presentation/pos_screen_test.dart` — the counter: the empty basket with no
  till, the batch chooser (FEFO head marked, and a choice rather than an automatic
  pick), the line rendering, quantity/rate/slab edits moving the bill, the change
  on an over-tender, and a written sale opening its bill.
- `sales/presentation/sales_screen_test.dart` — the list: empty state, rows with
  their customer and status, search narrowing (past the debounce), a status chip,
  the filtered empty state with Clear, and a failed read with a working retry.

### Sale returns — 36 tests

- `returns/application/sale_return_form_controller_test.dart` —
  `SaleReturnableLine.returnable` as `qty - alreadyReturned` (a fully returned line,
  and an over-returned one clamping to 0 rather than going negative), an empty
  `batchId` blocking the line, the proportional slice from the line's **stored**
  `totalAmount`/`taxAmount` (a discounted line, where `qty x rate` would give a
  different and larger answer — D-020's rule), the write's refusals (over the cap,
  empty set, cancelled bill), and restock / refund mode / reason reaching the row.
- `returns/presentation/sale_return_form_screen_test.dart` — the form: the bill
  lookup, the line list with what can still come back, the quantity cap reported at
  the field, submit enabled/disabled, the restock switch, the refund mode, a
  refused write left in place and retried, and a failed line read with a retry.

### Support

Four new doubles and two mini-routers in `test/support/`, all following the
existing shape: `fake_sales_repository.dart` (whose `checkout` sums the payload's
own lines into the document it returns, as `checkout_sale()` does),
`fake_sale_returns_repository.dart` (which re-runs the real cap, blocked-line,
empty-set and cancelled-sale rules), `sales_test_app.dart` and
`sale_returns_test_app.dart`.

### Gate output at completion

```
dart format lib test                      -> 0 changed (tree is formatter-clean)
dart run build_runner build --delete...   -> Built with build_runner; wrote 22 outputs
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +382: All tests passed!
```

(291 before; 382 now — 91 added, none changed.)

## Chat 3 Progress (Phase 3 + Phase 4)

### Migrations 00019-00021 — sale automation, ledger/payments, reporting [DONE]

All three are applied to the hosted project (`supabase migration list`: 21/21
local and remote match) and each has a SQL test in `supabase/tests/`.

- `20260918000019_phase3_sale_automation.sql` — enables the sale side of the
  automation that migration 00010 shipped commented out, in a new file (D-013's
  reasoning, one phase later): `ledger_auto_entry_sale()`,
  `stock_update_on_sale()` (per sale **line**, gated on the parent sale not being
  cancelled) and `write_audit_log()`, plus `stock_restore_on_sale_return()` /
  `ledger_auto_entry_sale_return()`, the `invoice_counters` table that gives a
  POS its per-day invoice number, and `checkout_sale(jsonb)` — the whole sale in
  one transaction. Two deliberate deviations from the shipped bodies: a sale with
  no customer posts nothing (a walk-in owes nothing, and
  `ledger_entries_party_check` needs a party), and the ledger gate is "not
  cancelled" rather than "is completed", so a credit sale posts its receivable
  when it is written rather than when it is settled.
- `20260918000020_phase4_ledger_payments.sql` — corrects two defects 00019 shipped
  with, both found by `supabase/tests/phase3_sale_triggers.sql`: the EXECUTE
  grant `anon` had kept (D-017's trap, again), and an overpayment storing a
  negative `balance_due` (now a `before insert or update` trigger on `sales`).
  It also closes the gap Phase 2 left: a purchase return posts its credit note
  (`reference_type = 'purchase_return'`, at D-020's `grand_total`), and
  `record_payment(...)` writes a payment and its `ledger_entries` row in one
  transaction, taking the tenant from `get_my_pharmacy_id()`.
- `20260918000021_phase4_reporting.sql` — `report_summary(date, date)`, one
  `security definer` RPC returning every figure the reports screen shows as
  `jsonb`. Server-side because PostgREST cannot `sum()`: a total assembled from
  one capped page would be silently short of the truth, which is the one outcome
  a financial report must not have. Verified by
  `supabase/tests/phase4_report_summary.sql` (7 groups of assertions over the
  sales, purchases, returns, expenses, stock and expiry blocks, the window edges,
  and the anon/no-tenant refusals).

### Phase 3 — sales/POS, sale returns, GST billing [DONE, NO DART TESTS]

Delivered by the previous session and gated here as it stood: `features/sales/`
(list with search and status filter, the POS counter over `PosCart` and
`checkout_sale`, bill detail and print) and the sale side of `features/returns/`
(sale-return form with `restock` and `refund_mode`, over
`SaleReturnsRepository`). **It added no Dart tests** — `test/features/sales/`
does not exist — which is open item T-2 below. Its database behaviour is
covered by `supabase/tests/phase3_sale_triggers.sql`.

### Phase 4 — ledger, payments, expenses, reports [DONE]

- `features/ledger/` — `ledger_screen.dart` (supplier/customer segmented picker,
  the selected party's balance and its paged entries, with the direction each
  entry moved money spelled out per party type, and a payment sheet), over
  `LedgerSelectionController`, `LedgerEntriesController`,
  `partyLedgerBalanceProvider` and `PaymentController`. The balance is read from
  `ledger_entries`, not from a stored figure, because the ledger *is* the record.
- `features/expenses/` — `expenses_repository.dart`,
  `expenses_controller.dart` (paged list + the write, which invalidates both the
  list *and* the reports summary), `presentation/expenses_screen.dart` at
  `/reports/expenses`, and `presentation/widgets/expense_sheet.dart` (category
  from the fixed list, amount, mode, date, notes).
- `features/reports/` — `application/reports_controller.dart` (the window, its
  chip presets, and the one-round-trip summary provider) and
  `presentation/reports_screen.dart` (seven cards: sales, purchases received,
  returns, expenses, what the window contributed, stock on the shelf, and
  expiry — each labelled with what it is, and the contributed figure labelled
  with what it is **not**: it knows what was sold and what was spent, and nothing
  about what those goods cost).
- `Routes.expenses` is `/reports/expenses` rather than a top-level `/expenses`,
  so the Reports destination stays highlighted; a path matching no shell
  destination would leave the rail on Dashboard while the user read their
  expenses (D-022).
- `ledger_placeholder.dart` and `reports_placeholder.dart` deleted; `/ledger` and
  `/reports` build the real screens. The unused `routes.dart` import in
  `ledger_screen.dart` and the two analyze errors caused by the missing
  `reports_controller.dart` are fixed.
- Tests: 54 added, none changed — `report_summary_test.dart` (the RPC envelope's
  decode, including numbers that arrive as strings), `reports_controller_test.dart`
  (window arithmetic against fixed dates, the chip presets, the drag-the-other-end
  rule, and the provider), and widget tests for the three screens over new fakes
  and mini-router pump helpers in `test/support/`
  (`fake_ledger_repository`, `fake_expenses_repository`,
  `fake_reports_repository`, `ledger_test_app`, `reports_test_app`).

### PHASE 4 COMPLETE

Gate output at completion:

```
dart format lib test                      -> 0 changed (tree is formatter-clean)
dart run build_runner build --delete...   -> wrote 89 outputs (T-1 SDK notice only)
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +291: All tests passed!
```

(237 at the end of Phase 2; 291 now — 54 added, none changed. Phase 3 contributed
no tests of its own, so 54 is the whole of the increase.)

Seven files the previous session wrote by hand were reformatted by
`dart format` on the way through (`expense.dart`, `ledger_entry.dart`,
`report_summary.dart`, `ledger_controller.dart`, `ledger_screen.dart`,
`payment_sheet.dart`, `reports_repository.dart`); the diffs are wrapping and
annotation placement only, no behaviour.

## Chat 2 Progress (Phase 1 + Phase 2)

### Migration 00015 — Phase 2 automation layer [DONE]

`20260918000015_phase2_extras.sql` applied to the hosted project
(`supabase migration list`: 15/15 local and remote match). Contents:

- `purchases.stock_posted_at` column — one-way stock-posting marker
- `ledger_auto_entry_purchase()` — verbatim from the commented block in
  migration 00010 line 150
- `stock_apply_purchase()` — document-level posting on status -> received
- `stock_apply_purchase_item()` — line-level posting for lines added to an
  already-received document
- `stock_apply_adjustment()` — stock_adjustments rows move their batch
- `stock_update_on_purchase_return()` — returns decrement, oversell raises
- 5 triggers, plus 4 indexes (`purchases_pharmacy_id_pending_stock_idx`
  partial, two pg_trgm on `products.name`/`generic_name`, and the
  `product_aliases` unique key the alias upsert needs)

**Contract:** a purchase reaches `received` once as far as stock is
concerned; draft/ordered lines never move stock; quantity received is
`qty + free_qty`; moving a document back out of `received` does NOT reverse
stock or the ledger (the marker is never cleared).

Verified by `supabase/tests/phase2_stock_triggers.sql` — 15 assertions, all
pass, run with
`supabase db query --linked --file supabase/tests/phase2_stock_triggers.sql`.
The script is atomic and rolls itself back, so it leaves no rows (confirmed:
zero `ZZTEST` rows remain).

**Not enabled:** `ledger_auto_entry_sale()`, `stock_update_on_sale()` and
`write_audit_log()` stay commented for Phase 3. The per-line
`stock_update_on_purchase()` from migration 00010 was deliberately NOT
attached; its semantics are replaced by the two functions above.

### Migration 00016 — landed cost for scheme stock [DONE]

`20260918000016_landed_cost.sql` applied (16/16 migrations match remotely).

- `product_batches.landed_cost_per_unit numeric(12,4)`, backfilled from
  `purchase_rate`
- `product_stock.stock_value_at_cost` now sums
  `qty * coalesce(landed_cost_per_unit, purchase_rate)`; `security_invoker`
  preserved through the `create or replace view`
- `stock_apply_purchase()` and `stock_apply_purchase_item()` re-created to set
  the cost basis as a **moving weighted average** over the units the batch
  holds, not a per-line overwrite (see D-012)
- `ledger_auto_entry_purchase()` untouched: it posts `grand_total`, which is
  what was payable, so free goods never affected it

Verified: `phase2_stock_triggers.sql` now has 20 assertions, all passing —
including the spec's numbers (landed 83.3333; value 1000.00, not 1200.00) and a
second receipt into the same batch (cost basis 1100.00, not 1300.00). Test is
atomic and self-rolling-back; zero `ZZTEST` residue confirmed.

### Products module — data and application layer [DONE]

- `features/products/data/products_repository.dart` — list (paged, searched,
  filtered), byId, create, update, setActive, batchesFor (FEFO), stockFor,
  aliasesFor, addAlias, removeAlias
- `features/products/application/products_list_controller.dart` — filter state
  (kept alive) + paged list (not kept alive) with `loadMore`
- `features/products/application/products_detail_controller.dart` — product +
  FEFO batches + aliases + stock rollup; owns the alias writes
- `features/products/application/products_form_controller.dart` — create,
  update, deactivate
- New shared pieces: `data/models/product_alias.dart`,
  `data/models/product_draft.dart`,
  `data/datasources/postgrest_error_mapper.dart`,
  `core/utils/postgrest_search.dart`
- Tests: `postgrest_search_test.dart`,
  `products_list_controller_test.dart` (fake repository via `implements` +
  `noSuchMethod`, covering filtering, paging, debounce and load-more failure)

### Products module — complete [DONE]

Data and application layers as listed above, plus:

- Screens: `products_screen.dart` (search, schedule and availability filters,
  paged list, load-more), `products_form_screen.dart` (create/edit, barcode
  hook), `products_detail_screen.dart` (Info / Batches / Aliases tabs,
  deactivate with confirmation)
- Widgets: `product_card.dart`, `product_filter_bar.dart`,
  `product_badges.dart` (schedule and expiry tone mappings)
- Routes: `/products`, `/products/new`, `/products/:productId/edit`,
  `/products/:productId` (declared in that order so `new` is not read as an
  id), and `products_placeholder.dart` deleted
- Shell: primary-bar and drawer highlighting now match by prefix, so a nested
  product screen still lights up Products
- Shared pieces added along the way: `core/widgets/app_back_button.dart`,
  `core/errors/error_message.dart`
- Tests: `product_card_test.dart`, `products_screen_test.dart` (list, empty
  state, search narrowing, schedule filtering) over the shared fake in
  `test/support/fake_products_repository.dart`

### Suppliers + customers modules [DONE]

Built by two parallel subagents on strictly disjoint directories
(`features/suppliers/**`, `features/customers/**`), with every shared file
written by the main agent: `routes.dart`, `app_router.dart`,
`dashboard_shell.dart`, `widget_test.dart`, and the ledger pieces both modules
needed (`data/models/party_balance.dart`,
`data/repositories/ledger_repository.dart`). Neither subagent ran codegen — one
`build_runner` run in the main agent covered both, because two concurrent runs
corrupt `.dart_tool`.

- Suppliers: draft model, repository (`SuppliersQuery`), filter/list/form/detail
  controllers, three screens, card + filter bar, 10 controller tests
- Customers: the same shape, 10 controller tests, plus `CustomerDraft`
- Integration fixes after the merge: a missing `party_balance` import in the
  suppliers detail screen (extension members need their library imported), and
  the customers form's private email validator replaced with the shared
  `Validators.emailIfPresent` added to `validators.dart`

### Bug fix — phantom "not linked to a pharmacy" [DONE]

Reported: saving a product failed with *"Your account is not linked to a
pharmacy yet."* for `rohit@arihant.com`, whose `profiles.pharmacy_id` was set
correctly in the database, even after clearing storage, signing out and back in,
and hot restarting.

**Root cause (two defects, both in our code, neither in the data):**

1. `authControllerProvider` was auto-dispose (Riverpod 3's default), and the
   only thing that ever watched it was the dashboard. Navigating dashboard →
   products disposed it, so the next screen's read of the tenant scope rebuilt
   it and started a fresh profile fetch.
2. `activePharmacyId` read `authControllerProvider.value?.pharmacyId`
   synchronously, and that value is `null` **while the profile is loading**. So
   "the profile has not arrived yet" was indistinguishable from "the profile has
   no pharmacy", and a valid user was told they were unlinked.

The reported hypothesis (a profile cached forever across sign-out/sign-in) was
not what the code did: `AuthController.build()` already invalidated itself when
the signed-in user id changed, and `authStateChangesProvider` already existed.

**Fix:**

- The auth chain is now kept alive end to end
  (`supabaseClient` → `authRepository` → `AuthController` → scope), so the
  profile survives navigation; `riverpod_lint` enforces that chain.
- `requirePharmacyId` distinguishes all four states: loading, loaded-with-id,
  loaded-without-id, and failed read. Only a *loaded* profile with no
  `pharmacy_id` reports "not linked"; a failed read reports itself; a profile
  still in flight reports that it is loading and can be retried.
- `AuthController` also refetches on `tokenRefreshed`, so a profile row changed
  underneath a signed-in user (a pharmacy linked, a role changed) is picked up
  without a sign-out.
- New `profileStateProvider` is the seam that lets tests drive all four states.

**Verified:** 140 tests pass, including four new ones covering each profile
state. Not verified in a browser - see the note in the chat.

### Security fix — profile privilege escalation [DONE]

Any authenticated user could set their own `profiles.role = 'owner'` and point
`profiles.pharmacy_id` at another tenant's uuid. RLS is row-level, so
`profiles_update_self` permitted it, and `get_my_pharmacy_id()` reads that same
row - making it both self-promotion and a tenant hop.

- `20260918000017_harden_profiles.sql` - revokes the **table-level** UPDATE grant
  on `profiles` from `authenticated`, grants UPDATE back on `full_name`, `phone`
  and `avatar_url`, recreates the self-update policy for the row restriction, and
  adds the `onboard_pharmacy()` SECURITY DEFINER RPC.
- `20260918000018_harden_profiles_anon.sql` - takes EXECUTE on that RPC away from
  `anon`, which held its own grant independent of `PUBLIC`.

Two traps, both caught by checking the live database rather than trusting the
SQL: a column-level `revoke` is a **no-op** while a table-level privilege exists
(so the obvious fix would have done nothing), and revoking from `PUBLIC` does not
remove a role's own grant (so `anon` could still have created tenants).
Recorded in D-017.

Verified by `supabase/tests/profile_privileges.sql` - 16 assertions, all passing.
It impersonates the `authenticated` role with `auth.uid()` set inside one
transaction and proves: self-promotion refused, `pharmacy_id` rewrite refused,
legitimate column edits still work, `anon` cannot execute the RPC and sees zero
business rows, onboarding refuses an already-linked account, and the happy path
creates a pharmacy and links it as owner. Atomic and self-rolling-back; zero
residue confirmed (`0` test pharmacies, the real profile untouched).

### Onboarding flow [DONE]

`features/onboarding/` - repository over the RPC, controller that invalidates the
profile on success, and a form screen (name, GSTIN, drug licence, phone, city,
state, PIN). New `/onboarding/pharmacy` route, deliberately outside the shell
(with no pharmacy, every nav destination could only fail), and a router redirect
that sends a signed-in account with no pharmacy there.

The redirect waits while the profile is still loading rather than treating
"not yet loaded" as "unlinked" - the same defect as the tenant-scope bug above,
one layer up. `_AuthRouterRefresh` now listens to the profile as well as the
session, so the redirect re-runs once onboarding links the account.

### Bug fix — desktop navigation hid seven destinations [DONE]

Reported: on desktop (>700px) the rail showed only the four primary destinations
and nothing could open the drawer, so Suppliers and Customers were unreachable.

**Root cause:** the desktop rail was built from the four-destination primary
list, and the shell renders no `AppBar` - `Scaffold.drawer` only draws a
hamburger when an `AppBar` exists, so the drawer it also configured had no
trigger. Adding the masters to the drawer in Phase 1 put two user-facing screens
somewhere desktop could not reach.

**Fix (D-018):** all 11 destinations now live in one `_navDestinations` list;
the rail renders all of them expanded, the drawer renders all of them on mobile
only, and the bottom bar renders the four flagged `inBottomBar`. The rail is
`scrollable` (11 destinations overflow a short window), auto-collapses below
1200px with a toggle to override, and desktop no longer configures a drawer that
nothing can open.

Structure captured from the running widget tree at three widths:

```
=== 1920x1080  shell.drawer=false
NavigationRail(extended=true, scrollable=true, count=11)
  labels => Dashboard, Products, Suppliers, Customers, Inventory, Purchase,
            Sales, Returns, Ledger, Reports, Settings
=== 800x900  shell.drawer=false
NavigationRail(extended=false, scrollable=true, count=11)
  labels => (same 11)
=== 500x900  shell.drawer=true
NavigationBar(4) => Dashboard, Products, Sales, Reports
```

Tests: `test/features/dashboard/dashboard_shell_test.dart` (7 cases: every
destination labelled on desktop, no drawer on desktop, tapping a rail item
navigates and highlights, auto-collapse, manual toggle, nested path keeps its
section highlighted, mobile keeps 4 + the full drawer), plus `widget_test.dart`
now pins `DashboardShell.destinationPaths == Routes.shellPaths` and
`.bottomBarPaths == Routes.bottomNavPaths`.

### Phase 2 — Purchase module: data + application layer [DONE]

Models: `purchase.dart` (+ `PurchaseStatus`), `purchase_item.dart`,
`purchase_draft.dart` (`PurchaseDraft` + `PurchaseLineDraft`).

- `features/purchase/data/purchase_totals.dart` — line and document money math,
  pure and separately tested. Rounds each figure before summing so a stored grand
  total always equals the sum of its stored lines, and rounds half-away-from-zero
  with an epsilon so `1.005` does not come out a paisa short of what Postgres
  `numeric` would store.
- `features/purchase/data/purchases_repository.dart` — list (supplier, status,
  date range, search), byId, itemsFor, create, updateDraft, setStatus, receive.
- `data/repositories/pharmacy_repository.dart` — the pharmacy's state, needed to
  decide the GST split.
- Application: filter/list controller with paging, form controller,
  `purchaseWithLines`, `purchaseTaxSplit`, and `GrnController`.
- Tests: `purchase_totals_test.dart` (12) and `grn_controller_test.dart` (6).

**The receipt's write order** (D-013) now lives in one place,
`PurchasesRepository.receive`, with the reasoning inline:

1. `product_batches` upserted on `(pharmacy_id, product_id, batch_no)`
   **without `qty`** — a new row takes the default 0, and the upsert leaves an
   existing batch's balance alone instead of zeroing live stock;
2. `purchase_items` replaced wholesale, now carrying `batch_id` and the line's
   share of the tax;
3. the header's totals **and** `status = 'received'` in one statement, because
   `ledger_auto_entry_purchase()` reads `grand_total` off the row it is handed.

**Verified against the live database** by `supabase/tests/grn_write_order.sql`
(15 assertions, all passing, atomic and self-rolling-back), which reproduces the
client's exact payloads and proves: a draft creates no batch; a new batch starts
at 0 with no landed cost; lines written before receipt move nothing; receipt
applies `qty + free_qty` for every line; the landed cost lands at 83.3333; the
marker is stamped; the ledger posts 1344 from the same statement as the status;
the lines add up to the document totals; **a repeat upsert of the same batch does
not reset its stock**; and two payload rows for one batch are refused by Postgres
(which is why `validateLines` exists).

### Purchase module — presentation layer [DONE]

The purchase module is complete. Built after a crash mid-write of
`purchase_line_editor.dart`; `context/chat2b-summary.md` is the detailed account.

- Screens: `purchases_screen.dart` (search, supplier dropdown, status chips,
  invoice-date range, paging), `purchase_form_screen.dart` (order: invoice
  details and lines, no batches), `grn_screen.dart` (the receipt — reaches stock
  and the ledger), `purchase_detail_screen.dart` (invoice, stored totals, lines
  with batches, and the next step)
- Widgets: `purchase_line_editor.dart` (one editor for both halves of a
  purchase's life; `showBatchFields` is the difference), `purchase_card.dart`,
  `purchase_filter_bar.dart`, `purchase_status_badge.dart`,
  `purchase_locked_view.dart`
- Routes `/purchase`, `/purchase/grn`, `/purchase/new`,
  `/purchase/:purchaseId/edit`, `/purchase/:purchaseId/grn`,
  `/purchase/:purchaseId` — literal segments declared before the parameterised
  one, since declaration order is match order; `purchase_placeholder.dart`
  deleted
- New shared pieces: `core/widgets/app_date_field.dart` (a `FormField`-based date
  field, so a required date reports at the field), and
  `suppliers/application/supplier_options.dart` (`supplierOptions` — every
  supplier, inactive included, for pickers and for naming a card)
- `ProductPickerField` gained `selectedName`: an existing document stores a
  line's product id and a displayed name, not the catalogue row
- Detail totals are rendered from the document's own stored columns, because
  those are what `ledger_auto_entry_purchase()` posted; the tax *head* is summed
  from the lines, where it is actually stored
- A standalone receipt (goods with no purchase order behind them) creates the
  document as a draft and receives it in one action, so a failure in between
  leaves a recoverable draft rather than losing the typed lines
- Tests: 21 widget tests across the four screens, over
  `test/support/fake_purchases_repository.dart` (which runs the real
  `validateLines`, so a screen that skips a check the write enforces fails in the
  test rather than in front of a user) and `test/support/purchase_test_app.dart`
  (a mini-router, so each screen's `context.go` is exercised)

Two bugs were found by those tests and fixed: a picked date never reached the
line draft (`AppDateField.onChanged` did not `_emit()`, so the receipt was
refused for a missing expiry the user had chosen), and the detail screen could
show a stale document because the writing screen invalidated the list but not
`purchaseWithLines(id)`.

### P-1 fix — an edited order reverts to draft only when its lines change [DONE]

`updateDraft` wrote `status = 'draft'` unconditionally, so saving an `ordered`
purchase silently undid the transition. Decided and implemented as option 1 from
the brief, recorded as **D-019**:

- `PurchasesRepository.statusAfterEdit` / `.linesDiffer` — pure and public, so the
  rule is unit-tested without a client and the test fake runs the same function.
- The comparison is a multiset of per-line signatures over the fields a supplier
  would have to re-confirm (product, qty, free qty, rate, mrp, discount, GST,
  batch, expiry), compared at the precision the columns store. Order is ignored
  on purpose: `purchase_items.created_at` is a transaction timestamp, so a read
  can return rows in a different order than they were written, and an
  order-sensitive comparison would revert a document nobody touched.
- `PurchaseFormScreen` reports the revert with a SnackBar ("Order returned to
  draft because lines changed — review and re-confirm"), driven by comparing the
  status it loaded with the status it got back rather than by predicting it.
- Tests: `purchase_edit_status_test.dart` (11, over both branches and the
  boundaries) and two widget tests on the form.

### Inventory module — complete [DONE]

`features/inventory/` — data, application and presentation
(`inventory_placeholder.dart` deleted).

- `data/inventory_repository.dart` — the cross-product reads (`stockList` paged
  and searchable with an in/out-of-stock filter, `lowStock`, `expiringBatches`,
  `batchesExpiringBetween`, `namesFor`) and the `stock_adjustments` write.
  `ProductsRepository` keeps the per-product reads it already had (`batchesFor`,
  `stockFor`); the split is by question, not by table.
- Screens: `inventory_screen.dart` (Stock / Low stock / Expiry tabs) and
  `expiry_calendar_screen.dart` (a month grid with units per day, filtering the
  list below by a tapped day). Route `/inventory/calendar` added; the shell is
  unchanged.
- Widgets: `product_stock_card.dart`, `expiry_batch_card.dart`,
  `expiry_bucket_bar.dart`, `stock_level_badge.dart`,
  `stock_adjustment_sheet.dart`.
- The stock rows print the rollup's own `total_qty` and `stock_value_at_cost`, so
  the screen cannot disagree with the view, and the valuation keeps the landed
  cost (D-012) rather than a rate.
- The expiry rows show units and value **at MRP**, not at cost: `batch_status`
  does not carry `landed_cost_per_unit` (it was added to `product_batches` after
  that view was created, and a view's `b.*` is expanded when it is created), and
  `qty x purchase_rate` would overstate any batch that took in scheme stock.
- Adjustments are batch-scoped and reachable from two places: the expiry list,
  and the Batches tab of the product detail (extended rather than duplicated, as
  the brief asked). The sheet caps a decrease at what the batch holds, and the
  trigger's own `check_violation` is surfaced verbatim when a concurrent write
  gets there first.
- One shared rule was extracted rather than copied: `Validators.positiveInt`
  (used by the adjustment sheet and the purchase line editor), and `ExpiryBadge`
  moved to `core/widgets/expiry_badge.dart` so the product detail and the expiry
  dashboard cannot disagree about which bucket is urgent.
- Tests: 16 across `inventory_screen_test.dart` (list, filter, low stock, the
  three buckets, a written adjustment, the at-the-field cap, a refused
  correction) and `expiry_calendar_test.dart` (month arithmetic, the screen, the
  day filter).

### Purchase returns module — complete [DONE]

`features/returns/` — `returns_placeholder.dart` deleted; routes `/returns`,
`/returns/new`, `/returns/:returnId`. Sale returns stay Phase 3.

- Models `purchase_return.dart`, `purchase_return_item.dart`; repository over
  `purchase_returns` / `purchase_return_items`; list controller with paging; form
  controller; detail controller.
- `ReturnableLine` is the whole decision a return line makes: what the invoice
  billed, what has already gone back (summed from this purchase's returns, keyed
  by `purchase_item_id`), and what is in the batch right now. The form shows that
  number and the write re-derives it, so the two cannot disagree and the supplier
  cannot be credited twice for the same units.
- The credit is a **proportional slice of the invoice line's own stored amounts**
  (`PurchaseReturnTotals`), not `qty x rate`: `purchase_return_items` has no
  discount column, so recomputing would credit the list price of discounted
  goods. Recorded as D-020.
- `create` takes only `(purchaseItemId -> qty)`: the amounts, the supplier and the
  batch come from the invoice line.
- Tests: `purchase_return_totals_test.dart` (5) and 11 widget tests over the list
  and the form, including the credit preview and the cap.
- Two bugs found by those tests: the return line's quantity field only reported
  on submit (so a browser or desktop user's quantities never reached the parent —
  or the credit preview), and a fixture without a `batch_id` showed how a
  received line with no batch can never be returned.

### PHASE 2 COMPLETE

Delivered in this chat: the P-1 fix (D-019), the inventory module (stock, low
stock, expiry dashboard, expiry calendar, stock adjustments) and the purchase
returns module. Phase 2's DB automation was already live and verified; no
migration was added or needed, so `supabase db push` was not part of this gate
run.

Gate output at completion:

```
dart format lib test                      -> 0 changed (tree is formatter-clean)
dart run build_runner build --delete...   -> wrote 127 outputs (T-1 SDK notice only)
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +237: All tests passed!
```

(191 tests at the end of the purchase module; 237 now — 46 added, none changed.)

### PHASE 1 COMPLETE

Delivered: three masters at full CRUD — products (multi-batch FEFO view,
aliases tab, schedule badges, search by name/generic/barcode, schedule and
availability filters, low-stock indicator on detail), suppliers and customers
(contact, registration, commercial fields, read-only ledger balance, active
filter). 12 new routes, dashboard nav for both new masters, placeholders
deleted.

Gate output at completion:

```
dart format lib test                      -> 0 changed (tree is formatter-clean)
dart run build_runner build --delete...   -> wrote 167 outputs (T-1 SDK notice only)
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +136: All tests passed!
```

(29 tests at the end of Phase 0; 136 now.)

### Shared foundation [DONE]

- Models: `ProductStock` (`product_stock` view), `BatchStatus` +
  `ExpiryStatus` (`batch_status` view)
- Widgets: `StatusBadge`, `AppDropdownField`, `AppEmptyView`,
  `SectionCard`, `AppSearchField`, `showConfirmDialog`
- Utils: `Debouncer`; validators for drug licence, optional GSTIN/phone/
  PIN code and non-negative numbers
- Providers: `activePharmacyId` / `requirePharmacyId`
  (`features/auth/application/pharmacy_scope.dart`)

### Gate status (2026-09-18, after the products module)

```
dart run build_runner     -> outputs written (T-1 SDK notice only)
dart run custom_lint       -> No issues found!
flutter analyze            -> No issues found!
flutter test               -> +113: All tests passed!
```

### Environment notes discovered this chat

- Riverpod 3 wraps whatever a provider threw before handing it to a provider
  that watches it, in `ProviderException` (`flutter_riverpod/misc.dart`). A
  screen rendering `error.toString()` would show Riverpod's developer dump
  instead of the app's message, so `describeError()` unwraps it in a loop
- `DropdownButtonFormField.value` is deprecated after Flutter 3.33; use
  `initialValue` (it re-syncs when the parent passes a new value, so the
  field stays controlled)
- Riverpod 3.0.3 has no `AsyncValue.valueOrNull`; `AsyncValue.value` is
  already nullable
- Riverpod 3 disposes providers with no listeners by default. State that must
  outlive navigation needs `@Riverpod(keepAlive: true)`; the products filter
  uses it, the product list deliberately does not
- Riverpod 3's generated notifier base class already defines `update`, so a
  controller method with that name is a compile error. Controller methods are
  named `<verb><Entity>` (`createProduct`, `updateProduct`)
- `AsyncValue.copyWithPrevious` is marked `@internal` in Riverpod 3 and cannot
  be called from app code, so a failed `loadMore` restores the previous page and
  rethrows instead
- `Override` is declared in `riverpod`, not re-exported by `flutter_riverpod`,
  so provider override lists in tests must be inferred
- `ThemeData(brightness: dark)` does not give the theme a dark
  `colorScheme`; build one via `ColorScheme.fromSeed(brightness:)`
- `MaterialApp` swaps themes through an `AnimatedTheme`, so widget tests
  must `pumpAndSettle` before reading a theme
- A `SliverList` only *mounts* the children inside its viewport, so a widget
  test asserting on a field below the fold finds nothing at all — not something
  merely off-screen. The purchase-screen tests size the test window tall in
  `pumpPurchaseApp` instead of scrolling to every assertion
- A `DropdownButton` keeps every item it was given in its own subtree (an
  `IndexedStack`), so `find.text('Arihant Distributors')` also matches the
  closed filter button. Assert through `find.widgetWithText(SomeCard, …)`, or
  through the chip
- `find.text` matches an `EditableText`'s content too, so a search field holding
  the term matches the same `find.text` the results do
- After a write that changes a document, invalidate **the document provider as
  well as the list**: a document provider still cached against the screen that
  wrote it can hand the next screen the pre-write copy (found by a purchase test)

---

## Next Action

**Phase 5 Chunk E — the chatbot** (`chat-sql-agent`), the last Phase 5 function and the
last Phase 5 chunk. **Next Action once Chunk E completes = Phase 6.** Auto-send PO is
no longer a Phase 5 chunk — it moves to Phase 6's add-ons (D-052). Chunk D is done,
deployed and probed (above); what remains in Phase 5 is the one function the master
plan has always listed and no chunk has built. Its brief is
`context/chat3j-opening-prompt.md`, and **D-026 is the constraint that shapes it**:
the chatbot answers through **RPCs, never free-form SQL** — a model that writes SQL
against a live tenant is a model that can be talked into writing it somewhere else,
and the parameterised RPC is the boundary that makes the question safe. Concretely:

**Chunk E is split two ways, and part 1 is done, deployed and probed:**

- **E-part-1 (done):** migration **00029** (`top_products`, `dead_stock`, the last two
  of D-026's four aggregates) with `supabase/tests/phase5_chat_aggregates.sql` —
  **36 PASS / 0 FAIL of 37 assertions** — and **`chat-sql-agent` built, deployed and
  live-probed** (4 invocations: `low_stock_products`, `top_products` with its `meta`
  window and `returns_not_netted`, an `rpc: null` refusal, and the preflight/400 paths),
  covered by 52 new Deno tests (the full suite is **181 passed**). **D-053** records the
  phrasing rule (templated in code, never model-generated) and **D-052** the auto-send PO
  deferral. The Makefile and `HANDOFF_PROTOCOL.md` carry the new `deno check` line.
- **E-part-2 (next):** the `/chatbot` Dart surface (service + controller + screen +
  widget tests, the 13th shell destination). Briefed in
  `context/chat3k-opening-prompt.md`. **The endpoint itself needs no further probing** —
  it was verified end to end in part 1; a token is only needed if an end-to-end run of the
  Flutter build is wanted.

The notes below are E-part-1's implementation record, kept because E-part-2's screen
depends on the contract they describe:

- `_shared/gemini.ts` already carries the poster (`postGemini`) and the error
  vocabulary, and D-030 named the vision model in code; the chatbot's **text** model
  should be named the same way and its answer verified live, because a model name is
  the thing that rots.
- **D-047 already reserved the two aggregates for it** — "one implementation, three
  callers (the list, the inventory screen when it is next touched, the chatbot)" —
  and `report_summary()` is the other aggregate it should reach for. Any question
  that needs a *new* aggregate is a migration, not a SQL string.
- The tenant is never an argument (D-004): the RPCs take it from
  `get_my_pharmacy_id()`, so the function presents the caller's JWT and nothing else.
- Phase 5's own discipline applies unchanged: 200-vs-error is decided by whether
  anything was recorded, a refusal is a sentence rather than a crash, and the tests
  run with **no secret at all** — the whole handler through stubs.
- Its Dart surface (a chat screen, probably under `/reports` or its own top-level
  destination) has not been decided, and chunk E should decide it rather than inherit
  it: D-048 chose a top-level destination for notifications on the grounds that
  notifications span every domain, and a chatbot that answers questions about stock,
  sales and ledgers spans them just as widely.

**What chunk D deliberately did not do**, so chunk E does not assume it: nothing
dispatches the alerts (D-046 — Phase 6 owns the credentials and the triggers), no push
is registered (N-1), and the two rows the probe wrote stay in production on purpose.

Then **Phase 6**: testing, deployment, documentation — the Windows build fix (W-1),
the README refresh (R-1), push registration (N-1), the SendGrid/WhatsApp credentials
and the alert triggers (D-046), N-9's re-measurement once the catalogue is real, N-5's
index, and **auto-send PO** (D-052 — it needs the same WhatsApp/SendGrid credentials
the alert triggers do).

What Phase 5 builds on, and must not break:

- A sale is written through `checkout_sale(jsonb)` and nothing else, and its
  stock moves per line from a trigger on `sale_items`. Quantity is
  `product_batches.qty`; **no client posts it** (D-021's closing note). An OCR
  path that fills a purchase invoice must go through `PurchasesRepository.receive`
  for the same reason.
- Every DB query is scoped by `pharmacy_id`, read **synchronously** from
  `requirePharmacyIdProvider` (D-015).
- `checkout_sale()`, `record_payment()` and `report_summary()` are
  `security definer` and take the tenant from `get_my_pharmacy_id()`; an AI or
  Edge Function must present the user's JWT, never `service_role` (D-004).
- Money is computed once, by a pure helper, and both the screen and the write use
  it (`PurchaseTotals`, `PurchaseReturnTotals`, `PosCart`), with
  `PurchaseTotals.round2` as the shared rounding rule.
- A document that has posted stock is corrected by a return, never by an edit
  (D-013 for purchases, and the sale side follows it: `sale_status` has no draft).
- Three open items Phase 5 should not make worse: **T-3** (the ledger's failure
  path offers no retry after a party is chosen), and **T-4** / **T-5** (the
  sale-return form's dead bill validator, and its picker where "loading" and
  "nothing sold yet" look the same). I-1 to I-3, R-1 and the new **N-1** are still
  open.
- The AI substrate now exists and is verified: `products.embedding` with its HNSW
  index (D-027), the private path-scoped `purchase-bills` bucket (D-028), and
  `device_tokens` / `notification_logs` (00022). Chunk B uploads to the bucket;
  chunks C-E read the vector and write the log. Do not `select *` a table that has
  an embedding on it.
