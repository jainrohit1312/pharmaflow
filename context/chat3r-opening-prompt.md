# Chat 3r — Phase 7a: the balances (C3/4, the last chunk)

You are continuing work on PharmaFlow, picking up Phase 7a's Flutter side where chat 3q left it.
The durable layer is on hosted (39 = 39); the app's **C1a, C1b, C2, C3/1, C3/2 and C3/3 are
committed locally and gated**. **What remains of Phase 7a is C3's fourth chunk — the balance
views** — and nothing else.

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — the Phase 7a four-part status at the top, and the phase table
2. `MASTER_PLAN.md` → Phase 7, especially §1 (the four sale types), §5 (the reports), §6 (the GST
   basis, D-075) and §7 (the open items)
3. `DECISIONS.md` → **D-067**, **D-070**, **D-071**, **D-074**, **D-075**, **D-076**, **D-077**,
   **D-078**, **D-079** (the receipt's contract) and — added for this slice's predecessor —
   **D-080** (the two-step confirmation and the payment rule)
4. `HANDOFF_PROTOCOL.md` — the contract this file is written to
5. `context/chat3q-summary.md` — what the previous chat built, and its open items
6. This file
7. **The code, before changing it**: `app/lib/features/ledger/` in full (the Phase 4 payment sheet,
   `payment_controller.dart`, `ledger_screen.dart`, `LedgerRepository`), the three files C3/2 and
   C3/3 just changed — `app/lib/features/sales/data/sales_repository.dart`,
   `app/lib/features/sales/application/sale_detail_controller.dart`,
   `app/lib/features/sales/presentation/sale_detail_screen.dart` — and
   `supabase/migrations/20260920000036_phase7a_sale_write_paths.sql`'s balance readers and
   `…000037_phase7a_allocation_integrity.sql`'s `collect_payment` / `allocate_payment`
   (**read them; do not modify either migration**)

Output a 5-line understanding check:

- The backend contract C3/4 integrates with (what the two balance readers return, and what
  `collect_payment` / `allocate_payment` each do)
- What C1a, C1b, C2 and C3/1–3 already put in place (do not rebuild them)
- What C3/4 adds, in the order it has to be built
- The two things that must not regress: a balance is never a sum of rows in Dart, and applying a
  deposit is not a second receipt
- What you are about to build first

## ENVIRONMENT (FIXED)

- Workspace: `C:\Projects\PharmaFlow\` (Flutter app in `app/`)
- Supabase: **hosted only**, project ref `yeroxzkpmodbzcvjlqwd`; no `supabase start`, and the local
  stack is not this project's. **Docker IS available** and is what the throwaway pgvector harness
  uses
- Flutter 3.44.8 / Dart 3.12.2; Riverpod 3.0.3 (codegen), Freezed 3.2.3, `very_good_analysis`
- **Gate list, in this order, from `app/`** (`deno` from the repository root):
  `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` →
  the five `deno check` entry points.
  `flutter analyze` and `flutter test` both cover `test/**`: a lint in a fixture fails the gate
  before a single test runs.
- Measured baseline at handoff: **943 Flutter tests, 181 Deno tests**, all passing, at `0f8ad77`.
- **Report actual counts, never a running total.**

## THE LOCAL SQL HARNESS (only if you write or change SQL)

The container `pharmaflow-pg7a` is standing, and `.qwen/tmp/pg7a/` holds the harness.
**`run_all.sql` now lists `00001`–`00039` and `run_tests.sql` all 16 test files**, so a new one
needs its line added. **The order is `reset` → `stub` → `run_all` → `seed` → `run_tests`**, and
`stub.sql` must be re-run after every `reset.sql` (it drops schema `public`, and with it the stub's
schema grants). Grep each file's `SUMMARY:` line — only 9 of the 16 print one.

**C3/4 needs no migration and no SQL test.** The readers and both allocation RPCs are already
committed, applied on hosted and asserted by `supabase/tests/phase7a_sale_types.sql` (75 assertions,
0 FAIL). If you find yourself writing SQL, re-read the scope below: the server side of this chunk
already exists.

## SCOPE — C3/4: the balance views (the last chunk of Phase 7a, ~60k)

**The figures are the server's. No screen sums rows in Dart, and no screen recomputes money.**

### 1. The three places, as the owner approved them on 2026-09-21

- **The patient's balance is a section on the existing `/customers/:customerId` screen**
  (`features/customers/presentation/customers_detail_screen.dart`), reading
  `patient_account(p_customer_id)`.
- **A new route `/admissions/:admissionId`** — the episode's own account, reading
  `admission_account(p_admission_id)`, reachable from the customer detail and from the sale detail.
- **The sale's allocations are a section inside the existing `/sales/:saleId` bill**
  (`sale_detail_screen.dart`), listing the `payment_allocations` rows against that sale.

### 2. What each figure is (D-025, D-075, D-076 — do not re-derive it)

`patient_account` returns `charges`, `returns_credits`, `allocated`, `outstanding` and
**`unallocated_deposits`**; `admission_account` returns the same shape without deposits, per
episode. The rule is **`outstanding = charges − valid returns − allocated collections`**.

- **An unallocated deposit stays visibly a deposit.** A receipt whose allocations total less than its
  amount leaves a remainder; it is not "paid" against anything and must not read as one.
- **A package sale never lands on the patient's balance.** Its debtor is the hospital's account row,
  a different `customer_id` — so the patient's own outstanding is unmoved, and an account row's
  balance is the hospital's.
- **Money is taken with `collect_payment`** (the receipt **and** its allocations in one transaction,
  through `record_payment()`), and **applied with `allocate_payment`** (an existing receipt's
  remainder; writes only an allocation row). **An allocation is limited by what is owed, computed
  under a row lock** — so the client never decides how much may be applied, and a refusal takes the
  whole collection with it.
- **No business logic in widgets**: a write goes through a controller, as everywhere else.

### 3. The question to settle before writing the collection UI

**The app already has a payment path, and it is a different one.** Phase 4's
`ledger/presentation/widgets/payment_sheet.dart` → `PaymentController` → `LedgerRepository.recordPayment`
calls **`record_payment`** directly — a receipt with **no allocations at all**. C3/4's collections
have to go through `collect_payment` instead, or a payment taken from the ledger screen will never
settle a bill and every balance will read as unpaid behind a receipt that says it was paid (the exact
divergence D-075 warns about: *"every paid bill would read as unpaid once balances are computed from
allocations"*).

Two ways to resolve it, and **this is the owner's call, not yours to make silently**:

- **(a) One collection path.** Move the ledger's payment sheet onto `collect_payment`, passing an
  empty allocation list when no target is named — which the function supports, and which is exactly
  what an unallocated deposit is. Every receipt then arrives through one door.
- **(b) Two paths, deliberately.** Leave the ledger sheet as `record_payment` and record in
  `DECISIONS.md` that a payment taken there is a deposit that must be applied later.

**Ask before choosing.** Report the file:line evidence for what each path does today.

## WHAT THE OWNER ALREADY DECIDED (do not re-litigate)

- **The three placements above** (patient on the customer detail, a new admission route, allocations
  inside the sale detail).
- **A balance is the server's aggregate** — never a sum of rows in Dart.
- **An allocation is limited by what is owed, under a lock** (D-076); **applying a deposit is not a
  second receipt** (D-075/D-076).
- **F2:** rewriting assertions to the new contract is allowed and expected; the count may not fall;
  nothing may be deleted, skipped, loosened or weakened.
- **F3:** any tab or list built from data, never from a list hard-coded in the app — and that applies
  to a balance screen's own rows.
- **F4:** no GSTIN anywhere in the counter's registration.
- **C2's and C3/3's contracts must not regress:** Enter adds and **never checks out**; Escape closes
  the list and never clears the basket; Tab walks the quantities; a rapid second Enter/tap cannot
  double-add or double-submit (D-078); and a write is still **confirmed on the counter's figures and
  answered by the server** (D-080).

## WORKFLOW RULES

- Write **full file contents**, never truncated; run `dart format lib test` before the gates.
- `@riverpod` codegen for every new provider; Freezed for value models (`abstract class X with _$X`).
  A provider **family argument** needs real `==`, so it is a Freezed value (see `PosListKey`).
- Every DB query is pharmacy-scoped; tenant comes from `get_my_pharmacy_id()` on the server.
- Money is `SaleTotals`' business alone; **balances are the server's aggregates**, never a sum of
  rows in Dart.
- **Ask before:** modifying a migration, the RPC, the RLS policy or a committed SQL test; pushing
  anything; deploying; adding a dependency.
- Commit locally per chunk, do **not** push, and report with the hash and the raw gate output.
- **Verify every item in a commit message against the diff** (`git show --stat` and read the lines)
  before signing it.

## END-OF-CHAT HANDOFF

When C3/4 is done — which completes Phase 7a's Flutter side — or context reaches ~60–70%:

1. Run the gates and paste the raw output, including the real `flutter test` count, and the per-file
   `SUMMARY:` lines if any SQL moved
2. Update `PROGRESS.md` — the Phase 7a four-part status (it can finally say **C3 is done**), the
   phase table, and the Flutter App list
3. Write `context/chat3r-summary.md` and `context/chat3s-opening-prompt.md`
4. Update `DECISIONS.md` for anything that is a new decision — including the collection-path answer
   from §3 above
5. Output a numbered list of every file created/modified
6. **Before signing a commit message, verify every item in it is in the diff** (`git show --stat`
   and read the lines). This rule exists because a commit message here once described work that was
   not in the diff at all.

## BEGIN

Report your 5-line understanding and your C3/4 plan (chunk split, files to modify vs create, and your
answer on §3's collection path) before writing code.
