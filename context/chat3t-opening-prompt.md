# Next chat — Phase 6.5c chunk 5: the master data, the sale acts, and the last of the gates

You are continuing work on PharmaFlow. **This is a long session by design**: the window is 1M, so the
work is sized to fill it rather than to stop at every checkpoint.

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md`, `MASTER_PLAN.md`, `DECISIONS.md` — **D-085 puts this chunk's policy in writing**,
   and D-083/D-084 are the shape the two previous chunks established; D-071 is the discount's
2. `context/phase6_5c-approval-rbac.md` — the policy and the six-chunk plan; **this is the brief**
3. `context/chat3s-summary.md` — what the last session did, and the five things it left open
4. `supabase/migrations/20260921000045_phase6_5c_approval_returns.sql` — the most recent chunk, and
   the pattern chunk 5 follows for anything requested rather than staged
5. this file

Output a 5-line understanding check: the chunk you are doing, the previous chunks' deliverables, the
environment, two load-bearing dependency pins, and what you are about to build.

## THE OWNER'S TWO ANSWERS — SETTLED 2026-09-21, DO NOT RE-ASK

Both questions the last session left open are answered, and the answers are recorded as **D-085**:

1. **Expenses are NOT gated.** *"expenses donot need approvals only notification, email, whatsapp
   notification"*. Recording an expense stays **free for every role**; `expenses` keeps its write
   grants and gets **no request path and no revoke**. The owner is **told** instead, through the rail
   Phase 5 built (`queue_notification()`, migration `00028`) and the already-deployed
   `send-notification` (which answers `skipped` naming the missing credential until N-1 resolves).
   **`expense_create` / `expense_edit` / `expense_delete` are RETIRED** — they stay in the enum (a
   value cannot be dropped) but will never have an executor, and the `comment on type
   public.approval_action_type` has to say so, or the enum reads as "a chunk is coming" for three
   action types that will never have one.
2. **`sale_edit` and `sale_cancel` ARE gated.** *"sale edit/ sale cancle need approval from owner"*.

## ONE QUESTION IS STILL OPEN, AND IT BLOCKS ONLY 5d

`5a`, `5b` and `5c` below **do not wait for it** — build them and ask it in the same reply.

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

**For `sale_edit` the same question is smaller**, and there is a scope worth proposing: an edit of the
**non-money identity fields only** — the printed patient name/mobile/address, the prescriber, the
hospital reference — changes nothing about stock, tax or the receivable, which makes it a gate that is
cheap and safe to build. Editing a **line** (quantity, rate, batch) means re-pricing a posted bill and
re-cutting its stock: if he wants that, it is a *return plus a re-bill*, not an edit, and it should be
said back to him plainly. **Propose the narrow edit and ask before building anything wider.**

## SCOPE — in this order, and keep going

### 5a. The product master — `product_create` / `product_edit` / `product_delete`

- Write paths: `products_repository.dart` (the form's insert/update **and a real `delete`**),
  `products_repository.dart` **+548** (the batch write), and the alias path (`addAlias`, whose
  uniqueness story is migration 00030 / N-5).
- **The revokes ship WITH the request flow, never before it.** `products`, `product_batches` and
  `product_aliases` lose their write grants in the same migration as their request path, or staff
  cannot add a product at all. This is the chunk that **closes the `product_batches` hole D-083
  recorded**: today a session can still set a batch's `qty` by hand, which is a stock adjustment in
  disguise and is exactly what `stock_adjustment` was gated for.
- **Choose between the two shapes this module now has, and say which and why:**
  - a **staged row** (what a purchase does — a status to wait in, the owner reads the document
    itself, a pre-image restores a refusal), or
  - **the request IS the document** (what a return does — nothing exists until he approves).
  A **brand-new product** is closer to a return: nothing can reference a product that does not exist,
  so nothing is half-written while it waits, and the owner's own words are *"Adding a new product needs
  approval"*. An **edit** of a product that already has history is closer to a purchase. **Do not
  invent a third shape**; if the two cases genuinely differ, use both — and say in the migration why.
- A **soft delete** is already the policy (D-083's answer): the row stays, `is_active` goes false, and
  the products list keeps showing it to whoever needs to see what happened.

### 5b. `customer_edit`, with `update_patient` folded into it

- `update_patient()` (migration `00038`, **D-076**) refuses anyone but the owner or a pharmacist, and
  `customers` has table-level UPDATE revoked with exactly eight columns granted back (the customers
  form's own).
- **The owner's policy supersedes the pharmacist half of that rule** — a pharmacist is gated like a
  cashier now — so the action type must **absorb** it rather than sit beside it. Say in the migration
  comment which rule won and why.
- **Re-express the assertions the change moves**, do not delete them: grep `update_patient` under
  `supabase/tests/` (the Phase 7a suite covers it) and put the before → after list in the commit
  message.
- The customers form's eight granted columns are a **different** thing from the patient master, and
  the brief says the customer form is not this phase's to change — decide whether a customer edit
  through *that* form is gated at all, and say so either way.

### 5c. The expense notification (chunk 6's first half, and small)

- A recorded expense **tells the owner** — in-app through `queue_notification()`'s `notify_user_id`
  (the owner's profile row in that pharmacy) plus the delivery log for the channels that are not
  configured yet (email/WhatsApp wait on N-1's credentials; `send-notification` is deployed and says
  `skipped` naming what is missing).
- Decide and state: a **trigger on `expenses`** (so every write path tells him, including a future
  one) or a **call in the app's write path** (so the app controls the wording). A trigger is the
  honest choice if the rule is "every expense tells him" — a screen can be bypassed by a session, and
  the *notification* is the control he asked for.
- **No approval, no revoke, no executor.** Do not add an `expenses` request path.

### 5d. The sale acts — only after his answer

- `sale_cancel`: whichever of (a)/(b) he chooses, built on the rail — a request for staff, the write
  performed by the executor, the revoke on `sales`/`sale_items` **in the same migration as the request
  path** (chunk 3's rule, and it is the last pair of tables that still take writes directly).
- `sale_edit`: the narrow identity edit if he agrees, or nothing at all if he says a correction is a
  return — in which case say so in the enum's comment, the way expenses now do.

### 5e. If the window still has room

- The **approvals queue refreshes only itself** (`ApprovalActions.decide` invalidates the pending list
  and nothing else), so an open purchase or list screen can show the pre-decision state until it is
  re-entered. Worth closing while you are in this module.
- A **stale pending request** is refused when decided but never expires (chunk 6's other half).

## WHAT MUST NOT BREAK

- The counter: the sale bill, a payment and a new patient stay free for **every** role.
  **Expenses join that list as of D-085** — free, with a notification.
- **The owner's own work is never gated** — he writes through the same RPCs, which ask him nothing.
- The committed SQL tests and the stock/ledger triggers: approving must run exactly the write the
  staff used to run. Chunk 4 shows the pattern that achieves it without touching a trigger.
- The truthfulness rule: no screen may promise an approval that does not exist, and a refusal's
  sentence must name what is actually missing. **`document_payload_problem()` is the one shape check
  both the ask and the write use** — a new document type gets an entry there rather than its own copy.
- **An older deployed client cannot write purchases or returns** (D-083's last consequence). The owner
  has said this is fine — the app is not live and is still in development — so treat a rebuild as
  expected, not as a blocker.

## RULES

- Write FULL file contents, never truncate. Reproduce a `create or replace` body from the applied
  migration's own text and **diff it** — `.qwen/tmp/pg7a/build_00042.js` and `build_00043.js` are the
  pattern; `00044`/`00045` show the same discipline for a body that travels again.
- One mechanism, never a second one for one action. `approval_has_executor()`, `request_approval()`,
  `approval_execute()` and each executor move in step, in one migration.
- Every changed assertion documented **before → after** in the reply **and the commit message**; no
  assertion deleted, skipped or loosened; the test count may not fall. `00044`/`00045` show what
  re-expressing one looks like when its subject stops being true.
- **Run a new SQL test against hosted, not only locally** (D-082's lesson — the hosted run found the
  `open_bills` ordering defect the local suite passed by luck).
- `dart format lib test` before the gates; `flutter analyze` covers `test/**` too.

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
- **Baseline at this handoff: 1038 Flutter tests, 181 Deno tests, all passing, at `d746794`** (pushed).
  The SQL suite is 21 files green locally; hosted holds migrations `00043`, `00044` and `00045`, each
  re-verified there with its own test.

## ALSO OPEN, FROM PHASE 7a (not this module's — do not start it mid-chunk)

`context/chat3r-opening-prompt.md` §2: **the deposit-application sheet.** `open_bills` (migrations
`00040`/`00041`) has **no Dart caller**, and a party's receipts with money still unapplied have no
reader (their total is already `patient_account().unallocated_deposits`). Phase 7a's C3/4b is
otherwise complete and its durable layer is on hosted.

## END-OF-SESSION HANDOFF (when you are near the limit)

Gates run and pasted raw, `PROGRESS.md` updated, a chat summary and the next opening prompt written,
`DECISIONS.md` updated if a decision was made, and a numbered list of every file touched. Push before
you write the handoff, so the next session starts from the remote and not from a working tree.
