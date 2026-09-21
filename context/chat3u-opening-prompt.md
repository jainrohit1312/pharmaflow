# Next chat — Phase 6.5c chunk 6 (and 5e): the notification's other half, and the last of the polish

You are continuing work on PharmaFlow. **This is a long session by design**: the window is 1M, so the
work is sized to fill it rather than to stop at every checkpoint.

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md`, `MASTER_PLAN.md`, `DECISIONS.md` — **D-087 is the last chunk's decision** (a cancel
   is a status flip on a bill nothing has happened to; a sale edit is the printed identity), **D-086**
   is the master data, **D-085** the policy (expenses are not gated — he is notified instead), and
   D-083/D-084 the module's two document shapes
2. `context/chat3t-summary.md` — what the last session did across chunks 5a-c and 5d, and the six
   things it left open
3. `supabase/migrations/20260921000047_phase6_5c_approval_sale_acts.sql` — the most recent chunk, and
   `20260921000046_…_master_data.sql` for the expense notification this chunk delivers on
4. this file

Output a 5-line understanding check: the chunk you are doing, the previous chunks' deliverables, the
environment, two load-bearing dependency pins, and what you are about to build.

## WHERE THE MODULE STANDS

**Every declared approval action type is now implemented or retired**, and every table the owner
named is behind the rail: a purchase is a pending document, a return and a stock correction are
requests, the product and customer masters are requests, a posted bill can be cancelled or corrected
only through `cancel_sale()` / `save_sale_identity()`, and an expense is free with a notification
instead. What is left is not a gate — it is the **notification's delivery**, and three pieces of
polish the module has been carrying since chunk 3.

## SCOPE — in this order, and keep going

### 6a. The expense notification's DELIVERY half (this is the chunk's substance)

The trigger is built and it queues the right rows (chunk 5a-c, `notify_owner_of_expense()`): the in-app
row lands in the owner's inbox, and a WhatsApp delivery-log row is opened when his profile carries a
number. **Nothing dispatches it.** Read these two facts before designing anything:

- **`send-notification` is deployed and records every attempt** (D-029/D-049) — `queue`, `call`,
  `settle` — and it answers `skipped` naming the missing credential until N-1 resolves. Its own doc
  says plainly: *"There is no automatic dispatch of the Phase 5 alerts (D-046): this function is
  built and reachable, and nothing calls it on a schedule."*
- **The rail's shape is queue → call → settle** and the call cannot be inside a transaction, so the
  honest dispatcher is *outside* the database. Decide where it lives and say why: a `pg_net` trigger
  from the queue row, a scheduled Edge Function, or the app calling it after a write — each has a real
  cost (a credential the project does not have, a schedule nothing runs, or a screen a session can
  bypass). **If the answer is "this waits on N-1's credentials", say so and build the part that does
  not wait**: the delivery-log rows and their `queued` → `sent`/`failed`/`skipped` settle are already
  the seam, and the email leg needs an ADDRESS (`profiles` has a phone and no email) before it can be
  queued honestly.

Do NOT gate anything here, add a request path, or revoke anything: D-085 settled that an expense is
free and this is the control instead.

### 6b. Does a stale pending request expire?

A request whose document moved on between the ask and the answer is **refused, not applied** (chunks
3, 4, 5 and 5d all assert it) and stays `pending`, so the owner's list can hold a question he can
never usefully answer. Decide: an expiry (`expires_at` + a sweep), closing it when its document
changes, or leaving it with the refusal as the answer — and whatever you choose, say it in the
enum's or the table's own comment. **The purchase side already has the machinery for the third case**
(`approval_close_purchase_asks()`, and chunk 5d's inline closure for a cancelled bill): a request
whose subject can no longer be acted on is closed as refused rather than left standing.

### 6c. The approvals queue refreshes only itself (carried from chunk 3)

`ApprovalActions.decide` invalidates the pending list and nothing else, so an open purchase or list
screen can show the pre-decision state until it is re-entered. `ref.invalidate(approvalForTargetProvider)`
and the family providers are the likely fix; a widget test that decides an ask while a detail screen is
mounted is the proof.

### 6d. Then, from Phase 7a and still open

- **The deposit-application sheet** (`context/chat3r-opening-prompt.md` §2). `open_bills` (migrations
  `00040`/`00041`) has **no Dart caller**, and a party's receipts with money still unapplied have no
  reader (their total is already `patient_account().unallocated_deposits`).
- **The customers form's eight granted columns are still not gated** (D-086): a session can set a
  customer's `is_active` (a soft delete) and `opening_balance` (money). `customer_edit` is already the
  action type the chunk that closes it will raise — but that chunk must change the form too, so the
  revoke and its screen ship together.

## WHAT MUST NOT BREAK

- The counter: the sale bill, a payment, a new patient and **an expense** stay free for every role.
- **The owner's own work is never gated** — he writes through the same RPCs, which ask him nothing.
- The committed SQL tests and the stock/ledger triggers: approving runs exactly the write the staff
  used to run, through the same door.
- The truthfulness rule: no screen may promise an approval that does not exist, and a refusal's
  sentence must name what is actually missing. **`document_payload_problem()` is the one shape check
  both the ask and the write use.**
- **Every business table's write grant is a decision, not an oversight.** After chunk 5d the only
  tables a session may still write are `expenses` (by design) and the customers form's eight columns
  (a named gap). Check before you add or remove one.

## RULES

- Write FULL file contents, never truncate. Reproduce a `create or replace` body from the applied
  migration's own text and **diff it** — `.qwen/tmp/pg7a/build_00042.js`, `build_00043.js`,
  `build_00046.js` and `build_00047.js` are the pattern, and `build_00046.js`'s own header records the
  `$`-in-a-replacement-string trap that silently corrupted a body there.
- One mechanism, never a second one for one action.
- Every changed assertion documented **before → after** in the reply **and the commit message**; no
  assertion deleted, skipped or loosened; the test count may not fall.
- **A file that ERRORs prints no SUMMARY line and no FAIL line, so a run that greps for `FAIL` reads
  it as green.** Count the `psql:/repo/supabase/tests/…` header lines and check none says `ABORTED` as
  well as grepping for FAIL — that is how two files were found to have been broken since chunks 3 and
  4, and how `phase4_report_summary` broke again in chunk 5d.
- **Run a new SQL test against hosted, not only locally** (D-082's lesson).
- `dart format lib test` before the gates; `flutter analyze` covers `test/**` too.

## ENVIRONMENT (FIXED)

- Workspace `C:\Projects\PharmaFlow\`; remote `origin` = `https://github.com/jainrohit1312/pharmaflow.git`
  (**`git push` works from here** — the owner's credentials are in place).
- Supabase **hosted only** (ref `yeroxzkpmodbzcvjlqwd`), no Docker for Supabase; migrations by
  `supabase db push --yes`. **47 = 47** as of this handoff (`d2c26e5`).
- The **local SQL harness lives at `.qwen/tmp/pg7a/`** and the container `pharmaflow-pg7a` has been up
  for days — reuse it (memory: *Verify the SQL suite locally*). `run_all.sql` lists `00001`-`00047`;
  `run_all_pre46.sql` is the **baseline arm** at `00045`; `run_tests.sql` lists 23 files. Run order:
  `reset` → `stub` → `run_all` → `seed` → `run_tests`.
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0 — do not touch the pinned ranges.
- Gates: `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` → the
  five `deno check` entry points.
- **Baseline at this handoff: 1061 Flutter tests, 181 Deno tests, all passing, at `d2c26e5`** (pushed).
  The SQL suite is 16 files with a SUMMARY line, 0 FAIL locally on a fresh 47-migration database, and
  hosted holds migrations `00043`-`00047`, each re-verified there with its own test.

## END-OF-SESSION HANDOFF (when you are near the limit)

Gates run and pasted raw, `PROGRESS.md` updated, a chat summary and the next opening prompt written,
`DECISIONS.md` updated if a decision was made, and a numbered list of every file touched. Push before
you write the handoff, so the next session starts from the remote and not from a working tree.

**Phase 6.5c closes when this chunk is done** — say so in `PROGRESS.md` and in the phase table, and
move the current phase pointer to Phase 7's remaining work (the deposit-application sheet first) or to
Phase 6.5b (the receiver app), whichever the owner's sequence says next.
