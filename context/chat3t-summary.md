# Chat 3t Summary — Phase 6.5c chunk 5a-c (the master data, and the expense notification)

**Status:** COMPLETE for chunk 5a, 5b and 5c. **Chunk 5d (the sale acts) is NOT built**: it needs the
owner's answer to what cancelling a posted sale does to the stock and money it has already moved, and
that question was put to him in this session's report rather than guessed at.
**Date:** 2026-09-21
**Commits:** `fb1998c` (the chunk), plus a docs commit for D-086 and PROGRESS.md — both pushed to
`origin/main`. Migration `20260921000046` is applied to the hosted project (**46 = 46**).

---

## What this session was asked to do, and what it did

The opening prompt (`context/chat3t-opening-prompt.md`) scoped 5a (the product master), 5b
(`customer_edit`, with `update_patient` folded in), 5c (the expense notification), 5d (the sale acts,
**only after the owner's answer**) and 5e (optional polish). Two owner questions were already
answered as D-085: **expenses are NOT gated** (he is notified instead) and **`sale_edit` /
`sale_cancel` ARE gated**. 5a, 5b and 5c are done; 5d is blocked on the answer; 5e was not reached.

## Supabase changes

| Migration | What it does | Verified |
|---|---|---|
| `20260921000046_phase6_5c_approval_master_data.sql` | `save_product()` — ONE door to `products`, `product_batches` and `product_aliases`, deriving `product_create` / `product_edit` / `product_delete` from the document; `update_patient()` re-expressed to answer the `{outcome, document, request_id}` envelope and to absorb 00038's owner-or-pharmacist rule; `document_payload_problem()`, `approval_has_executor()`, `request_approval()` and `approval_execute()` replaced (the master-data family joins the one shape check and the one dispatch); a TRIGGER on `expenses` that tells the owner through `queue_notification()`; the three product tables lose INSERT/UPDATE/DELETE to `authenticated`; the enum's own comment names the RETIRED action types | local (fresh 46-migration apply) + **hosted** (`supabase db push --yes`, then `phase6_5c_master_data.sql` → **110/0**) |

The four `create or replace` bodies were rebuilt from `00045`'s own text by `.qwen/tmp/pg7a/build_00046.js`
and diffed before being applied — the discipline `build_00042.js` and `build_00043.js` established.

## Flutter files created

- `app/lib/features/products/data/product_payload.dart` — the document `save_product()` takes, in its
  own testable file (the `purchase_payload.dart` pattern).
- `app/test/features/products/product_payload_test.dart` — 8 assertions, including that NO payload
  carries the tenant or the action type.
- `app/test/features/products/gated_product_writes_test.dart` — 3 widget tests: a staff create says
  where it went and navigates nowhere, the owner's create lands and opens the detail, and a staff
  deactivation leaves the product Active and says so.
- `app/test/support/products_test_app.dart` — a router + pump helper for the catalogue screens.

## Flutter files modified

`products_repository.dart` (the five writes go through `save_product()` and answer `WriteOutcome`; the
`normalize_product_name` round trip is gone, because the server normalizes now),
`products_form_controller.dart`, `products_detail_controller.dart` (an alias refresh happens only when
the write LANDED), `products_form_screen.dart`, `products_detail_screen.dart`,
`fake_products_repository.dart` (an `isOwner` switch, the write path, and the reads the detail screen
needs), and six SQL test files (below).

## Verification evidence (raw, at `fb1998c`)

```
flutter test                    1049 passing, 0 failures      (1038 at the session's start)
dart format lib test            540 files, 0 changed
dart run custom_lint            No issues found!
flutter analyze                 No issues found!
deno test supabase/functions    181 passed | 0 failed
deno check <5 entry points>     ALL_FIVE_CHECKS_OK

SQL, fresh 46-migration database, 15 files with a SUMMARY line, 0 FAIL:
  SUMMARY: 27/0, 36/0, 34/0, 42/0, 32/0, 21/0, 65/0, 75/0, 23/0, 22/0, 30/0, 30/0, 91/0, 61/0, 110/0
  (plus the files that log PASS/FAIL lines only, all green)

Hosted, after `supabase db push --yes` (46 = 46):
  phase6_5c_master_data.sql   110 PASS / 0 FAIL
  phase7a_sale_types.sql       75 PASS / 0 FAIL      (repaired; it had been aborting)
  phase6_5c_purchases.sql      91 PASS / 0 FAIL
  phase6_5c_returns.sql        61 PASS / 0 FAIL
  phase6_5c_approval.sql       30 PASS / 0 FAIL
  phase6_alias_identity.sql    21 PASS / 0 FAIL
  phase4_report_summary.sql    14 assertions, 0 FAIL (repaired; it prints no SUMMARY line)
```

## Key decisions

- **D-086** — the product master is REQUESTED (a new product cannot be staged, and an edit has no
  status to wait in); `save_product()` derives the action type rather than accepting one; an alias is
  a document of its own; `update_patient()` absorbs the pharmacist gate; the customers form's eight
  columns stay free with the gap named; `product_batches` loses writes and needs no door; an expense
  is free and a trigger tells him.

## Assertions changed, before → after (none deleted, none loosened, no count falls)

- `phase6_5c_approval.sql`: the "unimplemented action type is refused" example moved from
  `product_create` to **`expense_create`** (retired by D-085, so it stops moving). 30 before and after.
- `phase6_5c_purchases.sql` (91) and `phase6_5c_returns.sql` (61): the same move for the
  `approval_has_executor()` check; the label is re-worded, the rule is unchanged.
- `phase6_alias_identity.sql`: five client upserts became five `save_product()` calls, and the file
  impersonates the **owner** now. 20 → 21 assertions.
- `phase7a_sale_types.sql`: section 17 re-expressed around the envelope — the owner reads `document`,
  and **"a pharmacist may edit a patient master" became "a pharmacist is gated like a cashier now"**,
  because D-085 supersedes 00038's rule. Same count.
- `phase4_report_summary.sql` + `phase7a_sale_types.sql`: **both had been ERRORING since chunks 3 and
  4**, writing revoked tables directly as `authenticated`, so they never reached their summary — and a
  run that counts FAIL lines reads that as green. Their fixtures are written as postgres now. Proved
  pre-existing with `.qwen/tmp/pg7a/run_all_pre46.sql` (a baseline arm at migration `00045`).

## Open risks / things the next session must know

1. **Chunk 5d is the only part of chunk 5 left, and it needs the owner.** Nothing writes
   `sales.status = 'cancelled'` and there is no sale-edit screen, so both acts have to be BUILT
   before they can be gated. The two honest options for a cancel, and the recommendation, are in the
   report that ended this session (and in `context/chat3u-opening-prompt.md`).
2. **An older deployed client cannot write a product, a batch or an alias.** Expected — the app is not
   live — but it is the third time this transitional cost has been paid.
3. **The customers form is still not gated**, and a session can set a customer's `is_active` and
   `opening_balance` through it. Named in D-086 and in the migration's own comment as a later chunk's
   work.
4. **The email leg of the expense notification is not queued** (no address on the account); the
   WhatsApp leg is, and stays `queued` until something dispatches it — there is still no automatic
   dispatch of the Phase 5 rail (D-046), and N-1's credentials are still missing.
5. **`product_batches` has no request path and does not need one today** — but a future screen that
   wants to add a batch by hand now has no door at all, and would need one built with the revoke's
   reasoning in mind.
6. Chunk 5e was not reached: the approvals queue still refreshes only itself, and a stale pending
   request is refused when decided but never expires.

## What's next

`context/chat3u-opening-prompt.md` — **chunk 5d (the sale acts)**, which opens with the owner's answer
about what a cancel does to posted stock and money; then 5e, then chunk 6, and — still open from
Phase 7a — the **deposit-application sheet** (`context/chat3r-opening-prompt.md` §2).
