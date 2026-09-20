# Chat 3q — Phase 7a: payment, the receipt and the balances (C3)

You are continuing work on PharmaFlow, picking up Phase 7a's Flutter side where chat 3p left it.
The durable layer is on hosted; the app's **C1a, C1b and C2 are committed locally and gated**.
**What remains of Phase 7a is C3** — payment, the receipt and the balances — and nothing else.

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — the Phase 7a four-part status at the top, and the phase table
2. `MASTER_PLAN.md` → Phase 7, especially §1 (the four sale types), §5 (the reports), §6 (the GST
   basis, D-075) and §7 (the open items)
3. `DECISIONS.md` → **D-067**, **D-070**, **D-071**, **D-074**, **D-075**, **D-076**, and — added for
   this slice — **D-079** (the receipt's contract and the patient-code decision), **D-077** and
   **D-078** (the counter's list and its keyboard contract, so C3 does not undo them)
4. `HANDOFF_PROTOCOL.md` — the contract this file is written to
5. `context/chat3p-summary.md` — what the previous chat built, and its open items
6. This file
7. **The code, before changing it**: `app/lib/services/invoice_printer.dart` in full,
   `app/lib/features/sales/application/sale_detail_controller.dart`,
   `app/lib/features/sales/presentation/sale_detail_screen.dart`,
   `app/lib/features/sales/data/sales_repository.dart`,
   `app/lib/features/sales/data/sale_totals.dart` (it already has `changeFor` and `recordablePaid`),
   `app/lib/features/sales/application/pos_controller.dart` and `pos_screen.dart` (the payment
   fields that exist), and `supabase/migrations/20260920000036_phase7a_sale_write_paths.sql`
   (`collect_payment`, `allocate_payment`, `admission_account`, `patient_account`) — **read them, do
   not modify 00036**

Output a 5-line understanding check:

- The backend contract C3 integrates with (what `collect_payment` does, and what the two balance
  readers aggregate)
- What C1a, C1b and C2 already put in place (do not rebuild them)
- What C3 adds, in the order it has to be built
- The two things that must not regress: the tax-inclusive basis and the idempotency rule
- What you are about to build first

## ENVIRONMENT (FIXED)

- Workspace: `C:\Projects\PharmaFlow\` (Flutter app in `app/`)
- Supabase: **hosted only**, project ref `yeroxzkpmodbzcvjlqwd`; no `supabase start`, and the local
  stack is not this project's. **Docker IS available on this machine** and is what the throwaway
  pgvector harness uses (see below)
- Flutter 3.44.8 / Dart 3.12.2; Riverpod 3.0.3 (codegen), Freezed 3.2.3, `very_good_analysis`
- **Gate list, in this order, from `app/`** (`deno` from the repository root):
  `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` →
  the five `deno check` entry points.
  `flutter analyze` and `flutter test` both cover `test/**`: a lint in a fixture fails the gate
  before a single test runs.
- Measured baseline at handoff: **926 Flutter tests, 181 Deno tests**, all passing, at `ed4e177`.
- **Report actual counts, never a running total.**

## THE LOCAL SQL HARNESS (C3 needs it, and it is already standing)

Migration `00039` has to be verified **locally**, because the brief forbids pushing without asking
and the committed SQL files are not in any automated gate.

- **The Docker container is already up**: `pharmaflow-pg7a` (`pgvector/pgvector:pg17`, **no published
  port**, so it cannot collide with anything else on the machine). Do **not** touch the unrelated
  containers on this host.
- **The harness is already on disk**, outside version control, at `.qwen/tmp/pg7a/`: `stub.sql` (the
  Supabase-managed schemas and roles the migrations grant to), `reset.sql`, `seed.sql`, `run_all.sql`
  (every migration in order), `run_tests.sql` (every test file in order), plus the upgrade-path files
  (`run_all_pre7a.sql`, `upgrade_before.sql`, `run_7a_only.sql`, `upgrade_after.sql`,
  `data_scenario.sql`) and the recorded outputs (`out_*.txt`).
- **`run_all.sql` lists migrations 00001–00038.** Add the new `…000039_…` line before the fresh run —
  it is a harness file, not a committed one.
- The signal worth having is **applying every migration to a fresh database**: an ordering or
  dependency mistake shows up as an ERROR that an incremental push would hide. All 38 applied clean on
  2026-09-20.
- Each test file prints one machine-readable line: `SUMMARY: <n> PASS / <m> FAIL of <k> assertions`.
  Grep that line. **Check the file's own counting idiom before reading `k`** — the older files count
  the summary itself, and `phase7a_sale_types.sql` carries a long header note about it. Never edit a
  number to make a total match.
- **State the harness's limits** rather than letting "locally verified" stand for more: RLS is
  exercised by `set role authenticated`, not by a JWT through PostgREST; GoTrue and the storage
  service do not exist at all; and a single-session script cannot test true two-session concurrency.
- Verified from the repository root; the full recipe is in the SQL-suite notes.

## SCOPE — C3: payment, receipt and balances (approved, ~120k)

**The receipt is blocked on this migration, so write it first.**

### 1. Migration `00039` — `sale_document` (approved; **the body below is the owner's, verbatim**)

`checkout_sale` is **not to be touched** (it returns the `sales` row, and a composite return type
cannot carry lines). The owner approved this function body on 2026-09-20:

```sql
create or replace function public.sale_document(p_sale_id uuid)
returns jsonb
language sql stable security invoker
as $$
  select jsonb_build_object(
    'sale', to_jsonb(s.*),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'item', to_jsonb(si.*),
        'batch_no', pb.batch_no,
        'expiry_date', pb.expiry_date,
        'is_unknown_batch', pb.is_unknown_batch
      ) order by si.created_at)
      from sale_items si
      left join product_batches pb on pb.id = si.batch_id
      where si.sale_id = s.id
    ), '[]'::jsonb)
  )
  from sales s
  where s.id = p_sale_id
    and s.pharmacy_id = get_my_pharmacy_id();
$$;
```

**One insertion, and it is the answer to the owner's own open question** (recorded as **D-079**):
the receipt also needs the patient's **code**, which is not a column on `sales`. It is **joined** —
one round trip, and the code the row held rather than a second read that could race the master —
so the function returns a `'patient_code'` key beside `'sale'`:

```sql
    'sale', to_jsonb(s.*),
    'patient_code', c.patient_code,
    'lines', ...                                    -- unchanged
  from sales s
  left join customers c
    on c.id = s.customer_id
   and c.pharmacy_id = s.pharmacy_id
  where s.id = p_sale_id
    and s.pharmacy_id = get_my_pharmacy_id();
```

Two things that fall out of it, and both are correct rather than a gap:

- for a **counter or IPD** sale, `sales.customer_id` **is** the patient (D-074), so the code is the
  patient's;
- for a **package** sale that customer is the **hospital's account** row, whose patient code is
  legitimately absent — the patient on a package bill is the sale's own `patient_name` /
  `patient_mobile` snapshot and has no patient row of their own. The receipt prints the snapshot and
  no code.

Also: **grant execute to `authenticated`** and revoke from `anon, public` (the idiom migration 00018
settled); add `set search_path = public` if you keep every other function in this family consistent
(it is an attribute, not the body); write it as the **next migration in order**; **do not push it
without asking**.

### 2. The 80mm receipt, with per-line batch and expiry (Drug Rules)

- `app/lib/services/invoice_printer.dart` is the whole receipt: `buildSheet` (pure content),
  `buildDocument` (the 80mm layout) and `printReceipt`. A line's content is today
  `name` + `detail` (`2 x Rs 100.00 less 10% + 12% GST`) + `amount`. **The batch and the expiry have
  to join that**, per line.
- **Unknown batch/expiry print `—`** — never `OPENING-…`, never a fake date. 145 of the owner's
  opening-stock batches have no expiry (migration 00031), so this is the common case, not a corner.
- The data comes from `sale_document`, **not** from client-side cart state and not from a Dart join of
  `sale_items` to `product_batches`: a receipt is printed from the server's own document (D-079).
- The bill's arithmetic stays the stored row's (`sub_total`, `tax_total`, `grand_total`) and the
  tax heads add back to `tax_total` exactly as they do now (D-057) — do not recompute money.
- **Never print before the server answers**, and never show success before it does.

### 3. Payment, and the confirmation on **server** totals

- Payment modes exist (`PaymentMode` with `isOnAccount`), as do the tender field, `changeFor` (which
  is never negative) and `recordablePaid`. C3 adds the **confirm dialog on the server's totals**, the
  payment-mode completeness, and the rule that **nothing is shown as written or printed until the
  server has answered**.
- The **on-credit guard** is the server's rule said on screen: a sale with a balance needs a party to
  owe it (`sale_requirements.dart` already refuses it; `checkout_sale` refuses it too).
- **Discounts above 10% are refused by the server** (D-071) — there is no approval UI to invent, and
  6.5c does not exist.

### 4. The balance views

- Patient, admission, and **sale detail with its allocations**.
- The figures are the server's: `admission_account(p_admission_id)` and `patient_account(p_customer_id)`
  (aggregates, D-025/D-075), and `collect_payment(...)` / `allocate_payment(...)` for taking and
  applying money (D-076: an allocation is limited by what is owed **under a lock**; applying a deposit
  is **not** a second receipt). No screen sums rows in Dart.
- A `customer_id`'s outstanding is **charges less valid returns less allocated collections**, and any
  remainder of a receipt stays a visible **unallocated deposit**. A package sale never lands on the
  patient's balance: its debtor is the hospital's account row, a different `customer_id`.

## WHAT THE OWNER ALREADY DECIDED (do not re-litigate)

- **The receipt's per-line batch/expiry source:** option (b), the additive migration `00039` above —
  not a PostgREST read-back the client stitches together. The body is the owner's, verbatim, and the
  `patient_code` join is the answer to the question the owner asked this chat to decide (**D-079**).
- **A package sale's debtor is one `customers` row per hospital** ("… (Account)"), chosen by the
  operator; the patient's name and mobile are required on the bill for traceability.
- **Discounts are capped at 10% by refusal** — no approval UI is to be invented (6.5c does not exist).
- **Unknown batch/expiry print "—"**, never `OPENING-…` and never a fake date.
- **F2:** rewriting assertions to the new contract is allowed and expected; the count may not fall;
  nothing may be deleted, skipped, loosened or weakened.
- **F3:** any tab or list built from data, never from a list hard-coded in the app (C2's strip is the
  precedent — see `pos_strip.dart` / `product_categories.dart`).
- **F4:** no GSTIN anywhere in the counter's registration.
- **C2's contract must not regress:** Enter adds and **never checks out**; Escape closes the list and
  never clears the basket; Tab walks the quantities; a rapid second Enter/tap cannot double-add or
  double-submit (D-078).

## WORKFLOW RULES

- Write **full file contents**, never truncated; run `dart format lib test` before the gates.
- `@riverpod` codegen for every new provider; Freezed for value models (`abstract class X with _$X`).
  A provider **family argument** needs real `==`, so it is a Freezed value (see `PosListKey`).
- Every DB query is pharmacy-scoped; tenant comes from `get_my_pharmacy_id()` on the server.
- No business logic in widgets: a write goes through a controller (see `SaleCheckoutController`,
  `AdmissionController`, `PatientRegistrationController`).
- Money is `SaleTotals`' business alone; money figures are never recomputed in a widget — and
  **balances are the server's aggregates**, never a sum of rows in Dart.
- **Ask before:** modifying a migration, the RPC, the RLS policy or a committed SQL test; pushing
  anything; deploying; adding a dependency.
- Commit locally per chunk, do **not** push, and report with the hash and the raw gate output.
- **A new SQL test file needs a `SUMMARY:` line** and the harness run that backs it; and a test that
  would pass without the code it is supposed to guard is worth re-reading before it is called
  evidence (C2's `checkoutGate` exists for exactly that reason).

## END-OF-CHAT HANDOFF

When C3 is done, or context reaches ~60–70%:

1. Run the gates and paste the raw output, including the real `flutter test` count, and the per-file
   `SUMMARY:` lines from the local SQL harness
2. Update `PROGRESS.md` — the Phase 7a four-part status, the phase table, and the Flutter App list
3. Write `context/chat3q-summary.md` and `context/chat3r-opening-prompt.md`
4. Update `DECISIONS.md` for anything that is a new decision
5. Output a numbered list of every file created/modified
6. **Before signing a commit message, verify every item in it is in the diff** (`git show --stat`
   and read the lines). This rule exists because a commit message here once described work that was
   not in the diff at all.

## BEGIN

Report your 5-line understanding and your C3 plan (chunk split, files to modify vs create, and
anything you need clarified) before writing code.
