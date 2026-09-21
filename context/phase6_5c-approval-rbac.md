# Phase 6.5c — the approval RBAC (owner policy settled 2026-09-21, not started)

**Status:** the owner's policy is **settled** (2026-09-21) and the design below is settled with it.
**Nothing is built**: no migration, no table, no Dart file. This file is the brief for the work, and
chunk 1 is the next thing to write.

## The owner's policy, in his words

> "I need owner approval on purchase, sale return, purchase return, any modification and deletion
> from staff. **Only sale bill is allowed without approval**, rest all functionality is allowed only
> on approval from owner."

Asked the four questions the plan left open (`MASTER_PLAN.md` Phase 6.5: *"The exact list of action
types is still to come from the owner"*), he answered:

| Question | Owner's answer |
|---|---|
| How is a purchase gated? | **Pending GRN** — the GRN is saved as `pending_approval` and **nothing posts** (no batch stock, no supplier ledger) until he approves. Approving runs the same triggers that run today. |
| Who counts as "staff"? | **Everybody except the owner.** Pharmacist, cashier and viewer all need approval; **only the owner is free**. (This *supersedes* the email-00038 rule that trusts a pharmacist for `update_patient` — that gate becomes one action type among many.) |
| What does deletion mean? | **Soft delete.** The row stays; its status becomes cancelled; who asked and who approved stays on the record. |
| What stays free for every user? | **The sale bill, taking a payment / collection, and registering a new patient.** **Adding a new product needs approval.** |

## What is gated, and what is not

**Free for every authorised user** — the counter must keep working:
`checkout_sale` (the bill), `collect_payment` / `record_payment` / `allocate_payment`,
`save_patient` (registering a patient), `save_admission`, and every read.

**Gated — staff may only *ask*:**

| Action type | The write it protects |
|---|---|
| `purchase` | creating a GRN (`purchases` + `purchase_items`) |
| `purchase_edit` | changing an editable GRN |
| `purchase_delete` | cancelling a GRN |
| `purchase_return` | a purchase return |
| `sale_return` | a sale return |
| `sale_edit` / `sale_cancel` | changing or cancelling a posted sale |
| `stock_adjustment` | an inventory adjustment |
| `product_create` / `product_edit` / `product_delete` | the product master (`products`, `product_batches`) |
| `customer_edit` | a customer master edit (absorbing today's `update_patient` role gate) |
| `expense_create` / `expense_edit` / `expense_delete` | expenses — **ANSWERED 2026-09-21: NOT gated (D-085). The owner wants a *notification* instead.** The three action types stay declared in the enum and will never get an executor. |
| `discount_above_limit` | D-071's above-10% discount, which is the reason Phase 7a is blocked |

Adding an action type later is `alter type … add value`, so this list is not a one-way door.

## Why this is not just a screen

**Purchases and returns are not RPCs.** The client writes them **straight to the tables** over
PostgREST — `purchases_repository.dart:498,738,767` (insert/update, and lines deleted and re-inserted
on edit), `purchase_returns_repository.dart:336,354`, `sale_returns_repository.dart:291,308`,
`inventory_repository.dart:291`, `products_repository.dart:666` (a real `delete`),
`expenses_repository.dart:38`. So a gate that lives in the POS screen is a suggestion: anything
holding a session can write the table. **The gate has to be server-side, on every one of those
paths**, which is why chunk 3 and 4 are larger than they look.

## The mechanism (one, for every action — D-071's own design)

1. **`approval_requests`** — `action_type` (enum), `payload` jsonb, `status`
   (`pending` / `approved` / `rejected`), plus who asked, when, who decided, when, the decision
   note, and when the write actually ran. This is the shape `MASTER_PLAN.md` already recorded.
2. **Staff rows have no write path.** The client still *builds* the document, but submits it as a
   **request**; the protected tables' INSERT/UPDATE/DELETE are **revoked from `authenticated`** and
   reachable only from the executing functions.
3. **Approving executes the write server-side**, as the owner, through the *same* code the direct
   write used to take (the stock and ledger triggers are untouched), and stamps `executed_at`.
4. **`sales.discount_above_limit_request_id`** is a **real foreign key** to `approval_requests(id)`
   (D-071), not a soft reference.
5. **The owner's screen**: a pending list with a title and a one-line summary, approve / reject with
   a note, and what the decision ran. **The staff's feedback**: "sent to the owner, waiting" on the
   document they were building, and its state afterwards.

**Blocking, not retroactive** (D-071, confirmed by the owner 2026-09-20): the document does not
count until it is approved. For a GRN that means the medicine is **not in stock and cannot be sold**
until the owner approves — the pending GRN he chose, with its operational cost stated plainly.

## The order of the work

The one hard safety rule: **the revokes ship WITH the request flow, never before it.** Revoking a
table's writes while the app still tries to write it directly would leave staff unable to work at
all, so each chunk lands as a pair (server + the screens that use it).

- **Chunk 1 — the mechanism, proved on the discount (D-071).** The enums, the table, its RLS, the
  `request_approval()` / `decide_approval()` functions, and `sales.discount_above_limit_request_id`
  — wired to `checkout_sale` so an above-10% discount is *requested*, the bill waits, and the owner's
  approval lets it through. This is what the brief that scoped Step 1–3 asked for (*"make the
  discount its first `action_type`"*), it is the smallest slice that proves request → decide →
  execute end to end, and it unblocks the >10% discount Phase 7a is currently refusing.
- **Chunk 2 — the owner's approvals screen and the staff's waiting state.** Without this the
  mechanism has no user, and no later gate can land safely.
- **Chunk 3 — purchases.** `pending_approval` on `purchase_status`, the request path in
  `purchases_repository`, the owner's approve-executes-GRN, and the revokes. The largest chunk.
- **Chunk 4 — returns and stock adjustments.** `purchase_return`, `sale_return`,
  `stock_adjustment`, on the same rail.
- **Chunk 5 — master data.** `product_create` / `product_edit` / `product_delete` / `customer_edit`
  / the expense rows, and the `update_patient` role gate folded into `customer_edit`.
- **Chunk 6 — polish.** Notify the owner when something is waiting (the existing
  `queue_notification` rail), and decide whether a stale pending request expires.

## What must not break

- The counter: the sale bill, a payment and a new patient stay free for **every** role.
- **The owner's own work is never gated** — he writes directly, as he does today.
- The stock and ledger triggers, and every committed SQL test: approving must run exactly the write
  the staff used to run, so a purchase approved by the owner posts identically.
- The truthfulness rule these briefs keep: a screen must not promise an approval workflow that is not
  there. Today's refusal sentences already say Phase 6.5c does not exist; they come out with chunk 1.

## Decisions this brief needed from the owner — ALL ANSWERED (2026-09-21)

1. **Expenses are NOT gated** (D-085). He answers with a different mechanism: *"expenses donot need
   approvals only notification, email, whatsapp notification"*. So `expense_create` / `expense_edit` /
   `expense_delete` stay declared in the enum and **never get an executor** — recording an expense
   stays free for every role, and the owner is **told** instead (the `queue_notification` rail, chunk 6
   or the chunk that builds it). The `expenses` table therefore keeps its write grants: there is no
   request path to ship with a revoke.
2. **`sale_edit` and `sale_cancel` ARE gated** (D-085): *"sale edit/ sale cancle need approval from
   owner"*. Note what that means in this app: **neither act exists** — nothing anywhere writes
   `sales.status = 'cancelled'`, and there is no sale-edit screen, so a correction today is a sale
   *return* (already gated, chunk 4). Building the gate means building the act, and a posted bill has
   already moved stock and posted a ledger entry — so what a cancel *does* to those is the open design
   question recorded in `context/chat3t-opening-prompt.md`.
3. **A pharmacist is gated like a cashier** per his answer — said back plainly because it removes a
   trust that exists today, and it is why `update_patient`'s role gate is folded into `customer_edit`
   rather than left beside it.

## Files when chunk 1 starts

- **new**: `supabase/migrations/20260921000043_phase6_5c_approval_rbac.sql`,
  `supabase/tests/phase6_5c_approval.sql`
- **read first**: `20260920000035` (the deferred FK and its `comment`), `20260920000036` +
  `20260921000042` (`checkout_sale`, whole), `20260920000038` (the `get_my_role()` gate idiom),
  `20260918000012` (RLS policies), `20260919000028` (`queue_notification`, for chunk 6)
- **do not touch**: `sale_requirements.dart`'s type rules, the receipt's arithmetic, and anything
  outside the approval rail
- **DECISIONS.md**: the entry for this policy goes in with chunk 1 (next free number), not here.

## Gates (unchanged)

`dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
`dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` → the five
`deno check` entry points; the SQL harness at `.qwen/tmp/pg7a/` (`run_all.sql` gains each migration,
`run_tests.sql` each test file). Baseline at this handoff: **987 Flutter tests, 181 Deno, all
passing**, at `3406e41`. Counts must not fall; assertions are re-expressed, never weakened.
