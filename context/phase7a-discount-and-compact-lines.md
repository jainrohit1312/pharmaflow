# Phase 7a — the bill-level discount and the one-line cart row (accepted, not started)

**Status:** accepted by the owner on 2026-09-21, **not started**. This file is the brief for the
next session, written because the first step needs a large `create or replace` and the session
that took the decision had run out of room.

## The two decisions (owner, 2026-09-21)

1. **The discount is a bill-level amount in rupees**, entered once near the totals — not a
   per-line percentage. His example: a bill of **546**, a discount of **46**, and **500** to pay.
2. **Each cart line is one row**: name + batch + qty + total, with the rest (rate, discount, slab)
   on demand. Today's line is two or three rows tall and he says it eats the screen.

They go in this order because the second depends on the first: once the discount is bill-level,
a line no longer needs a discount field of its own, and the row can be one line.

## The GST rule he confirmed, in his words

> "we are giving discount on price including gst so after discount gst will be calculated on that
> discounted total amount"

So the discount is taken off the **tax-inclusive** total, and the taxable value and the tax are
then derived from the **discounted inclusive** amount — which is the same extraction D-075
already does, applied to a smaller number:

    discountedInclusive = lineTotal − its share of the bill discount
    taxable             = discountedInclusive / (1 + slab/100)
    tax                 = discountedInclusive − taxable

This is the treatment a GST invoice needs: a discount given at the time of supply reduces the
taxable value and the tax with it. Getting it wrong here over-reports GST.

## Step 1 — migration `00042` (do this first, and on its own commit)

**What it must do.** Accept a bill-level discount in the sale payload and apply it so that every
figure stays self-consistent:

- **Distribute the discount across the lines**, proportionally to each line's `total_amount`, so
  the last line absorbs the rounding remainder and the shares add back up to the rupee figure
  exactly. (Distributing rather than subtracting at the header is what keeps
  `sub_total + tax_total = grand_total` and the per-line tax heads adding back to the tax charged
  - the identity `checkout_sale` has always held, D-057/D-075.)
- **Recompute each line's** `taxable`, `tax_amount`, `cgst_amount`, `sgst_amount` and
  `total_amount` from its discounted inclusive total, with the slab it already has.
- **`discount_total`** then equals the sum of the lines' discounts (the bill discount's share plus
  any per-line discount), so the receipt's `Discount -Rs 46.00` line is the stored figure.
- **Refuse** a discount larger than the bill, and keep a cap. **The 10% cap (D-071) is currently a
  per-line `discount_percent` check and cannot stay as it is**: with a rupee discount the natural
  rule is that the bill discount may not exceed **10% of the bill's total**, by refusal, with the
  same sentence the counter already uses ("A discount above 10% needs the owner's approval…").
  Confirm this wording with the owner if it differs from what he expects.
- **Idempotency and the legacy seam are untouched**: a payload that names no discount behaves
  exactly as it does today, and `sales_payment_check` still refuses an over-payment.

**The gotcha that made this a separate session.** `checkout_sale(p_payload jsonb)` is **~600
lines of plpgsql inside migration `20260920000036`**. Adding this means a full
`create or replace` of that function: read `00036` from line 88 to its end, reproduce it with the
discount handling inserted where the lines are priced, and check the whole body against the
original before applying it. **Do not hand-edit a fragment of it** — a truncated
`create or replace` silently drops the rest of the function's behaviour, and its tests are the
only thing that would catch it.

**Its test**: `supabase/tests/phase7a_bill_discount.sql`, with a `SUMMARY:` line, on the local
harness (`run_all.sql` currently lists `00001`-`00041`; add `00042`; `run_tests.sql` is 17 files).
Assert: the owner's own example (546 → 46 → 500, with the tax extracted from 500 and the heads
adding back), the shares add to the rupee exactly, a bill with several lines splits in proportion
and the last line takes the remainder, the identity `sub_total + tax_total = grand_total` still
holds, a discount larger than the bill is refused, the cap is refused with the counter's sentence,
and a payload with no discount is unchanged. **Then run it against hosted too** — that is how the
`open_bills` ordering defect was found (D-082).

**Then push it** (the owner authorises migrations per brief; ask, as the last two were pushed on
his word), and verify live as `00039`/`00040` were.

## Step 2 — the client (after the migration is on hosted)

- `SaleCartLine`/`PosCart` gain the bill discount; `SaleTotals` applies it the way the server
  does (distribute, then extract) so the counter's preview equals the stored row - the whole point
  of D-075's basis. **`SaleTotals` is the only place money is worked out**; no widget recomputes.
- A `Discount ₹` field near the totals, visible without a tap, with the resulting total beside it.
- `sale_checkout.dart` sends it; `sale_requirements.dart` refuses what the server refuses.
- The four per-line money facts stay derivable: `quantity x rate − discount`, tax extracted.

## Step 3 — the one-line cart row

- `pos_cart_line.dart`: **name + batch + qty + total on one row**; rate/discount/slab leave the
  line entirely (the discount is bill-level now, and the rate is the batch's own).
- Keep every contract that already holds and is asserted: the caret goes to a newly added line's
  quantity with the number **selected**; an emptied quantity **keeps the line** and settles back
  on blur; **Enter returns to the search**, **Tab moves on** (and leaves the basket for payment
  after the last quantity); **Delete removes the line the caret is on**; the icon controls stay at
  least 44px for a thumb (D-078 and the two fixes after it — `c0082e3`, `ec41388`, `3e83c55`).
- Watch for these regressions, all of which have tests: the traversal bands (a quantity must sort
  above every one of a line's own controls, or Tab lands on the line instead of the payment card),
  the 360x800 layout pass, and the batch/expiry string.

## Files

- **new**: `supabase/migrations/20260921000042_phase7a_bill_discount.sql`,
  `supabase/tests/phase7a_bill_discount.sql`
- **read first, change carefully**: `supabase/migrations/202609200000036…` (the whole
  `checkout_sale`), `app/lib/features/sales/data/sale_totals.dart`,
  `app/lib/features/sales/data/sale_checkout.dart`, `app/lib/features/sales/application/pos_controller.dart`,
  `app/lib/features/sales/presentation/pos_screen.dart`,
  `app/lib/features/sales/presentation/widgets/pos_cart_line.dart`
- **do not touch**: `sale_requirements.dart`'s type rules, any other module, and the receipt's
  arithmetic (it prints the stored row - the discount arrives on `discount_total` by itself).

## Gates (unchanged)

`dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
`dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` →
the five `deno check` entry points. Baseline at this handoff: **965 Flutter tests, 181 Deno**, all
passing, at `7b30c3b`. Counts must not fall; assertions are re-expressed, never weakened.
