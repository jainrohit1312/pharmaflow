# Chat 4 / Chunk D (PARTIAL, part 1 of 2) — the alert sources (COMPLETE)

**Status:** **PARTIAL** — Chunk D is split in two, and **part 1 is done and gated**:
the two alert sources (`low_stock_products`, `expiring_batches`) are live and asserted.
**Part 2 — `send-notification`, the in-app list and the Dart seams — is not started**
and is briefed in `context/chat3i-opening-prompt.md`.
**Date:** 2026-09-19

## Why it split here

The chunk's own halves are the ones the earlier chunks used: **the server side
first**, gated on its own, then the app. Part 1 was finished and gated at ~60-70%
context, which is the handoff rule — and the split is honest in a second way:
part 1 is exercisable on live data with **no credential at all**, while part 2 is the
half whose WhatsApp/SendGrid credentials do not exist yet (D-046).

## What part 1 ships

**`supabase/migrations/20260919000027_phase5_alert_sources.sql`** (applied): two
`stable security definer` functions, no table, no column, no trigger, and nothing that
moves stock.

- **`low_stock_products(p_limit int default 50) → jsonb`** — products below their
  reorder level, worst first, each with `total_qty`, `min_stock_level` and
  **`shortfall`** (units that close the gap). The rule is `<`, the app's own, now
  evaluated where both columns live. An inactive product is never reported; a product
  with no batches is `0` and is.
- **`expiring_batches(p_days int default 90, p_limit int default 50) → jsonb`** —
  batches with stock left inside the horizon, soonest first, `days_left` **negative**
  for an already-expired one. An empty batch is excluded.
- Both read the tenant from `get_my_pharmacy_id()` and carry `pharmacy_id = v_pharmacy`
  explicitly. Not belt-and-braces: the views they read are `security_invoker = true`,
  and inside a definer function the "invoker" is the owner.

**`supabase/tests/phase5_alerts.sql`** — 25 PASS / 0 FAIL of 26 assertions, atomic
and self-rolling-back: the reorder boundary (`<` reports, `=` does not), the
no-batches case, an inactive product never reported, the shortfall number, worst-first
ordering, the limit, the horizon widening with `p_days`, the negative `days_left`, the
already-expired batch first, an empty batch excluded, tenant isolation both ways, and
that reading them moves nothing.

**D-047** records the shape: **an alert is a question, a notification is an event.**
The alerts are derived (an RPC answer) and never stored; `notifications` stays what it
is — events a recipient was told about. Without that distinction, D-046's "alerts
appear in the in-app list" would have meant rows that are wrong as soon as stock moves
(or, with nothing on a schedule, rows nobody would write).

## A finding worth keeping

The alert RPCs answer against the real pharmacy **right now**: its single catalogue
product has `min_stock_level = 20` and no stock, so `low_stock_products()` returns it
with a shortfall of 20. The alerts are therefore exercisable end to end on live data
without a credential — the opposite of part 2.

And a schema fact the test found: `product_batches.expiry_date` is `NOT NULL`, so the
function's `is not null` guard is a mirror of the column, not a live branch. The test
asserts the column's nullability instead of inventing a fixture the schema forbids.

## Files

```
supabase/migrations/20260919000027_phase5_alert_sources.sql   (new, applied)
supabase/tests/phase5_alerts.sql                              (new, 26 assertions)
context/chat3i-opening-prompt.md                              (part 2's brief)
```

**Modified:** `PROGRESS.md` (the D-part-1 section, the counts, I-1's plan, Next
Action), `DECISIONS.md` (**D-047**). **No Dart changed in part 1**, so the 493 Flutter
tests are C2's.

## Verification evidence

```
supabase db push --dry-run   -> Would push: 20260919000027_… ; then "up to date"
supabase db push --yes       -> Applying migration …00027…, Finished
supabase db query --file supabase/tests/phase5_alerts.sql
                             -> SUMMARY: 25 PASS / 0 FAIL of 26 assertions
deno test supabase/functions -> ok | 92 passed | 0 failed
deno check ×3 (ocr, match, backfill) -> clean
dart format lib test         -> 383 files, 0 changed
dart run custom_lint         -> No issues found!
flutter analyze              -> No issues found!
flutter test                 -> +493: All tests passed!
```

Migration count: **27/27 local and remote**, with 00028 reserved for whatever part 2
needs (most likely nothing — the tables already exist).

## Open risks / blockers

- **Part 2 has no credential to verify against**: no WhatsApp Cloud API token, no
  SendGrid key, and no recipient phone numbers are collected anywhere (D-046). The
  function must therefore be built so a missing secret is a `not_configured`
  sentence, with the log row still written, and its tests must run with no secret at
  all (stubs, the way `match-product`'s do).
- **N-7** still governs a live invocation: ask the user for a session from the app.
- **I-1 is now half-closed**: the server-side answer exists (D-047), but
  `InventoryRepository.lowStock` still decides in Dart over its 500-row scan. The fix
  is a client change, recorded in I-1's plan.
- N-9, N-8, N-5, N-2, N-4, N-6 unchanged. **D-027's residual** (hiding
  `products.embedding` behind column grants) still open.

## What's next

**`context/chat3i-opening-prompt.md`** — Chunk D part 2, then Phase 6.
