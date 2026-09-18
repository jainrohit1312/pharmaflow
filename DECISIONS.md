# Architecture Decisions Log

Append-only record of decisions that constrain future chats. A decision
listed here is not re-litigated unless the user explicitly changes it.

---

## D-001 — State Management: Riverpod 3.x

**Date:** 2026-09-18

**Decision:** Riverpod 3.x with codegen (`@riverpod`).

**Rationale:** Less boilerplate than BLoC, compile-time safety, no
`BuildContext` dependency, great for multi-tenant async patterns.

**Consequences:** All new providers use `@riverpod` codegen.
Hand-written `Provider` is allowed only for stubs.

---

## D-002 — Models: Freezed 3.x with abstract class

**Date:** 2026-09-18

**Decision:** All data models use Freezed 3.x with
`abstract class X with _$X`.

**Rationale:** custom_lint 0.8.x forces `freezed_annotation` ^3.0.0.
Freezed 3 generates `_$X` as an abstract mixin, so the class itself must be
declared `abstract`.

**Consequences:** JSON snake_case via
`@JsonSerializable(fieldRename: FieldRename.snake)`. `// ignore:
invalid_annotation_target` on the factory constructor.

---

## D-003 — Backend: Hosted Supabase Only

**Date:** 2026-09-18

**Decision:** Hosted Supabase only. No local stack, no Docker.

**Project ref:** `yeroxzkpmodbzcvjlqwd` (Mumbai, ap-south-1)

**Consequences:** `supabase db push` is the ONLY migration command.
No `supabase start` / `stop` / `status` / `db reset`.

---

## D-004 — Multi-Tenant Isolation via RLS

**Date:** 2026-09-18

**Decision:** Every business table has `pharmacy_id uuid` and RLS policies
scoped by `get_my_pharmacy_id()`.

**Consequences:** Every INSERT includes `pharmacy_id`. AI/Edge Functions
use the user JWT, never `service_role` for reads.

---

## D-005 — Cross-Platform: Web First

**Date:** 2026-09-18

**Decision:** Priority: Web (Chrome) -> Windows -> Android -> iOS.

**Consequences:** Barcode scanner has a web fallback. Thermal print: web
uses PDF, Windows uses native.

---

## D-006 — Auth: Supabase Email + RLS

**Date:** 2026-09-18

**Decision:** Supabase Auth. `auth.users` + `public.profiles`.

**Consequences:** `handle_new_user()` trigger auto-creates a profile with
`role='viewer'`. The first user is manually promoted to owner via the SQL
Editor.

---

## D-007 — Dependency Pins Are Load-Bearing

**Date:** 2026-09-18

**Decision:** These MUST NOT be changed without explicit approval:

```yaml
riverpod_lint: '>=3.0.0 <3.1.0'  # 3.1.8 renamed its entrypoint
custom_lint: ^0.8.0              # forces Freezed 3.x
freezed: ^3.0.0                  # models must be abstract
environment:
  sdk: ^3.8.0                    # json_serializable null-aware elements
```

**Why:** `riverpod_lint` 3.1.8 renamed its public entrypoint from
`lib/riverpod_lint.dart` to `lib/main.dart`, while `custom_lint` 0.8.1 still
generates a plugin client importing
`package:riverpod_lint/riverpod_lint.dart`. Widening the constraint to
`^3.0.0` lets it resolve to 3.1.8 and `dart run custom_lint` then dies with
"Failed to start the plugins". 3.0.3 is the newest release whose entrypoint
custom_lint 0.8.1 can load.

---

## D-008 — Multi-Chat Workflow via Files (1M Context Optimized)

**Date:** 2026-09-18

**Decision:** 4 chats total, 2 phases per chat.

- Chat 1: Phase 0 [done]
- Chat 2: Phase 1 + Phase 2
- Chat 3: Phase 3 + Phase 4
- Chat 4: Phase 5 + Phase 6

Persistent state in: `PROGRESS.md`, `MASTER_PLAN.md`, `DECISIONS.md`,
`HANDOFF_PROTOCOL.md`, `context/chatN-summary.md`,
`context/chat(N+1)-opening-prompt.md`.

**Handoff trigger:** ~600k tokens OR quality degradation.

---

## D-009 — AI Deferred to Phase 5

**Date:** 2026-09-18

**Decision:** AI OCR, fuzzy match, embeddings, and notifications are all
Phase 5.

**Rationale:** AI needs real data. Manual flows must be solid first.


## D-010 — Drift Local DB Deferred to Phase 6+

**Date:** 2026-09-18
**Status:** Active

**Decision:** Drift + offline-first sync is deferred to Phase 6 or later.
All data comes from hosted Supabase directly. No local cache layer in
Phases 1-5.

**Rationale:**
- Retail pharmacies in urban India have stable internet connectivity.
- Online-first is simpler and safer for multi-device consistency.
- Drift adds significant complexity (sync queue, conflict resolution,
  schema drift between local and remote).
- It can be added later without architectural changes — wrap repositories
  with a Drift fallback when the need arises.

**Consequences:**
- `drift`, `drift_flutter`, `sqlite3_flutter_libs` stay in pubspec.yaml
  but are unused. Leave them; do not remove — Phase 6 may use them.
- No local cache in Phase 1-5.
- `app/pubspec.yaml:30` TODO(phase-2) marker is superseded by this
  decision — update the marker to TODO(phase-6+) if it still exists.
- MASTER_PLAN.md Phase 2 scope does NOT include Drift.

---

## D-011 — Scheme/Free Goods Count as Physical Stock

**Date:** 2026-09-18
**Status:** Active

**Decision:** Free goods from suppliers (scheme quantity) are added to
`product_batches.qty` alongside the paid quantity.

**Rationale:** They are physically dispensed at the counter, so omitting them
would understate stock and let the counter oversell a batch that is really empty.

**Consequences:**
- `stock_apply_purchase()` and `stock_apply_purchase_item()` add
  `qty + free_qty`. This is a deliberate deviation from the shipped
  `stock_update_on_purchase()` block in `20260918000010_triggers.sql`, which
  added `qty` only.
- Because free units are in the denominator of the stock balance, receipts with
  a scheme line must carry a landed cost (D-012) or stock value is overstated.

---

## D-012 — Landed Cost for Stock Valuation

**Date:** 2026-09-18
**Status:** Active

**Decision:** Stock value at cost uses `product_batches.landed_cost_per_unit`,
stored per batch at GRN time:

```
landed_cost_per_unit = (purchase_rate * paid_qty) / (paid_qty + free_qty)
```

**Rationale:** Prevents overstatement on scheme receipts. Ten units paid at 100
plus two free is 1000 of cost behind 12 units, not 1200 — and the overstatement
would otherwise distort P&L, GST filing, audits and dead-stock decisions.

**Consequences:**
- `product_stock.stock_value_at_cost` sums `qty * landed_cost_per_unit`, with an
  inner `coalesce(..., purchase_rate)` so a batch that was never costed falls
  back to its purchase rate instead of dropping out of the sum.
- A second receipt into the same batch is a moving weighted average over the
  units the batch holds, not an overwrite: overwriting would restate the cost of
  units already in stock, and possibly already dispensed.
- Outbound movements (purchase returns, stock adjustments) change quantity only.
  Remaining units keep the batch's basis, which is correct for a write-off.
- `ledger_auto_entry_purchase()` is unaffected: it posts `grand_total`, which is
  what the invoice says was payable, not a rate-derived figure. Payments and the
  ledger track cash; landed cost tracks inventory value.

---

## D-013 — Phase 2 Automation Is Enabled by a New Migration

**Date:** 2026-09-18
**Status:** Active

**Decision:** The Phase 2 trigger functions are enabled by
`20260918000015_phase2_extras.sql`, not by uncommenting the blocks in
`20260918000010_triggers.sql` (which are left in place and now point at the new
file). Purchase stock posting is gated on a document reaching `received` and is
made idempotent by `purchases.stock_posted_at`. Stock adjustments and purchase
returns move stock through their own triggers.

**Rationale:** Migration 00010 is already applied to the hosted project, and
`supabase db push` applies only versions missing from
`supabase_migrations.schema_migrations` — uncommenting in place would have left
the database inert while the repository looked enabled. Separately, the shipped
per-line `stock_update_on_purchase()` had no status test, so writing a draft
purchase order's lines would have inflated batch stock before any goods arrived.

**Consequences:**
- A purchase reaches `received` exactly once as far as stock is concerned.
  Moving it back out of `received` does NOT reverse stock or the ledger entry,
  and re-entering `received` does not post a second time. The purchase status
  control must warn about this rather than hide it.
- `stock_adjustments` rows move their batch in the same transaction; a decrease
  that would drive the batch negative raises `check_violation`.
- `purchase_return_items` decrement stock and refuse to oversell.
- Still disabled, for Phase 3: `ledger_auto_entry_sale()`,
  `stock_update_on_sale()` and `write_audit_log()`.
- Verified by `supabase/tests/phase2_stock_triggers.sql` (20 assertions, atomic
  and self-rolling-back).

---

## D-014 — PostgREST Search Term Sanitization

**Date:** 2026-09-18
**Status:** Active

**Decision:** Every `ilike` / `or()` filter is built from
`buildIlikeOrFilter()` in `lib/core/utils/postgrest_search.dart`, which runs
the term through `sanitizeSearchTerm()`. The characters `,` `%` `_` `(` `)` `*`
`"` `'` `\` are stripped (replaced with a space) before the term reaches
PostgREST.

**Rationale:** Prevents filter injection: a comma typed into a search box would
otherwise split the `or=(...)` filter into an extra condition, which is how a
search term could attempt to bypass a predicate the caller ANDed on - such as
`active=true` or the tenant scope. `%` and `*` would turn user text into a
wildcard, and parentheses would open a nested condition group.

**Consequences:**
- Repositories never interpolate a raw search string. `buildIlikeOrFilter()`
  returns `null` for a term that sanitizes to nothing, and callers skip the
  search filter entirely in that case rather than sending a term that matches
  everything.
- Reserved characters become spaces rather than being deleted, so
  `para,cetamol` searches for two words instead of one unknown token.
- `_` is an SQL single-character wildcard rather than a filter-structure
  character: it cannot widen which rows a predicate admits, only how many
  characters one position matches. It is stripped anyway so this list and the
  implementation agree.

  Note: `_` is stripped as a UX convenience, not a security measure. Users type
  underscores as separators; product names do not contain them literally, so
  searching `dolo_650` matches `dolo 650`.
- Covered by `test/core/utils/postgrest_search_test.dart`, including a case
  asserting a comma cannot become a second condition.

---

## D-015 — Auth and Tenant Scope Are Kept Alive, and Read Synchronously

**Date:** 2026-09-18
**Status:** Active

**Decision:** The auth chain —
`supabaseClientProvider` → `authRepositoryProvider` → `authControllerProvider`
→ `profileStateProvider` → `requirePharmacyIdProvider` — is declared
`@Riverpod(keepAlive: true)` throughout, and `requirePharmacyId` is a
**synchronous** provider that throws rather than awaiting.

**Why:**

- Riverpod 3 disposes providers with no listeners by default. The auth
  controller's only listener was the dashboard, so navigating to any other
  screen disposed it and re-triggered a cold profile fetch. Because the scope
  read the profile's `.value` (which is `null` mid-load), a correctly linked
  user was told "your account is not linked to a pharmacy" on the next screen.
- An asynchronous scope provider chained through `.future` was tried and
  reverted. In Riverpod 3 a *failed* build is kept as a result and rethrown at
  read sites, so `await provider.future` on a failed provider never completes:
  every dependent would spin forever instead of reporting the failure. A
  one-shot `ref.read(provider.future)` of an auto-dispose provider can also be
  disposed mid-build ("disposed during loading state"). Both were reproduced in
  tests before reverting.

**Consequences:**

- `requirePharmacyId` must keep its four states distinct: loading, loaded with
  an id, loaded without one, and failed read. Collapsing any of them into
  `null` re-creates the reported bug.
- A kept-alive provider may only depend on kept-alive providers
  (`riverpod_lint: only_use_keep_alive_inside_keep_alive`), which is why the
  whole chain carries the annotation rather than only the scope.
- The error a provider build throws reaches callers wrapped in
  `ProviderException`; `describeError()` unwraps it in a loop, so screens must
  render failures through that helper rather than `toString()`.
- New write paths must scope by `requirePharmacyIdProvider` synchronously. Do
  not introduce `await ref.read(requirePharmacyIdProvider.future)`.

---

## D-017 — Profile Sensitive Columns Protected by Column Grants

**Date:** 2026-09-18
**Status:** Active

**Decision:** `role`, `pharmacy_id` and `is_active` on `profiles` cannot be
updated by authenticated users directly. Postgres column-level grants enforce
this, because RLS is row-level and cannot restrict columns. Legitimate changes go
through SECURITY DEFINER RPCs - currently `onboard_pharmacy()`.

**Rationale:** Without this, any authenticated user could self-promote to owner
or hop tenants. `get_my_pharmacy_id()` reads the caller's own `profiles` row, so
editing `pharmacy_id` does not just change a field: it re-scopes every RLS policy
to a different tenant. Migration `20260918000017_harden_profiles.sql` closes it.

**Consequences:**

- The fix is **not** `revoke update (col, ...) ... from authenticated`. Supabase
  grants table-level privileges on public tables, and in PostgreSQL a
  table-level privilege covers every column, so column revokes are ignored while
  it exists. The table-level grant must be revoked first, then the permitted
  columns granted back (`full_name`, `phone`, `avatar_url`). The same pattern is
  required for any future column protection on a table Supabase granted
  wholesale.
- Revoking from `PUBLIC` is likewise not enough for functions: Supabase grants
  EXECUTE directly to `anon` and `authenticated`, so removing the PUBLIC grant
  leaves their own grant intact (`20260918000018_harden_profiles_anon.sql`).
- User profile edits (name, phone, avatar) still work via direct UPDATE. Role and
  pharmacy changes need an RPC.
- Onboarding is now the supported path for linking an account, replacing the
  manual SQL Editor step.
- Verified by `supabase/tests/profile_privileges.sql`, which impersonates the
  `authenticated` role with `auth.uid()` set and asserts the escalation attempts
  fail. A SQL Editor session cannot verify this - it runs as `postgres`, where
  privilege checks do not apply.

---

## D-018 — Desktop Navigation Uses an Extended Rail

**Date:** 2026-09-18
**Status:** Active

**Decision:** Desktop (>= 700px) shows all 11 destinations in a
`NavigationRail`, expanded so labels are readable, with no drawer. Mobile
(< 700px) keeps the four-destination bottom bar plus the 11-item drawer.

**Rationale:** Pharmacy desktop work (billing, inventory, masters) needs fast
access to every module. Hiding seven of them behind a hamburger is a mobile
pattern that does not fit, and in this shell it was worse than that: the shell
renders no `AppBar`, and `Scaffold.drawer` only produces a hamburger when an
`AppBar` exists - so the drawer it configured had no trigger at all and seven
destinations, including the Suppliers and Customers masters, were unreachable on
every desktop window.

**Consequences:**

- The bottom bar stays at four destinations: a phone is held for the counter
  flows, and a five-or-more item bar stops being usable.
- `_navDestinations` in `dashboard_shell.dart` is the single source of truth. The
  rail and the drawer render all of it; the bottom bar renders the entries
  flagged `inBottomBar`. Adding a route means one entry there.
- `DashboardShell.destinationPaths` and `.bottomBarPaths` exist so tests can pin
  them against `Routes.shellPaths` and `Routes.bottomNavPaths`. The two pairs are
  parallel by necessity (the router cannot depend on icons), and drift between
  them is exactly the bug above.
- The rail is `scrollable: true`. Eleven destinations do not fit a short window,
  and `NavigationRail` only scrolls its destination list when asked.
- The rail auto-collapses below `AppConstants.extendedRailBreakpoint` (1200) and
  a toggle overrides that for the session. Every destination stays reachable
  collapsed - only the labels go away.
- Mobile is unchanged, which means its drawer is still reachable only by edge
  swipe: there is no AppBar to carry a hamburger. The four bottom-bar
  destinations cover the phone flows, so this is accepted rather than fixed.