# Chat 3r — Phase 7a: applying a deposit (C3/4b, the last piece)

You are continuing work on PharmaFlow, picking up Phase 7a where chat 3q left it. The durable layer is
on hosted (39 = 39). The app's **C1a, C1b, C2, C3/1, C3/2, C3/3 and C3/4a are committed locally and
gated** — including the three balance views and the one collection path. **What remains of Phase 7a is
C3/4b: applying a deposit from the UI** — and nothing else.

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — the Phase 7a four-part status at the top, and the phase table
2. `MASTER_PLAN.md` → Phase 7, especially §5 (the reports) and §7 (the open items)
3. `DECISIONS.md` → **D-025**, **D-067**, **D-074**, **D-075**, **D-076**, **D-079**, **D-080** and —
   added for this slice — **D-081** (a receipt has one door: everything goes through
   `collect_payment`)
4. `HANDOFF_PROTOCOL.md` — the contract this file is written to
5. `context/chat3q-summary.md` — what chat 3q built, and its open items
6. This file
7. **The code, before changing it**: `app/lib/features/balances/` in full — especially
   `data/balances_repository.dart` (its `applyDeposit` and `PaymentAllocationTarget` are the writer
   this chunk needs), `application/balances.dart` and `presentation/widgets/patient_balance_card.dart`
   — plus `app/lib/features/ledger/presentation/widgets/payment_sheet.dart` (the sheet whose structure
   you may reuse) and
   `supabase/migrations/20260920000037_phase7a_allocation_integrity.sql`'s `allocate_payment`
   (**read it; do not modify it**)

Output a 5-line understanding check:

- What `allocate_payment()` does, and what it refuses
- What C3/4a already put in place (do not rebuild it)
- What C3/4b adds, in the order it has to be built
- The two things that must not regress: applying a deposit is not a second receipt, and no screen
  sums rows
- What you are about to build first, and your answer to §1 below

## ENVIRONMENT (FIXED)

- Workspace: `C:\Projects\PharmaFlow\` (Flutter app in `app/`)
- Supabase: **hosted only**, project ref `yeroxzkpmodbzcvjlqwd`; no `supabase start`, and the local
  stack is not this project's. **Docker IS available** and is what the throwaway pgvector harness uses
- Flutter 3.44.8 / Dart 3.12.2; Riverpod 3.0.3 (codegen), Freezed 3.2.3, `very_good_analysis`
- **Gate list, in this order, from `app/`** (`deno` from the repository root):
  `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` →
  the five `deno check` entry points
- Measured baseline at handoff: **954 Flutter tests, 181 Deno tests**, all passing, at `be05756`
- **Report actual counts, never a running total**

## SCOPE — C3/4b: applying a deposit from the UI

### 1. ANSWERED: the reader exists (option (a), migrations 00040 and 00041)

A deposit is a receipt whose allocations totalled less than its amount: `unallocated_deposits` on
`patient_account()`. Applying it means `allocate_payment(p_payment_id, p_allocations)` — which
**writes only allocation rows** and is limited by what is still owed on each target, under a row lock.

So the sheet needs two lists. **Both are now readable:**

- **The party's open bills** — `public.open_bills(p_party_type public.party_type, p_party_id uuid)
  returns jsonb`, added by **migration `20260921000040`** and pushed to hosted:
  `{"bills": [{"sale_id", "invoice_no", "sale_date", "sale_type", "grand_total", "returned_total",
  "allocated_total", "outstanding"}], "total_outstanding"}` — **oldest first**, and **only bills with
  `outstanding > 0`**. Its arithmetic is `allocate_payment()`'s own expressions restricted to one bill,
  so **a bill's figure is the limit a refusal will name** (asserted: a slice one paisa larger is
  refused, and exactly that figure settles it). **`p_party_type` accepts `customer` only** — a supplier
  answers an empty list, because a supplier's open documents are purchases and this reader is about
  sales; that is recorded, not a bug, and `allocate_payment` can no more apply a supplier's receipt to
  a sale than this reader can list one.
- **The receipts with money still unapplied** — still a plain read, and **the one piece not yet
  written**: `payments` (`id`, `party_type`, `supplier_id`, `customer_id`, `amount`, `mode`,
  `reference_no`, `payment_date`, `notes`, `created_at`) plus `payment_allocations` for those ids;
  each receipt's remainder is `amount − Σ allocations`. The party's **total** is already the
  server's (`patient_account().unallocated_deposits`) — do not recompute that, only the per-receipt
  remainder the sheet has to show, and say so where you write it.

**Read `supabase/migrations/20260921000041_phase7a_open_bills_order.sql`'s header** before touching
this area: the first version of `open_bills` ordered by `sale_date, id`, and **the hosted run caught
it** — `now()` is the transaction start time, so two bills raised in one transaction share a
timestamp and the `id` tiebreak was a random uuid. It is now `sale_date, invoice_no, id`, and the test
asserts that the two fixture bills genuinely share a date, so the invoice-number assertion cannot
become vacuous. Two lessons worth carrying: **run the SQL tests against hosted, not only locally**,
and prefer an order that comes from the document's own sequence over one that comes from a uuid.

### 2. The sheet itself

- A `collection_sheet.dart` (or `apply_deposit_sheet.dart`) under
  `app/lib/features/balances/presentation/`, reusing the structure of Phase 4's
  `payment_sheet.dart` — which is the app's existing "take money" sheet and is worth reading for its
  form, its SnackBar-on-refusal and its return value.
- It shows **the deposits first** (a receipt with money still unapplied, its date, its mode, what it
  still holds), then the bills to apply it to, and lets the operator enter an amount per bill.
- **The client proposes; the server disposes.** `allocate_payment` may total **less** than the
  receipt (the rest stays held) but never more, and each target is capped by its own outstanding
  **under a lock** — so the sheet must read a refusal as the authority and never as a bug.
- A successful application reloads the patient's account and the bills it touched.
- **No business logic in the widget**: the write goes through a controller, as everywhere else.
- The entry point: the patient's account card (`PatientBalanceCard`) shows **held unapplied**, so that
  is where the action belongs — and the ledger screen is the other candidate, since it is where the
  deposit was taken.

### 3. Tests

- A deposit with no allocations is recorded and shows as held (already true via
  `LedgerRepository.recordPayment` — assert it, do not rebuild it).
- Appling part of a deposit settles the bill it names and leaves the rest held.
- An application that would over-settle a bill is refused, and the refusal is the server's words,
  with nothing written.
- Cross-admission isolation at the screen: applying to episode A leaves episode B's figure alone.
- A receipt that is already fully applied is not offered.

## WHAT THE OWNER ALREADY DECIDED (do not re-litigate)

- **One collection path**: every receipt goes through `collect_payment`, including Phase 4's ledger
  sheet, which passes no allocations (**D-081**).
- **A balance is the server's aggregate** — never a sum of rows in Dart.
- **An allocation is limited by what is owed, under a lock** (D-076); **applying a deposit is not a
  second receipt** (D-075/D-076).
- **The three views and their placements** (D-080's slice): patient on the customer detail, the
  admissions list with `/admissions/:admissionId`, allocations inside the sale detail.
- **F2:** rewriting assertions to the new contract is allowed and expected; the count (954) may not
  fall; nothing may be deleted, skipped, loosened or weakened.
- **F3:** any tab or list built from data, never from a list hard-coded in the app.
- **F4:** no GSTIN anywhere in the counter's registration.
- **C2's and C3/3's contracts must not regress:** Enter adds and **never checks out**; Escape closes
  the list and never clears the basket; Tab walks the quantities; a rapid second Enter/tap cannot
  double-add or double-submit (D-078); and a sale is **confirmed on the counter's figures and answered
  by the server** (D-080).

## WORKFLOW RULES

- Write **full file contents**, never truncated; run `dart format lib test` before the gates.
- `@riverpod` codegen for every new provider; Freezed for value models (`abstract class X with _$X`).
  A provider **family argument** needs real `==`, so it is a Freezed value (see `PosListKey`).
- Every DB query is pharmacy-scoped; tenant comes from `get_my_pharmacy_id()` on the server.
- **Ask before:** modifying a migration, the RPC, the RLS policy or a committed SQL test; **writing a
  new migration**; pushing anything; deploying; adding a dependency.
- Commit locally per chunk, do **not** push, and report with the hash and the raw gate output.
- **Verify every item in a commit message against the diff** (`git show --stat` and read the lines)
  before signing it.

## END-OF-CHAT HANDOFF

When C3/4b is done — which completes Phase 7a — or context reaches ~60–70%:

1. Run the gates and paste the raw output, including the real `flutter test` count
2. Update `PROGRESS.md` — the four-part status (it can finally say **Phase 7a's Flutter side is
   done**), the phase table, and the Flutter App list
3. Write `context/chat3r-summary.md` and `context/chat3s-opening-prompt.md`
4. Update `DECISIONS.md` for anything that is a new decision — including the §1 answer
5. Output a numbered list of every file created/modified
6. **Before signing a commit message, verify every item in it is in the diff** (`git show --stat` and
   read the lines). This rule exists because a commit message here once described work that was not in
   the diff at all.

## BEGIN

Report your 5-line understanding and your plan (files to modify vs create, and your answer to §1)
before writing code. **Ask about §1 rather than choosing silently.**
