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

---

## D-019 — Editing an Ordered Purchase Reverts to Draft When Lines Change

**Date:** 2026-09-18
**Status:** Active

**Decision:** `updateDraft` reverts `status` to `draft` only when line items
change (product, qty, free qty, rate, mrp, discount, GST, batch, expiry).
Metadata-only edits (notes, invoice number, invoice date) preserve the current
status.

**Rationale:** An `ordered` purchase has been sent to the supplier. If lines
change, the supplier's confirmed order is stale and needs re-confirmation.
Metadata changes do not invalidate the order.

**Consequences:**

- UI must surface the revert with a clear message. If the user wants to cancel
  an order entirely, `setStatus` is the explicit path. `PurchaseFormScreen`
  raises a SnackBar ("Order returned to draft because lines changed — review and
  re-confirm") when the status of the document it wrote differs from the one it
  loaded, so it reports what actually happened rather than predicting it.
- The rule lives in `PurchasesRepository.statusAfterEdit` and
  `PurchasesRepository.linesDiffer`, both pure and public, so it is unit-tested
  without a client and the test fake calls the *same* function the real write
  applies.
- The comparison is a **multiset** of per-line signatures, not an ordered list.
  `purchase_items.created_at` is a transaction timestamp: rows written in one
  statement share it, so the order a read returns them in is not the order they
  were written in, and an order-sensitive comparison would revert a document
  nobody had touched.
- Fields are compared at the precision their column stores (`numeric(12,2)`), so
  a difference the database would round away is not a revert.
- `selling_rate`, `product_name_raw` and `hsn_code` are deliberately **not**
  compared: the first is the pharmacy's own counter price and the others
  describe the invoice as printed, so none of them says anything about what was
  asked of the supplier.
- The document header (supplier, invoice number, invoice date, notes) is not
  compared either, so changing the supplier on an ordered document keeps it
  ordered. That follows the rule as written above, which is about line items;
  it is recorded here so it is a decision rather than an oversight.
- Supersedes the unconditional `status = 'draft'` write this replaced, which
  returned an `ordered` document to draft silently on any edit (PROGRESS.md
  P-1 / chat2b O-1).

---

## D-020 — A Purchase Return Credits a Slice of the Invoice Line

**Date:** 2026-09-18
**Status:** Active

**Decision:** A purchase return line's `tax_amount` and `total_amount` are the
proportional share - by returned quantity - of the purchase line's **stored**
`tax_amount` and `total_amount`, not a figure recomputed from
`qty x purchase_rate`. Implemented in
`features/returns/data/purchase_return_totals.dart`; the header's `sub_total`,
`tax_total` and `grand_total` are the sums of those lines.

**Rationale:** `purchase_return_items` has no `discount_percent` column, so
recomputing would credit the supplier the list price of goods they had already
discounted: ten units at 100 with a 10% discount cost 900, and returning four of
them is 360, not 400. Scaling the stored amounts also keeps a return equal to a
slice of what the invoice says, which is what a credit note has to reconcile
against, and it inherits the receipt's own rounding.

**Consequences:**

- The client sends only `(purchaseItemId -> qty)` in
  `PurchaseReturnsRepository.create`; the amounts, the supplier and the batch all
  come from the invoice line, so a stale or hostile form cannot enlarge a credit.
- `PurchaseTotals.round2` is public for the same reason: one rounding rule in the
  money path, shared by the purchase and the return.
- How much of a line may go back is `min(billed - already returned, on hand in the
  batch)`. "Already returned" is summed from this purchase's returns by
  `purchase_item_id`, because a batch balance alone would allow the same units to
  be credited twice - a batch can hold stock from more than one receipt.
- The batch balance is still the hard limit: `stock_update_on_purchase_return()`
  raises `check_violation` rather than overselling, and that error is surfaced
  verbatim (`mapPostgrestException` keeps the database's message for `23514`).
- Outbound movements change quantity only. The units left in the batch keep the
  batch's cost basis (D-012) - that is correct for a write-off, so do not "fix"
  it.
- A sale return (Phase 3) has the same question to answer and should answer it
  the same way, from the sale line's stored amounts rather than from the rate.

---

## D-021 — Inventory Reads the Views Directly; the Expiry Value Is MRP, Not Cost

**Date:** 2026-09-18
**Status:** Active

**Decision:** The inventory module adds **no migration**. It reads
`product_stock` and `batch_status` as they are, and:

- the stock list shows the view's own `total_qty` and `stock_value_at_cost`
  (so the valuation keeps landed cost, D-012);
- an expiring batch shows units and value **at MRP**, not at cost;
- the low-stock comparison `total_qty < min_stock_level` happens in Dart, over
  rows the server has already narrowed to `min_stock_level > 0`.

**Rationale:**

- `batch_status` is `select b.*` from `product_batches` **as that view was
  created**, and `landed_cost_per_unit` was added to the table afterwards
  (migration 00016) - so the view does not carry it. Showing a cost per expiring
  batch would need a new migration, and the obvious substitute
  (`qty x purchase_rate`) is exactly the overstatement D-011/D-012 exist to
  prevent on scheme stock. MRP is the one figure on the row that needs no cost
  basis, and it is what `product_stock.stock_value_at_mrp` already means.
- PostgREST cannot compare two columns, so `total_qty < min_stock_level` cannot be
  a server-side filter. The candidate set is narrowed server-side to products
  that *have* a reorder level - a threshold is set by hand, per product - and the
  comparison runs in Dart. The bound is `InventoryRepository.lowStockScanLimit`
  (500 candidates), the same trade-off `supplierOptionsLimit` makes; see PROGRESS
  item I-1 for the migration that would remove it.

**Consequences:**

- Inventory has two repositories reading two views, split by question rather
  than by table: `ProductsRepository` answers "what about *this* product"
  (`batchesFor`, `stockFor`) for the product detail screen, and
  `InventoryRepository` answers "what about the whole pharmacy".
- `ExpiryBadge` moved to `core/widgets/expiry_badge.dart` when the second screen
  needed it, so both agree on which bucket is urgent.
- Stock adjustments are batch-scoped: `stock_adjustments.batch_id` stays nullable
  in the schema, but nothing in the app writes a product-level row, because such a
  row records a correction that moves no stock.
- The four providers a batch balance feeds are invalidated in one place,
  `StockAdjustmentController._refreshStockReaders`. A future write that moves
  stock (a sale) must invalidate the same set.

---

## D-022 — A Screen That Is Not a Shell Destination Nests Under the One That Owns It

**Date:** 2026-09-19
**Status:** Active

**Decision:** Expenses lives at `/reports/expenses`, not at a top-level
`/expenses`. A screen reached from a destination it belongs to takes that
destination's prefix as its path, whether or not it is declared as a nested
`GoRoute`.

**Rationale:** `DashboardShell` decides which destination is lit by prefix
(`_belongsTo(path, destination)` is `path == destination ||
path.startsWith('$destination/')`). Every path in the app matched a destination
until now, so `/expenses` would have been the first that matched none — and the
fallback is index 0, which means the rail and the bottom bar would have sat on
"Dashboard" while the user was reading their expenses. The alternative was a
twelfth destination in the rail, which the shell has no room for and this screen
does not warrant (it is reached from the summary it feeds).

**Consequences:**

- The nested path is a routing convention, not an ownership claim: the expense
  screen belongs to the expenses feature, and only its URL sits under `/reports`.
  `/inventory/calendar` set this precedent and is declared the same way — as a
  sibling `GoRoute` right after its parent, whose comment says why.
- A new screen that hangs off an existing destination must take that prefix, or
  the shell has to learn about it. A top-level path is only correct for something
  that deserves its own destination (`Routes.shellPaths` and
  `DashboardShell.destinationPaths` have to stay parallel — see D-018).
- `Routes.expenses` is the constant callers use; no screen spells the path out.

---

## D-023 — A Sale Is One RPC and Its Stock Posts Per Line

**Date:** 2026-09-19
**Status:** Active

**Decision:** A sale is written only through `checkout_sale(jsonb)`
(migration 20260918000019), which creates the header, its lines and its
invoice number in one transaction. Stock moves from a trigger on
`sale_items` (`stock_update_on_sale()`), per line, gated on the parent sale not
being cancelled — not on a status change, and never from the client.

**Rationale:** PostgREST writes one statement at a time, so a header-then-lines
write can be refused halfway: the header would already have posted a receivable,
and a partial set of lines would have taken some units from stock and not others.
`product_batches.qty` is the single running balance, so a partial post is a
silently wrong number rather than a failed write. A purchase has a `draft` life
to gate on (`purchases.stock_posted_at`, D-013); a sale does not — `sale_status`
has no draft, so the lines are the only event and the once-only guarantee is
structural: the app inserts a sale's lines exactly once and has no update path
for them.

**Consequences:**

- A sale with **no customer** posts no ledger row. `ledger_entries_party_check`
  requires a party, and a walk-in pays at the counter and owes nothing.
- A **credit** sale posts its receivable when it is written, not when it is
  settled: the ledger gate is "not cancelled", not "is completed".
- An overpayment is refused (`sales_payment_check`, migration 00020). The change
  a cashier hands back is not a payment, so `amount_paid` may not exceed
  `grand_total` and `balance_due` may never go negative.
- A sale that needs the balance carried must name a customer;
  `SaleCheckoutController` refuses one that does not, before the write.
- **Corrections are returns, not edits.** Deleting a sale line does not put the
  units back — `write_audit_log()` records the deletion, and the correction path
  is a sale return (with `restock`) or a stock adjustment. Cancelling a sale that
  already moved stock does not reverse it, the same one-way contract D-013
  established for purchases.
- Anything that moves stock must refresh the same four readers; that rule is now
  one shared function, `refreshStockReaders` in
  `features/inventory/application/stock_readers.dart`, called by the stock
  adjustment, the sale checkout, the sale return and the purchase return. A new
  write that moves stock calls it rather than re-listing the providers.
- Verified by `supabase/tests/phase3_sale_triggers.sql`.

---

## D-024 — A Payment and Its Ledger Row Are One Transaction

**Date:** 2026-09-19
**Status:** Active

**Decision:** Recording a payment is `record_payment(...)`
(migration 20260918000020), which writes the `payments` row and its
`ledger_entries` row (`reference_type = 'payment'`) in one transaction, taking
the tenant from `get_my_pharmacy_id()` and refusing a party from another tenant.
The direction is the function's business: a supplier payment debits, a customer
payment credits.

**Rationale:** Two inserts cannot agree by convention. A payment that recorded the
cash and failed to post its ledger row would leave a party looking in debt after
they had paid — a wrong balance that nothing on screen could explain, in the one
table a pharmacy reconciles against.

**Consequences:**

- `LedgerRepository.recordPayment` sends parameters and nothing else; it does not
  write two rows and hope. The same reasoning is why the purchase return's credit
  note is posted by `ledger_auto_entry_purchase_return()`, a trigger on
  `purchase_returns`, rather than by a second client statement: the credit note
  and the ledger entry it produces are one event.
- The payment sheet is a modal sheet, not a route: `showPaymentSheet(...)` from
  the ledger screen's "Record payment" button, over `PaymentController`. The
  sheet resolves to whether anything was written, and the caller reloads its own
  reads — which is what keeps the dependency one way (the supplier and customer
  detail screens open it too, without the ledger feature knowing about them).
- `party_balances` is still read by paging `ledger_entries` in
  `LedgerRepository.balanceFor`; a server-side aggregate is the improvement
  `report_summary()` made for reporting and could make here.

---

## D-025 — A Report Is One Server-Side Aggregate, Never Rows Summed in Dart

**Date:** 2026-09-19
**Status:** Active

**Decision:** The reports screen reads `report_summary(p_from, p_to)`
(migration 20260918000021), one `security definer` RPC returning every figure it
shows as a single `jsonb` object. The window is an inclusive date range; presets
(today, this month, last month, this quarter, this year) are computed in
`features/reports/application/reports_controller.dart` and are the only place the
calendar arithmetic lives.

**Rationale:** PostgREST cannot `sum()`, so every total would otherwise be a page
of rows summed in Dart — bounded by `max_rows` (1000) and therefore silently
short of the truth in a busy month. A financial report that is wrong in a
plausible-looking way is worse than one that is slow. One function rather than
six queries is the other half of it: a report whose parts were read at different
moments can disagree with itself (a sale rung up between two reads lands in one
figure and not the other), and a report nobody trusts is worse than no report.

**Consequences:**

- New report figures belong in `report_summary()` (a migration — the function is
  `create or replace`), not in a repository method that sums rows.
- The pharmacy is not an argument: the function takes it from the caller's
  identity, so a crafted parameter cannot read another tenant's numbers (D-004's
  rule for RPCs, and the reason it is `security definer`).
- The screen never assembles a figure. `ReportSummary` (plain classes, not
  Freezed: it is an RPC envelope, and no migration owns its shape) decodes the
  numbers exactly once, tolerating a `numeric` that arrives as a string.
- The figures are honest about what they are: `contributedMargin` is billed less
  refunds less expenses, and the screen labels it "Not a profit" with the reason —
  it knows what was sold and what was spent, and nothing about what those goods
  cost, which arrived on invoices rather than on bills. Gross margin needs the
  cost of each sale line, which is a future migration.
- The expense write invalidates the summary as well as its own list
  (`ExpenseFormController.createExpense`), because an expense moves the window it
  was recorded in.
- Verified by `supabase/tests/phase4_report_summary.sql`.

---

## D-026 — The Chatbot Answers Through RPCs, Never Free-Form SQL

**Date:** 2026-09-19

**Status:** Active

**Decision:** `chat-sql-agent` (Phase 5, Chunk E) does not generate SQL. The model
classifies the question and extracts parameters; the answer comes from parameterised
RPCs — `report_summary()` as it stands, plus four new ones the chatbot needs
(`low_stock_products`, `expiring_batches`, `top_products`, `dead_stock`). Each is
`security definer`, takes the tenant from `get_my_pharmacy_id()` rather than from an
argument, and returns a `jsonb` envelope, the way `report_summary()` does (D-025).

**Rationale:** A model that emits SQL against the caller's JWT is a prompt-injection
runtime. Four separate reasons, any one of which is sufficient:

- **Prompt injection.** The question text is user input, and the reply is a
  statement. A pharmacy's own invoice text and product names are also attacker-
  influenced input on the OCR path — an invoice line reading `'; drop …` should be
  data everywhere, and in a whitelisted-RPC design it cannot be anything else.
- **`security definer` escapes.** Every RPC in this schema runs with the owner's
  rights. A generated statement is one more edge to reach a definer function from,
  with arguments the model chose.
- **Denial of service.** A conversational loop can be made to run an expensive query
  repeatedly; a fixed RPC set has a fixed cost.
- **Answer inconsistency.** The same question answered from two different generated
  statements in two sessions is two answers, and a chatbot nobody can rely on is
  worse than no chatbot.

**Consequences:**

- The set of questions the chatbot can answer equals the set of RPCs, so a new
  question is a migration, reviewed like any other. That is the intended cost.
- The four RPCs are the aggregates the reports screens want too, so they are not
  chatbot-only work. `low_stock_products` in particular is the server-side fix for
  **I-1** (the low-stock list currently compares `total_qty < min_stock_level` in
  Dart over at most 500 candidates).
- Every figure in an answer comes from the database, never from the model — the
  model's job is to pick an RPC, fill its parameters, and phrase what came back.
- A question that maps to no RPC is answered with "I cannot answer that" rather
  than with a guess. The model is never asked for a number it did not receive.

---

## D-027 — The Embedding Is a pgvector Column the Client Never Selects

**Date:** 2026-09-19

**Status:** Active

**Decision:** `products.embedding` is `extensions.vector(768)` (migration 00022):
Gemini's `gemini-embedding-001` at 768 dimensions, indexed with HNSW over cosine
distance and partial on `embedding is not null`. Every `products` read in the app
sends an explicit projection — `ProductsRepository.projection`, built from
`ProductsRepository.columns` — instead of PostgREST's default `*`.

**Rationale:** Three parts, in order of permanence:

- **768 dimensions** is ample for a catalogue of a few thousand SKUs and half the
  row and index width of 1536. The dimension is a hard schema constant: changing it
  later is a new column, a re-embed of the whole catalogue and a reindex.
- **The partial index** holds only rows that can participate in a match, which is
  what the backfill needs while it is catching up — `embedding is null` is the
  backfill's work list, so it needs no separate marker column.
- **`select=*` would be a payload regression.** A 768-float column serialised to
  JSON is roughly 8 kB per row, and it would ride along on the product list, the
  product detail and every picker that names a product, on the busiest screens in
  the app, for data no screen displays.

**Consequences:**

- A rejected alternative, recorded because it is the better-looking one: hiding the
  column from `authenticated` with column-level SELECT grants, the way D-017
  protects `profiles.role`. It is more robust in principle (it constrains every
  future client, including an Edge Function) and machine-checkable in the SQL test.
  It was not taken because it rests on two behaviours that cannot be verified on
  this host without Docker: that PostgREST expands `*` to exactly the granted
  columns, and that `count(*)` still works for a role holding only column-level
  SELECT. An unverifiable change on the critical master-data read path is a worse
  trade than a payload that is merely too large. If this is revisited, revisit it
  with a live REST call in hand.
- The cost of the choice is a list somebody has to maintain.
  `test/features/products/data/products_repository_columns_test.dart` keeps it in
  step with what `Product` decodes: adding a column to the model and not to the
  projection fails there rather than at runtime against the database.
- Nothing in the app reads this column, and nothing in the app should. The
  matching and backfill functions read and write it server-side, which is also why
  D-026's RPCs are where a vector search will live.
- The embedding's **input text** (name only, or name plus generic name and pack
  size) is a Chunk C decision, not this one — but it must be one convention for
  both the backfill and the live match, because two conventions produce vectors
  that are not comparable.
- Verified by `supabase/tests/phase5_ai_notifications.sql` (the type, the
  dimension's enforcement by a 769-dimension refusal, and the index's method and
  partial predicate).

---

## D-028 — OCR Bills Live in a Private, Path-Scoped Storage Bucket

**Date:** 2026-09-19

**Status:** Active

**Decision:** Supplier bill images are uploaded to the private `purchase-bills`
bucket under `<pharmacy_id>/<year>/<file>`, with four policies on `storage.objects`
(SELECT, INSERT, UPDATE, DELETE for `authenticated`) comparing the object's first
path segment with `get_my_pharmacy_id()`. The bucket caps uploads at 10 MB and
allows `image/jpeg`, `image/png`, `image/webp` and `application/pdf`.

**Rationale:** OCR needs bytes that both the tablet and the Edge Function can reach,
and the function runs with the caller's JWT (D-004) — so a stored object has to be
readable under the same tenant rule as every table. The tenant in the path is what
makes that expressible as a single predicate, and keeps the rule in the same place
as every other rule: the database. The size cap and the mime list are the bucket's
own guard, so an oversized photo is refused at upload rather than by a function
timeout half-way through a request.

**Consequences:**

- The bucket is created by the migration (`insert into storage.buckets …`) and not
  by `config.toml`: a `[storage.buckets.*]` block only seeds a local stack, and this
  project runs none (D-003).
- No `anon` policy. A bill image requires a signed-in member of that tenant, which
  is why the bucket is private rather than public-with-a-hard-to-guess-path.
- The Edge Function must not *trust* a path it is handed: it reads the object with
  the caller's JWT, so a path outside the tenant simply does not resolve. The
  matching and OCR functions therefore take a path and re-derive its tenant, rather
  than taking a URL.
- A feature that needs a bill outside a signed-in session (a link for a supplier, a
  public URL) is a signed-URL decision, not a relaxation of this policy.

---

## D-029 — Push Is Deferred to Phase 6; Phase 5 Stores Tokens and Dispatches Over WhatsApp/Email

**Date:** 2026-09-19

**Status:** Active

**Decision:** Phase 5 registers device tokens in `device_tokens` and dispatches
through `send-notification` over WhatsApp (Cloud API) and email (SendGrid), writing
`notification_logs` for every attempt. No FCM SDK is added in Phase 5: the Firebase
project, the web service worker and the platform credentials are Phase 6 work, which
owns deployment. `NotificationService.getFcmToken()` returns `null` until then.

**Rationale:** FCM on the web needs a Firebase project, a service-worker scope and a
VAPID key before it needs a single line of application code, and all three have to
be registered against a deploy target that does not exist yet. The parts a pharmacy
uses in the meantime — an in-app notification list, a low-stock or expiry alert, a
bill sent over WhatsApp — do not depend on push at all. Building push first would
mean a dependency and a set of credentials chasing a deployment decision.

**Consequences:**

- `device_tokens` stays empty in production until Phase 6 wires registration. The
  table, the `device_platform` enum and `notification_logs.channel = 'push'` all
  exist now, so nothing has to be reinterpreted when it arrives.
- `NotificationService`'s three-method surface stays as it is: `getFcmToken()`
  returns `null`, and Chunk D decides what `init()` and `showLocal()` mean without a
  push SDK (the in-app list is the surface that carries the message either way).
- Phase 6's checklist gains: `firebase_core`/`firebase_messaging` (or the JS SDK and
  a service worker for web), a VAPID key, and the registration call that fills
  `device_tokens`.
- The dispatch log is written for every channel from the start, so an operator
  auditing "did we tell this supplier" gets the same answer before and after push
  exists.

---

## D-030 — The Vision Model Is Named in Code, and a Model Change Is Verified Live

**Date:** 2026-09-19

**Status:** Active

**Decision:** The bill reader asks `gemini-3.6-flash`, named as
`DEFAULT_VISION_MODEL` in `supabase/functions/ocr-purchase-bill/gemini.ts`, with
`GEMINI_VISION_MODEL` as an optional function secret that overrides it without a
redeploy. A model change is made by someone editing that constant (or setting that
secret) *and* running one live invocation, because the model's own answer is the
only thing that proves a name still works.

**Rationale:** The name was not chosen from documentation — the first deployed
invocation returned

```
404 ... "This model models/gemini-2.5-flash is no longer available to new users.
Please update your code to use models/gemini-3.6-flash for the latest features"
```

so the API named its own successor, and a live call is what verified it. Model
names rot quietly and in one direction: `gemini-2.5-flash` still *lists* under
`GET /v1beta/models` while answering 404 to `generateContent`, so a name that
looks available is not the same as a name that works.

**Consequences:**

- The request shape that this model accepts is now a tested fact, not an
  assumption: `responseSchema` in the **older dialect** (uppercase `OBJECT`,
  `nullable: true`) works, `responseJsonSchema` (standard JSON Schema) does not
  answer reliably, `inlineData` accepts both `image/png` and `application/pdf`,
  and `maxOutputTokens` must be set generously because this family's *thinking*
  shares the output budget.
- A model swap is one string plus one live call. That is the point of keeping the
  name in code rather than in a table.
- Verified live at the end of Chunk B1: a synthetic three-line invoice parsed with
  every header field, every line, and `DD/MM/YYYY` dates converted to ISO, with
  `warnings: []` and `finish_reason: STOP`.

---

## D-031 — An Edge Function May Not Depend on Recent JavaScript Built-ins

**Date:** 2026-09-19

**Status:** Active

**Decision:** Code under `supabase/functions/` uses only language-core JavaScript,
and anything that needs a newer convenience lives in `_shared/` written by hand and
tested with plain `deno test`. The first instance is base64:
`_shared/base64.ts` rather than `Uint8Array#toBase64`.

**Rationale:** `Uint8Array#toBase64` is a TC39 *proposal*, and the deployed edge
runtime does not have it. Nothing local could have caught that:

- `deno check` passed, because the *type* exists in Deno 2.9's libraries.
- The 45 Deno tests passed, because they run on the local Deno.
- So the first invocation of the deployed function answered `500` — my handler's
  generic "something went wrong" — and there was no log to read (this CLI has no
  `functions logs`, and there is no container to serve locally).

The cost was three deploys and a bisect through the deployed function (a foreign
path → 403, a missing object → 404, which narrowed it to the one step between the
download and the model call). Twelve lines of hand-written arithmetic would have
avoided all of it, and a table of one byte's worth of propositions is not worth
that bill.

**Consequences:**

- The rule is about the *runtime's* feature set, not about style: a built-in that
  arrived with the proposal stage must not be load-bearing in a function.
- The `_shared/base64.ts` encoder is tested against `atob` for every remainder
  length, so a padding mistake cannot survive.
- Debugging a deployed function without logs is an established, disclosable
  practice here: a **temporary** `detail` on the function's internal error, one
  deploy, one invocation, then removed and redeployed. It was used once, in this
  chunk, and the repository does not carry it.
- Anything a function cannot express without a new built-in should be considered a
  candidate for SQL (D-026's answer, one layer down): the database's feature set is
  the one this project can actually pin.

---

## D-032 — The Bill Reader Does Not Retry, Because the Key Is on a Free Tier

**Date:** 2026-09-19

**Status:** Active

**Decision:** `ocr-purchase-bill` makes **one** attempt per request and reports a
retryable failure as `provider_unavailable` with the provider's own words. There is
no internal retry, no backoff and no queue.

**Rationale:** The project's Gemini key is on the free tier, measured during Chunk
B1 at **five requests per minute** (`generate_content_free_tier_requests, limit:
5`). Under a burst the API does not answer `429`; it answers
`503 UNAVAILABLE — "This model is currently experiencing high demand"`, which is
indistinguishable from a real outage except by the quota metric beside it. An
internal retry against a quota already spent turns one refused read into two
refused reads *and* hides the constraint from the person who can fix it (who sees
only a slower failure). Letting the user retry deliberately is both cheaper and
more honest, and the message they see says the reader is busy rather than that
their bill is unreadable.

**Consequences:**

- The app must present this failure as **retryable** and distinct from "this bill
  could not be read" — a bill the reader never saw is not a bill it could not
  understand.
- Whether to keep the free tier is a plan decision, not a code decision. Before
  Phase 5's OCR flow meets a real counter, either the key moves to a paid tier or
  a deliberate retry-once policy is added *with* a visible "waiting" state. Recorded
  as open item **N-2**; a busy counter will meet 5/minute on its own.
- The distinction is carried in the envelope, not guessed: `finish_reason` and the
  provider's status both travel with the answer, so a screen can say which kind of
  failure it is looking at.

---

## D-033 — The Retry Lives in the App, With a Visible Wait

**Date:** 2026-09-19

**Status:** Active

**Decision:** The function still makes one attempt (D-032). The **app** retries
once: `PurchaseOcrController` reads the bill again after
`ocrRetryDelayProvider` (3 seconds) and says it is doing so — `isRetrying` is part
of its state, distinct from "busy", so the screen can show *"the reader is busy —
retrying…"* rather than a bare spinner. `isRetryableOcrError` is the single place
that decides what deserves a second attempt: the code `provider_unavailable`
(the free-tier `503`) or `unreachable` (nothing came back at all). A retry re-reads
the object already in the bucket; it never uploads a second copy.

**Rationale:** D-032 left this open on purpose — "either the key moves to a paid
tier or a deliberate retry-once policy is added *with* a visible waiting state" —
and this is that choice, made in the client because the client is where a wait can
be *explained*. A user who sees nothing retries by tapping, which is the one thing
a five-requests-a-minute budget cannot afford; a user who is told to wait is a user
who waits. Two attempts, not more: the budget is per minute, so a third attempt
inside the same minute buys another wait and nothing else.

**Consequences:**

- The failure that survives the retry is presented as **retryable** — "the reader
  is busy, try again in a moment" — and never as "that bill could not be read".
  Those are different claims about the same bill, and only one of them is true.
- A manual retry is `rescan()`: the same object, read again, no second upload.
- The wait is a provider rather than a constant, so tests assert the *behaviour*
  (one retry, visible, then a retryable error) without spending real seconds.
- A third failure mode is now distinct too: an answer cut short
  (`finish_reason != STOP`) is not a failure at all — it is a partial read with a
  warning attached, which the verify screen shows.
- **A first read that fails still leaves the bill uploaded.** `OcrScan.bill` is
  nullable for exactly this: the upload is what puts the object in the bucket, so
  the scan exists from that moment even when nothing was read from it. Without
  that, "read it again" after a failed first read would have had no path to read
  and would have had to upload a second copy — the case this decision's own
  wording rules out. `PurchaseOcrState.hasBill` (nothing read yet) is therefore
  distinct from `hasScan` (nothing uploaded yet), and the screen shows the two as
  different situations with different retries.

---

## D-035 — A Platform Capability the App Cannot Fake Gets a Seam

**Date:** 2026-09-19

**Status:** Active

**Decision:** Choosing a bill goes through `BillPicker` and
`billPickerProvider` (`features/purchase_ocr/data/bill_picker.dart`), whose real
implementation wraps `image_picker` and whose `PickedBill` carries `bytes`,
`mimeType` and `fileName` — not `image_picker`'s `XFile`.

**Rationale:** `ImagePicker` is a concrete class that talks to a platform channel,
so a widget test cannot drive it, and a screen that called it directly would be a
screen whose pick path could only be tested by hand. `XFile` cannot be constructed
either, which is why `PickedBill` exists: a test hands the fake a real 1×1 PNG's
bytes, and the screen renders them for the same reason it would render a photo.

The rules that were tempting to put in the widget went to where the rest of the
feature's rules live: `PurchaseOcrController.pickBill` types an untyped file from
its name (`XFile.mimeType` is null off the browser) and refuses a file the bucket
would refuse *before* the round trip, using `PurchaseOcrRepository.validatePick` —
the same rule the write enforces. The widget's job is one line: ask the seam.

**Consequences:**

- Chunk D's push token and permission prompts, and Phase 6's printing, have the
  same shape waiting for them: an interface in the feature that needs it, a
  Riverpod provider, a fake in `test/support/`, and every rule above the seam.
- `test/support/fake_bill_picker.dart` carries a real PNG rather than filler
  bytes, because `Image.memory` on non-image bytes fails the widget tree with a
  decode error that has nothing to do with the test's subject. The verify screen
  still has an `errorBuilder`, so a file the platform cannot decode is a sentence
  rather than a crash.
- A seam is only worth it where the platform is otherwise unreachable. Wrapping
  something the app can already construct and compare in a test would be ceremony,
  not testability.

---

## D-034 — A Controller Checks `ref.mounted` After an Await Before Writing State

**Date:** 2026-09-19

**Status:** Active

**Decision:** A Riverpod controller that awaits and then assigns `state` checks
`ref.mounted` first, and returns when it is false.

**Rationale:** Riverpod 3 disposes a provider that has no listeners, and a screen
that navigates away stops being a listener — so a write after an await can land on
a disposed provider. It surfaced while testing the OCR controller, as

```
Cannot use the Ref of purchaseOcrControllerProvider after it has been disposed.
  ... check `ref.mounted` after async gaps or anything that could invalidate the provider.
```

and the production shape of it is ordinary: pick a bill, change your mind about the
screen while the upload is in flight, and the app throws from a future nobody is
awaiting. The guard is one line, and it is the difference between a discarded
result and an unhandled error.

**Consequences:**

- The guard sits after **every** await, not only the last one. In the OCR
  controller's retry loop that also means a screen that has gone away does not
  spend a second call from a shared quota on an answer nobody will see.
- Tests that drive a controller directly must keep it alive the way a screen does
  — `container.listen(provider, (_, __) {})` — otherwise they measure disposal
  rather than behaviour. `purchase_ocr_controller_test.dart` does this in its
  container helper, and has one test that deliberately does *not*, to pin the
  guard.
- The same pattern exists in `PurchaseFormController` and `GrnController` (await,
  then write): their tests pass because a screen watches them throughout. They
  were not changed here — recording it so the next person to touch a controller
  does not have to rediscover it.

---

## D-036 — The Match Is One RPC, Ranked by Score, With the Leg as Attribution

**Date:** 2026-09-19

**Status:** Active

**Decision:** Matching invoice text to the catalogue is `match_products(p_queries
jsonb, p_limit int)` (migration 20260919000023): one `stable security definer` RPC
that takes a whole bill's lines in one call and returns ranked candidates per line,
each carrying `reason` and the evidence behind it. Three legs — alias (1.0, a human
confirmed it), trigram, and vector cosine over `products.embedding` — are merged
per product, and **the ranking is by score, with the leg only an ordered tiebreak**
(0 supplier-scoped alias, 1 pharmacy-wide alias, 2 trigram, 3 vector). Two
thresholds are constants in the function and both were measured, not inherited:
**trigram ≥ 0.35** and **vector cosine ≥ 0.7**.

**Rationale:** Three parts, each from a measurement on the live project rather than
from intuition:

- **Trigram cannot be a priority over the vector leg.** `Dolo 650` scores **0.4545**
  against the invoice text `Dolo650Tab15s` and the wrong sibling `Dolo 500` scores
  **0.4444** — a 0.01 margin, which is a coin toss rather than a ranking. The vector
  leg is the thing that tells those two apart, and under a leg-priority ordering a
  0.45 trigram hit would have outranked every vector hit — the exact case the leg
  exists for. So the score decides and the leg explains.
- **The trigram threshold cannot be pg_trgm's own 0.3 default, and the obvious
  comparison is the wrong one.** `similarity('Dolo650Tab15s', 'Dolo 650')` is
  **0.278** — *below* the default — while `word_similarity('Dolo 650',
  'Dolo650Tab15s')` is **0.455** and `similarity('AMOXYCLAV 625 10S','Amoxyclav
  625')` is **0.778**. The score is therefore the best of the name, the generic name
  and the reversed `word_similarity`, at 0.35, which keeps `Dolo 650` and refuses
  junk (0.000).
- **Ranking and matching belong in SQL, and the pharmacy is not an argument**
  (D-004/D-026). A `security definer` function is not subject to RLS, so every query
  in it carries `pharmacy_id = get_my_pharmacy_id()` explicitly — the SQL test puts
  a second tenant's identically named, identically embedded product in reach and
  asserts it never appears.

**Consequences:**

- **An alias learned for one supplier does not answer the same printed text on
  another supplier's bill.** The alias leg accepts a supplier-scoped row for *this*
  supplier or a pharmacy-wide row (`supplier_id is null`). Two distributors
  abbreviate differently, and a mapping learned from one is not evidence about the
  other; what crosses suppliers is an alias recorded with no supplier. When the same
  text arrives for a different supplier, the pharmacy-wide alias answers if there is
  one and the text is otherwise read by trigram and vector.
- **An embedding failure never fails a bill.** `match-product` degrades to alias and
  trigram, says so in `meta.warnings`, and answers 200: the vector leg adds
  candidates, and a matcher that returns an error page because the free-tier key is
  busy (N-2) would be worse than one that suggests less for a moment.
- **The vector leg only answers what the backfill has embedded**, and a candidate
  below the floor is not a suggestion at all. Both are asserted with synthetic
  768-dimension vectors (cosine 0.9987, 0.7071 and 0.5774 against a unit query) so
  the test does not depend on the backfill having run.
- **The 0.7 floor is provisional.** With no catalogue embedded yet there was nothing
  to measure it against — text embeddings put unrelated short strings around 0.6–0.75
  — so the backfill chunk re-tunes it against real vectors and records what it found.
  The trigram threshold, by contrast, was measured before it was written.
- **Candidates are built from named columns**, never `select *`: `products` carries
  the 768-float embedding, and the SQL test asserts no payload contains it (D-027).
  A deactivated product is never a candidate on any leg, including an exact name
  match, because a receipt must not create stock for a discontinued product. The SQL
  test's decoy is a deactivated product named *exactly* what the query says.
- **Cost, stated:** the trigram leg evaluates `similarity()` per row of the caller's
  catalogue, so its filter is not the `%` operator and the GIN trigram indexes do not
  serve it. The vector leg is written as `order by distance limit n` with the floor
  behind the limit, which is what lets the HNSW index from migration 00022 serve it;
  the two are equivalent because the floor is monotone in distance.
- Verified by `supabase/tests/phase5_match_products.sql` — 43 assertions, atomic and
  self-rolling-back, covering the three legs, the supplier precedence, tenant
  isolation, the payload's field list, the untrusted-input rules (a blank line keeps
  its place, a malformed supplier id is "no supplier", a malformed embedding is "no
  vector leg") and the function's own contract (`prosecdef`, `provolatile = 's'`,
  a pinned `search_path`, no pharmacy in the signature, EXECUTE for `authenticated`
  and not for `anon`).

---

## D-037 — The Embedding Convention Is a Database Function, and the Query Keeps Its Words

**Date:** 2026-09-19

**Status:** Active

**Decision:** The catalogue text embedded into `products.embedding` is built by
`product_embedding_text(name, generic_name, pack_size)` in the database — name, then
generic name, then pack size, whitespace collapsed, empty parts omitted, `null` for
a row with nothing to embed. The Edge Function asks for **`outputDimensionality:
768`** explicitly and uses `RETRIEVAL_DOCUMENT` for catalogue text and
`RETRIEVAL_QUERY` for an invoice line. The **query** text is the invoice text as
printed, whitespace-collapsed, and deliberately **not** `normalize_product_name()`.

**Rationale:** D-027 left the embedding's input text to this chunk and named the trap
precisely: two conventions produce vectors that are not comparable, and the symptom is
a matcher that ranks at random. The convention therefore lives where both users of it
can reach it — the backfill embeds what the function returns, and any later re-embed
of a catalogue row produces the same string by construction rather than by agreement.
Building it in Deno instead would be two codebases agreeing by convention, which is
what drifts.

The query side is the opposite decision for a reason: `normalize_product_name()`
exists to make two spellings *identical* for an exact alias comparison, and it does it
by deleting everything that is not a letter or a digit — `Dolo650Tab15s` becomes one
unbroken token, with the word boundaries the model reads gone. The vector leg's whole
purpose is to cope with a supplier's own abbreviation, so the query keeps the words and
only collapses whitespace.

**Consequences:**

- The dimension is a hard schema constant and is asked for per request: the model
  emits 3072 unless told otherwise, and a 3072-element reply is refused by the parser
  with a sentence naming both numbers rather than being silently dropped — a wrong
  width means the request was ignored and every vector in the batch is incomparable.
- A whole bill is embedded in **one** `batchEmbedContents` request, not one per line:
  the free tier allows five requests a minute on the key the reader also uses (N-2),
  and a twenty-line bill would otherwise spend twenty of them.
- `_shared/gemini.ts` holds the one way a function posts to the model, so two
  functions cannot describe the same provider failure in two dialects. It takes the
  API key as an argument rather than reading it, which keeps it free of the Supabase
  client and therefore testable with a stub `fetch` and no secret.
  `ocr-purchase-bill` was deliberately **not** refactored onto it: it is deployed and
  live-verified, and rewriting working wiring for tidiness risks a regression for no
  behaviour. It should adopt it when it is next touched for another reason.
- **The catalogue is still entirely unembedded** (`products.embedding is null` on
  every real row), so the vector leg answers nothing in production until the backfill
  runs. That is the next chunk, and `NULL` is its work list (D-027) — there is no
  separate marker column.
- Code under `supabase/functions/` stays language-core JavaScript (D-031).

---

## D-038 — CORS Is Emitted by the Platform on Every Path, and the Check Must Not Be Case-Sensitive

**Date:** 2026-09-19

**Status:** Active

**Decision:** The CORS headers stay exactly as `supabase/functions/_shared/response.ts`
already sets them — `access-control-allow-origin: *`, an allow-headers list of
`authorization, apikey, content-type, x-client-info, x-supabase-api-version`, `POST,
OPTIONS` and a day of max-age — emitted from the one `json()` helper that
`okJson`, `failJson` and `preflight` all build their responses with, so a success, a
refusal and a preflight cannot disagree. **No code was changed and neither function
was redeployed for this**: the reported defect (open item N-6, "a live function
response carries no `access-control-allow-origin`") does not exist. A CORS
verification on this platform must be **case-insensitive**, and the canonical check is

```
curl -s -D - -o nul -X POST "<functions url>/<name>" -H "Origin: http://localhost:3000" ... | findstr /I "access-control"
```

**Rationale:** The finding was a **measurement artifact of my own**, and the shape of
it is worth recording because it is a trap anyone would fall into: the deployed
gateway answers with `Access-Control-Allow-Origin` **capitalised** while passing the
other three headers through lowercased (they are the ones written in the function).
`findstr /C:` is case-sensitive, so a filter for the lowercase spelling printed the
three lowercase headers and silently hid the one header being looked for — which
reads exactly like "the platform strips it". Two full header dumps settle it, on both
functions and on every response path:

```
POST    match-product     {"lines":["Dolo 650"]}  -> 401  Access-Control-Allow-Origin: *
OPTIONS match-product     (preflight)             -> 204  Access-Control-Allow-Origin: *
POST    ocr-purchase-bill {"path":42}             -> 400  Access-Control-Allow-Origin: *
```

Each of those carries the header **exactly once** — the gateway replaces the
function's own copy rather than adding a second, which is the outcome that matters,
because a duplicated `Access-Control-Allow-Origin` is rejected by a browser while
looking perfectly healthy in a raw dump.

**Consequences:**

- **A reported CORS failure is not to be "fixed" by re-adding headers that are already
  there** — and it was not. Redeploying two working functions to change nothing would
  have put a false cause in the log and cost two deploy cycles; the honest repair for
  a false positive is the record.
- The 200 path could not be exercised live while C1 shipped, because a 200 needs a
  pharmacy-scoped session and a throwaway account cannot sign in on this project
  (N-7). It is covered structurally rather than empirically: `okJson` and `failJson`
  both call the same `json()` with the same header map, and `failJson` is measured
  live on both functions.
- The allow-headers list is deliberately **not** narrowed to the four names a minimal
  spec would suggest. `supabase-js` sends `x-client-info` and `x-supabase-api-version`
  on an `functions.invoke`, and a browser preflight that does not echo them refuses
  the request before it is sent — so the list is a client-compatibility surface, not a
  decoration.
- The last word is still a browser: when C2's screen first calls the matcher from
  Chrome, that run confirms it end to end. Until then the evidence is the three header
  dumps above.
- Generalise it: on this host, a negative result produced by a **filtered** command is
  not evidence until the filter has been re-run case-insensitively. Verified — the
  same class of error as reading a truncated output as a missing line.

---

## D-039 — The Suggestion Is Asked For Once Per Bill, When the Supplier Is Named, and It Never Blocks the Save

**Date:** 2026-09-19

**Status:** Active

**Decision:** The verify screen asks `match-product` **once per bill**, at the moment
the human names the supplier — not when the parse arrives, and not per line.
`PurchaseMatchController.matchBill` sends every line in the order the screen holds
them (a blank line included, so the answer stays aligned by position), keeps the
answer mapped to the line slot rather than to a position, and treats **every**
failure as "no suggestions this time, and here is why". Nothing is retried
automatically: the note carries a **Look again** action, so the choice to spend
another embedding request is a human's. `ProductPickerField` renders at most
`maxSuggestions` (3) of the ranked candidates, each with the reason it is offered,
and only while the line has no product; tapping one applies it through the same
path the search dialog uses. **A suggestion is offered, never applied** — nothing
is pre-filled, and a line nobody touches keeps no product.

**Rationale:** Three measurements and one rule, in order of weight:

- **The supplier scopes the alias leg, and the supplier is a human choice.** C1's
  matcher accepts a supplier-scoped alias only for *this* bill's supplier (D-036),
  and the reader delivers a supplier's *name*, not a supplier id — matching that
  text to the pharmacy's own supplier list is a human's job. So a match asked for
  at parse time could only ever use pharmacy-wide aliases, which is the one leg that
  makes a repeat bill from a supplier cheap. Asking after the choice is also what
  keeps it to one request per bill: asking at both points would embed the same lines
  twice.
- **A bill must be saveable while the answer is still out.** Twenty lines are one
  round trip, and the save never consults the matcher: the screen is fully live
  throughout, and a matcher that never answers cannot stop a receipt. A failure is
  therefore a sentence above the lines, never an error state the form blocks on.
  (The repository refuses a line with no product, so "saveable" means the human
  picked — by hand or by accepting a suggestion — not that the matcher answered.)
- **The reason has to be visible, so it is a pure function.** `MatchCandidate
  .reasonLabel` is *also called DOLO-650 TAB*, *87% similar*, or *looks similar* —
  three different claims about three different legs, asserted in a unit test rather
  than only by eye.
- **Three rows, not five.** The server's own limit is 5 (I-3); on a twenty-line bill
  that is a hundred rows of advice on the screen that already has the most to show,
  and the search dialog is one tap away for the rest.

**Consequences:**

- A bill whose supplier the user never names gets no suggestions at all, and the
  note says so rather than leaving the absence unexplained. That is deliberate: they
  cannot save the bill without naming a supplier anyway.
- A *changed* supplier clears the offers and asks again — the offers were ranked for
  another distributor — which is the one case that spends a second embedding
  request, and it takes a deliberate act.
- The `_VerifyFormState` re-seed defect found while building this is fixed with it:
  the form is keyed on the parse (`ValueKey(scan.bill)`), so a successful re-read
  replaces the lines *and* starts an unasked form. The consequence is that a
  re-read also drops the supplier choice, which is the right trade for a form whose
  every other field is replaced by the new parse.
- The RPC's answer is looked up **by position**, never by `raw_name`: the server
  trims that echo, so matching on it would shift every later line onto the previous
  line's candidates.
- Verified by `purchase_match_controller_test.dart` (one call per bill, alignment
  with a blank line in the middle, a failure that is not retried, nothing asked when
  no line has text, the `ref.mounted` guard) and by seven widget tests on the screen
  (the ask waits for the supplier, tapping a candidate fills the line, a bill saves
  with the matcher held open, a failed match still saves, the server's warnings are
  shown, the learning payload, a failed learning write, and the second read).

---

## D-040 — Alias Learning Is One Best-Effort Write Per Bill, of the Text the Bill Printed

**Date:** 2026-09-19

**Status:** Active

**Decision:** At save — after `createPurchase` returns and before navigating — the
verify screen sends **one** `learn_product_aliases(jsonb)` call for the bill
(migration 20260919000024), carrying `{raw_name, product_id, supplier_id}` for every
line where the reader printed text **and** a human chose a product. The text is the
one the reader saw, held per line slot; `normalize_product_name()` runs **server-
side**, never in Dart. A failure is swallowed: the purchase is already saved, and
what is lost is only the next bill's head start. `ProductsRepository.addAlias` and
the `product_aliases` unique index are untouched (N-5 stays open).

**Rationale:** Only a human's choice is evidence — a suggestion that was not accepted
teaches nothing, and a line the reader printed but nobody matched teaches nothing
either — so learning happens once, where the choices are final, rather than at every
pick. It is one call rather than one per line for `match_products`' reason: a
twenty-line bill is one round trip, and the alternative is twenty ways to half-teach
a supplier's abbreviations.

**Consequences:**

- A **supplier-scoped** alias is the normal case (the bill names its supplier), and it
  does *not* answer the same printed text on another distributor's bill — two
  suppliers abbreviate differently, and what crosses suppliers is a pharmacy-wide
  row. The function treats a supplier id that is not this pharmacy's as "no supplier"
  and writes that pharmacy-wide row rather than refusing the line.
- The draft's `product_name_raw` keeps its existing behaviour (a pick overwrites it
  with the catalogue's own spelling, which is what the field then displays), which is
  exactly why the printed text is held on the line slot instead: a catalogue name is
  not what the next bill will print.
- The function is `security definer` with a pinned `search_path`, scopes every
  statement by `get_my_pharmacy_id()`, and treats every entry as untrusted: a blank or
  punctuation-only text, a product id that is not a uuid or not in this catalogue, and
  an entry that is not an object are **skipped with a reason** rather than raising. A
  bill that cannot teach is not a failure.
- Where `supplier_id` is null the write is an explicit update-then-insert, because the
  unique index cannot converge NULL suppliers at all (N-5). That is a sidestep inside
  the new function, not a fix: the index, `addAlias` and migration 00015's comment are
  as they were.
- Verified by `supabase/tests/phase5_learn_product_aliases.sql` — 42 PASS / 0 FAIL,
  atomic and self-rolling-back: the trim and the server-side normalization, the
  re-point on a second call, the NULL-supplier convergence, six kinds of untrusted
  input, tenant isolation both ways, no product, no batch and no purchase row created,
  and the learned alias answering the **alias leg of a real match** for its own
  supplier's bill and not another's.

---

## D-041 — The Embedding Budget Is Not the Reader's Five Per Minute (Measured)

**Date:** 2026-09-19

**Status:** Active

**Decision:** The Gemini free-tier limit that shapes Phase 5's design is the **reader's**
(`generate_content_free_tier_requests`, 5/minute, D-032) and **not** the embedding
model's. Measured live on 2026-09-19 against the deployed `match-product`: 11
`batchEmbedContents` requests inside ~3 minutes, all answered, including four batches
of **20 texts** each (80 texts embedded, `vector_used: true` throughout, no refusal,
no warning). C3 may therefore batch catalogue rows at 20 per request and pace an
operator loop without treating 5/minute as the ceiling; the embedding metric's exact
ceiling remains unmeasured and, for an operator-paced loop, does not need to be.

**Rationale:** N-2 assumed one shared five-a-minute budget, and D-036/D-037 justified
"one embedding call per bill" partly on it. The measurement separates the two: a
busy reader does not cost the matcher its vector leg, and a backfill does not starve
the counter. This is a measured fact, not a documented limit: the probe is the
evidence, and the exact quota was not driven to refusal because a per-minute ceiling
is not what the loop is designed against.

**Consequences:**

- "One embedding call per bill" (D-036) stands as a *design* choice — one round trip,
  one catalogue snapshot for every line — rather than as a quota necessity.
- The live probe also closed what C1 left unverified: the model name
  (`gemini-embedding-001`), the `batchEmbedContents` body shape and the 768-dimension
  parse are confirmed live, and the 200 path carries `Access-Control-Allow-Origin: *`
  (D-038's contract, now measured on the success path too).
- The same probe showed the vector leg answering **nothing** while
  `products.embedding is null` on every real row, which is D-037's prediction and
  C3's work list.
- The quota is a **plan** question, not a code one: a paid tier would not change any
  code written today, because nothing here depends on the ceiling.

---

## D-042 — A Function's Error Envelope Has One Reader in the App Too

**Date:** 2026-09-19

**Status:** Active

**Decision:** The client-side reading of `{ error: { code, message } }` lives in
`lib/core/errors/function_error.dart` (`functionException`), and `ocrException` — the
bill reader's name for it — delegates. A feature keeps its own **fallback sentence**
(`matchException` bakes in the matcher's) and its own retry policy
(`isRetryableOcrError` stays the reader's alone).

**Rationale:** The same reasoning as `_shared/gemini.ts` on the server side (D-031):
one contract read in two places is how two features end up describing one provider
failure in two dialects. The extraction is behaviour-preserving — the body parser and
the code-to-exception mapping moved verbatim, and `ocr_service_test.dart` asserts the
same mapping as before.

**Consequences:**

- A new function's failures are classified the moment they are read, with no new
  vocabulary: `unauthorized` is an auth failure, `invalid_request`/`forbidden`/
  `too_large` are validation failures, `not_found` is a not-found, and everything else
  (including `provider_unavailable`) is a server failure in the server's own words.
- The retry decision does **not** move: the reader retries once, visibly (D-033), and
  the matcher does not retry at all (D-039). Sharing a parser is not sharing a policy.

---

## D-043 — The Backfill Is Two RPCs and One Operator-Paced Invocation

**Date:** 2026-09-19

**Status:** Active

**Decision:** Embedding the catalogue is three pieces, and no UI:

- **`products_to_embed(p_limit int) → {items, remaining, unembeddable}`** — a
  `stable security definer` RPC returning one batch of the caller's own un-embedded
  catalogue rows, each with the text `product_embedding_text()` produces (D-037),
  plus how much is left and how much can never be done. The batch is 20 by default
  and clamped to 100, and the limit is applied **after** the un-embeddable rows are
  dropped, so a batch is never short for no reason.
- **`set_product_embeddings(p_items jsonb) → {written, remaining, unembeddable,
  skipped}`** — a `volatile security definer` RPC writing `{product_id, embedding}`
  rows, each scoped to `get_my_pharmacy_id()` and each cast by the **database** from
  the vector's own text form, never marshalled by PostgREST (D-027's refusal).
- **`backfill-embeddings`** — an Edge Function that reads one batch, embeds it in one
  `batchEmbedContents` request, writes it, and answers `{embedded, remaining,
  unembeddable, skipped, model}`. **No internal loop**: the operator repeats the
  invocation (or `make backfill`) until `remaining` is 0. A model failure, a short
  answer or a hole in the batch refuses the batch **whole** and writes nothing.

**Rationale:** The model call has to happen between a read and a write, and putting it
inside a SQL transaction is not possible; putting the loop inside the function would
hold the shared key for minutes and give the operator no place to stop. The loop is
therefore the operator's, and the state that makes it resumable is the column itself:
`embedding is null` (D-027), so a second run continues rather than repeating. All or
nothing per batch is what keeps `NULL` honest as that marker — a half-written batch
would leave rows looking untouched while having spent requests on them.

**Consequences:**

- **One batch is one embedding request**, and 20 texts is the measured-safe size
  (D-041). Nothing here needs a queue, a job table or a marker column.
- The catalogue text is never composed in Deno: it comes back from the database, so
  the backfill and the match cannot drift (D-037).
- Every write bumps `products.updated_at`, because `set_updated_at` is a
  `BEFORE UPDATE` trigger on the table. That is acceptable **because the work list is
  `embedding is null`**: each product is written exactly once, ever, so this is a
  one-time stamp at setup rather than a standing distortion of "last changed".
- The function refuses to embed a batch with a hole in it, which is deliberately
  stricter than `match-product`, whose vector leg is an enhancement it can degrade
  without (D-036). The two callers of `_shared/embedding.ts` therefore differ in
  policy while sharing the convention.
- **No UI in Phase 5.** A backfill is a one-time setup task, not a daily operation,
  and Phase 5's scope is the capability rather than an admin screen; if a second
  pharmacy or frequent new products make it routine, Phase 6 adds a small screen.
- Verified by `supabase/tests/phase5_embedding_backfill.sql` — 34 PASS / 0 FAIL,
  atomic and self-rolling-back: the read's scope and shape, the write's cast and its
  four refusals, tenant isolation **both ways**, resumability (`remaining` shrinking
  by exactly what was written), the vector leg of a real `match_products` call firing
  on a row this pair wrote, and nothing else moving (no product, no batch, no
  purchase).

---

## D-044 — The Vector Floor Is 0.78, Because That Is What Real Vectors Said

**Date:** 2026-09-19

**Status:** Active

**Decision:** `match_products`' `c_vector_min_similarity` is **0.78**, up from
00023's provisional 0.7. The change is migration
`20260919000026_phase5_vector_floor.sql`, which is 00023's function **verbatim** with
one constant moved (D-013: an applied migration is never edited in place). Measured on
2026-09-19 against the live catalogue, with the floor temporarily lowered to 0.01 so
the RPC reported every distance:

| invoice text | what it is | cosine |
|---|---|---|
| `Dolo 650 Tab`, `DOLO 650` | the product's own name | 1.0 (trigram) |
| `Dolo650Tab15s` | the real product, run together | **0.8280** |
| `Dolo 125` | a strength the pharmacy does not stock | **0.7216** |
| `Dolo 500` | a strength the pharmacy does not stock | **0.7084** |
| `Paracetamol 500mg` | same molecule, another brand | 0.6695 |
| `Amoxyclav 625 10s` | an unrelated medicine | 0.5780 |
| `Cetirizine 10mg Tab` | an unrelated medicine | 0.5546 |
| `ZZQQ nonsense 9999` | junk | 0.5364 |

**Rationale:** 00023 said the floor was a guess and named the backfill chunk as its
measurement; C3 produced the vectors and the guess was wrong in the direction that
matters. At 0.7 **two wrong strengths of the same brand scored above the floor**
(0.7084, 0.7216) and were offered as high-confidence suggestions for a `dolo 650`
catalogue — precisely the "plausible-looking wrong suggestion" D-036 said to avoid.
The window the data leaves open is (0.7216, 0.8280), and 0.78 sits in it: above every
wrong sibling, below the one true match, and closer to the wrong side on purpose — a
missed suggestion costs a tap, a wrong one costs trust.

**Consequences:**

- **What the floor does and does not stop, stated exactly:** it stops the *vector*
  leg asserting a wrong product with a high score. `Dolo 500` still comes back as a
  **trigram** hit at 0.5556 against a one-product catalogue, labelled `56% similar` —
  the trigram threshold is 0.35 because that is what reads `Dolo650Tab15s` (0.455),
  and it is untouched here. The two thresholds do different jobs and the reason each
  candidate is offered is shown to the user, which is what makes both honest.
- **00023's note about the model was too high.** It said unrelated short strings sit
  "around 0.6-0.75"; measured, junk sits at **0.5364** and unrelated medicines at
  0.55-0.67. A floor anywhere near 0.6 would have offered the whole catalogue for
  every line.
- **The measurement rests on one catalogue vector**, because the live pharmacy holds
  one product. Recorded as **N-9**: the floor stays provisional in that sense, and it
  errs high rather than low, so a richer catalogue should re-measure it (the same
  recipe: floor to 0.01, read the distances, put it back).
- The floor is asserted **behaviourally** rather than textually: migration 00023's
  test creates synthetic vectors at cosine 0.9987 (kept), 0.80 (just above) and
  0.5774 (refused), so a future change to the constant fails there. Those three
  numbers moved with the constant in this chunk, which is the test doing its job.
- Live end to end, after the backfill and the re-tune: `Dolo650Tab15s` → the real
  product at `reason: vector`, score 0.8280; `Dolo 650 Tab` → `reason: trigram`,
  1.0; `Cetirizine 10mg Tab` and `ZZQQ nonsense 9999` → no candidates at all.

---

## D-045 — Measurements Never Mutate Production

**Date:** 2026-09-19

**Status:** Active

**Decision:** Any measurement that requires modifying a function, a constant or a
table on the live project happens on a **temporary tenant** — a throwaway pharmacy
with its own fixtures — which is deleted afterwards. The live project is touched only
by versioned migrations.

**Rationale:** The floor re-tune (D-044) measured by patching the live
`match_products` — `pg_get_functiondef`, one word changed, reinstalled for about a
minute, then restored by migration 00026. It worked and the live constant was
verified afterwards, and it was still the wrong method: while the patch was installed
the deployed function was answering real queries with a floor of 0.01, so any genuine
match in that window would have come back with nonsense suggestions. A measurement
must never be something a real user can be inside.

**Exception:** Versioned migrations are the standard path, and D-013 covers them:
they are reversible, attached to the code, and reviewed like every other change. The
line is *reversibility plus review*, not "never change the database".

**Consequences:**

- The next measurement of this kind spends about two minutes creating and deleting a
  throwaway tenant. Cheap insurance against a race with a real query.
- **One implementation question is open, and the next measurement will meet it**: the
  temporary tenant needs an identity to act as — `get_my_pharmacy_id()` reads the
  caller's own profile, and this project's guard refuses hand-edited auth rows
  (N-7). A measurement that needs a **live function invocation** therefore needs
  either a session from the app or a temporary user created and removed with the
  tenant; a measurement that needs only the database can impersonate an existing
  identity the way every SQL test here does. Decide which, and say so, before the
  measurement starts.
- What remains verifiable without any mutation at all, and should be reached for
  first: the RPC's own reported numbers (C3 read every `distance` the matcher
  returned), a `select` over the data, and the SQL tests' impersonation.

---

## D-046 — Alerts Surface In-App in Phase 5, Dispatch in Phase 6

**Date:** 2026-09-19

**Status:** Active

**Decision:** Low-stock and expiring-batch alerts **appear in the in-app notification
list** and are not dispatched anywhere in Phase 5. No automatic WhatsApp or email
leaves the system for them. `send-notification` is built and ready in this phase; its
**triggers** land in Phase 6, with the credentials and the recipient numbers.

**Rationale:** There is nobody to send to and nothing to send with: no recipient phone
numbers are collected (neither users' nor suppliers'), there is no paid Meta WhatsApp
account, and there is no SendGrid key. An alert path that cannot deliver is a path
whose failures are noise, and Phase 5's discipline is to build the capability and
surface what it can honestly show. Auto-dispatch is also the wrong thing to switch on
before its credentials exist, because the first thing it would teach an operator is to
ignore it.

**Consequences:**

- Phase 5 ships **visibility**; Phase 6 ships **automation**. The function, the log
  table and the in-app list are all in place for it, so Phase 6 adds triggers and
  credentials rather than a subsystem.
- The in-app list is deliberately the surface that carries the message either way
  (D-029's reasoning, one layer out): a notification that could not be *delivered* is
  still visible in the app, and the list is where a failed dispatch is discovered.
- `notification_logs` still records every attempt the function makes, so the audit
  trail exists before the automation does — an operator asking "did we tell this
  supplier" gets the same answer before and after push and dispatch arrive.
- Alerts are computed **in SQL** (`low_stock_products`, `expiring_batches`) rather
  than compared in Dart, which is also I-1's fix and the RPCs D-026 already reserved
  for the chatbot: one implementation, three callers.

---

## D-047 — An Alert Is a Question, a Notification Is an Event

**Date:** 2026-09-19

**Status:** Active

**Decision:** The two alerts D-046 put in the in-app list — low stock and expiring
batches — are answered by **two `stable` RPCs** (`low_stock_products(p_limit)`,
`expiring_batches(p_days, p_limit)`, migration 20260919000027) and are **not written
as rows**. The in-app list shows them as a live section; `notifications` stays what it
is — events a recipient was told about. The reorder rule is `total_qty <
min_stock_level`, exactly the comparison the app already made in Dart, with the
manager's own reasoning: at the level is where the pharmacy meant to act, below it is
where they did not.

**Rationale:** Three parts.

- **A low-stock alert is a fact about stock now, not an event.** Materialising it
  means a row that is wrong by the time it is read (the goods arrived five minutes
  later) and, with nothing running on a schedule in Phase 5 (D-046), a row nobody
  would write at all. A derived answer cannot go stale.
- **I-1 is fixed by moving the comparison, not by moving the bound.** The inventory
  screen decided `total_qty < min_stock_level` in Dart over at most 500 candidate
  rows, because PostgREST cannot compare two columns — so a catalogue past that bound
  would silently report a partial answer. A stock alert that stops seeing products is
  worse than a slow one, and the fix is to compare where both columns are.
- **D-026 already reserved these two names** for the chatbot's aggregates and said
  they are "the aggregates the reports screens want too, so they are not chatbot-only
  work". This is that work arriving from the alert side: one implementation, three
  callers (the list, the inventory screen when it is next touched, the chatbot).

**Consequences:**

- `shortfall` (the units that close the gap) is returned rather than left to a screen,
  so an alert can say how much to order; `days_left` is negative for a batch that has
  already expired, so a screen can say "expired 6 days ago" rather than read a bucket.
- A discontinued product is never reported (nothing should be reordered into a product
  the pharmacy has stopped stocking), and a batch with nothing left in it is never a
  waste risk (nothing left to waste).
- **A note from the test, kept because it is a schema fact rather than a case**:
  `product_batches.expiry_date` is `NOT NULL`, so the function's `is not null` guard
  is a mirror of the column, not a live branch; the SQL test asserts the column's
  nullability instead of inventing a fixture the schema forbids.
- Both functions are `stable`, so neither can move stock (D-011/D-013), and both are
  tenant-scoped by hand inside a `security definer` function — which is not
  belt-and-braces here: the views they read are `security_invoker = true`, and inside
  a definer function "the invoker" is the owner.
- Verified by `supabase/tests/phase5_alerts.sql` — 25 PASS / 0 FAIL: the reorder
  boundary (`<` reports, `=` does not), the zero-and-no-batch case, an inactive
  product never reported, the shortfall number, worst-first ordering, the limit, the
  expiry horizon widening with `p_days`, the negative `days_left` and the
  already-expired batch coming first, an empty batch excluded, tenant isolation both
  ways, and that reading them moves nothing.
- **The notifications half of Chunk D is not built yet**: `send-notification`, the
  in-app list screen and the Dart seams are briefed in `context/chat3i-opening-prompt.md`.

---

## D-048 — Notifications Are a Top-Level Utility, Not a Domain Module

**Date:** 2026-09-19

**Status:** Active

**Decision:** `/notifications` is a **top-level shell destination**, treated as a
cross-cutting utility in the way `/settings` is, and nested under no domain module.
The desktop navigation rail gets a twelfth entry, placed **after Reports and before
Settings**; the mobile drawer gets the same entry; the **bottom bar stays at four**
(`inBottomBar: false`, the D-022 flag). The dashboard carries a small widget showing
the unread count — *Notifications (N)*, tappable through to the route, and **always
visible**: at zero it reads *No new notifications* rather than disappearing. A bell in
`AppScaffold` is **deferred to Phase 6**.

**Rationale:** Notifications span every domain — a low-stock alert is inventory, an
expiry alert is stock, a payable reminder is a purchase or a ledger entry, a payment
receipt is sales — so no single module owns them, and nesting the list under whichever
one was chosen first would make the other four look like second-class answers. Twelve
rail entries is still a list a person reads rather than scans, and the bottom bar's
four are the trading surfaces a counter actually taps, which is exactly the
distinction `inBottomBar` exists for (D-022). The bell is deferred because it is a
change to the scaffold every screen is built on — twenty-odd screens — for a
convenience the rail entry already provides.

**Consequences:**

- **Two lists have to move together, and a test already enforces it**: adding the
  destination means an entry in `_navDestinations` *and* a path in `Routes.shellPaths`,
  and `DashboardShell.destinationPaths` exists so a test can assert the two agree
  (`dashboard_shell_test.dart`). A half-added destination fails there rather than
  showing a rail entry that navigates nowhere.
- The bottom bar is untouched: `_bottomBarDestinations` filters on `inBottomBar`, so
  the twelfth entry cannot leak into it.
- The dashboard widget is **visible at zero on purpose**: a notification surface that
  vanishes when there is nothing to say is one a user forgets exists, and the first
  time they need it is the time they would not find it. *"No new notifications"* is
  the honest empty state, and it is the same rule T-5 records for the sale-return
  picker — "nothing here" and "still loading" must not look alike.
- **Where Phase 6 and later nest**: dispatch settings and per-user notification
  preferences go under `/notifications/*`, the way `/inventory/calendar` and
  `/reports/expenses` sit under the destination they serve, so the rail keeps
  highlighting the parent.
- The route is declared in `app_router.dart` as a shell child, and the health of the
  arrangement is asserted by the shell's existing destination test rather than by a
  new one.

---

## D-049 — Once the Queue Row Lands, a Dispatch Answers 200

**Date:** 2026-09-19

**Status:** Active

**Decision:** `send-notification` records **every** attempt, and a well-formed
request is answered with **200** carrying the attempt's settled outcome:
`{log_id, notification_id, status: 'sent'|'failed'|'skipped', provider, error}`. The
`{error: {code, message}}` envelope is reserved for a request that recorded
**nothing** — a bad method or body, an unauthenticated caller, an account with no
pharmacy, a database failure — and for the one case where the attempt was recorded
but its outcome could not be, which is a 500 that leaves the row `queued`. A missing
secret is therefore **not** a 503: it is `status: 'skipped'`, `provider: null`, and a
sentence naming the secret.

**Rationale:** Three parts, and the first one is the whole shape of the function.

- The sequence is **queue → call → settle**, and `queued` is the state that means
  "we started". The provider call cannot be inside a transaction — a transaction held
  open across a round trip to Meta or SendGrid is a lock held for as long as their
  latency — so the log row is written first, and it is written **always**, including
  when a secret is missing. A refusal that leaves no trace is the one outcome this
  function must not have: the row is what makes "we told them" answerable (D-046), and
  "we tried and could not" deserves a row as much as "we sent it" does.
- Once that row exists the request *did* happen and is on the record. A 5xx would say
  "nothing happened" about an attempt that is filed, and it would invite exactly the
  retry loop that cannot succeed — a retry cannot conjure a secret.
- So the caller reads one field (`status`) instead of inferring "outcome" versus
  "failure" from the HTTP class, and the app's one envelope reader keeps its meaning
  (D-042).

**Consequences:**

- **The contract gained two fields the table requires.** `notifications.type` is
  `NOT NULL` and the proposed contract had no field for it, so the request takes an
  optional `type` (default `'message'`), and an optional `title` that falls back to
  the subject — the only headline-ish thing an email has, and `null` for a WhatsApp
  message. `data` carries `dispatch_channel`, `recipient_type` and `recipient_id`,
  which is the column's documented purpose (deep-linking / channel rendering).
- **A `notify_user_id` outside the caller's pharmacy is refused**, in SQL, by the
  `queue_notification` RPC — because a `SECURITY DEFINER` function skips RLS, so the
  `notifications` insert policy's own rule (`user_id = auth.uid() or pharmacy_id =
  get_my_pharmacy_id()`) is restated by hand. An id that is present but not a uuid is
  **refused rather than dropped**, which is where this differs from the matcher's
  supplier id: it decides *whether a row is written at all*.
- A provider that refuses, or that cannot be reached, is `failed` with the provider's
  own words — WhatsApp nests them at `error.message`, SendGrid at `errors[0].message`,
  and both are read. A provider that is not configured is `skipped` with
  `provider: null`, because nobody was reached and recording a vendor would be
  claiming one was.
- **Four secrets, and the first one missing is the one named**: `WHATSAPP_TOKEN`,
  `WHATSAPP_PHONE_NUMBER_ID`, `SENDGRID_API_KEY`, `SENDGRID_FROM_EMAIL`. The Graph
  API version is a named constant (`WHATSAPP_API_VERSION` overrides it without a
  redeploy) for D-030's reason: Meta retires versions on a schedule, and a version
  change should be one line rather than a search.
- The body is capped at Meta's 4096-character text ceiling and refused as `too_large`
  rather than sent to fail at the provider.
- **`queue_notification` is one transaction; the settle is not.** The RPC writes the
  log row and, when `notify_user_id` is present, the `notifications` row it points at
  — which is D-024's rule (a payment and its ledger row) applied to the pair that
  points at each other. The settle is an ordinary tenant-scoped `update` made with the
  caller's own token, and it needs no definer help. A settle that fails leaves the row
  `queued`, which is what `queued` is for, and answers 500 — the one non-200 that
  follows a queued attempt, and the honest answer for a caller who does not know
  whether the message went.
- **One live invocation, with a session from the app (N-7):**

  ```
  POST send-notification  {channel: whatsapp, to: +910000000000, recipient_type: user,
                           notify_user_id: <the caller>, type: probe, title: …}
    -> 200 {"log_id":"60ee8b0c-…","notification_id":"7a909348-…","status":"skipped",
            "provider":null,"error":"This function is missing its WHATSAPP_TOKEN secret."}
  ```

  Both rows landed: the log row `status='skipped'` with `provider` and
  `provider_message_id` null, `channel='whatsapp'`, `recipient_type='user'`,
  `destination='+910000000000'`, `created_by` = the caller, pointing at an **unread**
  `notifications` row in the caller's own inbox, same pharmacy. The two rows are
  permanent on purpose — `notification_logs` has no delete policy — and the tables held
  nothing else before the probe or after it.
- **What the probe cannot prove, and does not claim to:** that any WhatsApp message
  was delivered. There is no Meta account, no SendGrid key and no recipient number in
  this phase (D-046), so what is proved is the wiring *below* the credential: the
  request contract, the queue → call → settle order, the `skipped` settling, and the
  two rows.

---

## D-050 — `showLocal` Is a No-Op That Says So in Debug

**Date:** 2026-09-19

**Status:** Active

**Decision:** `NotificationService` keeps its three methods, and Phase 5's
implementation — `UnavailableNotificationService`, still behind
`notificationServiceProvider`, which is codegen now — **completes all three**.
`init()` is a no-op (the hook Phase 6's push registration fills), `getFcmToken()`
answers `null`, and `showLocal()` completes **without showing anything**, printing one
line in a debug build naming the title and the reason.
`UnimplementedNotificationService` is deleted.

**Rationale:** D-029 leaves the app with no push SDK and no local-notification plugin
for this whole phase, so the seam's only honest job is to say what a caller can rely
on. A method that throws `UnimplementedError` forces every call site to special-case
this phase and then to be edited again in Phase 6, for a state the app is *designed*
to run in. A method that silently does nothing is worse in a different way: nothing in
the app calls `showLocal` yet, so its first caller will be Phase 6's push handler —
and a handler that believed a notification had appeared when it had not is a bug that
would look like the platform's fault. The debug line is one `kDebugMode` branch (a
`const`, so it compiles out of a release build), and a test asserts it.

**Consequences:**

- `getFcmToken()`'s `null` is documented as an **answer rather than a failure**, so
  N-1's arrival changes the implementation behind the provider and not one call site.
- The hand-written provider is gone, which closes one of D-1's five manual providers:
  `notificationServiceProvider` is codegen now, like every other provider here.
- The service is still not injected anywhere — nothing in Phase 5 needs it — so the
  seam exists and the fake waits. Phase 6's push handler is its first caller.

---

## D-051 — A Derived `AsyncValue` Is Mapped by Hand, Because a Retry Is a Loading State That Carries the Error

**Date:** 2026-09-19

**Status:** Active

**Decision:** `unreadNotificationCount` — the dashboard card's count — does **not**
use `AsyncValue.whenData`. It maps the inbox's state explicitly, in the order
**value → error → loading**.

**Rationale:** Riverpod 3 re-runs a provider whose build threw, on its own backoff,
and **during that retry the state is an `AsyncLoading` that still carries the error**
(`AsyncLoading(error: …, retrying)`). `whenData`'s loading branch returns a plain
`AsyncLoading`, which drops it — so the dashboard card would have said *Checking…* for
ever instead of *Could not check*. That is precisely the lie D-048 forbids: the card
must never report something it does not know, and "we could not count" is not "there is
nothing". Found by the card's own test, not by review.

**Consequences:**

- The order is deliberate and load-bearing: a count that exists is the last good
  answer and is *used*; a failure with no count is reported; only then is it genuinely
  "not counted yet".
- **A test in this project asserts a state, not a read count.** Riverpod 3's retry
  makes a read count blind to *why* a provider was re-read, so `expect(reads, 2)` after
  tapping a retry button is not evidence of anything — three assertions were written
  that way in this chunk and removed. What the retry button did is proven by the state
  it produced.
- Any future provider that derives an `AsyncValue` from another should do the same,
  and a widget test that expects an error state should expect the error's *sentence*
  rather than pump a fixed number of frames.

---

## D-052 — Auto-send PO Deferred to Phase 6

**Date:** 2026-09-19

**Status:** Active

**Decision:** Phase 5 ends with the chatbot (Chunk E). Auto-send PO on approval moves
to Phase 6 add-ons.

**Rationale:** Requires WhatsApp Meta account, SendGrid key, and supplier channel
preferences — none configured. Manual sending is adequate until credentials exist.

**Consequences:** Phase 5 = A + B + C + D + E. Auto-send PO rides with Phase 6
deployment work.

---

## D-053 — Chatbot Phrasing Is Templated, Not Model-Generated

**Date:** 2026-09-19

**Status:** Active

**Decision:** The chatbot never lets the model produce a numeral. The Gemini call
returns only `{rpc_name, params}` as a closed-set choice. The RPC returns a `jsonb`
envelope. Phrasing is a per-RPC template in code, filled with the RPC's own numbers.

**Rationale:** D-026 says "RPCs, never free-form SQL." Extending that: if the model can
phrase an answer, it can hallucinate a numeral — a "₹45,230" that no RPC produced.
Templating removes the possibility structurally, not via prompt engineering.

**Consequences:**

- Adding a new chatbot capability = adding an RPC + a template, not a prompt. The
  model's job is classification only.
- **No invisible semantics: an aggregate states its own window and caveats in the
  envelope.** `top_products` carries a `meta` block (`window_from`, `window_to`,
  `metric_used`, `returns_not_netted: true`, `limit`) and `dead_stock` its own
  (`as_of`, `quiet_days`, `limit`), so a surface renders the caveat under an answer —
  a reader can see *why* a product is top rather than having to know the rule.

---

## D-054 — The Chatbot Is a Top-Level Shell Destination

**Date:** 2026-09-19

**Status:** Active

**Decision:** `/chatbot` is a **top-level shell destination**, treated as a
cross-cutting utility in the way `/notifications` and `/settings` are. It is the
**thirteenth** entry in the navigation rail, placed **after Notifications and before
Settings**; it is in the mobile drawer and **not** in the bottom bar
(`inBottomBar: false`, the D-022 flag). The route is declared in `app_router.dart` as a
shell child.

**Rationale:** The same argument D-048 made for notifications, and it lands harder
here. The chatbot answers from `report_summary`, `low_stock_products`,
`expiring_batches`, `top_products` and `dead_stock` — a low-stock question is
inventory, what sells best is sales, what is expiring is stock, what is still owed is
purchases and the ledger. **No domain owns it**, so nesting it under whichever module
was chosen first would make the other four look like second-class answers, and the
user's mental model ("ask the pharmacy a question") would be buried inside one of the
five things they might ask about. The rail's utility group now reads
Notifications → Chatbot → Settings: the three entries that are *about* the pharmacy
rather than *one of* its trading surfaces. The bottom bar still carries the same four
trading surfaces, because that is what `inBottomBar` exists for.

**Consequences:**

- **Three lists moved together and the existing tests hold two of them**: `Routes.chatbot`
  plus its `Routes.shellPaths` entry, the `_navDestinations` entry, and
  `DashboardShell.destinationPaths` — which `dashboard_shell_test.dart` and
  `widget_test.dart` already assert against `Routes.shellPaths`, and which now assert a
  length of **13**. Nothing had to be added to the test suite for this destination; the
  parity tests were the whole enforcement, which is what they were built for.
- A half-added destination fails in the tests rather than in production: a rail entry
  that navigates nowhere, or a route with nothing leading to it, is a missing entry in
  one of the two lists.
- **The bottom bar is untouched** — `_bottomBarDestinations` filters on `inBottomBar`,
  so the thirteenth entry cannot leak into it, and the two utility destinations are
  asserted to stay out.
- What nests *under* it later goes at `/chatbot/…`, the way `/reports/expenses` sits
  under reports and `/notifications/…` is reserved for dispatch settings, so the rail
  keeps highlighting the parent.
- The dashboard deliberately gains **no card** for this: D-048's unread-count widget
  earned its place by being a number that changes without the user asking, while a
  chatbot has nothing to say until someone asks it something.

---

## D-055 — A Conversation Is Controller State, Not an `AsyncValue`

**Date:** 2026-09-19

**Status:** Active

**Decision:** `/chatbot`'s screen holds its conversation in a `ChatController` whose
`build()` returns a plain `const ChatState()` and **never throws**, with three separate
fields: `messages` (turns that happened), `asking` (the question in flight) and
`failure` (a question that could not be asked). The three situations a user can be in
are therefore three *structures*, not three captions on one:

| situation | what it is | what the screen shows |
|---|---|---|
| nothing asked yet | `messages` empty, nothing in flight | the invitation, with example questions |
| still waiting | `asking` is the question text | the question plus a spinner |
| no answer to that | a **message**, with `rpc: null` | the server's sentence as prose, in an ordinary answer bubble |
| could not ask | `failure`, which is **not** a message | an error icon, the server's sentence, one retry |

**Rationale:** Two decisions in one, and both are forced by this project's own history.

- **Not an `AsyncValue`.** A conversation cannot be one `AsyncValue`: the transcript,
  the outstanding question and the failed question are not three states of one read,
  and collapsing them loses exactly the distinctions the screen exists to keep.
- **A plain state whose build cannot fail.** Riverpod 3 re-runs a provider whose
  *build* threw, on its own backoff (D-051), so an error state reached that way is not
  stable across pumps. Reaching it from a failed write — as here — is. This is the
  `SaleReturnFormController` shape, chosen deliberately over the throwing-build one.
- **A failure is not a message.** `ChatMessage` is what the conversation *contains*;
  a failure is a turn that did not happen — no answer, never sent to the server, not in
  the history. Making that structural rather than cosmetic is what makes *"I cannot
  answer that"* (an answer, `rpc: null`, D-026) impossible to confuse with *"could not
  ask"* (a failure). T-5 records this project's version of the bug where those two look
  alike; here the types do not permit it.
- **One model call per user action, and nothing retries by itself** (N-2, D-032). The
  key is a free tier of five requests a minute shared with the bill reader, so `ask`
  refuses a second question while one is in flight *before* any call is made, and the
  only retry is `retry()` on a user's tap, re-asking the failed question verbatim. The
  retry sentence is `isRetryableChatError`'s — `provider_unavailable` or `unreachable` —
  and it only ever changes a sentence, never a behaviour.

**Consequences:**

- The failure's rendering uses `describeError` and the button primitives `ErrorView` is
  built from, rather than `ErrorView` itself: a failure here is one turn in a transcript
  and the question it belongs to has to stay visible. "Retry" is offered for every
  failure, because re-asking is the only action a failure leaves a user; retryability
  adds the sentence *"The assistant was busy, not beaten — worth another go."* — which is
  D-033's distinction, kept in the client because the client is where a wait can be
  explained.
- A new question supersedes a previous failure rather than stacking it: the failure
  described one question's attempt and the user has moved on. The failed question is
  only held while it is the newest turn.
- **The client sends the question and a bounded history** — the last
  `chatHistoryTurns` (6) completed turns, mirroring the function's own
  `MAX_HISTORY_TURNS`. Both bounds are "at most", so they cannot disagree in a way that
  matters, and a transcript that grows all afternoon does not grow into the request.
- **Nothing on the screen computes a figure.** The sentence is the server's, rendered
  in code from a report's own `jsonb` (D-053), and the note under it
  (`describeAnswerOrigin`) names the report, the arguments it was handed and the caveats
  its `meta` states — including `returns_not_netted`, which has no sentence anywhere
  else. A widget that formatted its own number would be a second implementation of
  D-053 on the wrong side of the wire.
- The `data` field is decoded and kept **verbatim**, not re-modelled into five report
  shapes: nothing on this screen reads a figure out of it, and five models would be five
  chances to lose the caveat that is the point of keeping it.

---

## D-056 — The Alias Key Treats "No Supplier" as a Value

**Date:** 2026-09-19

**Status:** Active

**Decision:** `product_aliases`' unique index is rebuilt `NULLS NOT DISTINCT` on
`(pharmacy_id, supplier_id, normalized_name)` (migration `20260919000030`). A NULL
`supplier_id` is therefore a **value**, so a pharmacy may hold one alias per printed
text per supplier *value*, and "no supplier" — a pharmacy-wide alias — is one of them.
`ProductsRepository.addAlias`'s upsert converges those rows instead of inserting a
duplicate.

**Rationale:** Open item N-5, and the reason it was an open item rather than a
preference: two places in the repository said contradictory things about the same key.
Migration 00015's comment claimed NULL-supplier rows "never conflict" and called that
correct; `addAlias`'s doc claimed re-adding a text "re-points the alias … which is what
the unique key is for". Postgres treats NULLs as distinct, so the first was true and
the second was false — a second manual alias with no supplier inserted a *duplicate*.

- **Why not the expression index.** The other candidate was
  `(pharmacy_id, coalesce(supplier_id, '<sentinel>'::uuid), normalized_name)`. It
  enforces the same rule and **PostgREST cannot use it**: `on_conflict` is matched to an
  index by column *names*, and an index over an expression is not inferrable from those
  names, so the app's upsert would have started failing with *"there is no unique or
  exclusion constraint matching the ON CONFLICT specification"*. PostgreSQL's own
  documentation describes inference as matching "exactly the `conflict_target`-specified
  columns/expressions", with no exclusion for `NULLS NOT DISTINCT`, so the plain-column
  index keeps working — and now the conflict it looks for is actually detected. This was
  checked in the docs before the migration was written, because a wrong call here would
  have broken the alias tab for every pharmacy rather than for one case.
- **Probe first.** A read-only query over the live project found **0 alias rows and 0
  colliding keys**, so the index was built over an empty table and nothing had to be
  de-duplicated. That is the only reason this is pure DDL: on a populated table it would
  have needed a decision about which row survives, which is not a thing an index swap
  should decide.
- **`learn_product_aliases` is deliberately not replaced.** Migration 00024's function
  carries an explicit update-then-insert for the NULL-supplier case precisely because
  `on conflict` could not converge those rows. That branch is now redundant and stays:
  it is still correct, and replacing a deployed, tested function in order to delete a
  branch that harms nothing is churn with a risk attached.

**Consequences:**

- `NULLS NOT DISTINCT` is a property of the index and cannot be turned on for an
  existing one, so the index is dropped and rebuilt. The statement is a no-op on a
  re-run (the table is empty, and `drop … if exists` precedes the create).
- Both contradicting comments are reconciled: 00015's points forward at 00030 (the way
  00010 points at 00015, D-013), and `addAlias`'s doc now states the behaviour the index
  actually has. The two Phase 5 tests that described the old fact were corrected rather
  than left to contradict the code.
- Verified by `supabase/tests/phase6_alias_identity.sql` (20 PASS / 0 FAIL): the index's
  own flags, both upsert paths converging, the supplier-scoped and pharmacy-wide rows
  still coexisting, two different texts still two rows, and tenant isolation. **The same
  file produced 7 FAILs against the pre-migration database**, which is what makes it
  evidence rather than decoration.

---

## D-057 — A Bill Is Built in Two Steps, and Its Tax Heads Sum to the Tax Charged

**Date:** 2026-09-19

**Status:** Active

**Decision:** `InvoicePrinter` builds a **content** model (`InvoiceSheet`, via
`buildSheet`) and then renders it (`buildDocument`), instead of laying out the PDF in
one method. And the intra-state split takes the **rounded** central half and subtracts
it for the state half, so CGST + SGST always equal the stored `tax_total`.

**Rationale:** Two things, and the first is what made the second findable.

- **A bill is a tax document, so what it says is worth asserting** — and while the
  layout and the content were one method, the only way to look at any of it from a test
  was to mock a print channel. Extracting `InvoiceSheet` (heading, title, reference,
  issued-at, lines, totals, payment, footer) puts the arithmetic, the statutory headings
  and the formatting on the testable side of the line. This closes the coverage gap
  `PROGRESS.md` had carried since Phase 3 ("a test would have to mock a platform channel
  rather than assert a document — the fix is to extract the document builder").
- **The split was wrong by a paisa.** The old code printed
  `round2(taxTotal / 2)` and `round2(taxTotal - taxTotal / 2)`. For a tax total with an
  odd number of paise — half of all two-decimal totals — the unrounded half subtracted
  gives the *same* number back, so both heads rounded up and their sum was `taxTotal +
  0.01`: a bill whose own tax heads disagreed with the tax it charged. Taking the
  rounded half and subtracting *that* makes the heads sum exactly. Nothing about what is
  stored changes: this is the printed document only, and `sales.tax_total` — the figure
  the ledger posted — is untouched.

**Consequences:**

- `printReceipt` is now three lines over `buildDocument`, and the provider seam
  (`invoicePrinterProvider`) is unchanged, so `sale_detail_screen.dart` did not have to
  move.
- `InvoiceRow.emphasis` and `.ruleAbove` travel with the row: which figure is the
  document's headline and where the rule above the total falls are part of what a GST
  bill looks like, not something the renderer decides from a label.
- 17 tests in `test/services/invoice_printer_test.dart`: the seller block and its
  placeholder, the lines and their pricing, both tax splits, the odd-paise case, the
  discount/discount-absent pair, the total's emphasis and rule, how it was settled, and
  two that the layout renders a PDF at all.
- `_money` keeps printing `Rs` rather than `₹`: the PDF package's built-in fonts have no
  rupee glyph, which the test run now says out loud ("Helvetica has no Unicode support")
  and which many thermal printers share.

---

## D-058 — A Failure Is Decided Before a Retained Value

**Date:** 2026-09-19

**Status:** Active

**Decision:** A screen that reads an `AsyncValue` renders the **error** when the read
failed *for what is on screen*, even if Riverpod is holding a previous value — and a
screen has **one** failure surface, not an error view and a SnackBar reporting the same
failure twice.

**Rationale:** Open item T-3. `LedgerEntriesController` returns an empty page while no
party is selected, and Riverpod 3 keeps the last value across a rebuild. So a party
chosen *after* the first frame arrived with that empty page attached, and
`page.hasError && !page.hasValue` — the condition the body used — was false. The screen
rendered **"Nothing on this ledger"** for a ledger nobody had managed to read, announced
the failure in a SnackBar beside it, and offered no retry control: the only way to ask
again was to navigate away and back. The error was reported and simultaneously hidden.

The general shape is worth naming, because it is this project's recurring bug: **two
states that mean different things rendered identically.** T-5 is the same defect one
screen over ("loading the bills" and "no bills exist" were one empty disabled picker),
D-048 records the rule for the notification widget ("no new notifications" must be
visible, not absent), and the same file's `T-4` is its sibling in the form's dead
branches. Here the fix is ordering: an error is about the party currently on screen, so
it wins over a value that belongs to a different question — or to no question at all.

**Consequences:**

- `_LedgerBody` checks `page.hasError` first, and the screen-level `ref.listen` SnackBar
  is gone: the `ErrorView` already names the failure and carries the retry, so a second
  report of the same failure was noise. The load-more path is untouched and still keeps
  its rows and reports through a SnackBar — there the page on screen is still *true*,
  which is the distinction.
- The "failure arrived while stale rows are on screen" case is now a retry, not a stale
  page: after recording a payment, a failed re-read shows "could not load that ledger"
  rather than a ledger that does not include the payment.
- The same ordering was applied to the sale detail screen, found while writing its
  tests: a bill that is **gone** renders *Bill not found* instead of a spinner that
  never resolves (`saleDetailProvider` answers `null` for an id that is no longer there).
  The check is `!isLoading` rather than `value == null` alone, because a *retry* also
  holds no value while it is in flight — the same conflation, one step in the other
  direction.
- Tests: the ledger's first-read failure now asserts **one** failure surface (it
  asserted two, deliberately, under the old design), and a new test reproduces T-3
  exactly — a party picked after the first frame whose read fails must offer a retry.

---

## D-059 — Phase 6 Ships Web First, Android Second, and Does Not Chase iOS

**Date:** 2026-09-19

**Status:** Active

**Decision:** Phase 6's deployment targets are **Web (Vercel) primary** and **Android
(APK, then Play) secondary**. **iOS is out of scope** for this phase and documented as a
runbook for whoever has a Mac. **Windows is not a launch target** — the build is fixed
because a broken build is a lie about the repository, not because a desktop build is
wanted. This supersedes MASTER_PLAN's "iOS TestFlight" deliverable for the phase.

**Rationale:** The student is the platform, so the target has to fit the toolchain and
the workflow. Web is where the counter work happens and it has no review cycle between
a fix and a live app; Android is the only place the camera-dependent workflows (bill
photography, product photos) are reliable; iOS cannot be built on this host at all —
no macOS, no Xcode, no way to upload — so listing it as a deliverable would be a
promise nothing here can keep. Windows had a fixable build (`permission_handler_windows`
compiles through `<experimental/coroutine>`, which MSVC 14.51 refuses as error
C2338/STL1011) and one line of CMake repairs it, which is worth doing and is not worth
a release process.

**Consequences:**

- The deploy work and the Edge Function secrets land in that order, and the credentials
  that are needed for each are known up front: a Vercel account, a Google Play developer
  account, and (for dispatch) Meta + SendGrid.
- `flutter build windows --debug` was run and produced
  `build\windows\x64\runner\Debug\app.exe`; the **release** Windows build was
  deliberately not run (the debug build already proves the CMake fix, and a release
  build costs minutes of toolchain time). `docs/DEPLOYMENT.md` says so explicitly so
  nobody mistakes it for verified.
- The CMake fix is scoped to `permission_handler_windows_plugin` via `if(TARGET …)`
  rather than added to `APPLY_STANDARD_SETTINGS`, which every plugin links through: a
  deprecation inside a third-party plugin is not a reason to stop reporting one in code
  we write. The definition is to be removed when that plugin moves to C++/WinRT 2.x.
- `docs/USER_MANUAL.md` and `docs/DEPLOYMENT.md` arrive with this decision, because
  "production readiness" is not a build artifact.

---

## D-060 — Email Confirmation Stays On, and Accounts Are Confirmed by Hand

**Date:** 2026-09-19

**Status:** Active

**Decision:** The hosted project keeps **"Confirm email" ON**. New sign-ups are
confirmed deliberately by the owner in the Supabase dashboard. **No app change**, no
"resend confirmation" affordance, no workaround, and no hand-editing of
`auth.users.email_confirmed_at`.

**Rationale:** N-7 was an open item because the repository's own belief contradicted
reality — `supabase/config.toml` says `enable_confirmations = false`, but that key only
ever configures a **local stack** (D-003), while the hosted project requires a confirmed
address: a sign-up returns `confirmation_sent_at` with no session, and the password grant
answers `email_not_confirmed`. So a throwaway probe account could not sign in, and the
obvious workaround — writing `auth.users.email_confirmed_at` by hand — is an
auth-weakening write to production, which the auto-mode guard correctly refuses.

The choice was the user's to make rather than a defect to fix: this is a pharmacy shop
with a handful of accounts created deliberately by the owner, not a self-service product
where a signup must work unattended. Turning confirmation off would be a *different*
policy, not a bug fix — and adding a resend affordance would be building UI for a flow
nobody is expected to hit.

**Consequences:**

- **For an operator**: creating an account is two steps — sign the user up, then confirm
  the address in the dashboard. The app tells an unconfirmed user that their address is
  not confirmed, rather than pretending the password was wrong.
- **For probes and tests that need a session**: use a real signed-in account
  (`rohit@arihant.com`, the only owner in the hosted project — found by **role**, not by
  address: the address this line originally named is no longer there), which is what every
  live probe since chunk C2 has done. The guard that refuses a hand-edited auth row stays
  exactly as it is.
- **For the app**: nothing changes. A future decision to allow self-service signup would
  revisit this and turn the dashboard setting off, or add the resend flow; the comment in
  `.env.example`, the README and the user manual now state the policy so the repository
  stops believing the opposite.
- **`config.toml`'s key is left alone**: it is not wrong, it is about a stack this
  project does not use.

---

## D-061 — Phase 6 Ships a Debug-Signed Release APK, for Sideloading

**Date:** 2026-09-19

**Status:** Active

**Decision:** The Android deliverable for Phase 6 is a **release-mode APK signed with
the debug key**, built with `flutter build apk --release`, copied to staff devices by
USB or a file share. **No upload keystore, no `key.properties`, no signing config**, and
**no Play Store listing**. `app/android/app/build.gradle.kts` keeps the Flutter
template's `signingConfig = signingConfigs.getByName("debug")`.

**Rationale:** The distribution channel the user actually needs is a handful of known
staff devices, not a store. A keystore is not a formality — it is a long-lived secret
whose loss is permanent (an app can never be updated under the same listing again) and
which has to be backed up and shared like one. Creating one now would be a decision made
without a reason, and generating and storing a key "just in case" is how a key gets lost.
The Play Console also brings a developer account, a data-safety declaration, a privacy
policy URL and a review cycle — all of which belong with the publish decision, not before
it.

**Consequences:**

- **The build is `--release`**, so it is AOT-compiled, not debuggable, and does not carry
  the debug banner: it is a real build of the app. It is *signed* with the debug key,
  which affects only how Android attributes the install — sideloading is unaffected.
- **A future Play publish is a reinstall for every staff device.** Play identifies an app
  by its signing key, so a proper upload key means a different signature, and Android
  will refuse to update over an install signed with another key. Staff must uninstall and
  reinstall once. This is accepted deliberately, and `docs/DEPLOYMENT.md` says so where
  somebody will read it before publishing.
- **`docs/DEPLOYMENT.md` keeps the full keystore/signing procedure**, marked as the
  publish-time work rather than deleted: the steps are the same whenever they are needed,
  and the file is where a future maintainer will look.
- **Nothing about the app depends on this.** When a keystore does arrive, the change is
  confined to `build.gradle.kts` plus a gitignored `key.properties` and `*.jks`, exactly
  as `docs/DEPLOYMENT.md` §3.2 spells out.
- Verified by the build that produced the APK; the artifact path and the fact that no
  keystore or signing config exists are recorded in `PROGRESS.md` and the chunk summary.

---

## D-062 — A Bill Gets Three Reads, and the First One Counts

**Date:** 2026-09-20

**Status:** Active

**Decision:** The bill reader's verify screen offers a **small text** "Read it again"
button (`TextButton.icon`, in the "What the reader saw" card, not a filled action), and
**one bill may be sent to the reader three times in a session, the first read included**.
The count is `PurchaseOcrState.reads`, incremented when a read *starts*
(`withReadStarted()`) and saturating at `PurchaseOcrState.maxReads == 3`. The counter
beside the button names **the attempt a tap would spend** — a form is only ever reached
through a successful read, so it opens at "Attempt 2 of 3" — the button is disabled while
a read is out and after the third (labelled **"Max attempts reached"**), and every
re-read asks first: *"Re-read? Uses one AI call."*

**Rationale:** Three things decided the shape.

- **The limit is a cost control, not a quality one.** The reader runs on a free-tier key
  with a per-minute budget (N-2/D-032) and every read is a request to a paid model, so a
  bill's reads are bounded the same way the matcher's are (D-036) — and the ask-first
  dialog is what makes the spend *deliberate* rather than accidental.
- **Counting the first read is what makes the number honest.** "Three reads of this bill"
  is a budget for the bill; counting only re-reads would permit four calls, and the
  counter would name a number that no read ever matched.
- **The count lives on the state, not in the widget.** It is a property of the bill, and
  the screen is rebuilt for every frame it is on.

**Consequences:**

- **N-8's transition is reachable at last.** The fix (a re-read keeps the supplier, the
  notes and every corrected line while taking the new parse) was *correct but latent* in
  chunk 2 — nothing a user could tap produced a second read. This button is that tap, and
  the widget test that proves it now drives the screen rather than the controller.
- **The automatic retry (D-032) is inside one read, not a second one.** A busy reader
  still gets its one immediate second chance; that is the same read, and it does not
  consume an attempt.
- **A failed read counts.** A read that times out still spent a request, and a limit that
  counted only answers would bound nothing. So a bill whose *first* read failed a few
  times arrives at the form with its allowance already spent, and the form says "Max
  attempts reached" straight away. Accepted: the reader had those reads.
- **The recovery path from a first read that never succeeded is deliberately NOT capped
  (N-13).** The failure card on the "choose a bill" screen calls `rescan()`, which this
  decision does not refuse: there the bill was never read, nothing on the screen can be
  saved, and refusing the last retry would strand the file (D-033). The consequence is
  that the limit is enforced where the bill has been *read* and not where it has only
  been *uploaded*. Closing that consistently means showing the same cap on that card —
  one screen's worth of work, recorded rather than done.
- **The verify form's own failure card is capped with it.** It offers "Read it again" too,
  and a failure does not earn a bill a fourth read; when the allowance is spent the button
  is disabled and the card says so. Leaving one of the two working would have put two
  re-read controls on the same screen contradicting each other.
- **`PurchaseOcrController.rescan()` stays permissive** — the *screen* decides what to
  offer. The alternative (refusing inside the controller) is what would have killed the
  recovery path above.

---

## D-063 — `vercel.json` Lives in the Root Directory, Not the Repository Root

**Date:** 2026-09-20

**Status:** Active

**Decision:** The Vercel configuration is committed at **`app/vercel.json`** — inside the
Flutter project, which is also the Vercel project's **Root Directory** setting. All its
paths are relative to `app/`: `outputDirectory` is `build/web`, and the install and build
commands run from inside `app/`. The runbook is
[`docs/DEPLOY_VERCEL.md`](docs/DEPLOY_VERCEL.md).

**Rationale:** Vercel reads `vercel.json` from **the project's root directory**, which is
the Root Directory setting — not from the repository root — and with a Root Directory
configured the build cannot read files outside it. Vercel's documentation is explicit on
both points: *"This file should be created in your project's root directory"*
(Static Configuration with vercel.json) and *"Your app will not be able to access files
outside of that directory. You also cannot use `..` to move up a level"* (Configuring a
Build → Root Directory). A copy at the repository root would therefore be **silently
ignored**, and the failure it produces looks like anything but a misplaced file: a build
with no Flutter SDK installed, no `build_runner` step (the `.g.dart` files are gitignored,
so a fresh clone has none) and an empty `.env` left behind by the env-var step.

**Consequences:**

- **The two arrangements that work, and the one that does not:**

  | Root Directory | `vercel.json` at | Result |
  | --- | --- | --- |
  | `app` | `app/vercel.json` | **Chosen.** `outputDirectory: build/web`; no `cd` anywhere |
  | *(empty)* | repository root | Also works, but every command needs `cd app &&` and the output directory becomes `app/build/web` |
  | `app` | repository root | **Broken.** Outside the Root Directory, never read |

- **`docs/DEPLOYMENT.md` §2.2's older snippet was corrected.** It carried
  `"outputDirectory": "app/build/web"`, which is right only for the empty-Root-Directory
  arrangement; both documents now say which arrangement they describe.
- **The build regenerates what git ignores.** `build_runner` runs inside the build
  command, before `flutter build web --release`, because `app/lib/**/*.g.dart` and
  `*.freezed.dart` are gitignored and a Vercel build starts from a clone.
- **The prebuilt route survives as the documented alternative** (build locally, deploy
  `app/build/web` as static output). It needs the Root Directory unset, and it ignores
  `app/vercel.json` — which is why `docs/DEPLOY_VERCEL.md` §8 spells the trade out rather
  than leaving the file's authority implicit.
- **Neither the file nor the runbook has been executed.** The Vercel account exists; the
  project has not been imported and no deploy has been made. The first deploy is the test
  of both, and `docs/DEPLOY_VERCEL.md` §7 lists the failures worth recognising when it
  runs.

---

## D-064 — A Purchase Is Found by Its Number, Its Notes, or Its Distributor

**Date:** 2026-09-20

**Status:** Active

**Decision:** The purchase-return form's invoice picker (I-3) is a **search dialog** built
on the same repository call the list screen pages with, not a list to scroll. One text
box covers **three things at once** — the invoice number, the notes written on the
purchase, and **the distributor's name** — alongside an invoice-date window; results
arrive **twenty at a time** with a "Load more" tile; and the field **carries the chosen
purchase** rather than deriving its label from whatever list it happens to hold.

The supplier branch is resolved by a **second query**, not a join: the term goes to
`SuppliersRepository.list` (which already searches name, GSTIN and phone), those ids go
into `PurchasesQuery.supplierIds`, and `PurchasesRepository.list` ORs them with the text
branches in **one disjunction** — `invoice_no.ilike.…,notes.ilike.…,supplier_id.in.(…)` —
while the status and date window keep ANDing as they always have. The three filter
builders live in `core/utils/postgrest_search.dart`, where a mistake is testable rather
than silent (D-014's reasoning, extended from `ilike` to `in.(…)`).

**Rationale:**

- **The 200-row bound was not a bug in a list; it was the wrong interaction.** A dropdown
  over received invoices works until a pharmacy has two hundred, and then a document that
  exists cannot be returned against. Search is what makes the list unbounded in practice.
- **One box beats three controls** for the question asked here ("which invoice are these
  goods from"): the person remembers an invoice *number*, a scribbled *note*, or *who it
  came from*, and not which of those they remember.
- **The two-query resolution is the version of this that could be verified from here.** A
  filtered join (`suppliers!inner(name)` inside `or=()`) would be one round trip, but its
  availability depends on the deployed PostgREST version and this project has no local
  stack to try it against; a maintained `search_text` column would need a migration, a
  backfill and a trigger that also fires when a supplier is *renamed*. The extra lookup is
  one indexed `ilike` per searched term.
- **A picker is not a browsing context.** The providers are the picker's own and
  auto-disposed (unlike the list screen's `keepAlive` filter), so a term typed here
  neither inherits nor disturbs the list screen's filters, and closing the dialog forgets
  it.

**Consequences:**

- **`returnablePurchaseLimit` and `returnablePurchasesProvider` are deleted.** Their own
  doc comment predicted this ("past it, the fix is the searchable picker the products
  already have"); the form is the only consumer either ever had.
- **The field owns its label.** `_purchaseLabel`'s `'Another purchase'` branch — the old
  code admitting it could not name a purchase outside the page it had loaded — is gone,
  and the label is built from the row the user tapped. `PurchaseCard`'s supplier-name map
  idiom is reused for the name, and an unresolved name is left off rather than failing
  anything.
- **Bounds, stated rather than hidden.** Twenty rows per page; the supplier branch is
  capped at `purchasePickerSupplierMatchLimit` (25), because it becomes an `in.(…)` list
  inside the filter; and the *name shown* on a row comes from `supplierOptionsProvider`,
  which has its own 500-row bound. Each narrows the answer rather than failing it, and
  each is recorded here rather than discovered later.
- **Four states, told apart** (T-5, D-058): rows, "no invoice matches this search",
  "no received purchases yet", and a search that *failed* — with its own sentence and its
  own retry. The empty-state test is `PurchasesQuery.hasSearch` rather than `isFiltered`,
  because this picker is scoped to received invoices from the moment it opens: the coarser
  question would tell somebody who typed nothing that nothing matched.
- **A failed "Load more" keeps the rows on screen** and reports itself under the list,
  rather than blanking a list the user is reading (the same trade as the list screen's
  `loadMore`).
- **Verified:** 11 controller tests (scope, paging, search by number, search by
  distributor, one supplier resolution per result set, a term with nothing searchable in
  it, date window, failure, and a failed page keeping its rows), 9 widget tests (the label,
  the four states, both searches, Load more, the date control) and 8 tests over the filter
  builders; 665 Flutter tests in total.
- **The filter was then sent, read-only, against the hosted PostgREST** with a signed-in
  session, and the construct this was worried about is accepted: an `or=()` containing
  `ilike` branches **and a `supplier_id.in.(…)` uuid list** parses and answers **200** — one
  id, three ids, and the branch alone, all 200. A deliberate negative control (`or=()`,
  malformed) answered **400 `PGRST100`**, so the 200s are the server accepting the tree and
  not a harness that ignores errors. A term containing `,` and `%` sanitises to a clean
  pattern (`arihant 650`) and the encoding round-trips (`%` → `%25`, space → `%20`); no 400,
  no injection surface. Exact URLs and bodies are in `context/chat3n-summary.md`; the
  harness had to be corrected first (it sent `or=()`, which the app never does — both
  repositories guard with `if (search != null)`), and that 400 was the harness's own bug.
- **What that probe does NOT establish, and it is the half that matters to a user:** the
  tenant holds **zero purchase rows of any status and zero suppliers**, so no case could
  return a row. *Parsing* is proven; *matching* is not — "finds the invoice by distributor
  name" has never been seen to work against real data, and the three-read SYN cases could
  equally have matched nothing. Needs a tenant with received invoices and suppliers in it.
  This is N-9's shape: a measurement the project cannot make yet because the data it needs
  does not exist.
- **One defect was found by reading the code path, not by the probe** (the empty tenant
  cannot show it): `_withSupplierMatches` guarded on the *raw* term, so a term that
  sanitises to nothing (`%%`, `,`) still ran the supplier lookup — which, with an empty
  search, applies no filter and returns the first page. A term that means nothing would
  have answered with the first twenty-five distributors' invoices. The guard is now on
  `sanitizeSearchTerm(query.search).isEmpty`, with a regression test asserting the lookup is
  not made at all; a meaningless term now behaves as it does in the products picker — like
  no term.

---

## D-067 — A Sale Has One of Four Types, and the Type Decides Its Rate, Its Bill and Whether a Hospital Shares

**Date:** 2026-09-20

**Status:** Active (recorded for Phase 7 — not started)

**Revised 2026-09-20, for the second time.** The first version of this entry had **three**
types and folded an admitted patient into the package flow. That was wrong in two
directions: an **IPD sale is retail-priced to an admitted patient** and is not a package at
all, and **a package sale is not a sale to a patient** — the hospital is the buyer. The
three-type text is superseded.

**Decision:** Phase 7 gives a sale one of four types, and the type decides its rate, what its
bill carries, and whether a hospital shares in its profit (D-068):

| `sale_type` | Rate | Hospital share | The bill carries |
|---|---|---|---|
| `counter` — a walk-in, hospital or outside patient | MRP − discount | **yes** | `patient_name` (**mandatory**), `patient_mobile` (**mandatory**), `patient_address` (optional), `doctor_name` (**mandatory for Schedule H/H1/X**) |
| `ipd_admission` — an admitted patient | MRP − discount | **yes** | the counter fields **plus** `hospital_reference` (the OPD/IPD number, **mandatory**) |
| `package` — the hospital buying for its own package patients | purchase rate + `pharmacies.package_markup_percent` | **no** — the hospital is the buyer, not a partner | patient fields **optional** (the hospital already holds the patient); `hospital_reference` |
| `transfer` — stock moving between locations | purchase rate, **no markup** | **no** | `from_location`, `to_location`, `reason`, `transfer_note_no` |

**"Pharmacy sale" is the business's umbrella name for the first two.** Counter and
`ipd_admission` are what it calls a pharmacy sale: both are retail-priced, both are subject
to the 10% discount limit (D-071), and both carry a hospital share (D-068). **Package and
transfer are separate categories** — neither is a pharmacy sale, neither has a discount
concept, and neither carries a share.

A transfer never leaves the owner's hands, so **no GST** is charged on it.

**Database (Phase 7):** a new `sale_type` enum (`counter`, `ipd_admission`, `package`,
`transfer`) and **twelve** new columns on `sales`: `sale_type` (`not null default 'counter'`),
`hospital_id` (**a snapshot** — set from the pharmacy's own hospital), `patient_name`,
`patient_mobile`, `patient_address`, `doctor_name`, `doctor_id` (→ the new `doctors` master,
D-072), `hospital_reference`, `from_location`, `to_location`, `transfer_note_no`, and
`discount_above_limit_request_id` (D-071). `customer_id` already exists and stays what it is
— the registered-patient link.

**`doctor_name` and `doctor_id` are a prescription record, not a profit-sharing one.**
Doctors take no share of anything (D-068); the names are on the bill because a pharmacy must
be able to say who prescribed what, and on a Schedule H/H1/X line the prescriber's name is
not decoration.

**Rationale:** four flows with four different economics. A counter sale is priced off the
label and has to be findable later. An `ipd_admission` sale is that same retail sale with an
admitted patient — same price, same share, plus the hospital's own number so the bill can be
tied to a bed. A package sale inverts who the customer is: the hospital buys for its
patients, at cost plus a service markup, and taking a share of it would be taking a share of
a fee the owner charges the hospital for the service (D-070). A transfer is not a commercial
sale at all — it is stock moving. The rate rule belongs to the type because a discount is a
retail idea, a markup is a package-service one, and a transfer has neither.

**Consequences:**

- **`sales` has none of this today** (`supabase/migrations/20260918000006_sales_tables.sql:3`)
  — no `sale_type`, no hospital, no patient, no doctor, no transfer columns — and `sale_type`
  is not among the types in `20260918000002_enums.sql`. Phase 7 is one **additive** migration,
  the same shape as the alias-key migration Phase 6 added (D-056).
- **The second version's `package_reference` and `transfer_to` are withdrawn before either
  was built.** The corrected model names `hospital_reference` for the patient identity, and
  `from_location` / `to_location` / `transfer_note_no` for a transfer. Nothing in the tree
  references the old names.
- **`patient_id` was resolved on 2026-09-20.** An earlier version carried a `patient_id` as
  well as a `hospital_reference` and left the next chat to guess whether they were one column
  or two. It is **one** column — `hospital_reference`, the OPD/IPD number — and `patient_id`
  is not a column.
- **The markup's source is settled** (it was the open gap in the previous version): it is a
  per-pharmacy setting, `pharmacies.package_markup_percent`, fixed when the pharmacy is
  configured — e.g. 20% for one hospital, 15% for another (D-070).
- **`sale_items.discount_percent` already exists** (`20260918000006_sales_tables.sql:24`, with
  `discount_amount` beside it), so "the final applied discount" needs no new column; the
  approval side of the discount rule is D-071.
- **`sales.hospital_id` is a snapshot, and the brief says so explicitly.** It duplicates what
  `pharmacies.hospital_id` says, because one pharmacy sits in exactly one hospital — and it is
  kept anyway so that a pharmacy changing premises cannot rewrite a month already settled.
  That is the same reason D-068's share rule and these sale lines carry their own values.
- **An unstated GST interaction is now visible, and it is the same question as N-14.** The
  counter and `ipd_admission` flows charge GST (it is implemented today — `sale_items.gst_percent`
  and its four tax columns, D-057), while the transfer flow does not. `package` is unstated.
  The GST question (N-14) therefore has to be answered before these four bills can be printed
  correctly, not after.
- **The bill's mandatory fields are per type, and nothing in the schema enforces them yet.** A
  counter bill must carry a mobile and an IPD bill must carry an OPD/IPD number, but all twelve
  columns are nullable, because a single `sales` table holds four shapes. Whether Phase 7 adds
  per-type `CHECK` constraints or leaves the rule to the RPC and the screens is a Phase 7
  choice, and it is recorded here rather than discovered in the DDL.
- **`sale_type` defaults to `counter`**, which is the right default for this business (it is
  the commonest sale) and the wrong one for a caller that forgets to send it: an omitted
  `ipd_admission` would post as a counter sale and still be retail-priced and shared, but lose
  the OPD/IPD requirement. The default is recorded as the brief gives it.
- **`sales.customer_id` already exists** and references `customers`
  (`20260918000004_master_tables.sql:23`). A counter patient is not necessarily a customer
  row, so Phase 7 decides whether a counter sale finds-or-creates a customer, or stays
  denormalised on the sale the way the patient columns suggest it does.
- **The rate and the markup are server-side rules.** D-023 puts a sale in one RPC with its
  stock posting per line, and D-011/D-013/D-023 keep stock on triggers, so "purchase rate +
  `package_markup_percent`" belongs in the sale RPC, resolved from the pharmacy's own setting —
  never in a widget's arithmetic. The same RPC is where `hospital_id` must be filled from the
  pharmacy rather than trusted from the payload, as `checkout_sale` already does for
  `pharmacy_id` (`20260918000019_phase3_sale_automation.sql`).

---

## D-068 — Hospital Profit Sharing, and the Doctor Is Not a Partner

**Date:** 2026-09-20

**Status:** Active (recorded for Phase 7 — not started)

**Revised 2026-09-20.** This entry was written earlier the same day as "Doctor Profit
Sharing", with each doctor taking a percentage of the profit on what they referred. That
was a misreading of the business and is superseded here: **the profit-sharing partner is
the hospital a pharmacy sits in**, and a doctor takes nothing. Nothing had been built from
the earlier text — no migration, no table, no screen — so nothing in the tree carries it.

**Decision:** Phase 7 records on each sale line what the goods cost, and splits the gross
profit between the owner and the **hospital** whose premises and patient flow the pharmacy
sells through.

- **`hospitals`** — `(id, name, address, city, state, contact_person, contact_phone,
  contact_email, gstin, notes, is_active, created_at, updated_at)`. The table **does not
  exist yet**; Phase 7 creates it.
- **`pharmacies.hospital_id`** — references `hospitals`. A pharmacy sits in **exactly one**
  hospital, so this is a column and not a join table.
- **`hospital_profit_sharing`** — `(id, pharmacy_id, hospital_id,
  gross_profit_share_percent, effective_from, effective_to, notes, created_at, updated_at)`.
  A share is a **dated** rule, so a deal that changes does not rewrite a month that was
  already settled. (`pharmacy_id` is the tenant scope every business table carries under
  D-004/D-015; `hospital_id` names the partner.)
- **`sale_items`** gains `cost_basis_per_unit` (`numeric(12,4)`), `cost_total`
  (`numeric(14,2)`) and `gross_profit` (`numeric(14,2)`) — **snapshots taken at sale time**,
  because cost changes over time.
- **The share applies to two of the four sale types only: `counter` and `ipd_admission`** (the
  "pharmacy sale" pair — D-067). A `package` sale and a `transfer` carry **no hospital share
  at all**, because on neither is the hospital a profit-sharing partner: on a package sale it
  is the *buyer* (D-070), and a transfer is stock moving between the owner's own locations.
- **The shares as configured:** Arihant → Rohit Kidney & Stone **50%**; Erika Prime →
  Govardhan **60%**; Medicotraders → Jain **0%**; Sudha → Pandey **0%**. The mapping is in
  `PROGRESS.md`.
- **0% is a value, not an absence.** Medicotraders and Sudha have a real 0% deal: no share
  transaction is written and the whole gross profit is the owner's. **Nothing may read a 0%
  rule as "no rule configured"** — not a query that falls back to a default, not a report
  that skips the hospital, not a settlement that treats it as unconfigured.
- **The arithmetic (confirmed):** `Sale Value = ₹X`; `Purchase Cost (COGS from the batch) =
  ₹Y`; `GP = X − Y`; `Hospital Share = GP × share%`; `Owner Share = GP − Hospital Share`; and
  monthly, `Owner Net = Σ Owner Share − Σ Expenses`.
- **The owner bears the expenses.** A hospital's share is a share of gross profit and is not
  reduced by them — which is why the two reports below give two different numbers. The
  expense categories are D-069.
- **RPCs:** `pharmacy_monthly_pnl(pharmacy_id, month)`, `hospital_monthly_settlement(hospital_id,
  month)` — the latter for **hospitals whose share is above 0%** — plus D-070's
  `package_sale_monthly(pharmacy_id, month)` and D-072's
  `doctor_referral_report(doctor_id, from, to)`.

**Rationale:**

- **A doctor is not the party the pharmacy pays for its position.** The partner is whoever
  supplies the space and the patient flow, and here that is the hospital, which takes a
  percentage of gross profit in exchange for both. The deal is therefore a property of the
  (pharmacy, hospital) pair and of a date range, in the same way a landed cost is a property
  of a purchase rather than of a product (D-012).
- **Doctors belong on a sale for a clinical reason, not a commercial one.** A prescription
  must name who wrote it; that is what `doctor_name`/`doctor_id` are for (D-067). Paying a
  share to a prescriber would be a different and far more sensitive arrangement than the one
  the owner describes — recording it as this project's model was simply wrong.
- **A dated rule, because a deal changes.** 50% at one hospital and 60% at another is the
  normal case in this group, and a renegotiation must not move a month already settled.
- **The owner's share is the residue**, `GP − Hospital Share`, so the split balances by
  construction and rounding lands on the owner rather than on the hospital.
- **A snapshot, because the alternative is a silent rewrite.** A sale's gross profit computed
  later from live cost would move every time a purchase rate moved, and a settled month would
  move with it.

**Consequences:**

- **Neither `hospitals` nor `hospital_profit_sharing` exists in this repository.** No
  migration creates either, and "hospital" appears in the tree only as prose in `DECISIONS.md`
  and `MASTER_PLAN.md`. `pharmacies.hospital_id` does not exist either: `pharmacies`
  (`supabase/migrations/20260918000003_core_tables.sql:3`) carries `name`, `address`, `city`,
  `state`, `pincode`, `phone`, `email`, `gstin`, `drug_license_no` and `logo_url`, and no
  hospital link. All three are Phase 7 additions, and the first two need `pharmacy_id` scope
  and RLS to match every other tenant table (D-004/D-015).
- **`profit_sharing_rules` is withdrawn before it was ever built**, replaced by
  `hospital_profit_sharing`. Nothing in the tree references the old name.
- **`doctors` is no longer a profit-sharing table — and is still not a table at all.** The
  earlier text had `doctors` gaining `default_profit_share_percent`; that column is **dropped**,
  because a doctor takes no share. But `doctor_id` is still in the corrected sale field list
  (D-067), so Phase 7 must decide whether it needs a `doctors` master (a name plus an active
  flag, scoped to the pharmacy) or whether `doctor_name` alone is enough. The corrected brief
  names the column and does not ask for the table.
- **The cost snapshot is the input the report screen already says it is missing.**
  `report_summary`'s `contributedMargin` is billed less refunds less expenses
  (`app/lib/data/models/report_summary.dart:249`), and the screen prints its own admission
  beside it: *"Gross margin needs the cost of each sale line."*
  (`app/lib/features/reports/presentation/reports_screen.dart:310`). `sale_items.cost_total`
  is that line — so Phase 7 is where that card can stop being a substitute for a margin.
- **D-021/D-012 are why it must be a snapshot.** The inventory views carry **today's** landed
  cost, not what the goods cost when they left the shelf, so a later join to a batch would
  answer a different question than the one a settlement asks (`sale_items.cost_basis_per_unit`
  is therefore the batch's landed cost at the moment of sale).
- **D-025 applies to the split.** Gross profit, the hospital's share and each settlement are
  server-side aggregates — the two RPCs above — never rows summed in Dart, and never a figure
  a screen recomputes.
- **`pharmacy_monthly_pnl` and `hospital_monthly_settlement` disagree by construction** — one
  is net of the expenses and the other is not — and each should say so where a person reads
  it, because two different numbers for "the month's profit" otherwise look like a defect.
- **The four-to-four mapping is recorded** in `PROGRESS.md` (Arihant → Rohit Kidney & Stone,
  Erika Prime → Govardhan, Medicotraders → Jain, Sudha → Pandey), so the Phase 7 seed has a
  source of truth to write from rather than a memory.
- **The RPC name is now confirmed rather than inferred.** The previous version recorded
  `hospital_monthly_settlement(hospital_id, month)` as an inference from the report rename;
  the corrected brief names it itself, alongside `package_sale_monthly` and
  `doctor_referral_report`.
- **The GST basis is settled by the owner, and it is a business decision rather than an
  accounting correction.** `gross_profit = sale_value − cost_total`, **both GST-inclusive**;
  `hospital_share = gross_profit × percent`; `owner_share = gross_profit − hospital_share` —
  and **the owner pays the GST out of `owner_share`**. In the owner's own words:

  > GST is borne by the owner from their share. Hospital share is calculated on GST-inclusive
  > gross profit, per owner's business model. Owner accepts that GST liability reduces their net.

  The arithmetic that made this worth asking about is real and unchanged: `sale_items.total_amount`
  **is** tax-inclusive — `checkout_sale` derives the header's taxable value as `grand_total −
  tax_total` (`supabase/migrations/20260918000019_phase3_sale_automation.sql`) — so a 50% share
  of a tax-inclusive gross profit does pay the hospital half of the tax the pharmacy remits.
  That is now the **accepted model, deliberately**: the hospital's deal is a share of the full
  margin, and the tax is a cost the owner carries. The taxable-value alternative
  (`GP = (total_amount − tax_amount) − cost_total`) is therefore **not** the formula, and it is
  recorded here only so that the rejection is visible rather than rediscovered.
- **N-14 stays open, but only for compliance — the formula no longer waits on it.** Whether GST
  is charged on a retail sale at all, and whether this pharmacy sits in a hospital-exempt
  category, is still an open question (`PROGRESS.md` N-14). **The profit-sharing formula is not
  affected by that answer:** if N-14 comes back "no GST on B2C", the tax columns carry zeros and
  the formula above computes exactly the same thing.
- **A 0% hospital must still get an answer.** `hospital_monthly_settlement` is defined for
  shares above 0%, and the "0% is a value" rule above means a 0% hospital must remain
  answerable: *"0% share — nothing owed"* is a different answer from *"no rule"*, and the two
  must not render the same way.

---

## D-069 — Expense Categories Become One Fixed List, and the Monthly P&L Is One RPC

**Date:** 2026-09-20

**Status:** Active (recorded for Phase 7 — not started)

**Decision:** Phase 7 standardises `expenses.category` to one fixed set — `salary`,
`staff_food`, `breakage`, `stationery`, `printer`, `utilities`, `rent`, `misc` — and adds
`expense_summary(pharmacy_id, month, category)` plus the expense-breakdown report.

**Rationale:** the point of recording an expense is to report on it, and "rent", "Rent" and
"shop rent" are three categories that cannot be added up. A fixed list is also what makes
`expense_summary`'s third argument meaningful rather than a `like` pattern over prose.

**Consequences:**

- **The app already keeps a fixed list, and it is a different list.** `expenseCategories`
  (`app/lib/data/models/expense.dart:47`) offers *Rent, Salaries, Electricity, Freight,
  Licences, Maintenance, Marketing, Other*, and that is what the form writes and the
  repository saves (`app/lib/features/expenses/presentation/widgets/expense_sheet.dart:81`,
  `app/lib/features/expenses/data/expenses_repository.dart:82`). Against the Phase 7 set it
  is missing `staff_food`, `breakage`, `stationery` and `printer`, it carries four categories
  the set does not (`Freight`, `Licences`, `Maintenance`, `Marketing`), and it is Title Case
  where the set is lowercase tokens. **Reconciling the two is a decision, not a
  translation**, and it has to be taken before the constraint: the report cannot group what
  has two vocabularies.
- **The column is unconstrained today.** `expenses.category` is `text not null` with no
  `CHECK` and no enum type (`supabase/migrations/20260918000007_ledger_tables.sql:49`), and
  there is no expense-category type in `20260918000002_enums.sql`. A `CHECK` (or an enum)
  therefore arrives with a **backfill**: existing rows hold Title Case strings from the
  client's list, and a constraint naming only the new tokens refuses every one of them until
  they are mapped — and the mapping is the half that can fail the migration.
- **One vocabulary, three readers.** The DB constraint, the client's list and the report's
  grouping all have to agree. Today only the first two exist, and they already disagree with
  the Phase 7 set.

---

## D-070 — A Package Sale Is a Service the Hospital Buys, Priced at Cost Plus a Per-Pharmacy Markup

**Date:** 2026-09-20

**Status:** Active (recorded for Phase 7 — not started)

**Decision:** A `package` sale (D-067) is priced at **purchase rate + the pharmacy's own
markup**, and that markup is a **per-pharmacy setting** fixed when the pharmacy is
configured — not negotiated per sale:

- `pharmacies.package_markup_percent numeric(5,2)`, **default 20** (e.g. 20% for one hospital,
  15% for another).
- The rate is `purchase rate × (1 + package_markup_percent/100)`, the same for every package
  sale from that pharmacy, and the hospital takes it as-is.
- **No discount** concept on a package sale, and **no hospital share** (D-068).
- The **pharmacy** holds and maintains the stock and **absorbs chori / breakage / wastage**;
  the hospital pays purchase cost + markup.
- RPC: `package_sale_monthly(pharmacy_id, month)` → total cost, total markup, and the total
  the hospital owes.

**Rationale:** on a package sale the hospital is not sharing this pharmacy's profit — it is
buying a service (stock held, stock maintained, losses carried) at a fixed fee on cost. That
is why the markup is a configuration value rather than a per-sale negotiation, and why the
share is zero: taking a share of the markup would be taking a percentage of the fee the
owner is charging the hospital. The risk-bearing is what the markup is *for*.

**Consequences:**

- **`pharmacies` has no such column today.** `pharmacies`
  (`supabase/migrations/20260918000003_core_tables.sql:3`) carries `name`, `address`, `city`,
  `state`, `pincode`, `phone`, `email`, `gstin`, `drug_license_no` and `logo_url`.
  `package_markup_percent` is a Phase 7 addition, and the four per-pharmacy values are an open
  item (the owner supplies them; the default is 20).
- **A not-null default of 20 makes "unconfigured" indistinguishable from "intentionally
  20%".** The brief asks for the default *and* for per-pharmacy values to be supplied later;
  with a default, a pharmacy nobody configured silently prices package sales at 20%. This is
  the mirror of D-068's 0%-is-a-value rule — there a value must not be read as absence, here
  absence produces a value — and whether an unconfigured pharmacy should instead *refuse* a
  package sale is recorded as an open item rather than decided here (MASTER_PLAN.md Phase 7
  §7).
- **The rate is computed server-side** (D-023): it is `purchase rate × (1 + …)` inside the
  sale RPC, never in a widget's arithmetic.
- **Which "purchase rate" is unstated, and the two candidates differ.** D-012's **landed cost**
  (what the batch actually cost, inclusive of freight and scheme effects) and the **rate
  printed on the purchase invoice** are not the same number, and `package_markup_percent`
  multiplies whichever is chosen. It is recorded as "purchase rate" as the brief gives it, and
  flagged as needing a decision before the RPC is written.
- **Risk-bearing is a commercial term, not a schema term.** Nothing in the schema enforces
  that the pharmacy absorbs breakage; it is recorded here so that a later reader does not
  model `chori`/breakage on a package sale as a *hospital* liability, and so the `breakage`
  expense category (D-069) is understood to be the pharmacy's own cost.

---

## D-071 — A Discount Above 10% Needs the Owner's Approval, and the Sale Carries the Approval's Id

**Date:** 2026-09-20

**Status:** Active (recorded for Phase 7 — not started)

**Decision:** On a `counter` or `ipd_admission` sale (D-067) a discount is capped at **10%**
without approval. Above 10% the staff **cannot apply it**: it must be requested, the owner
approves, and only then is it applied. Package and transfer sales have no discount concept.

- The approval uses the **`approval_requests` infrastructure of Phase 6.5c** — the approval
  RBAC — rather than a second approval mechanism invented for billing.
- `sale_items.discount_percent` is the **final applied discount** (it already exists), and a
  sale above the limit carries `sales.discount_above_limit_request_id` →
  `approval_requests(id)`.
- **The behaviour is blocking, and it is confirmed rather than proposed** (owner, 2026-09-20):
  an above-limit discount cannot be recorded until it is approved — the decision is taken while
  the sale is in progress, not written first and approved retroactively.

**Rationale:** the 10% cap is a control the owner already enforces by hand, and a control that
can be bypassed by writing the sale first and approving it later is not a control — it is a
reporting artefact, and by then the customer has walked away with the goods. Blocking is what
makes "staff cannot apply it" true rather than aspirational. The id on the sale is what lets a
month's discounts be reconciled against the approvals that authorised them.

**Consequences:**

- **The dependency on Phase 6.5c is hard, and it fixes the sequencing (owner, 2026-09-20).**
  The **full approval system is built as Phase 6.5c, before Phase 7**, because one unified
  mechanism serves many actions — a sale edit, a purchase delete, a return, a stock adjustment,
  **a discount above 10%**, a customer or product edit — rather than two parallel systems for
  one idea. So `sales.discount_above_limit_request_id` is a **real foreign key to
  `approval_requests(id)` once 6.5c lands** — **not a soft reference**, and not an id the client
  is trusted to invent. **Phase 7a (the sale types) cannot be built before 6.5c completes**,
  which is now the plan's stated order (`MASTER_PLAN.md`, Phase 7 → Sequencing).
- **`approval_requests` does not exist yet.** No migration creates it and no table, function or
  Dart file references the name; Phase 6.5 is still a stub. Its shape is **action-type based —
  a table with an `action_type` enum and a `payload` jsonb** — and **the exact list of action
  types is still to be provided by the owner**, at 6.5c design time. Until then this foreign key
  has no target, which is precisely why the order matters rather than being a preference.
- **The brief puts the reference in two different places.** The prose says *"if > 10%,
  sale_item requires an approval_request_id reference"*; the schema block puts
  `discount_above_limit_request_id` on **`sales`**. It is recorded on `sales` per the schema,
  and flagged: a **per-line** approval is a different design from a **per-bill** one, and they
  diverge the moment one bill mixes a 5% line with a 15% line.
- **`sale_items.discount_percent` and `sales.discount_total` already exist**
  (`20260918000006_sales_tables.sql:24` and `:3`), and `checkout_sale` already writes both from
  the payload, so "the final applied discount" needs no new column.
- **What the 10% is a percentage *of* is unstated.** `sale_items.discount_percent` is a
  percentage of the line's own rate, so the cap is recorded as **per line**; a per-bill cap on
  the total discount would need a different check and a different column.
- **The limit belongs in one place, server-side.** A cap enforced only in the POS screen is a
  suggestion: `checkout_sale` is the single write path for a sale (D-023), so the rule has to
  hold there, with the client's copy of it existing to explain a refusal rather than to
  enforce it.
- **A blocked sale is not a failed sale.** Somebody mid-bill whose discount needs approval is
  holding a live customer, so the refusal's wording and what the POS does with the half-built
  bill matter as much as the rule. A Phase 7 UI decision, noted here so it is not discovered at
  the counter.

---

## D-072 — Doctors Are a Master Table, Because Referrals Are Tracked and Never Paid

**Date:** 2026-09-20

**Status:** Active (recorded for Phase 7 — not started)

**Decision:** Phase 7 adds a **`doctors`** master — `(id, pharmacy_id, name, specialization,
contact, is_active, created_at, updated_at)` — and `sales.doctor_id` references it, while
`sales.doctor_name` keeps the spelling the prescriber actually used on that bill.

- **No commercial column.** The `default_profit_share_percent` that the first version of D-068
  put on this table is **gone**: a doctor takes no share of anything (D-068).
- `doctor_referral_report(doctor_id, from, to)` is an **optional trend** — how many
  prescriptions, of what — and is **not** a settlement.

**Rationale:** a prescriber's name is repeated on every bill and then grouped across them,
which is a master-data problem — the same reason suppliers and customers are tables rather
than columns on a document. It is not a commercial relationship, and the table is deliberately
stripped of anything that could be mistaken for one. The name stays on the sale as well as
being linked, because a bill is a document: re-pointing a doctor master later must not rewrite
what a printed bill said.

**Consequences:**

- **The table does not exist.** No migration creates `doctors`; `grep` for "doctor" over the
  tree matches nothing but `flutter doctor` in `README.md` and the prose in these decisions.
  This closes the question the previous version of D-068 left open — a `doctors` master *is*
  wanted — and drops that version's `default_profit_share_percent` with it.
- **Scoped by `pharmacy_id` per the brief, and that has a consequence:** a doctor who
  prescribes at two of the four pharmacies is **two rows**. That is consistent with every
  other tenant table (D-004/D-015) and with how one pharmacy's records work, but it means a
  cross-pharmacy "this doctor's referrals" figure is a group-by-name question rather than a
  `doctor_id` one. Worth knowing before anyone builds a group-level referral report.
- **The name is not the identity.** `doctor_name` on the sale is what the bill printed; a
  doctor whose name is typed three ways is one master row and three spellings. Which is why
  the referral report reads the master and the bill reads the sale.
- **A Schedule H/H1/X bill requires the prescriber (D-067)**, so this is not decoration:
  `sale_items.schedule_type` exists precisely to drive statutory register reporting
  (`20260918000006_sales_tables.sql`), and a register that cannot name the prescriber is not
  a register.

---

## D-065 — The Opening Stock Import Reads the File in the App and Decides in the Database

**Date:** 2026-09-20

**Status:** Active (Phase 6.5a, built)

**Decision:** The one-time import of a pharmacy's existing stock is two halves with one owner
each. The **client reads the bytes** — it splits the CSV into records, honours quoting and
encodings, trims each field's edges and keeps its inside, and sends every value as **text**.
The **database decides everything else**: `opening_stock_classify()` parses each field,
validates it, matches the name against the catalogue and classifies the row, and both
`preview_opening_stock()` (which writes nothing) and `commit_opening_stock_import()` (which
writes everything) call **that same function**, so a preview cannot promise something the
commit refuses.

- **CSV only.** `import_jobs.source_format` accepts `'csv'` and `'xlsx'`, but only `'csv'` is
  written: the owner's export is a CSV, and reading a spreadsheet would need a parser in an
  Edge Function to be worth anything. The column keeps the value for the day one exists.
- **The route is `/settings/import/opening-stock`**, not a top-level `/import/…` (D-022): the
  shell lights a destination by prefix, and a one-time migration the owner runs once belongs to
  the settings it is reached from rather than to a fourteenth rail entry the shell has no room
  for (D-018).

**Rationale:** every rule about what an opening-stock row may contain ends up mattering twice —
once when the owner is looking at a preview and once when the file is written — and two
implementations of "is this row acceptable?" is how the two come to disagree. The Dart side
therefore owns only what the server cannot see: the file's bytes. It is also the reason
`normalize_product_name()` is reused rather than re-expressed: the app never normalizes a name
at all, so the matching rule the alias learner already uses is the only one in play.

**Consequences:**

- **The client validates nothing but the header.** A blank name, a negative quantity, a date
  that is not `YYYY-MM-DD` and a non-numeric rate are all refused by the server, each with the
  line number and a sentence — `qty "abc" is not a whole number` — which is what lets the screen
  list every bad row at once instead of the first one it happens to parse.
- **A field that cannot be read is refused rather than dropped.** An unparseable expiry is an
  error, not a null: silently discarding a date the owner wrote would hide a broken column in
  their export, which is exactly the failure the preview exists to catch.
- **The reader is a small RFC 4180 reader**, not a split on commas, because
  `normalize_product_name()` strips commas out of item names — which only makes sense if a name
  may contain one — and a quoted field must survive intact. It handles a byte-order mark, CRLF,
  doubled quotes inside a quoted cell, blank lines and a trailing newline, and it refuses an
  unclosed quote.
- **Row numbers count data rows** (1 = the first row after the header), and they are the same
  number in the preview, in a refusal and in the audit trail, because the payload the server
  reads is that list in that order.
- **Four functions, and one of them is internal.** `opening_stock_classify(uuid, jsonb)` is
  granted to **no role** — its callers are SECURITY DEFINER and gate on the owner and the tenant
  before it runs. The three public ones (`preview_opening_stock`, `commit_opening_stock_import`,
  `get_import_job`) are granted to `authenticated` and revoked from `anon, public`, per
  migration 00018's finding.
- **`digest()` needed qualifying.** pgcrypto lives in Supabase's `extensions` schema, and every
  function here pins `set search_path = public`, so the fingerprint is
  `extensions.digest(...)` — the same qualification migration 00022 uses for
  `extensions.vector(768)`. Migration 00032 exists solely to correct that call in 00031, where it
  had been written unqualified and failed only at runtime on a valid payload.

---

## D-066 — The Import Is All-or-Nothing, Idempotent by Content, and One Batch Per Product

**Date:** 2026-09-20

**Status:** Active (Phase 6.5a, built)

**Decision:** The commit is one transaction that either writes every row or refuses the file,
and it is idempotent **by content**:

- `import_jobs` has `unique (pharmacy_id, content_fingerprint)`, where the fingerprint is a
  sha256 over the canonical rows — item name normalized, batch number and expiry trimmed and
  lowered, money at the two places the columns hold — **sorted**, so the same rows in another
  order, under another filename, or with a row's outer whitespace trimmed, are the same import.
- Idempotency is decided by the **insert**, not by a select-then-insert: `on conflict do nothing`
  is what arbitrates two identical uploads at once, and the loser finds the committed job and
  answers with its id (and `idempotent: true`). Nothing claims success before the commit, because
  the answer is built from rows this transaction wrote.
- **A refusal is total and row-numbered.** Unreadable rows and **ambiguous** names are both
  refused, in one message naming every affected line (capped at 25, with a count of the rest).
- **One batch per product**, enforced rather than assumed: two rows whose names normalize alike
  are refused, because opening stock is one batch per product by definition and the alternative is
  either double stock in two batches or a silently dropped row.
- **Unknown is a value, not an absence.** A blank batch number becomes `OPENING-<first 8 of the
  product uuid>` with `is_unknown_batch`, and a blank expiry is **NULL** —
  `product_batches.expiry_date` had to lose its NOT NULL for that, and `batch_status` gained a
  fourth expiry bucket, `'unknown'`, because the old CASE would have reported a batch nobody can
  date as having more than ninety days of shelf life.
- **Opening stock is not a financial event.** No purchase, no purchase line, no payment, no
  ledger entry, no sale, no stock adjustment. `landed_cost_per_unit` is set equal to
  `purchase_rate` (D-012's formula with no freight and no free quantity), and `selling_rate` is
  left at its 0 default so the till prices at MRP until the owner sets counter prices.
- **The GST slab is stored, nullable, with no default.** `products.gst_percent`,
  `cgst_percent` and `sgst_percent` are new columns and the import writes 5.00 / 2.50 / 2.50 on the
  products it creates. `default 5.00` was rejected: every pre-existing product would then read as
  5, including the ones already bought and sold at 12, and "nobody has said" would stop being
  distinguishable from "five per cent" — which is D-068's own rule about 0.
- **Neither new table has a write policy.** `import_jobs` and `import_job_rows` are written only
  by the SECURITY DEFINER RPC and hold a select policy for the owner; a client cannot insert a row
  claiming `status = 'committed'`, which is the audit record the owner would otherwise trust.

**Rationale:** an import that half-succeeds is worse than one that fails, because the owner has no
way to know which half — and the file is a one-time migration, so re-running it is cheap. The
fingerprint exists for the same reason: the first thing an owner does after a refusal is fix the
file and upload it again, and the second thing they do is upload it again by accident.

**Consequences:**

- **Two of the four `status` values are unreachable from this path.** A refused import raises and
  takes its own `import_jobs` row with it, so `'failed'` and `'rolled_back'` are vocabulary rather
  than behaviour — recorded in the migration's comment so a later reader does not go looking for
  the code path that writes them.
- **A batch number the pharmacy already holds refuses the whole file** with a row-numbered
  message (`unique_violation`), rather than adding quantity to the existing batch: opening stock
  states a quantity, it does not add one, and a merge would be invisible in the audit trail.
- **The fingerprint covers well-formed content only.** A file with an unreadable row has no
  canonical content, so it has no fingerprint and the preview offers no "already imported" — the
  commit refuses before it looks for one. Content that is well-formed but ambiguous *does* get a
  fingerprint, because the fingerprint names content rather than importability.
- **The client must render an expiry state the app has never shown before.**
  `expiryStatusFromDb` maps anything it does not recognise to `ExpiryStatus.safe`, so an
  unknown-expiry batch currently wears the "more than 90 days of shelf life" badge. That label is
  the inventory screens' to add, and it is recorded as an open item rather than fixed here,
  because this chunk does not own those screens.
- **Re-running is free and safe:** the same content answers with the first job's id and writes
  nothing, which `supabase/tests/opening_stock_import.sql` asserts four ways (replayed, reordered,
  re-trimmed, renamed).

---

## D-073 — The Web Picker's Window-Focus Cancel Is Turned Off, Not Worked Around

**Date:** 2026-09-20

**Status:** Active (fixes the defect the owner's browser test found in Phase 6.5a's import)

**Decision:** On the web the opening stock picker is called with
`FilePickerWebOptions(cancelUploadOnWindowBlur: false)`, reached through one conditional import
(`app/lib/features/import/opening_stock/data/opening_stock_file_picker.dart`); every other platform
passes the base `WebOptions` and is unchanged. Four things are part of the decision:

- **`file_picker_web` becomes a direct dependency, at the version already resolved** (`^4.0.0`).
  Nothing in `pubspec.lock` changes except the entry's own `dependency:` marker, and D-007's four
  protected pins (`riverpod_lint`, `custom_lint`, `freezed`, the SDK) are untouched.
- **A `null` from the picker means "the user changed their mind" and nothing else.** The app may
  not make a null carry a second meaning; anything that goes wrong reading a file raises a sentence
  instead.
- **The upload reports the two boundaries it can see, and marks the send done when the payload is
  handed over** - not on a timer, and never as a percentage.
- **The file is read twice, deliberately:** a first pass of a hundred rows when the file is chosen
  (what the owner confirms), and the full read when they upload it (what the import is).

**Rationale:** the browser test reported that choosing the CSV did nothing at all - the dialog
opened, the file was selected, and the screen looked exactly as it had before. The four candidate
causes were all checkable and all wrong, and the fifth was the actual one. `file_picker` 13.1.0's
`pickFile()` has no `withData` parameter (13.0.0 removed it, and the web implementation reads the
file's bytes by default), `PlatformFile.path` is never used, no catch is empty, and the controller's
`ref.watch` does rebuild. What happens is that `FilePickerWeb`'s input session registers a `window`
`focus` listener and, **500 ms after any focus event, completes a pick that is still in progress
with `null`** - "the user changed their mind" - discarding a file the user did select. The app then
mapped that null to "back to the offer", which is why nothing was on screen to say so.

**Consequences:**

- **The flag that turns it off only exists on the package's own subclass.** `file_picker` 13.0.0
  removed `cancelUploadOnWindowBlur` from the public `pickFile()`/`pickFiles()` (upstream #2202,
  #2203); the `WebOptions` the facade re-exports declares no fields at all
  (`file_picker_platform_interface-4.0.0/lib/src/file_picker_options/web_options.dart`), and
  `FilePickerWeb` falls back to its defaults for anything that is not its own class
  (`file_picker_web-4.0.0/lib/src/file_picker_web.dart`). So the setting is unreachable without
  naming `FilePickerWebOptions`, which is what the direct dependency and the conditional import are
  for. If the facade ever re-exposes the flag, both can go.
- **This is a known failure mode upstream, not a new one.** #1833 ("File picker cancels upload when
  browser extensions intervene") is the same mechanism, #1834 added the flag for it, #1961/#1962
  made it public, and #1202 is the same user-visible symptom from the same 500 ms. The default of
  `true` is what `FilePickerWebOptions` ships with.
- **The exact moment Chrome dispatches a `window` `focus` event on Windows was not observed
  directly** - a native file dialog cannot be driven from a test, and Playwright's file-chooser
  interception never opens one, so the focus transitions that matter do not happen under it. What
  was checked is the code path, the upstream reports, and the compile. The fix does not depend on
  resolving that question, because it removes the listener rather than racing it: with
  `cancelUploadOnWindowBlur: false` no timer is armed, whenever the event arrives.
- **The web-only file is compiled for the web only, and that was checked on the artifact.** With
  `cancelUploadOnWindowBlur` removed from the facade, the failure mode of getting the conditional
  import wrong is a web build that quietly hands the picker the base options - the bug still there,
  every test still green. So it is not left to argument: `flutter build web --source-maps` puts
  `opening_stock_picker_options_web.dart` in `build/web/main.dart.js.map` and leaves
  `opening_stock_picker_options.dart` out of it, which is the web branch taken and the other
  dropped. The other direction is asserted from the Dart VM by
  `app/test/features/import/opening_stock/opening_stock_file_picker_test.dart`, so `flutter test`
  does check that half.
- **The runtime assertion of the same thing does not run in the gate.** 
  `app/test/features/import/opening_stock/opening_stock_picker_options_web_test.dart` is marked
  `@TestOn('browser')`, so `flutter test` does not collect it and needs
  `flutter test --platform chrome <that file>`. On this machine that command reached the browser
  compiler - an early run reported a Dart compile error from the browser side, and the error was in
  the test rather than the toolchain - but a full run did not complete: two attempts sat at
  `loading ...` for ten and fifteen minutes without finishing. Adding the line to the gate list is a
  change to `HANDOFF_PROTOCOL.md` and the `Makefile`, and it is deliberately **not** made here.
- **A picker that never answers now shows a spinner rather than looking untouched.** The offer's
  button is busy while the dialog is open and while the chosen file is being read, and every step
  that can fail lands on the failure card with the step named.

