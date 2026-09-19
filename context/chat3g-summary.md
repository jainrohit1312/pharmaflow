# Chat 4 / Chunk C3 summary — the embedding backfill (COMPLETE, live)

**Status:** COMPLETE. Chunk C is done: **C1** (the matcher), **C2** (the app's seam,
alias learning, the suggestions) and **C3** (this — the catalogue embedded and the
vector floor measured). Phase 5's *smart matching* half is finished and
live-verified; the notification half (Chunk D) is briefed in
`context/chat3h-opening-prompt.md`.
**Date:** 2026-09-19

| Piece | Scope | State |
|---|---|---|
| C1 | migration 00023 (`product_embedding_text`, `match_products`) + 43-assertion SQL test + `match-product` | DONE |
| C2 | `MatchService`, the match models, the batch controller, suggestions, `learn_product_aliases` (00024) + SQL test | DONE |
| C3 | `products_to_embed` + `set_product_embeddings` (00025), `backfill-embeddings`, the re-tuned floor (00026) + SQL test | DONE, run live |

## What C3 ships

**`supabase/migrations/20260919000025_phase5_embedding_backfill.sql`** (applied):
two functions, no table, no column, no trigger, nothing that moves stock.

- **`products_to_embed(p_limit int) → {items, remaining, unembeddable}`** —
  `stable security definer`. One batch of the caller's own un-embedded rows, each
  with the text `product_embedding_text()` produced (D-037), plus what is left and
  what can never be embedded. Limit 20 by default, clamped to 100, applied **after**
  the un-embeddable rows are dropped.
- **`set_product_embeddings(p_items jsonb) → {written, remaining, unembeddable,
  skipped}`** — `volatile security definer`, `search_path public, extensions`.
  `{product_id, embedding:[768]}` rows, each scoped to `get_my_pharmacy_id()` and
  each cast **by the database** from the vector's own text form. Four refusals, all
  skips with a reason: not an item, not a uuid, not 768 numbers, not this catalogue's
  product. `remaining` is computed after the writes.

**`supabase/migrations/20260919000026_phase5_vector_floor.sql`** (applied): 00023's
`match_products` **verbatim** with one constant moved — `c_vector_min_similarity`
**0.78**. A new migration rather than an edit of 00023 (D-013). Its function text was
verified byte-identical to 00023's apart from the floor block before it was applied.

**`supabase/functions/backfill-embeddings/`** — deployed, `verify_jwt` on:

```
POST /functions/v1/backfill-embeddings   {"limit": 20}   (a bare POST is one default batch)
200 { "embedded": n, "remaining": m, "unembeddable": u, "skipped": [...], "model": "gemini-embedding-001" }
4xx/5xx { "error": { "code", "message" } }
```

- **One invocation, one batch, one `batchEmbedContents` request.** No internal loop.
- **All or nothing**: a model failure, a provider refusal, a short answer or a hole
  in the batch writes **nothing** — deliberately stricter than `match-product`,
  which degrades, because a half-written batch is invisible (`NULL` is the marker).
- Nothing to do costs **no** model request: an empty batch answers `0 / 0` without
  calling anything.
- The catalogue text comes back from the database and is embedded verbatim.

**`supabase/tests/phase5_embedding_backfill.sql`** — 35 assertions, 34 PASS / 0 FAIL,
atomic and self-rolling-back. Its strongest three: tenant isolation both ways (the
foreign row is checked **after** `reset role`, because RLS hides it from the caller),
resumability (`remaining` shrinks by exactly what was written), and **the vector leg
of a real `match_products` call firing on a row this pair wrote** — with no model
involved anywhere in the test.

**`make backfill`** — one batch per invocation, token read from
`SUPABASE_USER_TOKEN`, `@`-prefixed so make cannot echo the expanded command line.

## The live run (the evidence)

```
counts before:  1 product, 1 un-embedded, 0 aliases   (read as postgres, read-only)
invocation 1 -> {"embedded":1,"remaining":0,"unembeddable":0,"skipped":[],"model":"gemini-embedding-001"}
invocation 2 -> {"embedded":0,"remaining":0,...}       <- resumes, and spends nothing
counts after:   1 product, 0 un-embedded
```

Then the floor measurement (floor temporarily lowered to 0.01 by a one-word
`pg_get_functiondef` patch on `c_vector_min_similarity`, restored by 00026):

```
'Dolo 650 Tab'        -> trigram 1.0000
'DOLO 650'            -> trigram 1.0000
'Dolo650Tab15s'       -> vector  0.8280   the real product, run together
'Dolo 125'            -> vector  0.7216   a strength the pharmacy does not stock
'Dolo 500'            -> vector  0.7084   a strength the pharmacy does not stock
'Paracetamol 500mg'   -> vector  0.6695   same molecule, another brand
'Amoxyclav 625 10s'   -> vector  0.5780
'Cetirizine 10mg Tab' -> vector  0.5546
'ZZQQ nonsense 9999'  -> vector  0.5364   junk
```

**At 0.7 two wrong strengths were above the floor** and offered as high-confidence
suggestions; 0.78 sits inside the window (0.7216, 0.8280). Live after the re-tune:

```
'Dolo650Tab15s'       -> dolo 650, reason vector,  0.8280   kept
'Dolo 650 Tab'        -> dolo 650, reason trigram, 1.0000   exact name
'Dolo 500'            -> dolo 650, reason trigram, 0.5556   weaker, and labelled as such
'Paracetamol 500mg'   -> dolo 650, reason trigram, 0.6667   weaker, and labelled as such
'Cetirizine 10mg Tab' -> no candidates
'ZZQQ nonsense 9999'  -> no candidates
```

Read that table exactly: the re-tune removed the **vector** leg's high-confidence
wrong claim. The **trigram** leg (threshold 0.35, untouched and measured in C1)
still offers a weaker, honestly-labelled candidate. Two thresholds, two jobs.

## Files

```
supabase/migrations/20260919000025_phase5_embedding_backfill.sql   (new, applied)
supabase/migrations/20260919000026_phase5_vector_floor.sql         (new, applied)
supabase/tests/phase5_embedding_backfill.sql                       (new, 35 assertions)
supabase/functions/backfill-embeddings/{index,deps,handler,handler_test}.ts  (new, deployed)
context/chat3g-summary.md · context/chat3h-opening-prompt.md        (this handoff)
```

**Modified:** `Makefile` (the `backfill` target, the new `deno check`, `help`),
`HANDOFF_PROTOCOL.md` (the gate block), `PROGRESS.md`, `DECISIONS.md` (D-043, D-044,
open item **N-9**), `supabase/tests/phase5_match_products.sql` (its three synthetic
boundary vectors moved with the floor: 0.9987 kept, 0.80 just above, 0.5774 refused).
**No Dart changed**, so `flutter test` is still the 493 from C2.

## Verification evidence

```
supabase db push --dry-run            -> Would push: …00025…, then …00026…; finally "up to date"
supabase db push --yes                -> Applying migration …, Finished (twice)
supabase db query --file supabase/tests/phase5_embedding_backfill.sql
                                      -> SUMMARY: 34 PASS / 0 FAIL of 35 assertions
supabase db query --file supabase/tests/phase5_match_products.sql
                                      -> 43 PASS / 0 FAIL
deno test supabase/functions          -> ok | 92 passed | 0 failed
deno check …/ocr-purchase-bill/index.ts    -> clean
deno check …/match-product/index.ts        -> clean
deno check …/backfill-embeddings/index.ts  -> clean
dart format lib test                  -> 383 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> wrote 55 outputs
dart run custom_lint                  -> No issues found!
flutter analyze                       -> No issues found!
flutter test                          -> +493: All tests passed!
```

Live state afterwards, read as postgres: **floor 0.78, trigram 0.35, 1 product
embedded, 0 un-embedded.**

## Open risks / blockers

- **N-9 (Low, new)** — the floor's measurement rests on **one catalogue vector**,
  because the live pharmacy holds one product. It errs high (a missed suggestion, not
  a wrong one) and the recipe to re-measure is three commands; the tests move with the
  constant.
- **N-7 (Low)** — a live invocation still needs a session from the app; the token
  used here was one, and it is not valid any more. Sign out of that session when
  convenient.
- **`products.updated_at` moves once per product** during a backfill, because
  `set_updated_at` is a `BEFORE UPDATE` trigger. Acceptable because the work list is
  `embedding is null`: each row is written exactly once, ever.
- **N-5, N-2, N-6, N-8** unchanged. **D-027's residual** (hiding `products.embedding`
  behind column grants) is still open; C3 touches that column server-side only.
- The live catalogue is still a one-product demo with no purchases, so end-to-end
  *bill* flows are exercised by tests and probes rather than by a real invoice.

## What's next

**Chunk D — notifications**: `send-notification` over WhatsApp/Email with
`notification_logs`, the in-app list, and the low-stock/expiry alerts. Then Phase 6
(testing, deployment, documentation, the Windows build fix, push registration).
