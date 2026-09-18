# PharmaFlow — Progress Tracker

**Last Updated:** 2026-09-18
**Current Phase:** Phase 0 COMPLETE | Phases 1-2 NEXT (combined chat)
**Overall Status:** Foundation solid, ready for business modules

---

## Phase Status Overview

| Phase | Name | Status | Started | Completed |
|---|---|---|---|---|
| 0 | Project Setup + Schema + Auth | COMPLETE | 2026-09-18 | 2026-09-18 |
| 1 | Product + Supplier + Customer Master | PENDING | - | - |
| 2 | Purchase + Inventory + Batch Tracking | PENDING | - | - |
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

## Next Action

Start Chat 2 with Phase 1 + Phase 2. Paste the contents of
`context/chat2-opening-prompt.md` into a fresh chat.
