# Chat 4 / Phase 6, chunk 1 — the no-external-input half (COMPLETE)

**Status:** **COMPLETE** (chunk 1 of n). Phase 6 is open; this chunk closed every item
in it that needs no account, no credential and no live session, plus the documentation
the phase owns. The deploy half — and the credentials behind it — is the next chunk
(`context/chat3m-opening-prompt.md`).
**Date:** 2026-09-19
**Decisions:** **D-056** (the alias key), **D-057** (the bill's two steps, and its tax
heads), **D-058** (a failure is decided before a retained value), **D-059** (Phase 6's
platform scope).

---

## What this chunk ships

No new feature surface. One migration, eleven source/test files, two documents, and the
coverage the open-items list had been carrying since Phase 3.

### 1. W-1 — the Windows build is fixed

**Reproduced first**, so the fix had a target and the evidence is real:

```
C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231\include\experimental\coroutine(37,1):
  error C2338: static assertion failed: 'error STL1011: The /await compiler option,
  <experimental/coroutine>, <experimental/generator>, and <experimental/resumable> are
  deprecated by Microsoft and will be REMOVED SOON. ... You can define
  _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS to suppress this error for now.'
  [...\permission_handler_windows_plugin.vcxproj]
Build process failed.
```

The diagnosis is in the error and in the resolved plugin list
(`windows/flutter/generated_plugins.cmake` names `permission_handler_windows`):
`permission_handler_windows` implements its checks on C++/WinRT's pre-2.0 ABI, which
compiles through `<experimental/coroutine>`, and MSVC 14.51 (VS 2026) made that
deprecation a hard error. The plugin is compiled for every desktop target whether the
app uses it or not, so nothing in the repository built for Windows.

**The fix** is in `app/windows/CMakeLists.txt`, immediately after
`include(flutter/generated_plugins.cmake)`:

```cmake
if(TARGET permission_handler_windows_plugin)
  target_compile_definitions(permission_handler_windows_plugin PRIVATE
    _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)
endif()
```

Three deliberate choices in that block, all commented in place:

- **Scoped to the one target**, not added to `APPLY_STANDARD_SETTINGS` (which every
  plugin links through): a deprecation inside a third-party plugin is not a reason to
  stop reporting one in code we write.
- **`if(TARGET …)` guarded**, because the plugin list beside it is generated — a
  pubspec that ever drops `permission_handler` must not leave this line breaking the
  build.
- **A removal condition**: delete it when that plugin ships a Windows implementation on
  C++/WinRT 2.x.

Result: `flutter build windows --debug` → `√ Built build\windows\x64\runner\Debug\app.exe`.
**The release build was deliberately not run** — the user cancelled it ("not worth 40
minutes of context"), and the debug build already proves the compile fix (D-059).
Nobody should mistake it for verified: `PROGRESS.md`, `README.md` and
`docs/DEPLOYMENT.md` all say so explicitly.

### 2. A-1 — `publishableKey`

`bootstrap.dart` now passes `publishableKey: Env.supabaseAnonKey` and the
`// ignore: deprecated_member_use` is gone with the argument it excused. Verified
against the **resolved** package rather than the item text: `supabase_flutter` 2.17.2,
whose `Supabase.initialize` carries `@Deprecated('Use publishableKey instead. anonKey
will be removed in a future major version.')` and resolves `publishableKey ?? anonKey!`.
Only the argument was renamed — the **env var stays `SUPABASE_ANON_KEY`**, because that
is the contract `.env.example` and the README document, and the comment in place says
the two names differ on purpose.

### 3. I-1 — the reorder list is the server's answer

`InventoryRepository.lowStock` is now one round trip to `low_stock_products()` and
returns `List<LowStockProduct>` — the **same payload** the notification list and the
chatbot already read (D-047). Deleted: the `product_stock` read, the `min_stock_level >
0` narrowing, the Dart `totalQty < minStockLevel` comparison, the Dart sort, and
`lowStockScanLimit` (500). Added: `lowStockLimit = 200`, which is the server's own
ceiling, so one read is the whole list rather than a page of it and there is no bound a
screen can silently fall off.

**The trade this forced, stated plainly.** `low_stock_products()` answers in
quantities — on hand, level, **shortfall** — and not in money. `ProductStockCard`
renders `stockValueAtCost`, so mapping the RPC row into a `ProductStock` would have
printed **"₹0.00 at cost"** on a reorder list: a wrong figure, silently. The low-stock
tab therefore renders a new `LowStockCard` over the payload it actually has:

- `N units · reorder at M`, plus **`Order K units`** (the shortfall — the number the
  RPC's own comment says it exists to provide, and which the old list did not show);
- `Out of stock` when nothing is on hand, and *no* "Low stock" badge, because every row
  of that list is low (the same reason `StockLevelBadge` stays quiet for a healthy row);
- **no "at cost" line.** That figure belongs to the `product_stock` rollup, which the
  stock tab and the product detail still show at landed cost (D-012).

One card, one file (`low_stock_card.dart`), and a one-line reversion if the review
prefers the old copy. `lowStockListProvider` still watches `requirePharmacyIdProvider`
to *gate* the read — the RPC takes the tenant from the JWT (D-004), but a tab that
answered "nothing is below its level" while the profile was resolving would be T-5's
mistake in a new place.

### 4. N-5 — the alias key treats "no supplier" as a value (D-056)

Migration **`20260919000030_phase6_alias_identity.sql`**: the unique index on
`(pharmacy_id, supplier_id, normalized_name)` is rebuilt **`NULLS NOT DISTINCT`**, so a
NULL supplier is a value and `ProductsRepository.addAlias`'s upsert converges the two
rows it used to duplicate.

- **Why not the coalesce expression.** The brief offered
  `(pharmacy_id, coalesce(supplier_id, sentinel), normalized_name)` as an equivalent.
  It is not: PostgREST's `on_conflict` is matched to an index by **column names**, and
  an index over an expression is not inferrable from those names — so `addAlias`'s
  upsert would have started failing with *"there is no unique or exclusion constraint
  matching the ON CONFLICT specification"* for **every** pharmacy, not just the NULL
  case. PostgreSQL's documentation was checked before writing the migration (inference
  matches "exactly the `conflict_target`-specified columns/expressions", with no
  exclusion for `NULLS NOT DISTINCT`), and the SQL test proves the inference works on
  the real objects by running the statement PostgREST emits.
- **Probe first, read-only, on the live project**: **0 alias rows, 0 colliding keys**
  (`.qwen/tmp/n5_alias_dupes.sql`). That is the only reason this migration is pure DDL —
  on a populated table it would have needed a decision about which row survives, and
  that is not something an index swap should decide.
- **`learn_product_aliases` is deliberately not replaced.** Its update-then-insert for
  the NULL-supplier case is now redundant and stays: it is still correct, and replacing
  a deployed, tested function to delete a harmless branch is churn with a risk attached.
- **Both contradicting comments are reconciled**: migration 00015's now points forward at
  00030 (the way 00010 points at 00015 — D-013), `addAlias`'s doc states the behaviour
  the index actually has, and the two Phase 5 tests whose wording described the old fact
  were corrected rather than left to contradict the code.

`supabase db push --yes` → applied; `supabase migration list` → **30/30 local and
remote**.

**The test that makes this evidence rather than decoration** —
`supabase/tests/phase6_alias_identity.sql`, atomic, self-rolling-back, 20 PASS / 0 FAIL
of 21 assertions. It was run **before** the migration too, and produced **7 FAILs**, all
traceable to the one duplicated row:

```
FAIL: 2. re-adding the same text with no supplier converges instead of duplicating (found 2, wanted 1 …)
FAIL: 3. the surviving row re-points at the product chosen the second time
FAIL: 3. and it carries the printed text as last added (got DOLO-650 TAB)
FAIL: 5. a supplier-scoped alias and a pharmacy-wide alias for one text still coexist (found 3, wanted 2)
FAIL: 6. the same unscoped text exists in both pharmacies as separate rows (found 3, wanted 2)
FAIL: 6. the signed-in caller sees only its own tenant's row (found 2, wanted 1)
FAIL: 1. it is NULLS NOT DISTINCT, so a NULL supplier is a value (got false) - the whole of N-5
```

**Two of those failures were my own test's fault first**, and the pre-migration run is
what caught them: the first draft's "same text twice" fixture used `'DOLO-650 TAB'` and
`'DOLO 650 TAB'`, which normalize to **different** keys (`dolo650 tab` vs `dolo 650
tab` — measured with a read-only probe, `.qwen/tmp/n5_normalize_forms.sql`), so it never
exercised the duplicate at all. The fixture now asserts the two printed forms normalize
to one key *before* anything depends on it, and the count assertions are deltas rather
than absolutes. A test that would have passed while proving nothing got fixed because it
was run in the failing state first.

### 5. T-3 / T-4 / T-5 — three screens where two states looked alike

- **T-3 (the ledger, D-058).** `LedgerEntriesController` returns an empty page while no
  party is selected, and Riverpod keeps the last value across a rebuild — so
  `page.hasError && !page.hasValue` was **false** for a party chosen after the first
  frame, and the body rendered *"Nothing on this ledger"* for a ledger nobody had read,
  announced the failure in a SnackBar beside it, and offered **no retry**. The body now
  decides the error before the retained value, and the screen-level `ref.listen` SnackBar
  is gone: the `ErrorView` already names the failure and carries the retry, so the second
  surface was noise. Load-more is untouched — there the page on screen is still true.
- **T-4 (the sale-return form's dead branches).** The picker's `'Choose a bill'`
  validator and `_save`'s report of the same thing could never run, because the button
  is disabled until a bill is chosen. The rule now lives in **one** place — the button's
  `onPressed` — and the surviving null check is type narrowing with a comment saying so.
  (The live-button alternative was considered and rejected: in the bill-list *failure*
  state there is no picker widget at all, so a live button would validate clean and then
  do nothing silently — a worse dead end than a disabled button.)
- **T-5 (the bill picker).** `sales.value ?? const <Sale>[]` collapsed "still reading"
  into "no sales yet", so a pharmacy that had not been asked yet was shown an empty,
  disabled picker claiming it had never sold anything. The hint is now three-way —
  `Loading the bills…` / `No sales yet` / `Which bill` — and `enabled` still follows the
  options.

**T-6 is new** (found while writing the bill screen's tests): a sale that is **gone**
rendered as an endless spinner, because `saleDetailProvider` answers `null` for an id
that is no longer there and the screen read `null` as "still loading". It now renders
*Bill not found*, and the check is `!isLoading` rather than `value == null` alone, so a
*retry* in flight — which also holds no value — is not mistaken for a missing bill.

### 6. The two coverage gaps Phase 3 named (34 tests)

Phase 3's summary left two things untested *for reasons*, and both reasons are gone:

- **`test/services/invoice_printer_test.dart` (17).** `printReceipt` used to lay the PDF
  out *and* call `Printing.layoutPdf` in one method, so a test would have had to mock a
  platform channel rather than assert a document. **D-057** splits it:
  `buildSheet` produces an `InvoiceSheet` (heading / title / reference / issuedAt /
  lines / totals / payment / footer — plain classes, because this is a printer's content
  model and not a table row or an RPC envelope) and `buildDocument` lays it out.
  `printReceipt` is three lines over `buildDocument`, and `invoicePrinterProvider` is
  unchanged, so the screen did not have to move.

  **Writing it found a real defect.** The intra-state split rounded **both** halves of
  `tax_total` separately: for a total with an odd number of paise (half of all
  two-decimal totals) `round2(t/2)` and `round2(t - t/2)` are the *same* number, so
  CGST + SGST printed as `tax_total + 0.01` — a bill whose own tax heads disagreed with
  the tax it charged. The split now subtracts the **rounded** half
  (`_cgst(t)` then `t - _cgst(t)`), so the heads sum exactly. **Only the printed document
  changed**; `sales.tax_total` — the figure the ledger posted — is untouched, and the
  test asserts the sum against the stored total rather than a hardcoded pair.

  The tests cover the seller block and the placeholder when the pharmacy is null, the
  lines and how they were priced (a discount clause and a GST clause only when they
  exist), both tax splits, the odd-paise case, the discount present/absent pair, the
  total's emphasis and the rule above it, the payment block, and two that
  `buildDocument` renders a PDF at all (which the run announces with *"Helvetica has no
  Unicode support"* — the reason `_money` prints `Rs`, not `₹`).
- **`test/features/sales/presentation/sale_detail_screen_test.dart` (14).** The bill the
  counter opens. It needed a harness of its own — `sales_test_app.dart` deliberately
  stubs `/sales/:saleId` with a text placeholder — so
  `test/support/sale_detail_test_app.dart` adds a router that stands the real screen up,
  a `FakeInvoicePrinter extends InvoicePrinter` that records the **sheet** it would have
  printed, and a `FakePharmacyRepository`. The tests assert the figures come from the
  document's own columns (a fixture whose header deliberately disagrees with its line),
  the tax head follows the split, the line metrics appear and the ones a line does not
  have do not, a prescription-only line is marked for the drug register, a walk-in and
  an account sale read differently, a part payment shows what is still owed, printing
  goes through the seam with the right pharmacy, a refused print keeps the bill on
  screen, a read failure offers a retry, and a gone bill says so (T-6).

  Two expectations were wrong on the first run and are now recorded as fact: the screen
  prints `Discount 20.0%` because `discountPercent` is stored as a `numeric` and arrives
  a double (the printer strips the `.0` for a 32-column thermal roll; a screen does not
  have to), and a **second `pumpWidget` in one test does not reliably re-apply a
  *family* provider override**, so the intra-state and inter-state assertions are two
  tests rather than two pumps.

### 7. R-1 and `docs/`

- **`README.md` rewritten.** It said "Phase 0 (scaffold)", "14 ordered migrations" and
  "21 tables"; all three were wrong. It now carries the real state: 30 migrations, 24
  tables / 2 views, five Edge Functions, the 13 shell destinations, 627 Flutter and 181
  Deno tests, the exact gate block, the three load-bearing pins and why each is
  load-bearing, the per-phase status, the W-1 fix with its removal condition, the
  web-debug workaround, the secret table with what is set and what is not, and a
  documentation map.
- **`docs/USER_MANUAL.md`** — written for the person behind the counter, not for a
  developer: getting in and roles, the dashboard, products (with why each field
  matters), aliases, suppliers and customers, ordering and receiving (including *when*
  stock moves and that an ordered document returns to draft when its lines change),
  the bill reader, inventory and the reorder list, the counter, the bill and printing,
  returns, the ledger and payments, reports, notifications, the chatbot (with example
  questions and what it will not answer), day-to-day recipes, and an explicit
  "what PharmaFlow deliberately does not do" section listing decisions rather than
  defects.
- **`docs/DEPLOYMENT.md`** — the runbook, and it opens by saying **nothing in it has
  been executed yet**. The gates; the fact that `.env` is **compiled into the bundle**
  (which is what makes a Vercel deploy a build-time concern, and why the publishable key
  is public by design); the Vercel steps plus the `curl` checks that verify a deploy
  without driving a browser; the Android keystore, the **exact `build.gradle.kts` change
  still to be made** (release currently signs with the debug keys), the AAB/APK builds
  and the Play Console paperwork; the iOS runbook for a Mac; the Windows release note;
  the five secret names and how to prove a dispatch; a post-deploy checklist; and the
  honest outstanding list.

---

## Files

```
supabase/migrations/20260919000030_phase6_alias_identity.sql      (new)
supabase/tests/phase6_alias_identity.sql                          (new, 20 PASS)
app/lib/features/inventory/presentation/widgets/low_stock_card.dart (new)
app/test/services/invoice_printer_test.dart                       (new, 17 tests)
app/test/features/sales/presentation/sale_detail_screen_test.dart (new, 14 tests)
app/test/support/sale_detail_test_app.dart                        (new)
docs/USER_MANUAL.md                                               (new)
docs/DEPLOYMENT.md                                                (new)
context/chat3l-summary.md                                         (this file)
context/chat3m-opening-prompt.md                                  (Phase 6's next chunk)
```

**Modified:**

```
app/windows/CMakeLists.txt                              W-1
app/lib/bootstrap.dart                                  A-1
app/lib/features/inventory/data/inventory_repository.dart       I-1
app/lib/features/inventory/application/low_stock_controller.dart  I-1
app/lib/features/inventory/presentation/inventory_screen.dart   I-1
app/lib/features/ledger/presentation/ledger_screen.dart          T-3
app/lib/features/returns/presentation/sale_return_form_screen.dart  T-4, T-5
app/lib/services/invoice_printer.dart                   D-057
app/lib/features/sales/presentation/sale_detail_screen.dart      T-6
app/lib/features/products/data/products_repository.dart          N-5 (comment)
supabase/migrations/20260918000015_phase2_extras.sql            N-5 (comment)
supabase/tests/phase5_match_products.sql                        N-5 (comment)
supabase/tests/phase5_learn_product_aliases.sql                 N-5 (comment)
app/test/support/fake_inventory_repository.dart         I-1
app/test/support/fake_sales_repository.dart             T-5 gate + errorToThrow on byId/itemsFor
app/test/features/inventory/inventory_screen_test.dart  I-1
app/test/features/ledger/presentation/ledger_screen_test.dart    T-3
app/test/features/returns/presentation/sale_return_form_screen_test.dart  T-4, T-5
README.md, PROGRESS.md, DECISIONS.md
```

---

## Verification evidence

```
dart format lib test                                       -> 421 files, 0 changed
dart run build_runner build --delete-conflicting-outputs    -> wrote outputs, no errors
dart run custom_lint                                      -> No issues found!
flutter analyze                                           -> No issues found!
flutter test                                              -> +627: All tests passed!  (593 -> 627)
deno test supabase/functions                              -> ok | 181 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts     -> clean
deno check supabase/functions/match-product/index.ts         -> clean
deno check supabase/functions/backfill-embeddings/index.ts   -> clean
deno check supabase/functions/send-notification/index.ts     -> clean
deno check supabase/functions/chat-sql-agent/index.ts        -> clean
flutter build windows --debug                              -> √ Built build\windows\x64\runner\Debug\app.exe
supabase migration list                                    -> 30/30 local and remote match
supabase db push --yes                                     -> applied 20260919000030_phase6_alias_identity.sql
supabase db query --linked --file supabase/tests/phase6_alias_identity.sql
                                                           -> 20 PASS / 0 FAIL of 21 assertions
                                                              (7 FAILs against the pre-migration database)
supabase db query --linked --file supabase/tests/phase5_learn_product_aliases.sql
                                                           -> 42 PASS / 0 FAIL (no regression)
supabase db query --linked --file supabase/tests/phase5_match_products.sql
                                                           -> every assertion PASS (no regression)
```

`flutter analyze` caught four test-file findings on the way (three
`avoid_escaping_inner_quotes`, one `unused_import`) — recorded because the analyzer
analyzes `test/**` and those only appear after `dart format` has already run.

---

## Decisions recorded

- **D-056** — the alias key treats "no supplier" as a value: `NULLS NOT DISTINCT` on the
  plain columns, **not** the coalesce expression, because PostgREST's `on_conflict`
  matches by column name and an expression index is not inferrable. Probe first (0 rows);
  `learn_product_aliases` left alone on purpose.
- **D-057** — a bill is built in two steps (content, then layout), and its tax heads sum
  to the tax charged (the rounded half is subtracted, not the unrounded one).
- **D-058** — a failure is decided **before** a retained value, and a screen has one
  failure surface. The general shape of this project's recurring bug — two states that
  mean different things rendered identically — is named, with T-3, T-5, T-6 and D-048 as
  its instances.
- **D-059** — Phase 6 ships Web (Vercel) first, Android second, does not chase iOS (no
  Mac on this host), and treats the Windows build as a repository-integrity fix rather
  than a launch target. Records the CMake definition's scope and its removal condition.

---

## Open risks / blockers

- **Nothing was made worse.** I-2, I-3, N-1, N-2, N-4, N-7, N-8, N-9, D-027's residual and
  T-1 are all untouched; the two permanent probe rows from chunk D are still in
  production on purpose (D-049's evidence).
- **N-11 is new and is the whole remaining blocker**: the deploy targets need accounts.
  A Vercel project, a Google Play developer account (plus an upload keystore and its
  passwords), and the WhatsApp/SendGrid/Firebase credentials that D-046's dispatch,
  D-052's auto-send PO and N-1's push all wait on.
- **The Windows release build is unverified** — by instruction, not by oversight.
  D-059 and `docs/DEPLOYMENT.md` both say so.
- **A judgement call worth a glance in review, and a one-line reversion**: the low-stock
  tab no longer shows the stock value at cost, and shows the shortfall instead (I-1).
  The reasoning is above; the alternative is `ProductStockCard` over a `ProductStock`
  built from a payload that does not carry the value, which prints `₹0.00`.
- **The chatbot's two naming calls from chunk E** are still as chunk E left them
  ("Chatbot" as the rail label; `describeAnswerOrigin` renders `params` as *what was
  asked*). Nothing in this chunk revisited them.
- **`PROGRESS.md`'s older sections are historical records** and still describe the state
  at the time they were written (chunk E's notes say T-3/T-4/T-5 are open). The new
  Phase 6 section at the top of the Chat 4 progress area is the current statement.

---

## What's next

**Phase 6's deploy half** — `context/chat3m-opening-prompt.md`. In short: ask the user for
the accounts and credentials up front (N-11), then the Vercel web deploy, then the Android
keystore + release signing + APK/AAB and the Play listing, then I-3, then the credential
work (D-046's dispatch triggers and D-052's auto-send PO) and N-1's push, then N-9's
re-measurement once the catalogue has 50+ products.
