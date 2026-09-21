# Next chat — Phase 6.5c chunk 5: the master data, and the last of the gates

You are continuing work on PharmaFlow. **This is a long session by design**: the window is 1M, so the
work is sized to fill it rather than to stop at every checkpoint.

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md`, `MASTER_PLAN.md`, `DECISIONS.md` (**D-083** and **D-084** are this module's own
   contract; D-071 is the discount's), `HANDOFF_PROTOCOL.md`
2. `context/phase6_5c-approval-rbac.md` — **the policy and the six-chunk plan; this is the brief**
3. `context/chat3s-summary.md` — what the last session did, and the five things it left open
4. `supabase/migrations/20260921000045_phase6_5c_approval_returns.sql` — the most recent chunk, and
   the pattern chunk 5 follows
5. this file

Output a 5-line understanding check: the chunk you are doing, the previous chunks' deliverables, the
environment, two load-bearing dependency pins, and what you are about to build.

## ASK THE OWNER FIRST — TWICE (chunk 5 cannot be written without these)

The brief's chunk 5 is the master data, and it carries two questions the brief itself recorded and
nobody has answered. **Ask them before writing the migration**, because both change what is built:

1. **Expenses.** The brief's table gates `expense_create` / `expense_edit` / `expense_delete`, and
   the owner never named expenses in his own sentence ("I need owner approval on purchase, sale
   return, purchase return, any modification and deletion from staff"). He bears the expenses
   himself, which is an argument for gating them; the brief says *"Confirm or drop this row."*
2. **`sale_edit` / `sale_cancel`.** He said "any modification and deletion". The app has **no
   sale-edit screen**: a sale is corrected by a sale *return*, and cancelling one sets
   `SaleStatus.cancelled`. So: does "modification of a sale" mean a return plus a cancel (and the
   two action types exist for the record), or does he want a real edit flow built?

Everything else in chunk 5 is settled by D-083/D-084 and needs no answer: **everybody but the owner
is gated, the owner is exempt, and deletion is a soft delete.**

## SCOPE — chunk 5, in this order

### 5a. The product master

- **`product_create` / `product_edit` / `product_delete`.** The write paths are
  `products_repository.dart` (the form's insert/update and a real `delete`), `products_repository.dart`
  **+548** (the batch write — `product_batches` INSERT/UPDATE/DELETE, which chunk 3 deliberately left
  granted and named as chunk 5's to close), and the alias path (`addAlias`, which has its own
  uniqueness story — migration 00030, N-5).
- **The revokes ship WITH the request flow, never before it.** `products`, `product_batches` and
  `product_aliases` lose their write grants in the same migration as their request path, or staff
  cannot add a product at all. This is the chunk that **closes the `product_batches` hole D-083
  recorded** — a session can still move a batch's `qty` by hand today, which is a stock adjustment in
  disguise.
- **A product document has a life, like a purchase's**, so decide deliberately between the two
  patterns this module now has: **staged as a row** (what a purchase does: a status to wait in, an
  owner who reads the document itself, a pre-image to restore on refusal) or **the request IS the
  document** (what a return does: nothing exists until he approves). A *new* product is closer to a
  return; an *edit* of one with history is closer to a purchase. Do not invent a third shape.
- **The brand-new-product case is the one the owner named himself**: "Adding a new product needs
  approval." A product that does not exist yet cannot be referenced by anything, so nothing is
  half-written if it waits in a payload.

### 5b. `customer_edit`, which folds in today's role gate

- `update_patient()` (migration `00038`, D-076) refuses anyone but the owner or a pharmacist, and
  `customers` has table-level UPDATE revoked with exactly eight columns granted back. **The owner's
  policy supersedes the pharmacist half of that rule** — a pharmacist is gated like a cashier now —
  so the action type has to absorb it rather than sit beside it. Say in the migration comment which
  rule won and why, and re-express the `phase7a_sale_types.sql` assertions the change moves (they
  exist: grep `update_patient` under `supabase/tests/`).
- The customers form's eight granted columns are a *different* thing from the patient master, and
  the brief says the customer form is not this phase's to change. Decide whether a customer edit
  through that form is gated at all, and say so.

### 5c. The three expense rows, if he keeps them

- `expenses_repository.dart:38` is the write. The same pattern: a request path, an executor, the
  revokes, and a test that nothing posts until he approves.

### 5d. Chunk 6, if the window still has room

- **Notify the owner when something is waiting** on the existing `queue_notification()` rail
  (migration `20260919000028`), and decide whether a **stale pending request expires** (the module
  already refuses to apply one; today it simply stays pending until somebody answers it).
- Worth doing while you are there, from `context/chat3s-summary.md` §4: the approvals queue
  invalidates the pending list only, so an open purchase/list screen can show the pre-decision state
  until it is re-entered.

## WHAT MUST NOT BREAK

- The counter: the sale bill, a payment and a new patient stay free for **every** role.
- **The owner's own work is never gated** — he writes through the same RPCs, which ask him nothing.
- The committed SQL tests and the stock/ledger triggers: approving must run exactly the write the
  staff used to run. Chunk 4 shows the pattern that achieves it without touching a trigger.
- The truthfulness rule: no screen may promise an approval that does not exist, and a refusal's
  sentence must name what is actually missing. **`document_payload_problem()` is the shape check both
  the ask and the write use** — a new document type gets an entry there rather than its own copy.
- **An older deployed client is already broken for purchases and returns** (D-083's last
  consequence). Do not make that worse without saying so.

## RULES

- Write FULL file contents, never truncate. Reproduce a `create or replace` body from the applied
  migration's own text and **diff it** — `.qwen/tmp/pg7a/build_00042.js` and `build_00043.js` are the
  pattern.
- One mechanism, never a second one for one action. `approval_has_executor()`, `request_approval()`,
  `approval_execute()` and each executor move in step, in one migration.
- Every changed assertion documented **before → after** in the reply and the commit message; no
  assertion deleted, skipped or loosened. Migrations `00044`/`00045` show what re-expressing one
  looks like when its subject stops being true.
- **Run a new SQL test against hosted, not only locally** (D-082's lesson — the hosted run found the
  `open_bills` ordering defect the local suite passed by luck).

## ENVIRONMENT (FIXED)

- Workspace `C:\Projects\PharmaFlow\`; remote `origin` = `https://github.com/jainrohit1312/pharmaflow.git`
  (**`git push` works from here** — the owner's credentials are in place).
- Supabase **hosted only** (ref `yeroxzkpmodbzcvjlqwd`), no Docker for Supabase; migrations by
  `supabase db push --yes`. **45 = 45** as of this handoff.
- The **local SQL harness lives at `.qwen/tmp/pg7a/`** and the container `pharmaflow-pg7a` has been up
  for days — reuse it (memory: *Verify the SQL suite locally*). `run_all.sql` lists `00001`-`00045`;
  `run_tests.sql` lists 21 files. Run order: `reset` → `stub` → `run_all` → `seed` → `run_tests`.
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0 — do not touch the pinned ranges.
- Gates: `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` → the
  five `deno check` entry points.
- **Baseline at this handoff: 1038 Flutter tests, 181 Deno tests, all passing, at `3668b72`** (pushed).
  The SQL suite is 21 files green locally; hosted holds migrations `00043`, `00044` and `00045`, each
  with its own test re-run there.

## ANOTHER OPEN ITEM, FROM PHASE 7a (not this module's, but it is real work)

`context/chat3r-opening-prompt.md` §2: **the deposit-application sheet** — `open_bills` (migration
`00040`/`00041`) has **no Dart caller**, and a party's receipts with money still unapplied have no
reader (their total is already `patient_account().unallocated_deposits`). Phase 7a's C3/4b is
otherwise complete. Mention it in the handoff if it is still unbuilt; do not start it in the middle
of 6.5c.

## END-OF-SESSION HANDOFF (when you are near the limit)

Gates run and pasted raw, `PROGRESS.md` updated, a chat summary and the next opening prompt written,
`DECISIONS.md` updated if a decision was made, and a numbered list of every file touched. Push before
you write the handoff, so the next session starts from the remote and not from a working tree.
