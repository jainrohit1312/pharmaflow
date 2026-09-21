# Next chat — Phase 6.5c chunk 3: purchases, and the two things 2b left behind

You are continuing work on PharmaFlow.

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md`, `MASTER_PLAN.md`, `DECISIONS.md`, `HANDOFF_PROTOCOL.md`
2. `context/phase6_5c-approval-rbac.md` — **the policy and the six-chunk plan; this is the brief**
3. `context/phase7a-discount-and-compact-lines.md` — the discount work chunk 1 wired
4. this file

Output a 5-line understanding check: the chunk you are doing, the previous chunks' deliverables,
the environment, two load-bearing dependency pins, and what you are about to build.

## ENVIRONMENT (FIXED)

- Workspace `C:\Projects\PharmaFlow\`; Supabase **hosted only** (ref `yeroxzkpmodbzcvjlqwd`), no Docker
  for Supabase, migrations by `supabase db push --yes` (ask the owner first — he authorises per push).
- The **local SQL harness is still at `.qwen/tmp/pg7a/`** with the container `pharmaflow-pg7a` — reuse
  it (memory: *Verify the SQL suite locally*). `run_all.sql` lists `00001`-`00043`, `run_tests.sql` 19 files.
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0. Do not modify the pinned ranges.
- Gates: `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` → the
  five `deno check` entry points. **Baseline at this handoff: 1009 Flutter, 181 Deno, all passing, at
  `6de6e85`.** Counts must not fall; assertions are re-expressed, never weakened.

## WHERE THE APPROVAL MODULE STANDS

**The owner's policy (settled 2026-09-21):** everything but the sale bill needs his approval. Gated:
purchases (create/edit/cancel), purchase returns, sale returns, sale edit/cancel, stock adjustments,
product create/edit/delete, customer edits, expenses, and a discount above 10% of a bill. **Free for
every role:** the sale bill, taking a payment, registering a new patient. **Adding a product needs
approval.** A purchase is a **PENDING GRN** (nothing posts until he approves), deletion is a **soft
delete**, and **everybody but the owner is gated — the pharmacist too.** The owner is exempt from all
of it, the discount cap included.

Landed so far, in order:

| Chunk | What | Commit | State |
|---|---|---|---|
| 1 | the mechanism (`approval_requests`, its 16-action enum, `request_approval`/`decide_approval`, `sales.discount_above_limit_request_id`) + the discount wired to it | `6bea1b2` | **pushed to hosted and verified there** (migration `00043`) |
| 2a | the owner's queue: model, repository, providers, `/settings/approvals` screen | `60e0a61` | local, not pushed (no SQL) |
| 2b | the counter's ask flow: the "Ask the owner" button, the waiting state, `PosCart.discountApprovalId`, `discount_approval_id` on the wire | `1af220f` | local, not pushed |
| 2c | the widget test for that flow — which **found and fixed a real bug** | `6de6e85` | local, not pushed |

**The bug it found, and the class of it:** the approval was dropped by *every* cart copy, following
the idempotency key's rule — but the key identifies a *payload* and the approval is matched against
the bill's *figures*, so choosing the patient or typing the tender silently threw it away and no
approved bill could ever be written. Fixed for `withPatient` and `withTendered` only.

## SCOPE — two carried-over items, then chunk 3

### 3a. Finish what 2b left (do this FIRST — it is small and it is a real defect)

1. **Carry `discountApprovalId` through every copy that does not move the bill's figures:**
   `withCustomer`, `withPatientDetails`, `withAdmission`, `withDoctor`, `withHospitalReference`,
   `withTransfer`, `withPaymentMode`, `withPlaceOfSupply`. It must still be dropped by `withLines`,
   `withBillDiscount` and `withSaleType` — those change the figures the owner approved. Add a case to
   the cart's setter test that asserts *carrying* is not the same as *moving*, so the distinction is
   pinned rather than described.
2. **Drive the write half of the discount loop.** `pos_screen_test.dart`'s
   *'an above-cap discount offers the owner, and waits for him'* stops at "Approved - you can bill
   this."; the assertions that the sale is written and its payload carries the approval id are
   **not there yet**, with the reason recorded in the file. Find out why the sale does not reach the
   fake repository through that harness (a SnackBar over the till was ruled out once) and assert both.

### 3b. Chunk 3 — purchases

- **`pending_approval` on `purchase_status`** (`00002:21` has `draft, ordered, received, cancelled`).
  A GRN staff submit is written `pending_approval`, stock and the supplier ledger **do not post**, and
  approving runs the same triggers that run today.
- **The request path in `purchases_repository.dart`** — the client currently writes `purchases` and
  `purchase_items` **straight to the tables** (`:498`, `:738`, `:767`), which is why a screen-level
  gate would be a suggestion.
- **The executor:** `approval_has_executor()` + `decide_approval()`'s dispatch are where a new action
  type becomes real (`00043`, section 4 and 6). Approving must perform the write server-side as the
  owner.
- **The revokes**, and they ship **WITH** the request flow, never before it: protected tables lose
  their INSERT/UPDATE/DELETE grant to `authenticated` in the chunk that gates them, or staff cannot
  work at all. `purchase_items` is deleted and re-inserted on an edit (`:738`), so both sides matter.
- **Tests:** a SQL test for the pending GRN (nothing posts until approved; approving posts exactly
  what a direct write used to) and the client's own.

## WHAT MUST NOT BREAK

- The counter: the sale bill, a payment and a new patient stay free for **every** role.
- **The owner's own work is never gated** — he writes directly, as he does today.
- The stock and ledger triggers, and every committed SQL test: approving must run exactly the write
  the staff used to run.
- The truthfulness rule: a screen must not promise an approval that does not exist. The discount's
  sentences now say what is true ("the counter cannot request one yet" became "ask for it" when 2b
  landed), and the same care is owed to a purchase's.

## RULES

- Write FULL file contents, never truncate. Reproduce a `create or replace` body from the applied
  migration's own text and **diff it** — `.qwen/tmp/pg7a/build_00042.js`/`build_00043.js` are the
  pattern, and they caught nothing because they were used.
- One mechanism, never a second one for one action. If a rule needs a decision the brief does not
  contain, put it to the owner instead of guessing.
- Every changed assertion documented **before → after** in the reply and the commit message; no
  assertion deleted, skipped or loosened.

## END-OF-CHAT HANDOFF

Gates run and pasted raw, `PROGRESS.md` updated, a chat summary and the next opening prompt written,
`DECISIONS.md` updated if a decision was made, and a numbered list of every file touched. Do not start
chunk 4.
