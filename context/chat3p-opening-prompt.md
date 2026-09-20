# Chat 3p — Phase 7a: the POS UX refactor (C2), then payment, receipt and balances (C3)

You are continuing work on PharmaFlow, picking up Phase 7a's Flutter side where chat 3o left it.
The durable layer is already on hosted; the app's C1a and C1b are committed locally and gated.

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — the Phase 7a four-part status at the top, and the phase table
2. `MASTER_PLAN.md` → Phase 7, especially §1 (the four sale types), §6 (the GST basis, D-075) and §7
   (the open items)
3. `DECISIONS.md` → **D-067** (four sale types), **D-070** (the package markup), **D-071** (the
   discount cap), **D-072** (doctors), **D-074** (a patient is a customer), **D-075** (the
   tax-inclusive basis), **D-076** (allocation integrity and the gated patient edit)
4. `HANDOFF_PROTOCOL.md` — the contract this file is written to
5. `context/chat3o-summary.md` — what the previous chat built, and its open items
6. This file
7. **The code, before changing it**: `app/lib/features/sales/` in full (`data/sale_totals.dart`,
   `data/sale_checkout.dart`, `application/pos_controller.dart`,
   `application/sale_checkout_controller.dart`, `application/sale_requirements.dart`,
   `presentation/pos_screen.dart`, `presentation/patients/patient_step.dart`,
   `presentation/widgets/`), plus `app/lib/services/invoice_printer.dart` for C3 and
   `supabase/migrations/20260920000036_phase7a_sale_write_paths.sql` for the server contract
   (**read it; do not modify it**)

Output a 5-line understanding check:

- The backend contract the app integrates with (the typed `checkout_sale`, what it recomputes)
- What C1a and C1b already put in place (do not rebuild them)
- What C2 changes, and what C3 adds
- The two things that must not regress: the tax-inclusive basis and the idempotency rule
- What you are about to build first

## ENVIRONMENT (FIXED)

- Workspace: `C:\Projects\PharmaFlow\` (Flutter app in `app/`)
- Supabase: **hosted only**, project ref `yeroxzkpmodbzcvjlqwd`; no Docker, no `supabase start`
- Flutter 3.44.8 / Dart 3.12.2; Riverpod 3.0.3 (codegen), Freezed 3.2.3, `very_good_analysis`
- **Gate list, in this order, from `app/`** (`deno` from the repository root):
  `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` →
  the five `deno check` entry points.
  `flutter analyze` and `flutter test` both cover `test/**`: a lint in a fixture fails the gate
  before a single test runs.
- Measured baseline at handoff: **898 Flutter tests, 181 Deno tests**, all passing.
- **Report actual counts, never a running total.**

## SCOPE

**C2 — the POS UX refactor (approved, ~150k).** On top of what C1b built, in the owner's words:
A) auto-focused search with a top-5 dropdown (stock, MRP, batch, expiry in MM/YY) where **Enter
adds the highlighted result** and no batch chooser interrupts the default case; arrow keys move,
Esc closes. B) compact cart lines — product, batch+expiry, qty, line total visible; rate, disc %
and GST % on demand; Tab from qty to the next line; Delete removes a line. C) a top strip of
Recent (last 10 sold) + category tabs — **built from the catalogue's own distinct categories: the
imported products have `category` NULL, so ship "Recent" + "All" today and add tabs as data
appears**. D) the keyboard contract: Enter never checks out from search; Esc closes then steps
back and never clears the cart silently; focus is restored after a selection, a dialog and a
validation error; a rapid Enter/tap cannot double-add or double-submit. E) responsive at
**360×800** with ≥44px targets.

**C3 — payment, receipt, balances (approved, ~120k).** Payment modes, change (never negative), the
on-credit guard, a confirm dialog on **server** totals, and never showing success or printing
before the server answers; the 80mm receipt with **batch and expiry per line** (Drug Rules), which
needs **migration `00039`** (below); and the balance views (patient, admission, sale detail with
allocations).

## WHAT THE OWNER ALREADY DECIDED (do not re-litigate)

- **The receipt's per-line batch/expiry source:** option (b) — a **new additive migration `00039`**
  with `sale_document(p_sale_id uuid) returns jsonb`. **`checkout_sale` is not to be touched** (it
  returns the `sales` row and a composite return type cannot carry lines). The owner approved this
  body **verbatim** on 2026-09-20; it is reproduced here because the chat that approved it is gone:

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

  Grant execute to `authenticated`; RLS still enforces the tenant. Write it as the next migration in
  order, verify it locally with the project's throwaway-pgvector harness (the recipe is in
  `PROGRESS.md` and the SQL-suite notes), and do **not** push it without asking.
- **The receipt also needs `customers.patient_code`**, which is not a column on `sales`: decide
  whether `sale_document` returns it (an extra join, one round trip) or the client reads the
  customer row, and say why.
- **A package sale's debtor is one `customers` row per hospital** ("… (Account)"), chosen by the
  operator; the patient's name and mobile are required on the bill for traceability.
- **Discounts are capped at 10% by refusal** — no approval UI is to be invented (6.5c does not
  exist).
- **Unknown batch/expiry print "—"**, never `OPENING-…` and never a fake date.
- **F2:** rewriting assertions to the new contract is allowed and expected; the count may not fall;
  nothing may be deleted, skipped, loosened or weakened.
- **F3:** category tabs come from data, not a hard-coded list.
- **F4:** no GSTIN anywhere in the counter's registration.

## WORKFLOW RULES

- Write **full file contents**, never truncated; run `dart format lib test` before the gates.
- `@riverpod` codegen for every new provider; Freezed for value models (`abstract class X with _$X`).
- Every DB query is pharmacy-scoped; tenant comes from `get_my_pharmacy_id()` on the server.
- No business logic in widgets: a write goes through a controller (see `SaleCheckoutController`,
  `AdmissionController`, `PatientRegistrationController`).
- Money is `SaleTotals`' business alone; money figures are never recomputed in a widget.
- **Ask before:** modifying a migration, the RPC, the RLS policy or a committed SQL test; pushing
  anything; deploying; adding a dependency.
- Commit locally per chunk, do **not** push, and report with the hash and the raw gate output.

## END-OF-CHAT HANDOFF

When C2 and C3 are done, or context reaches ~60–70%:

1. Run the gates and paste the raw output, including the real `flutter test` count
2. Update `PROGRESS.md` — the Phase 7a four-part status, the phase table, and the Flutter App list
3. Write `context/chat3p-summary.md` and `context/chat3q-opening-prompt.md`
4. Update `DECISIONS.md` for anything that is a new decision
5. Output a numbered list of every file created/modified
6. **Before signing a commit message, verify every item in it is in the diff** (`git show --stat`
   and read the lines). This rule exists because a commit message here once described work that was
   not in the diff at all.

## BEGIN

Report your 5-line understanding and your C2 plan (chunk split, files to modify vs create, and
anything you need clarified) before writing code.
