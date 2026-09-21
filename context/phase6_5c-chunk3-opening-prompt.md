# Next chat — Phase 6.5c chunks 3 and 4: purchases, then returns and adjustments

You are continuing work on PharmaFlow. **This is a long session by design**: the window is 1M, so the
work is sized to fill it rather than to stop at every checkpoint.

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md`, `MASTER_PLAN.md`, `DECISIONS.md`, `HANDOFF_PROTOCOL.md`
2. `context/phase6_5c-approval-rbac.md` — **the policy and the six-chunk plan; this is the brief**
3. `context/phase7a-discount-and-compact-lines.md` — the discount work chunk 1 wired
4. `supabase/migrations/20260921000043_phase6_5c_approval_rbac.sql` — the mechanism's own comment
5. this file

Output a 5-line understanding check: the chunks you are doing, the previous chunks' deliverables, the
environment, two load-bearing dependency pins, and what you are about to build.

## HOW TO WORK THIS SESSION (the owner's own instruction, 2026-09-21)

> "jaise window kafi badi hoti hai uske hisab se hi aage ke chunks bnao, kyoki baar baar development
> ruk jata hai manually approve krna padta hai, jha par tumko widget check krne chayea karo, jha par
> sql run krni hai kro, jha par edge function deploy krne hai karo, jha par git commit and push krna
> hai karo, but context 1 million se thoda kaam bnana"

So:

- **Do not stop for permission on the mechanical steps.** Run the SQL harness, run the Flutter gates,
  run `deno check`/`deno test`, **commit AND `git push` when a chunk's gates are green**, and drive the
  widget tests yourself. He has authorised this standing: publishing work is expected, not asked about.
- **Do stop and ask** for anything that is *his* decision rather than a mechanical step: a change to
  the policy (who is gated, what is free), spending on a hosted resource, a destructive migration, or
  a conflict between the brief and the code.
- **Size the work to fill the window, and hand off just under ~900k tokens.** Bigger chunks, fewer
  sessions. Do not hand off after one chunk if the gates are green and the next is ready — keep going
  through the list below, and write the end-of-session handoff when you are near the limit.
- Keep the tree green at every commit: a chunk that compiles, passes its gates and is pushed is a
  checkpoint worth having even if the next chunk is unfinished.

## ENVIRONMENT (FIXED)

- Workspace `C:\Projects\PharmaFlow\`; remote `origin` = `https://github.com/jainrohit1312/pharmaflow.git`
  (**`git push` works from here** — the owner's credentials are in place).
- Supabase **hosted only** (ref `yeroxzkpmodbzcvjlqwd`), no Docker for Supabase; migrations by
  `supabase db push --yes` when a chunk adds one.
- The **local SQL harness lives at `.qwen/tmp/pg7a/`** and the container `pharmaflow-pg7a` has been up
  for days — reuse it (memory: *Verify the SQL suite locally*). `run_all.sql` lists `00001`-`00043`;
  `run_tests.sql` lists 19 files. Run order: `reset` → `stub` → `run_all` → `seed` → `run_tests`.
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0 — do not touch the pinned ranges.
- Gates: `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` → the
  five `deno check` entry points.
- **Baseline at this handoff: 1009 Flutter tests, 181 Deno tests, all passing, at `7f65358`** (pushed).
  The SQL suite is 19 files green locally; hosted holds migration `00043`.

## WHERE THE MODULE STANDS

**The owner's policy (settled 2026-09-21):** everything but the sale bill needs his approval. Gated:
purchases (create/edit/cancel), purchase returns, sale returns, sale edit/cancel, stock adjustments,
product create/edit/delete, customer edits, expenses, and a discount above 10% of a bill. **Free for
every role:** the sale bill, taking a payment, registering a new patient. **Adding a product needs
approval.** A purchase is a **PENDING GRN** (nothing posts until he approves), deletion is a **soft
delete**, and **everybody but the owner is gated — the pharmacist too.** The owner is exempt from all
of it, the discount cap included.

| Chunk | What | Commit | State |
|---|---|---|---|
| 1 | the mechanism (`approval_requests`, the 16-action enum, `request_approval`/`decide_approval`, `sales.discount_above_limit_request_id`) + the discount wired to it | `6bea1b2` | **migration `00043`, applied to hosted** |
| 2a | the owner's queue: model, repository, providers, `/settings/approvals` | `60e0a61` | pushed, no SQL |
| 2b | the counter's ask flow: "Ask the owner", the waiting state, `PosCart.discountApprovalId`, `discount_approval_id` on the wire | `1af220f` | pushed, no SQL |
| 2c | the widget test for that flow, which **found and fixed a real bug** | `6de6e85` | pushed, no SQL |

## SCOPE — in this order, and keep going

### 3a. Finish what 2b left (small, and it is a real defect — do it first)

1. **Carry `discountApprovalId` through every copy that does not move the bill's figures:**
   `withCustomer`, `withPatientDetails`, `withAdmission`, `withDoctor`, `withHospitalReference`,
   `withTransfer`, `withPaymentMode`, `withPlaceOfSupply`. It must still be **dropped** by `withLines`,
   `withBillDiscount` and `withSaleType` — those change the figures the owner approved. Right now a
   cashier can ask for an approval, get it, then tap **Card** or fill the place of supply and silently
   lose it. Extend the cart's setter test so *carrying* is pinned as distinct from *moving*.
2. **Drive the write half of the discount loop.** `pos_screen_test.dart`'s
   *'an above-cap discount offers the owner, and waits for him'* stops at "Approved - you can bill
   this."; the assertions that the sale is written and its payload carries the approval id are missing,
   with the reason recorded in the file. Find out why the sale does not reach the fake repository
   (a SnackBar over the till was ruled out once), and assert both.

### 3b. Chunk 3 — purchases (the largest chunk)

- **`pending_approval` on `purchase_status`** (`00002:21` is `draft, ordered, received, cancelled`).
  A GRN staff submit is written `pending_approval`, stock and the supplier ledger **do not post**, and
  approving runs the same triggers that run today.
- **The request path** in `purchases_repository.dart` — the client writes `purchases` and
  `purchase_items` **straight to the tables** (`:498`, `:738`, `:767`), which is why a screen-level gate
  would be a suggestion.
- **The executor:** `approval_has_executor()` and `decide_approval()`'s dispatch (`00043` sections 4 and
  6) are where a new action type becomes real. Approving must perform the write server-side as the owner.
- **The revokes ship WITH the request flow, never before it** — protected tables lose their
  INSERT/UPDATE/DELETE grant to `authenticated` in the chunk that gates them, or staff cannot work at
  all. `purchase_items` is deleted and re-inserted on an edit (`:738`), so both sides matter.
- **Tests:** a SQL test that nothing posts until approval and that approving posts exactly what a
  direct write used to; plus the client's.

### 4. Chunk 4 — returns and stock adjustments

`purchase_return`, `sale_return`, `stock_adjustment` on the same rail
(`purchase_returns_repository.dart:336,354`, `sale_returns_repository.dart:291,308`,
`inventory_repository.dart:291`). Each needs its `alter type … add value`, its `approval_has_executor()`
entry, its executor, its revokes and its tests. **If the window still has room, start chunk 5** (master
data) — the same pattern, and it is the one that folds in today's `update_patient` role gate.

## WHAT MUST NOT BREAK

- The counter: the sale bill, a payment and a new patient stay free for **every** role.
- **The owner's own work is never gated** — he writes directly, as he does today.
- The stock and ledger triggers, and every committed SQL test: approving must run exactly the write the
  staff used to run.
- The truthfulness rule: a screen must not promise an approval that does not exist, and a refusal's
  sentence must name what is actually missing.

## RULES

- Write FULL file contents, never truncate. Reproduce a `create or replace` body from the applied
  migration's own text and **diff it** — `.qwen/tmp/pg7a/build_00042.js` and `build_00043.js` are the
  pattern.
- One mechanism, never a second one for one action.
- Every changed assertion documented **before → after** in the reply and the commit message; no
  assertion deleted, skipped or loosened.
- Keep the action-type enum, `approval_has_executor()` and the dispatch in step with each other.

## END-OF-SESSION HANDOFF (when you are near the limit)

Gates run and pasted raw, `PROGRESS.md` updated, a chat summary and the next opening prompt written,
`DECISIONS.md` updated if a decision was made, and a numbered list of every file touched. Push before
you write the handoff, so the next session starts from the remote and not from a working tree.
