# PharmaFlow — Progress Tracker

**Last Updated:** 2026-09-18
**Current Phase:** Phase 1 COMPLETE | Phase 2 NEXT
**Overall Status:** Masters done and gated; Phase 2 DB layer already live

---

## Phase Status Overview

| Phase | Name | Status | Started | Completed |
|---|---|---|---|---|
| 0 | Project Setup + Schema + Auth | COMPLETE | 2026-09-18 | 2026-09-18 |
| 1 | Product + Supplier + Customer Master | COMPLETE | 2026-09-18 | 2026-09-18 |
| 2 | Purchase + Inventory + Batch Tracking | IN PROGRESS (DB layer complete) | 2026-09-18 | - |
| 3 | Sales/POS + Returns + GST Billing | PENDING | - | - |
| 4 | Ledger + Payments + Reports | PENDING | - | - |
| 5 | AI OCR + Smart Matching + Notifications | PENDING | - | - |
| 6 | Testing + Deployment + Documentation | PENDING | - | - |

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
- **Chat 2:** Phase 1 + Phase 2 [target ~350k tokens]
- **Chat 3:** Phase 3 + Phase 4 [target ~390k tokens]
- **Chat 4:** Phase 5 + Phase 6 [target ~280k tokens]
- **Handoff trigger:** ~600k tokens used OR quality degrades OR both phases done

---

## What Currently Works

### Backend (Supabase Hosted)

- 14 migrations applied, all idempotent
- 21 tables, 2 views, RLS enforced on every business table
- 3 helper functions: `get_my_pharmacy_id()`, `get_my_role()`, `normalize_product_name()`
- 52 indexes (incl. GIN trigram on `product_aliases`), 28 triggers
  (`set_updated_at` on 21 tables + `handle_new_user`)
- Auth working: email provider ON, confirm email OFF
- User `owner@pharmaflow.dev` registered and promoted to `owner`
- Pharmacy row created: "My Pharmacy"
- Multi-tenant isolation verified with two test tenants

### Flutter App

- Bootstrap chain working: `main.dart` -> `bootstrap.dart` -> `PharmaFlowApp`
- Riverpod 3.x codegen setup (`@riverpod`)
- GoRouter with auth redirects
- Theme (light/dark, teal seed)
- Widgets: AppButton, AppTextField, AppScaffold, LoadingView, ErrorView
- 6 Freezed models: Pharmacy, Profile, Supplier, Customer, Product, ProductBatch
- Auth flow: splash -> login -> register -> dashboard -> signout
- Dashboard shell responsive (NavigationBar mobile / NavigationRail desktop)

### Platform Support

- Web (Chrome): working
- Windows: build fails (`permission_handler_windows`, STL1011)
- Android: configured, untested
- iOS: configured, untested

---

## Known Issues / Open Items

| ID | Issue | Severity | Plan |
|---|---|---|---|
| W-1 | Windows build fails (STL1011 — `<experimental/coroutine>` deprecated in VS 2026) | Medium | Fix in Phase 6 via `windows/CMakeLists.txt` |
| D-1 | 5 manual Providers remain (service stubs + router) | Low | Convert to `@riverpod` when the respective features are built |
| T-1 | `dart run custom_lint` SDK language version notice (cosmetic) | Low | Wait for upstream analyzer fix |
| A-1 | `anonKey` deprecated in supabase_flutter 2.17 | Low | Migrate to `publishableKey` in Phase 6 |

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

---

## Next Action

Phase 2 — Purchase + Inventory + Batch tracking. Build order:

1. Purchase module (repository, controllers, screens). The GRN screen is the
   complex part: it must upsert `product_batches` at `qty = 0` first, then write
   `purchase_items` carrying `batch_id`, then move the document to `received`
   (which is what posts stock and the supplier ledger entry).
2. Inventory (stock view, low-stock list from `product_stock`, expiry
   dashboard, adjustments), with the batch/expiry calendar inside it.
3. Purchase returns (extend `features/returns/`).
4. Phase 2 gate + handoff.

The Phase 2 DB automation is already live and verified, so the purchase module
builds directly against it.
