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