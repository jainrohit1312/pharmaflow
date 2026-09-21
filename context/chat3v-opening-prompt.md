# Next chat — Phase 6.5b (the receiver app), and the one 6.5c gap left open

You are continuing work on PharmaFlow. **This is a long session by design**: the window is 1M, so the
work is sized to fill it rather than to stop at every checkpoint.

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — the phase table now reads **6.5c COMPLETE** and **7a COMPLETE**, and the
   "Current Phase" block names the ONE gap left inside 6.5c's policy
2. `context/chat3u-summary.md` — what the last session did across chunk 6 and the deposit sheet, and
   its seven open items
3. `DECISIONS.md` → **D-088** (the two questions chunk 6 answered: the dispatch waits on N-1, and a
   stale ask is closed through one closure), D-086 (the named gap), D-087 (the sale acts),
   D-085 (the policy) and D-021 (`refreshStockReaders`, the shape `refreshApprovalReaders` follows)
4. `MASTER_PLAN.md` → **Phase 6.5** (the receiver app is listed there as a sub-chunk and **has no
   shape written down** — that is the first thing this session has to settle) and Phase 7
5. this file

Output a 5-line understanding check: the phase you are doing, the previous session's deliverables, the
environment, two load-bearing dependency pins, and what you are about to build. **Then ask the owner
what the receiver app IS before designing it** — see below.

## WHERE THE PROJECT STANDS

**Phase 6.5c is COMPLETE** (chunks 1–6, migrations `00043`–`00049`, all on hosted, 49 = 49) and
**Phase 7a is COMPLETE** (the durable layer on hosted, the Flutter side C1/C2/C3 and the
deposit-application sheet). What is left of the owner's declared sequence is:

```
Phase 6.5b  →  the receiver app          <-- next, and the only one with no shape yet
Phase 7b    →  hospital profit sharing   (D-068's dated rules, 50% / 60% / two real 0% deals)
Phase 7c    →  the reports
```

## SCOPE — in this order

### 1. ASK FIRST: what is the receiver app?

`MASTER_PLAN.md` says only *"**Phase 6.5b — the receiver app.** A receiving role/flow."* — the owner's
own words, recorded as a stub, with the note that "beyond the approval system's shape nothing else is
known, so nothing else is written here". **Do not design it from that sentence.** Put these to him
(with a recommendation each) before writing a line:

- **What does it receive?** Goods against a GRN the pharmacy already sent? An OCR'd supplier bill? A
  transfer from another of the four pharmacies? All three?
- **Who runs it** — a role that does not exist yet (`app_role` has `owner`, `pharmacist`, `cashier`,
  `viewer`), or an existing role with a different screen? A new `app_role` VALUE is an `alter type`
  and a migration; a new screen on `cashier` is not.
- **Does it talk to the counter** it is receiving for, and does the goods receipt remain the one
  `save_purchase()` path (chunk 3's answer: a staff GRN is a `pending_approval` document), or is a
  receiver's receipt a different act?
- **Where does it run** — the same Flutter app, a second app, a web-only screen?
- **What does it do about the D-046/auto-send-PO work** (`MASTER_PLAN` Phase 6's add-on), which waits
  on the same provider accounts as N-1?

**Record his answers as a decision before building.** This phase has no shape, so its first
deliverable is a decision, not a migration.

### 2. The one gap left inside 6.5c's policy (small, and it ships in one piece)

**The customers form's eight granted columns.** `customers` has table-level UPDATE revoked with
exactly eight columns granted back (migration `00038`, deliberately, so "no existing screen changes
behaviour"): `name, phone, email, address, gstin, opening_balance, loyalty_points, is_active`. D-086
left them alone and **named the gap rather than hiding it**: a session can set a customer's
`is_active` (a soft delete) and `opening_balance` (money), and both are acts the owner's sentence
covers.

**The rule that chunk has to obey is D-086's own: a revoke ships WITH its request path**, so the
revoke and the form's re-route are ONE migration. `customer_edit` is already the action type it
raises, `update_patient()` is already the door for a patient master edit, and the customers form
(`app/lib/features/customers/presentation/customers_form_screen.dart`, its
`customers_form_controller.dart`, and the repository's update) is what has to change with it. Ask
before you revoke anything, and check the customers form's SQL test (`phase7a_sale_types.sql` asserts
the eight columns today).

### 3. Then, if the owner's sequence has moved on

Phase 7b (hospital profit sharing, D-068) and 7c (the reports). Do NOT start either without his
answer to §1 — the receiver is what his own sequence puts first.

## WHAT MUST NOT BREAK

- The counter: the sale bill, a payment, a new patient and **an expense** stay free for every role.
- **The owner's own work is never gated** — he writes through the same RPCs, which ask him nothing.
- The committed SQL tests and the stock/ledger triggers: approving runs exactly the write the staff
  used to run, through the same door.
- The truthfulness rule: no screen may promise an approval that does not exist, and a refusal's
  sentence must name what is actually missing. **`document_payload_problem()` is the one shape check
  both the ask and the write use.**
- **Every business table's write grant is a decision, not an oversight.** The only tables a session
  may still write are `expenses` (by design, D-085) and the customers form's eight columns (§2).
  Check before you add or remove one.

## RULES

- Write FULL file contents, never truncate. Reproduce a `create or replace` body from the applied
  migration's own text and **diff it** — `.qwen/tmp/pg7a/build_00048.js` and `build_00049.js` are the
  current pattern, and `build_00046.js`'s own header records the `$`-in-a-replacement-string trap
  that silently corrupted a body there.
- One mechanism, never a second one for one action. **A list of readers is one mechanism;
  `refreshApprovalReaders()` is where a new one goes.**
- Every changed assertion documented **before → after** in the reply **and the commit message**; no
  assertion deleted, skipped or loosened; the test count may not fall.
- **A file that ERRORs prints no SUMMARY line and no FAIL line, so a run that greps for `FAIL` reads
  it as green.** Count the `psql:/repo/supabase/tests/…` header lines and check none says `ABORTED`
  as well as grepping for FAIL.
- **Run a new SQL test against hosted, not only locally** (D-082's lesson).
- `dart format lib test` before the gates; `flutter analyze` covers `test/**` too.

## ENVIRONMENT (FIXED)

- Workspace `C:\Projects\PharmaFlow\`; remote `origin` = `https://github.com/jainrohit1312/pharmaflow.git`
  (**`git push` works from here**).
- Supabase **hosted only** (ref `yeroxzkpmodbzcvjlqwd`), no Docker for Supabase; migrations by
  `supabase db push --yes`. **49 = 49** as of this handoff (`86aec67`).
- The **local SQL harness lives at `.qwen/tmp/pg7a/`** and the container `pharmaflow-pg7a` has been up
  for days — reuse it (memory: *Verify the SQL suite locally*). `run_all.sql` lists `00001`-`00049`;
  `run_tests.sql` lists **24** files. Run order: `reset` → `stub` → `run_all` → `seed` → `run_tests`.
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0 — do not touch the pinned ranges.
  **`ref.invalidate` takes a `ProviderOrFamily`**, so a family can be invalidated whole, which is what
  `refreshApprovalReaders()` relies on.
- Gates: `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` → the
  five `deno check` entry points.
- **Baseline at this handoff: 1074 Flutter tests, 181 Deno tests, all passing, at `86aec67`** (pushed).
  The SQL suite is **17 files with a SUMMARY line**, 0 FAIL locally on a fresh 49-migration database
  and no file `ABORTED`, and hosted holds migrations `00043`-`00049`, each re-verified there.

## END-OF-SESSION HANDOFF (when you are near the limit)

Gates run and pasted raw, `PROGRESS.md` updated, a chat summary and the next opening prompt written,
`DECISIONS.md` updated (this session's §1 answer is a decision), and a numbered list of every file
touched. Push before you write the handoff, so the next session starts from the remote and not from a
working tree.
