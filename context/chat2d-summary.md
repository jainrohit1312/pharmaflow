# Chat 3 summary — Phase 3 + Phase 4 complete

Continues `context/chat2d-opening-prompt.md`. Covers Phase 3 (sales/POS, sale
returns, GST billing) — which the previous session built and this one gated — and
Phase 4 (ledger, payments, expenses, reports), which this session finished.

**Both phases are complete and gated.** Gates at the end of this chat:

```
dart format lib test                      -> 0 changed (tree is formatter-clean)
dart run build_runner build --delete...   -> wrote 89 outputs (T-1 SDK notice only)
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +291: All tests passed!
```

237 tests at the end of Phase 2; 291 now. Phase 3 added none of its own, so all 54
of the increase are Phase 4's.

---

## What this session inherited

The previous chat crashed part-way through Phase 4. Its last commit
(`ca82db0 wip: phase 3 complete, phase 4 near-complete (reports missing)`) was
**not gated**, and the state on disk was:

- Migrations `00019` (sale automation), `00020` (ledger/payments corrections +
  purchase-return credit note) and `00021` (reporting) applied;
- Phase 3 complete (`features/sales/`, the sale side of `features/returns/`) with
  **no Dart tests**;
- Phase 4 ledger (data, application, `ledger_screen.dart`, `payment_sheet.dart`)
  and expenses (data, application) present;
- Phase 4 reports: only `reports_repository.dart` — `reports_controller.dart` and
  `reports_screen.dart` missing, which left two analyze **errors** in
  `expenses_controller.dart`;
- one analyze warning (`ledger_screen.dart` imported `routes.dart` unused);
- no route wiring for ledger/expenses/reports, both placeholders still present.

All four of those were reproduced exactly by the gate run before anything was
changed, so nothing was built on a wrong assumption.

---

## What was done

### 1. `reports_controller.dart` — the provider `expenses_controller` expects

`features/reports/application/reports_controller.dart`:

- `ReportPreset` (today, this month, last month, this quarter, this year, custom)
  and `windowFor(preset, now)` — pure and public, so the calendar arithmetic is
  tested against fixed dates. `day: 0` arguments rely on Dart's own
  normalisation, which is what makes `lastMonth` end on the 31st when it should
  and the 30th when it should.
- `ReportWindow` (inclusive `from`/`to`, plus the preset that produced it) and
  `ReportsWindowController` (`keepAlive: true`): a chip sets a whole window; moving
  one end by hand drags the other rather than allowing an inverted range, and
  makes the window `custom` because the chip it came from no longer describes it;
  picking the chip already showing is a no-op so it cannot rebuild the summary.
- `reportSummaryProvider` — **auto-dispose**, deliberately: the expense form
  invalidates it from another feature, and a kept-alive provider may only depend
  on kept-alive ones (D-015), which the repository and the scope are not.

### 2. `reports_screen.dart`

Seven cards for one window — sales, purchases received, returns, expenses, what
the window contributed, stock on the shelf, expiry — every figure straight from
the one `report_summary` call, nothing summed in Dart. A window bar with the
preset chips and two date fields. While a moved window is being added up, a
`LinearProgressIndicator` sits above figures that stay on screen rather than
blanking the report the user is reading. The contributed figure is labelled
**"Not a profit"**, with the reason in the card.

### 3. The expense UI — which did not exist

The previous session built `expenses_repository.dart`, `expenses_controller.dart`
and `expenses` (the table, migration 00007) but no presentation layer at all and
no route. Added:

- `features/expenses/presentation/expenses_screen.dart` — the paged list, each row
  category / date · mode / amount / notes, a header showing what the **loaded**
  rows add up to (and saying so, because a total that silently means "the part you
  scrolled to" is worse than no total), a Load more control, and an "Add expense"
  FAB.
- `features/expenses/presentation/widgets/expense_sheet.dart` — a modal sheet
  (category from the fixed `expenseCategories` list, amount, mode chips, date,
  notes), reporting a refused write in place and staying open to fix it.

### 4. Routes

- `Routes.expenses = '/reports/expenses'`, wired with `/ledger` and `/reports`;
  `LedgerPlaceholder` and `ReportsPlaceholder` deleted.
- The unused `routes.dart` import removed from `ledger_screen.dart`; the two
  analyze errors disappeared with the controller. `custom_lint` and
  `flutter analyze` are both clean.

### 5. Tests — 54 added

- `report_summary_test.dart` — the RPC envelope's decode: every block, a `numeric`
  that arrives as a string, a missing block, a non-numeric value, plus the derived
  figures (`averageBill`, `net`, `atRisk`, `contributedMargin`).
- `reports_controller_test.dart` — `windowFor` against fixed dates (including
  February, a 31-day month before a 30-day one, and January), the presets, the
  no-op rule, the day-only trim, the drag rule, and `reportSummaryProvider` over a
  fake.
- `reports_screen_test.dart`, `expenses_screen_test.dart`,
  `ledger_screen_test.dart` — over new fakes (`fake_reports_repository`,
  `fake_expenses_repository`, `fake_ledger_repository`) and mini-router pump
  helpers (`reports_test_app`, `ledger_test_app`) in `test/support/`. The expense
  fake re-runs the two checks the real `create` makes, so a screen that skips one
  fails in a test rather than in front of a user.

---

## One spec conflict, raised rather than guessed

STEP 3 item 4 asked for `Routes` at `/ledger`, **`/ledger/payment`**, `/expenses`
and `/reports`. `/ledger/payment` does not exist anywhere in the repo: payments
were already implemented as a modal sheet (`payment_sheet.dart` +
`PaymentController`) opened from the ledger screen's "Record payment" button. I
asked rather than inventing a second payment UI; the answer was **skip the route,
keep the sheet**, and that is what shipped.

A second, smaller deviation: `/expenses` became `/reports/expenses`. A top-level
path would be the first in the app matching no shell destination, so the rail and
bottom bar would have highlighted "Dashboard" while the user read their expenses
(the fallback is index 0). Nesting keeps the Reports destination lit and follows
the `/inventory/calendar` precedent. Recorded as **D-022**.

---

## Two findings worth carrying forward

1. **A failed *rebuild* keeps the previous value.** `LedgerEntriesController`
   answers with an empty page while no party is selected, so when a read for a
   chosen party fails, the state is an error *with* a value — the screen's
   `if (page.hasError && !page.hasValue)` branch does not fire, the empty page
   stays, and the failure is reported only through the `ref.listen` SnackBar. So
   the ErrorView-with-retry path is reachable only on a **first** read, and a user
   who cannot load a party's ledger has no retry control until they navigate away
   and back. The screen test pins both paths by pre-selecting the party through
   `pumpLedgerApp(configure:)` for the first-read case. Recorded as **T-3**.
2. **A one-shot failure flag is unreliable in a widget test.** GoRouter builds a
   route more than once before the first frame settles, so a fake that threw once
   had already been retried into a success before the assertion ran — the reports
   error test kept rendering a full summary. Both fakes now fail *persistently*
   until the test clears the flag, and the test clears it before tapping Retry.

---

## Files

**Created (14)**

```
app/lib/features/reports/application/reports_controller.dart
app/lib/features/reports/presentation/reports_screen.dart
app/lib/features/expenses/presentation/expenses_screen.dart
app/lib/features/expenses/presentation/widgets/expense_sheet.dart
app/test/support/fake_reports_repository.dart
app/test/support/fake_expenses_repository.dart
app/test/support/fake_ledger_repository.dart
app/test/support/reports_test_app.dart
app/test/support/ledger_test_app.dart
app/test/features/reports/report_summary_test.dart
app/test/features/reports/reports_controller_test.dart
app/test/features/reports/presentation/reports_screen_test.dart
app/test/features/expenses/presentation/expenses_screen_test.dart
app/test/features/ledger/presentation/ledger_screen_test.dart
```

**Modified (10)**

```
app/lib/core/router/routes.dart          Routes.expenses; two stale "(Phase 1 placeholder)" comments
app/lib/core/router/app_router.dart      the three routes; imports swapped off the placeholders
app/lib/features/ledger/presentation/ledger_screen.dart   unused routes.dart import removed
```

Six more were changed by `dart format` alone — hand-written files from the
previous session that had never been through it: `data/models/expense.dart`,
`data/models/ledger_entry.dart`, `data/models/report_summary.dart`,
`features/ledger/application/ledger_controller.dart`,
`features/ledger/presentation/widgets/payment_sheet.dart`,
`features/reports/data/reports_repository.dart`. Wrapping and annotation
placement only; no behaviour.

**Deleted (2)**

```
app/lib/features/ledger/presentation/ledger_placeholder.dart
app/lib/features/reports/presentation/reports_placeholder.dart
```

**Documentation**

```
PROGRESS.md                       Phases 3 and 4 COMPLETE; Chat 3 section; T-2/T-3; Next Action = Phase 5
DECISIONS.md                      D-022 (a screen that is not a destination nests under one), D-023
                                  (a sale is one RPC, stock per line), D-024 (a payment and its
                                  ledger row are one transaction), D-025 (a report is one server-side
                                  aggregate)
context/chat2d-summary.md         this file
context/chat2e-opening-prompt.md  the Phase 5 brief
```

---

## Still open

- ~~**T-2 (Medium)** — Phase 3 has **no Dart tests**~~ — **RESOLVED**, see the
  follow-up section at the end of this file.
- **T-3 (Low)** — the ledger failure path above.
- **I-1, I-2, I-3, R-1** — unchanged from Phase 2. Note I-2's suggested fix ("an
  RPC when Phase 4 touches the ledger") was *not* taken: Phase 4 posted the
  purchase-return credit note with a trigger on `purchase_returns`, so a refused
  purchase-return line set can still leave a header with no lines.

---

## Follow-up: T-2 closed (a later session)

Phase 3's missing Dart tests are written — **91 of them, with no product code
changed**, so there is no migration and no new decision:

- **Sales (55)** — `test/features/sales/data/sale_totals_test.dart` (the money
  math: line and document totals, the discount moving the taxable value, the
  intra/inter-state split, the two halves adding back to the tax, half-away-from-
  zero rounding at `1.005`, and what a tender may record);
  `application/pos_controller_test.dart` (the basket: batch defaults, the merge
  rule, every edit recomputing the totals, `withCustomer(null)` clearing);
  `application/sale_checkout_controller_test.dart` (the payload, the document
  totals deliberately absent from it, availability re-read before the write, the
  balance-with-no-customer refusal, a credit sale, an over-tender clamped so no
  negative balance is stored); plus widget tests for the counter and the list.
- **Sale returns (36)** — `SaleReturnableLine.returnable` as
  `qty - alreadyReturned` (a fully returned line, and an over-returned one
  clamping to 0 rather than going negative), an empty `batchId` blocking the line,
  the proportional slice from the line's **stored** `totalAmount`/`taxAmount` (a
  discounted line, where `qty x rate` would give a different, larger answer —
  D-020's rule), the write's refusals, and widget tests for the form.
- **Support** — `fake_sales_repository.dart`, `fake_sale_returns_repository.dart`,
  `sales_test_app.dart`, `sale_returns_test_app.dart`, following the existing
  `test/support/` shape.

Gates: `dart format` 0 changed, `dart run build_runner` wrote its outputs,
`custom_lint` clean, `flutter analyze` clean, `flutter test` **+382** (291 before;
91 added, none changed).

**Still untested, and why:** `invoice_printer.dart` (its `printReceipt` lays out
the PDF *and* calls `Printing.layoutPdf` in one method, so a test would have to
mock a platform channel rather than assert a document) and
`sale_detail_screen.dart` (the bill the counter opens). Two findings from the new
tests are recorded in PROGRESS.md as **T-4** and **T-5** — both dead or ambiguous
UI in `sale_return_form_screen.dart`, neither a behavioural defect.

**One framework behaviour to know before writing another error-state widget
test:** Riverpod 3 retries a failed provider *build* on its own backoff, so a test
that clears a fake's failure flag and then `pumpAndSettle`s can find the retry
already succeeded and the `ErrorView` gone. Keep the failure flag persistent, and
clear it only immediately before the action that should recover.

