# Chat 3p Summary — Phase 7a, the POS UX refactor (C2)

**Status:** PARTIAL (Phase 7a's app is now done except C3 — C1a, C1b **and C2** are complete and
gated; C3 remains)
**Date:** 2026-09-21
**Phases done:** Phase 7a — the Flutter slice **C2 (the POS UX refactor)**, in three chunks, each with
its own commit and full gate run. The durable layer (migrations 00033–00038) was already on hosted
when this chat began, and C1a/C1b were already committed.

---

## Supabase Changes

**None.** No migration, function, policy or SQL test was changed — deliberately: C3's migration
`00039` (`sale_document`) is approved but **still unwritten**, and this chat's brief put it in C3.
`checkout_sale` was not touched. Nothing under `supabase/` appears in any of this chat's three
commits.

## Commits (all local, none pushed)

| Commit | What it is | `flutter test` |
|---|---|---|
| `1ef2234` | C2/1 — the search-and-keyboard core: the auto-focused search whose dropdown adds the FEFO batch on Enter, with no chooser in the default case | 898 → 911 |
| `d8b6335` | C2/2 — the compact basket lines, the Tab/Delete contract, and the 360×800 pass | 911 → 915 |
| `ed4e177` | C2/3 — the Recent / category / All strip, the double-submit guard, and focus restoration | 915 → 926 |

## Flutter Files Created (9)

**lib:**
- `features/sales/application/pos_search.dart` — `PosSearchHit`, the Freezed `PosListKey`, and the
  one `posList` provider answering the search, Recent, a category and All
- `features/sales/presentation/widgets/pos_search_results.dart` — the list's rows (batch, expiry as
  `MM/yy`, stock, MRP) and the choose-batch affordance
- `features/sales/presentation/widgets/pos_cart_line.dart` — the compact line, its on-demand
  rate/discount/slab, and its Tab/Delete orders
- `features/sales/presentation/widgets/pos_strip.dart` — Recent / the catalogue's categories / All
- `features/products/application/product_categories.dart` — the catalogue's own distinct categories

**test:**
- `test/features/sales/application/pos_search_test.dart`
- `test/features/products/application/product_categories_test.dart`

**generated (gitignored, not committed):** `pos_search.freezed.dart`, `pos_search.g.dart`,
`product_categories.g.dart`

## Flutter Files Modified (10)

**lib:** `core/utils/formatters.dart` (`monthYearShort`, `MM/yy`),
`core/widgets/app_search_field.dart` (optional `controller`/`focusNode`/`onSubmitted`/`autofocus`;
disposes only what it created), `features/products/data/products_repository.dart`
(`ProductsQuery` gains `category`/`ids`, `list` applies them, `batchesForProducts`, `categories`),
`features/sales/data/sales_repository.dart` (`recentlySoldProductIds`),
`features/sales/presentation/pos_screen.dart` (the strip, the key, the keyboard handler, the
double-submit guard, the focus restoration, the cart-line swap).
**test:** `features/sales/presentation/pos_screen_test.dart`, `support/fake_products_repository.dart`
(`category`/`ids` filtering, `categories`, a `category` on `buildProduct`),
`support/fake_sales_repository.dart` (`recentlySoldProductIds`, `checkoutGate`),
`support/sales_test_app.dart` (`posListProvider` and `productCategoriesProvider` overrides).
**docs:** `PROGRESS.md`, `DECISIONS.md` (D-077, D-078, D-079), `context/chat3p-summary.md`,
`context/chat3q-opening-prompt.md`.

## Verification Evidence (raw, per chunk)

Chunk 1 (`1ef2234`): `dart format lib test` → 495 files, 0 changed; build_runner → exit 0;
`custom_lint` → No issues; `flutter analyze` → No issues; `flutter test` →
`02:30 +911: All tests passed!`; `deno test supabase/functions` → `ok | 181 passed | 0 failed`;
five `deno check` → exit 0.

Chunk 2 (`d8b6335`): format → 0 changed; `custom_lint` → No issues; `flutter analyze` → No issues;
`flutter test` → `02:22 +915: All tests passed!`; Deno → `ok | 181 passed | 0 failed`; five
`deno check` → exit 0.

Chunk 3 (`ed4e177`): build_runner → exit 0; format → 0 changed; `custom_lint` → No issues;
`flutter analyze` → No issues; `flutter test` → `02:29 +926: All tests passed!`; Deno →
`ok | 181 passed | 0 failed`; five `deno check` → exit 0.

Count history, each the gate's own output: **898 → 911 → 915 → 926**, 0 failures at every step.
**28 new tests** (13 in C2/1, 4 in C2/2, 11 in C2/3), none deleted, skipped, loosened or weakened;
every re-expressed assertion is documented before → after in its commit message. `pos_screen_test`
15 → 29, `pos_search_test` 7 → 12, `product_categories_test` new with 2.

## Key Decisions Made

1. **The counter's list is one keyed provider (D-077)** — `PosListKey(term, recent, category)` keys
   `posList`, which answers the search, Recent, a category and All; a **strip tab is that key**, so
   the strip and the list cannot disagree. A typed term wins over the strip. Search = 5 rows,
   browse = 10. Freezed supplies the key's `==` (the linter refuses a hand-written operator on an
   unannotated class, and `meta` is not a direct dependency here).
2. **The strip is built from the catalogue's own categories** (the owner's F3): a bounded client-side
   distinct over `products.category`, because PostgREST has no `distinct` and no RPC was allowed.
   Every imported product has `category` NULL, so the strip is **Recent + All** today and a tab
   appears with no code change when data arrives.
3. **Recent is two reads and keeps the sold order** — `recentlySoldProductIds` (recent sales minus
   cancelled, then their lines, distinct, newest first), then the product rows put back into that
   order, because a product row cannot carry it. Recent is the strip's opening tab.
4. **The keyboard contract (D-078)**: Enter adds and **never checks out**; the arrows move the
   highlight; Escape closes the list **without touching the basket**; **Tab walks the quantities**
   (explicit focus orders, so it does not fall into a line's own details); **Delete removes the line
   the caret is on** (and not when the caret is in a field of it); and a rapid second Enter/tap
   cannot double-add or double-submit. The counter's icon controls are forced to ≥44px, because
   Material's `IconButton` default is 40.
5. **The double-submit guard reads live state, not the build's.** The button is disabled while a
   write is in flight, but the rebuild lands a frame after the tap, so `_checkout` re-reads the
   controller. It is proven by a test that **holds the write open** (`checkoutGate`) — with an
   instant fake the race does not exist and the test would pass without the guard.
6. **C3's receipt contract is recorded (D-079)**: `sale_document` returns the header, the lines with
   `batch_no`/`expiry_date`/`is_unknown_batch`, and the **patient's `patient_code` joined on
   `sales.customer_id`** — one round trip, and a package sale's account legitimately has none.

## Open Risks / Blockers

- **Migration `00039` `sale_document` is still unwritten.** C3's receipt needs it; the owner approved
  the body verbatim on 2026-09-20 and the body is reproduced in
  `context/chat3q-opening-prompt.md` and in D-079.
- **The category read is bounded** (`categoryScanLimit` = 1000 rows, `PROGRESS.md` would carry it as
  an open item): a catalogue past that could hide a category until the read becomes a server-side
  `distinct` in an RPC. At this pharmacy's ~315 products it is not binding.
- **C3 remains entirely**: payment modes and change, the on-credit guard, the confirmation on
  **server** totals, never showing success or printing before the server answers, the 80mm receipt
  with per-line batch and expiry, and the patient/admission/sale-detail balance views.
- **The local verification harness is still on disk and its container is still up**:
  `.qwen/tmp/pg7a/` (`stub.sql`, `reset.sql`, `seed.sql`, `run_all.sql`, `run_tests.sql`, plus the
  upgrade-path files and the recorded `out_*.txt`) and the Docker container `pharmaflow-pg7a`
  (`pgvector/pgvector:pg17`, no published port). **`run_all.sql` lists migrations 00001–00038** — it
  needs the new 00039 line added before a fresh run proves all 39 apply clean.
- **Nothing was pushed and nothing deployed**; the three commits are local on `main`, which is six
  commits ahead of `origin/main`.
- **N-18 stands**: the hosted SQL suite has 7 pre-existing failures in three Phase 5 files.

## What's Next

`context/chat3q-opening-prompt.md` — **C3: payment, the receipt (migration `00039` first) and the
balance views.**
