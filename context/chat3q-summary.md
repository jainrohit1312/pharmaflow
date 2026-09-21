# Chat 3q Summary — Phase 7a, C3 chunks 1 to 3 (the receipt and the payment)

**Status:** PARTIAL (Phase 7a's app is now done except **C3/4b**, the deposit-application sheet —
C1a, C1b, C2, C3/1, C3/2, C3/3 and C3/4a are complete and gated)
**Date:** 2026-09-21
**Phases done:** Phase 7a — the Flutter slice **C3, chunks 1 to 3 of 4**, each with its own commit
and full gate run, plus the one migration C3 was blocked on (**pushed to hosted**).

---

## Supabase Changes

**One migration, and it is on hosted.**

- `20260920000039_phase7a_sale_document.sql` (new) — `public.sale_document(p_sale_id uuid)
  returns jsonb`: the sale's own row, each line with its `batch_no` / `expiry_date` /
  `is_unknown_batch`, and the patient's `patient_code` joined on `sales.customer_id`. **The owner's
  body, verbatim**, plus that single `patient_code` key and the `customers` join (D-079 says where it
  comes from and why). `security invoker`, `stable`, `set search_path = public`; granted to
  `authenticated`, revoked from `anon, public`. `checkout_sale` was **not** touched.
- `supabase/tests/phase7a_sale_document.sql` (new) — **23 assertions, 0 FAIL**.
- **`supabase db push --yes` applied 00039 on 2026-09-21**, on the owner's explicit instruction and
  nothing else: `supabase migration list` then read **39 local = 39 remote**. **No Edge Function and
  no application was deployed.**
  - Verified live afterwards: `sale_document(p_sale_id uuid) -> jsonb`,
    `security=invoker, volatile=s, search_path=search_path=public`,
    `authenticated CAN execute / anon cannot`; `checkout_sale(p_payload jsonb) -> sales` present and
    its **body fingerprint `md5(prosrc) = 2a6a432e…`, identical to the local harness database built
    from the same committed migrations** — so "unchanged" is evidenced, not asserted.
  - The new test run against hosted: **`SUMMARY: 23 PASS / 0 FAIL of 23 assertions`**. Re-running the
    verification afterwards gave the identical output (`1 sales rows`, same fingerprint), so the test
    leaves **no residue** on the real project.

Nothing else under `supabase/` changed. No other migration, policy or RPC was touched.

## Commits (all local, none pushed)

| Commit | What it is | `flutter test` |
|---|---|---|
| `d2c0990` | C3/1 — migration `00039` `sale_document`, its SQL test, and D-079's status moved RECORDED → BUILT | 926 (no Dart changed) |
| `6804d10` | C3/2 — the receipt: the `sale_document` reader, and the 80mm bill's per-line batch, expiry and patient code | 926 → 933 |
| `0f8ad77` | C3/3 — the payment: the confirmation on the counter's figures, the server's answer as the authority, and the payment-mode completeness rule | 933 → 943 |
| `be05756` | C3/4a — the three balance views, and one collection path (`collect_payment` everywhere) | 943 → 954 |

**C3/4a — the balance views and the one collection path (`be05756`, 15 files).** The owner's answer to
the collection-path question was **one path**: `LedgerRepository.recordPayment` now goes through
`collect_payment` with `p_allocations: null`, so Phase 4's ledger sheet records a **deposit** rather
than a receipt that settles nothing — the divergence D-075 warns about is closed at the source
(**D-081**). No Dart file calls `record_payment` any more. Then the three views: a **patient's
account** (`patient_account`) above the ledger card on the customer detail; a new
**`/admissions/:admissionId`** screen (`admission_account`) reached from a new **Admissions list** on
that patient's detail and from a bill that names one; and **what settled a bill**
(`payment_allocations`) inside the sale detail. Every figure is the server's, and the tests prove it
with **deliberately inconsistent fixtures** — `charges − returns − allocated` ≠ the `outstanding` they
carry — so a screen that recomputed the balance would print a different number. The allocations card's
own row-total was **removed before it landed** for the same reason. `sale_detail_test_app.dart` gained
the `balancesRepositoryProvider` override, without which the bill screen silently read a live
repository in tests (one test caught it: two `ErrorView`s).

**Not built, and it is the whole of what remains: the deposit-application sheet.** `applyDeposit` and
`PaymentAllocationTarget` exist in `BalancesRepository` with the server's contract documented, and
**no screen calls them and no test exercises them yet**. Its first question is §1 of the next opening
prompt — how to list a party's **open bills**, which no RPC returns today — and the owner has to
choose between a small additive RPC and a client-side per-bill remainder.

## Flutter Files Created (2)

**lib:**
- `features/sales/presentation/widgets/payment_confirmation.dart` — `showPaymentConfirmation`
  (step one) and `showVerifiedTotals` (the notice when the server disagreed)

**test:** none new — the new tests went into the files that already cover these behaviours
(`invoice_printer_test.dart`, `pos_screen_test.dart`, `sale_requirements_test.dart`).

## Flutter Files Modified (10)

**lib:**
- `data/models/…` — none. `features/sales/data/sales_repository.dart` gains `SaleDocument`,
  `SaleDocumentLine` and `read saleDocument({required String saleId})` (**no `pharmacyId`**: the RPC
  derives the tenant and is `security invoker`, so a filter the server ignores would be worse than
  none)
- `features/sales/application/sale_detail_controller.dart` — `SaleDetailData` is served by the
  document; gains `lines` and `patientCode`, `items` derived once in the constructor so the screen
  needed **no** change
- `features/sales/data/sale_totals.dart` — `tenderedFor` (one definition of the raw tender) and
  `matchesStored` (exact comparison of the shown figures against the stored row)
- `services/invoice_printer.dart` — `InvoiceLine` gains `batch`/`expiry`; `InvoiceSheet` gains
  `patient`; the 80mm layout prints `Batch … · exp MM/YY` per line and the patient with their code;
  `InvoicePrinter.unknownMark` is the em dash an unrecorded value prints
- `features/sales/application/sale_requirements.dart` — `paymentModeRefusal`
- `features/sales/application/sale_checkout_controller.dart` — the package-markup read became the
  `packageMarkupPercent` provider (the counter and the write share it)
- `features/sales/presentation/pos_screen.dart` — the two-step `_checkout`, the `_confirming` guard,
  and the refusals moved **before** the dialog

**test:** `test/support/fake_sales_repository.dart` (`saleDocument`, `buildSaleDocumentLine`,
`patientCode`, `documentLines`, `storedTotalsOverride`), `test/support/sales_test_app.dart` (the
pharmacy override, so a package submit cannot reach a live client),
`test/services/invoice_printer_test.dart`, `test/features/sales/presentation/pos_screen_test.dart`,
`test/features/sales/application/sale_requirements_test.dart`.

**docs:** `DECISIONS.md` (D-079's status; **D-080**), `PROGRESS.md`, `context/chat3q-summary.md`,
`context/chat3r-opening-prompt.md`.

**not committed (harness plumbing under `.qwen/tmp/pg7a/`):** `run_all.sql` and `run_7a_only.sql`
(+00039), `run_tests.sql` (+the new test file), `upgrade_after.sql` (+4 assertions reading the new
function on a pre-7a sale), `hosted_verify_c3a.sql`, and the `out_*.txt` records.

## Verification Evidence (raw, per chunk)

C3/1 (`d2c0990`): SQL only. Fresh harness run — **all 39 migrations applied clean** under
`ON_ERROR_STOP=1` (exit 0, no ERROR, no FATAL); the committed suite ran **16 files, zero FAIL**;
`phase7a_sale_document.sql` → **`SUMMARY: 23 PASS / 0 FAIL of 23 assertions`**; the pre-7a → 7a
upgrade path → **16 PASS / 0 FAIL**. Flutter gates unchanged (no Dart): `dart format lib test` → 501
files, 0 changed; build_runner exit 0 (43 outputs); `custom_lint` No issues; `flutter analyze` No
issues; `flutter test` → `02:41 +926: All tests passed!`; `deno test` → `ok | 181 passed | 0 failed`;
five `deno check` → exit 0. Then the push, and the hosted verification above.

C3/2 (`6804d10`): format 501 → 0 changed; build_runner exit 0 (75 outputs); `custom_lint` No issues;
`flutter analyze` No issues; `flutter test` → **`02:32 +933: All tests passed!`**; Deno
`ok | 181 passed | 0 failed`; five `deno check` exit 0.

C3/3 (`0f8ad77`): format **502 files, 0 changed**; build_runner exit 0 (113 outputs); `custom_lint`
No issues; `flutter analyze` No issues; `flutter test` → **`02:40 +943: All tests passed!`**; Deno
`ok | 181 passed | 0 failed`; five `deno check` exit 0.

Count history, each the gate's own output: **926 → 933 → 943**, 0 failures throughout. **17 new tests
in this chat** (7 in C3/2, 10 in C3/3). **No assertion was deleted, skipped, loosened or weakened**
— verified against the diffs, which remove only fixture plumbing and one `reason:` argument.

## Key Decisions Made

1. **D-079's migration is now written, pushed and verified** — the body is the owner's verbatim, with
   the one `patient_code` key the owner asked this chat to decide, and the patient's code is a
   **join** so a receipt is one round trip.
2. **The receipt prints the pack** — `sale_document` is the only source; the client never joins
   `sale_items` to `product_batches` itself. An unrecorded batch or expiry prints **`—`**, never
   `OPENING-…` and never a date (the ordinary case: 145 of the owner's opening-stock batches have no
   expiry, 138 no number). **The em dash draws in the PDF** — proven by a layout test, not assumed,
   since this printer already avoids the rupee sign for lack of a glyph.
3. **A pre-7a bill's code is not a snapshot** — because the function joins the master, such a bill
   answers no code only until `save_patient()` first touches that customer, then prints the code it
   was given. Both states are pinned in the upgrade harness.
4. **D-080 — the two-step confirmation and the payment rule.** Step one shows the counter's own
   figures and says the server will verify them; step two is the server's answer, and a divergence
   raises a **"Verified"** notice naming both figures. A settling mode must collect the bill in full;
   only `credit` leaves a balance, and then a party must owe it.
5. **The server has no short-tender rule**, which is why the counter has one: `sales_payment_check()`
   refuses only an **over**-payment, and `checkout_sale()` turns any shortfall into a balance whatever
   the mode says — so a "cash" sale with a "balance due" was storable before this.
6. **Refusals moved before the dialog**, which is what made the pharmacy read one provider
   (`packageMarkupPercent`) rather than a private method inside the write.

## Open Risks / Blockers

- **C3/4 remains entirely: the balance views.** Patient (`patient_account`), admission
  (`admission_account`), and the sale detail with its allocations; taking money through
  `collect_payment` and applying a deposit through `allocate_payment`. **No screen sums rows in
  Dart** — the figures are the server's aggregates.
- **The `isLoading` double-submit guard's non-vacuous test narrowed** (recorded in D-080 rather than
  papered over): the modal barrier now covers the frame the old held-open-write test used.
- **N-18 stands**: the hosted SQL suite has 7 pre-existing failures in three Phase 5 files, all
  data-dependent and proven pre-existing. Only `phase7a_sale_document.sql` was run against hosted.
- **`run_tests.sql` is 16 files; 9 of them print a `SUMMARY:` line** — the other seven end at their
  `raise`. A grep that returns fewer lines than there are files is not a missing file.
- **Nothing was pushed** in git terms: the three commits are local, `main` is nine ahead of
  `origin/main`.
- The **category read** bound (C2's open item) is unchanged, and the harness's own limits stand (no
  PostgREST or GoTrue locally, no true two-session concurrency).

## What's Next

`context/chat3r-opening-prompt.md` — **C3/4b: applying a deposit from the UI**, and nothing else. Its
§1 is a question for the owner (how to list a party's open bills), and the prompt instructs the next
chat to **ask rather than choose**.
