# Chat 3u Summary — Phase 6.5c chunk 6, and Phase 7a's last piece

**Status:** COMPLETE. Phase 6.5c is closed (chunks 1–6) and Phase 7a is complete (C3/4b, the
deposit-application sheet).
**Date:** 2026-09-22
**Commits:** `d0a9639` (chunk 6a), `55ad192` (chunk 6b), `0fbfc25` (chunk 6c), `86aec67` (the
deposit-application sheet), plus this session's docs commits — all pushed to `origin/main`.
Migrations `20260922000048` and `20260922000049` are applied to the hosted project (**49 = 49**).

---

## What this session was asked to do, and what it did

The opening prompt (`context/chat3u-opening-prompt.md`) scoped 6a (the expense notification's
delivery half), 6b (whether a stale pending request expires), 6c (the approvals queue refreshes only
itself) and then 6d (the deposit-application sheet, and the customers form's eight columns). **All of
6a, 6b, 6c and the deposit sheet are done**; the customers form's eight columns were NOT touched, and
the reason is D-086's rule rather than a shortage of time (see below).

## Supabase changes

| Migration | What it does | Verified |
|---|---|---|
| `20260922000048_phase6_5c_expense_delivery.sql` | `profiles.email` (backfilled from `auth.users.email`, granted to `authenticated` beside `phone`); `handle_new_user()` re-expressed to carry it; `notify_owner_of_expense()` re-expressed to queue the **email leg**; a comment on `notification_status` (its first) and on `notification_logs.status` recording **where the dispatch waits and why** | local (fresh 49-migration apply) + **hosted** (`phase6_5c_expense_delivery.sql` → 35/0) |
| `20260922000049_phase6_5c_stale_asks.sql` | `approval_close_target_asks()` — the ONE closure, replacing and DROPPING `approval_close_purchase_asks()`; `save_purchase()`, `decide_approval()`, `cancel_sale()` and `record_sale_return()` re-expressed to route through it; the **new** closure that a recorded sale return closes (the bill's cancel ask, and only that); the `approval_requests` table's comment carries the **LIFECYCLE** paragraph | local (fresh 49-migration apply) + **hosted** (`phase6_5c_sale_acts.sql` → 69/0, `phase6_5c_purchases.sql` → 92/0) |

Both migrations were assembled from the applied migrations' own text by
`.qwen/tmp/pg7a/build_00048.js` and `build_00049.js` and **diffed** before being applied — six bodies
in total, and every diff is exactly the intended change.

## Flutter files created

- `app/lib/features/approvals/application/approval_readers.dart` — `refreshApprovalReaders()`, the
  one place that knows which cached reads an answer feeds.
- `app/test/features/approvals/presentation/approval_refresh_test.dart` (2 widget tests).
- `app/lib/data/models/party_deposits.dart` (`OpenBill`, `DepositReceipt`),
  `app/lib/features/balances/application/deposit_application_controller.dart`,
  `app/lib/features/balances/presentation/widgets/apply_deposit_sheet.dart`.
- `app/test/data/models/party_deposits_test.dart` (6 tests),
  `app/test/features/balances/presentation/apply_deposit_sheet_test.dart` (5 widget tests).

## Flutter files modified

`approvals_controller.dart` (the one-word fix: `refreshApprovalReaders(ref)` where it invalidated the
pending list alone); `balances_repository.dart`, `balances.dart`, `patient_balance_card.dart`
(the sheet's entry point); `test/support/fake_balances_repository.dart` (the two readers, the money
that moves, and a **write-only** refusal).

## Verification evidence (raw, at `86aec67`)

```
flutter test                    1074 passing, 0 failures     (1061 at the session's start)
dart format lib test            clean (7 files reformatted on the way)
dart run custom_lint            No issues found!
flutter analyze                 No issues found!
deno test supabase/functions    181 passed | 0 failed
deno check <5 entry points>     ALL_FIVE_CHECKS_OK

SQL, fresh 49-migration database, 17 files with a SUMMARY line, 0 FAIL, none ABORTED:
  27/0, 36/0, 34/0, 42/0, 32/0, 21/0, 65/0, 75/0, 23/0, 22/0, 30/0, 30/0, 92/0, 61/0, 111/0, 69/0, 35/0
  (plus the files that log PASS/FAIL lines only, all green)

Hosted, after each `supabase db push --yes` (49 = 49):
  phase6_5c_expense_delivery  35/0 new      phase6_5c_master_data   111/0 (was 110)
  phase6_5c_sale_acts         69/0 (was 60) phase6_5c_purchases      92/0 (was 91)
  profile_privileges          18 assertions, 0 FAIL

The 6c fix was proved to have teeth: its two widget tests were run with
`refreshApprovalReaders` reverted to `ref.invalidate(pendingApprovalsProvider)` and both FAILED
(2 failed, 0 passed), then passed again once restored.
```

## Key decisions

- **D-088, part 1 — the notification's dispatch waits on N-1, and the email leg's address was
  built.** The call cannot be inside the transaction that opens the row; each of the three candidates
  for a dispatcher (a `pg_net` trigger, a scheduled Edge Function, the app after a write) pays with a
  credential, a schedule or a bypass this project does not have — and behind all three stands the
  missing `WHATSAPP_TOKEN`/`SENDGRID_API_KEY`, which would make every attempt `skipped`. What was
  missing on this side of the seam was **an address**, so `profiles.email` now exists and the trigger
  queues the email leg honestly. The rule lives in `notification_status`'s own comment.
- **D-088, part 2 — a stale ask is CLOSED when its document washes it out, through ONE closure.** An
  expiry is impossible (no scheduler, proved), leaving it contradicts what every chunk since 3 has
  done, so the chunk-3/chunk-5d machinery was **generalised** — one function, one drop, five call
  sites — and `record_sale_return()` now closes the bill's cancellation ask the moment a return is
  written, while leaving the identity edit standing.

## Assertions changed, before → after (none deleted, none loosened, no count falls)

- `phase6_5c_master_data.sql` **110 → 111**: "no email row, because the profile carries no address"
  is KEPT and made **deterministic** (the fixture writes `email = null` beside the number it already
  wrote — because `00048` backfilled the column, so reading the environment would have passed locally
  and failed on hosted), plus a NEW assertion for the rule's other half (an address ⇒ the email leg IS
  queued, with the act as its subject).
- `profile_privileges.sql` **+1**: `email` is updatable by `authenticated`, with the row set named as
  00012's policies rather than widened.
- `phase6_5c_purchases.sql` **91 → 92**: "not `approval_close_purchase_asks`" becomes "not
  `approval_close_target_asks`, the ONE closure, either", plus a NEW assertion that the retired
  function no longer exists.
- `phase6_5c_sale_acts.sql` **60 → 69**: section 9 is NEW and is 6b's own proof (two asks about one
  bill, a return recorded, the cancel ask closed as refused with a note and `decided_by` set, the
  identity edit still pending **and still approvable**, and the table's own comment asserted).
- New files: `phase6_5c_expense_delivery.sql` (35), `party_deposits_test.dart` (6),
  `apply_deposit_sheet_test.dart` (5), `approval_refresh_test.dart` (2).

## Open risks / things the next session must know

1. **The dispatcher is still not built, and that is D-088's decision rather than an oversight.** When
   N-1's credentials exist, the thing to build is a dispatcher that reaches `send-notification`;
   the queued rows are already in `notification_logs`, and the candidates and their costs are in
   `notification_status`'s comment.
2. **The customers form's eight granted columns are STILL writable by a session** (`is_active` is a
   soft delete and `opening_balance` is money). D-086 ruled that the revoke ships WITH its screen, so
   that chunk has to change the form in the same migration that revokes. `customer_edit` is already
   the action type it will raise. **This is the one named gap left inside 6.5c's policy.**
3. **`phase6_5c_purchases.sql` §15 still pins a refusal that leaves an ask pending** — a purchase
   whose status a *fixture* moves out of band. Every door in the application closes its asks now; a
   direct write is not a door, and the refusal is the honest answer for it.
4. **The `sale_cancel`-after-a-later-receipt refusal is unreachable through the app** (`allocate_payment()`
   will not over-settle a settled bill) and is kept, pinned by a fixture, per D-087.
5. **`refreshApprovalReaders()` is the list to extend** when the rail learns to write a document no
   screen here caches yet: it invalidates whole families, so a new reader is one line, and every
   action type's documents are already covered.
6. **The deposit sheet settles SALES only**, because `open_bills()` lists a customer's sales. Applying
   money to an admission episode is possible through the repository
   (`PaymentAllocationTarget.admission`) and is refreshed by its controller, but no screen reaches it.
7. **`phase4_report_summary` and `phase7a_sale_types` were repaired in chunk 5 for ERRORING**, and this
   session re-confirmed the whole suite runs to completion — 24 files, none `ABORTED`, 17 with a
   SUMMARY line.

## What's next

`context/chat3v-opening-prompt.md` — **the owner's own sequence says the receiver app is next (Phase
6.5b)**, then Phase 7b (hospital profit sharing) and 7c (the reports). The customers form's eight
columns is a 6.5c-shaped chunk that must ship with its screen, and it is the only piece of that policy
left open.
