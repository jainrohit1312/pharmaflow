# Next chat — Phase 6.5c chunk 5d: the sale acts, and the last of the gates

You are continuing work on PharmaFlow. **This is a long session by design**: the window is 1M, so the
work is sized to fill it rather than to stop at every checkpoint.

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md`, `MASTER_PLAN.md`, `DECISIONS.md` — **D-086 is this chunk's predecessor** (the master
   data, the derived action type, and the two files it repaired), **D-085 is the policy this chunk
   executes** (expenses are not gated; `sale_edit`/`sale_cancel` are), and D-083/D-084 are the two
   shapes the module has
2. `context/chat3t-summary.md` — what the last session did, and the six things it left open
3. `supabase/migrations/20260921000046_phase6_5c_approval_master_data.sql` — the most recent chunk,
   and the pattern chunk 5d follows for a document that is REQUESTED rather than staged
4. this file

Output a 5-line understanding check: the chunk you are doing, the previous chunks' deliverables, the
environment, two load-bearing dependency pins, and what you are about to build.

## THE OWNER'S ONE ANSWER — AND WHERE IT IS WRITTEN DOWN

The last session built chunk 5a-c and put **one question** to the owner, because building the gate for
`sale_cancel` means building the act first and the act is not obvious:

**What does cancelling a *posted* sale do to the stock and the money it has already moved?**

This is not a policy question in the abstract; it is forced by what the code does today. A sale posts
its stock and its customer receivable **on insert**, through triggers. Nothing in the app has ever
written `sales.status = 'cancelled'` — the value is only *read* (the filter, the sale return's
refusal, and every outstanding-bill expression excludes it). So a cancel that only flipped the status
would leave the stock out of the shelf, the ledger row standing, and every account and report
excluding the bill: **two internally-consistent views disagreeing about one transaction**, the shape
D-075 and D-081 exist to prevent. The two honest options:

- **(a) A cancel reverses the bill** — the goods go back to their batches, the receivable is credited,
  and the status flips; the owner's approval runs all three, exactly the way a return's approval runs
  its own writes. **Recommended**, because it is the only reading where "cancelled" and the books
  agree, and it reuses the return machinery chunk 4 already has (one dispatch, one executor, the
  payload as the document).
- **(b) A cancel is only for a bill nothing has happened to** — no returns, no allocations, no
  payment — and anything else is refused in words ("correct it with a sale return, which the owner
  also approves"). Cheaper, honest, and almost unreachable: a counter bill is written *paid*.

**His answer is recorded as D-087** (the next free number after D-086), in whatever words he gave it.
**If D-087 does not exist, the answer has not arrived — ask him again before writing 5d, and do not
guess.** Check `DECISIONS.md` for `D-087` first; the last session's report put the question to him and
would have recorded the answer there and in this section.

**For `sale_edit` the same question is smaller**, and there is a scope worth proposing: an edit of the
**non-money identity fields only** — the printed patient name/mobile/address, the prescriber, the
hospital reference — changes nothing about stock, tax or the receivable, which makes it a gate that is
cheap and safe to build. Editing a **line** (quantity, rate, batch) means re-pricing a posted bill and
re-cutting its stock: if he wants that, it is a *return plus a re-bill*, not an edit, and it should be
said back to him plainly. **Propose the narrow edit and ask before building anything wider** — and if
he answers "a correction is a return, not an edit", then `sale_edit` gets **no executor ever** and the
enum's comment says so, exactly the way the three expense types now do.

## SCOPE — in this order, and keep going

### 5d-a. `sale_cancel`, whichever of (a)/(b) he chose, on the rail

- One door — `cancel_sale(jsonb)` — for both roles, deriving nothing a client can choose: the action
  type is `sale_cancel` and the document is the payload (whose shape is his answer).
- **The owner is not gated, and his route is the same RPC** (`get_my_role()` decides, server-side,
  exactly as `save_purchase()` and `save_product()` do).
- **The revoke on `sales` and `sale_items` ships in the SAME migration as the request path** — chunk
  3's rule, and these are the last two tables that still take writes from a session. Check what still
  writes them before revoking: `checkout_sale()` is SECURITY DEFINER and is the only legitimate
  writer, but grep `app/lib` for `.from('sales')` / `.from('sale_items')` to be sure nothing else
  does, and say in the migration comment what you found.
- If he chose **(a)**, approving must run the same writes a *sale return* runs (the stock restore, the
  credit), and it must NOT touch a committed stock or ledger trigger — reuse `document_apply_decision`'s
  shape, or add a sibling applier and extend `approval_execute()`'s dispatch. If he chose **(b)**,
  refusing a bill that has moved is a sentence, and the payload check in
  `document_payload_problem()` is where it belongs — **one shape check for both the ask and the
  write**, the rule chunk 4 established.
- `sales.status = 'cancelled'` must then be **excluded everywhere it is already excluded**, and the
  things that read it today are listed in the last session's summary — re-read them rather than
  assuming.

### 5d-b. `sale_edit`, if he agreed to the narrow edit

- Same rail, same revoke. The payload carries the identity fields it may change and the write is one
  UPDATE that touches no money column; the shape check refuses a payload naming `sub_total`,
  `grand_total`, a line, a batch or a rate, in words that say why ("a posted bill's lines are
  corrected with a sale return, which the owner also approves").
- If he said a correction is a return, build nothing and say so in the enum's comment.

### 5e. If the window still has room (carried over, unfinished)

- The **approvals queue refreshes only itself**: `ApprovalActions.decide` invalidates the pending list
  and nothing else, so an open purchase or list screen can show the pre-decision state until it is
  re-entered. `ref.invalidate(approvalForTargetProvider)` and the family providers are the likely fix;
  a widget test that decides an ask while a detail screen is mounted is the proof.
- A **stale pending request** is refused when decided but never expires (chunk 6's other half).

### 5f. Then chunk 6, and the Phase 7a debt

- **Chunk 6** is the notification polish: the expense notification's *delivery* half (N-1's
  credentials; `send-notification` is deployed and answers `skipped` naming what is missing), and
  whether a stale pending request expires.
- **Still open from Phase 7a, and not this module's**: the **deposit-application sheet**
  (`context/chat3r-opening-prompt.md` §2). `open_bills` (migrations `00040`/`00041`) has no Dart
  caller, and a party's receipts with money still unapplied have no reader.
- **A gap chunk 5a-c named on purpose**: the customers form's eight granted columns are still not
  gated, so a session can set a customer's `is_active` (a soft delete) and `opening_balance` (money).
  `customer_edit` is already the action type the chunk that closes it will raise — but that chunk
  must also change the form, so the revoke and its screen ship together.

## WHAT MUST NOT BREAK

- The counter: the sale bill, a payment and a new patient stay free for **every** role, and
  **expenses** joined that list in D-085.
- **The owner's own work is never gated** — he writes through the same RPCs, which ask him nothing.
- The committed SQL tests and the stock/ledger triggers: approving must run exactly the write the
  staff used to run. Chunk 4's `document_apply_decision` and chunk 5's `master_apply_decision` show
  the pattern that achieves it without touching a trigger.
- The truthfulness rule: no screen may promise an approval that does not exist, and a refusal's
  sentence must name what is actually missing. **`document_payload_problem()` is the one shape check
  both the ask and the write use** — a new document type gets an entry there rather than its own copy.
- **An older deployed client cannot write a purchase, a return, an adjustment, a product, a batch or
  an alias** (D-083/D-084/D-086's last consequence). The owner has said this is fine — the app is not
  live and is still in development — so treat a rebuild as expected, not as a blocker.

## RULES

- Write FULL file contents, never truncate. Reproduce a `create or replace` body from the applied
  migration's own text and **diff it** — `.qwen/tmp/pg7a/build_00042.js`, `build_00043.js` and
  `build_00046.js` are the pattern. **Watch the `$` in a JS replacement string**: `build_00046.js`
  found that `String.replace` reads `$$` and `$'` inside the replacement as patterns and silently
  corrupts SQL — use a replacer function.
- One mechanism, never a second one for one action. `approval_has_executor()`, `request_approval()`,
  `approval_execute()` and each executor move in step, in one migration.
- Every changed assertion documented **before → after** in the reply **and the commit message**; no
  assertion deleted, skipped or loosened; the test count may not fall.
- **A file that ERRORs prints no SUMMARY line and no FAIL line, so a run that greps for `FAIL` reads
  it as green.** Count the `psql:/repo/supabase/tests/…` header lines and check none says `ABORTED` as
  well as grepping for FAIL — that is how `phase4_report_summary` and `phase7a_sale_types` were found
  to have been broken since chunks 3 and 4.
- **Run a new SQL test against hosted, not only locally** (D-082's lesson).
- `dart format lib test` before the gates; `flutter analyze` covers `test/**` too.

## ENVIRONMENT (FIXED)

- Workspace `C:\Projects\PharmaFlow\`; remote `origin` = `https://github.com/jainrohit1312/pharmaflow.git`
  (**`git push` works from here** — the owner's credentials are in place).
- Supabase **hosted only** (ref `yeroxzkpmodbzcvjlqwd`), no Docker for Supabase; migrations by
  `supabase db push --yes`. **46 = 46** as of this handoff (`fb1998c`).
- The **local SQL harness lives at `.qwen/tmp/pg7a/`** and the container `pharmaflow-pg7a` has been up
  for days — reuse it (memory: *Verify the SQL suite locally*). `run_all.sql` lists `00001`-`00046`;
  `run_all_pre46.sql` is the **baseline arm** at `00045`; `run_tests.sql` lists 22 files. Run order:
  `reset` → `stub` → `run_all` → `seed` → `run_tests`.
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0 — do not touch the pinned ranges.
- Gates: `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` → the
  five `deno check` entry points.
- **Baseline at this handoff: 1049 Flutter tests, 181 Deno tests, all passing, at `fb1998c`** (pushed).
  The SQL suite is 15 files with a SUMMARY line, 0 FAIL locally on a fresh 46-migration database, and
  hosted holds migrations `00043`-`00046`, each re-verified there with its own test.

## END-OF-SESSION HANDOFF (when you are near the limit)

Gates run and pasted raw, `PROGRESS.md` updated, a chat summary and the next opening prompt written,
`DECISIONS.md` updated if a decision was made (**his answer to the cancel question is D-087**), and a
numbered list of every file touched. Push before you write the handoff, so the next session starts
from the remote and not from a working tree.
