# Chat 3t Summary — Phase 6.5c chunks 5a-c and 5d (the master data, the expense notification, and the two sale acts)

**Status:** COMPLETE for chunks 5a, 5b, 5c and 5d. **Chunk 5 is finished**, and with it **every declared
approval action type is either implemented or retired**. Chunk 5e (the polish) and chunk 6 (the
notification's delivery half, and whether a stale request expires) remain.
**Date:** 2026-09-21
**Commits:** `fb1998c` (chunk 5a-c), `d2c26e5` (chunk 5d) plus the docs commits for **D-086** and
**D-087** and PROGRESS.md — all pushed to `origin/main`. Migrations `20260921000046` and
`20260921000047` are applied to the hosted project (**47 = 47**).

---

## What this session was asked to do, and what it did

The opening prompt (`context/chat3t-opening-prompt.md`) scoped 5a (the product master), 5b
(`customer_edit`, with `update_patient` folded in), 5c (the expense notification), 5d (the sale acts,
**only after the owner's answer**) and 5e (optional polish). Two questions were already answered as
D-085: **expenses are NOT gated** (he is notified instead) and **`sale_edit` / `sale_cancel` ARE
gated**. 5a, 5b, 5c and 5d are done; 5e was not reached.

**The owner's answer, in his words:** *"this data is only for testing, i will again update data from
my current software when this product is fully developed and bug free, so you have to take easy way
out, and focus on completing your task"* — the cheap and honest cancellation, with no reversal
machinery — and *"Yes, narrow only"* for `sale_edit`.

## Supabase changes

| Migration | What it does | Verified |
|---|---|---|
| `20260921000046_phase6_5c_approval_master_data.sql` | `save_product()` — ONE door to `products`, `product_batches` and `product_aliases`, deriving the action type from the document; `update_patient()` re-expressed onto the rail (absorbing 00038's owner-or-pharmacist rule); `document_payload_problem()`, `approval_has_executor()`, `request_approval()` and `approval_execute()` replaced; a TRIGGER on `expenses` that tells the owner through `queue_notification()`; the three product tables lose INSERT/UPDATE/DELETE to `authenticated`; the enum's comment names the RETIRED types | local (fresh 46-migration apply) + **hosted** (`phase6_5c_master_data.sql` → 110/0) |
| `20260921000047_phase6_5c_approval_sale_acts.sql` | `cancel_sale()` — a status flip for a bill **nothing has happened to**; `save_sale_identity()` — the **printed** identity only, held to a whitelist; `sale_apply_decision()` + `approval_execute()` carry the decision out; `sales` and `sale_items` lose INSERT/UPDATE/DELETE to `authenticated` (**the last pair of tables that took writes directly**); a cancelled bill closes its own pending questions; the enum's comment now says every value is implemented or retired | local (fresh 47-migration apply) + **hosted** (`phase6_5c_sale_acts.sql` → 60/0) |

Both migration bodies were rebuilt from the previous migration's own text by
`.qwen/tmp/pg7a/build_00046.js` and `build_00047.js` and diffed before being applied —
`build_00046.js` is also where the `$`-in-a-JS-replacement-string trap was found.

## Flutter files created

- `app/lib/features/products/data/product_payload.dart` + `app/test/features/products/product_payload_test.dart`
  (8 assertions), `app/test/features/products/gated_product_writes_test.dart` (3 widget tests),
  `app/test/support/products_test_app.dart`.
- `app/lib/features/sales/data/sale_act_payload.dart` + `app/test/features/sales/sale_act_payload_test.dart`
  (7 assertions), `app/lib/features/sales/application/sale_acts_controller.dart`,
  `app/lib/features/sales/presentation/widgets/sale_identity_sheet.dart`,
  `app/test/features/sales/presentation/gated_sale_acts_test.dart` (5 widget tests).

## Flutter files modified

`products_repository.dart`, `products_form_controller.dart`, `products_detail_controller.dart`,
`products_form_screen.dart`, `products_detail_screen.dart`, `fake_products_repository.dart`;
`sales_repository.dart`, `sale_detail_screen.dart`, `fake_sales_repository.dart`; and five SQL test
files (below).

## Verification evidence (raw, at `d2c26e5`)

```
flutter test                    1061 passing, 0 failures      (1038 at the session's start)
dart format lib test            546 files, 0 changed
dart run custom_lint            No issues found!
flutter analyze                 No issues found!
deno test supabase/functions    181 passed | 0 failed
deno check <5 entry points>     ALL_FIVE_CHECKS_OK

SQL, fresh 47-migration database, 16 files with a SUMMARY line, 0 FAIL:
  27/0, 36/0, 34/0, 42/0, 32/0, 21/0, 65/0, 75/0, 23/0, 22/0, 30/0, 30/0, 91/0, 61/0, 110/0, 60/0
  (plus the files that log PASS/FAIL lines only, all green)

Hosted, after `supabase db push --yes` (47 = 47):
  phase6_5c_master_data   110/0     phase6_5c_sale_acts     60/0
  phase7a_sale_types       75/0     phase6_5c_purchases     91/0
  phase6_5c_returns        61/0     phase6_5c_approval      30/0
  phase6_alias_identity    21/0     phase4_report_summary   14 assertions, 0 FAIL
  probe: sales INSERT/UPDATE false, sale_items DELETE false, sales SELECT true;
         sale_cancel/sale_edit executors true, expense_create false; 0 cancelled bills
```

## Key decisions

- **D-086** — the product master is REQUESTED (a new product cannot be staged, and an edit has no
  status to wait in); `save_product()` derives the action type rather than accepting one; an alias is
  a document of its own; `update_patient()` absorbs the pharmacist gate (D-085 supersedes 00038); the
  customers form's eight columns stay free with the gap named; `product_batches` loses writes and
  needs no door; an expense is free and a trigger tells him.
- **D-087** — a cancel is a **status flip on a bill nothing has happened to** (no return, no receipt
  applied since it was raised, nothing still owed), it does **not** return the goods or reverse the
  money, and that trade is stated in the ask, the confirmation and the enum's comment; `sale_edit` is
  the printed identity only, enforced by a whitelist.

## Assertions changed, before → after (none deleted, none loosened, no count falls)

- `phase6_5c_approval.sql` (30) / `phase6_5c_purchases.sql` (91) / `phase6_5c_returns.sql` (61): the
  "unimplemented action type is refused" example moved from `product_create` to **`expense_create`** —
  a type D-085 RETIRED, so it stops moving.
- `phase6_5c_master_data.sql` (110): "and still no for an action type whose act does not exist yet
  (sale_cancel)" became "and yes for the two sale acts chunk 5d built, so no declared type is left
  without one".
- `phase6_alias_identity.sql`: five client upserts became five `save_product()` calls, run as the
  **owner**. 20 → 21 assertions.
- `phase7a_sale_types.sql`: section 17 re-expressed around the envelope; **"a pharmacist may edit a
  patient master" became "a PHARMACIST is gated like a cashier now"** (D-085 supersedes 00038's rule).
  Same count.
- `phase4_report_summary.sql` + `phase7a_sale_types.sql` had been **ERRORING since chunks 3 and 4**;
  their fixtures are written as postgres now. Proved pre-existing with `.qwen/tmp/pg7a/run_all_pre46.sql`
  (a baseline arm at migration `00045`). `phase4_report_summary`'s cancelled-sale fixture needed the
  same treatment again after 5d revoked the last session write `sales` had.
- New: `phase6_5c_master_data.sql` (110) and `phase6_5c_sale_acts.sql` (60).

## Open risks / things the next session must know

1. **A cancel does not reverse anything.** That is D-087 and the owner's own choice, and it is stated
   wherever he or the operator reads it. If the books ever have to agree for real, the reversal is the
   work — do not quietly "fix" it by adding a stock restore without the ledger half.
2. **The refusal that guards a receipt applied after the fact is unreachable through the app today**
   (`allocate_payment()` will not over-settle a settled bill, and a bill with anything outstanding is
   refused by the "not settled" rule). It is kept and pinned by a fixture; do not delete it as dead
   code without reading D-087.
3. **An older deployed client cannot write a sale, a sale item, a product, a batch, an alias, a
   purchase, a return or an adjustment.** Expected — the app is not live — but `sales` and
   `sale_items` were the last pair, so there is now no business table left that takes a session write
   except `expenses` (by design, D-085) and the customers form's eight granted columns.
4. **The customers form is still not gated** (`is_active` and `opening_balance`). Named in D-086.
5. **5e was not reached**: the approvals queue still refreshes only itself, so an open purchase or list
   screen can show the pre-decision state until it is re-entered; and a stale pending request is
   refused when decided but never expires.
6. **Chunk 6 is the notification's delivery half**: the email leg is not queued (no address on the
   account), the WhatsApp row stays `queued` until something dispatches it, there is still no
   automatic dispatch of the Phase 5 rail (D-046), and N-1's credentials are still missing.

## What's next

`context/chat3u-opening-prompt.md` — **chunk 5e and then chunk 6**, and — still open from Phase 7a —
the **deposit-application sheet** (`context/chat3r-opening-prompt.md` §2).
