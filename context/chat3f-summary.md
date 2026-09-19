# Chat 4 / Chunk C2 summary — the seam, the suggestions, and alias learning (COMPLETE)

**Status:** COMPLETE. Chunk C is split three ways; **C1** (the matcher) and **C2**
(this) are done, live on the hosted project. **C3** — the `products.embedding`
backfill — is briefed in `context/chat3g-opening-prompt.md`.
**Date:** 2026-09-19

| Piece | Scope | State |
|---|---|---|
| C1 | migration 00023 (`product_embedding_text`, `match_products`) + 43-assertion SQL test + `match-product` Edge Function | DONE |
| C2 | `MatchService`, the match models, the batch controller, suggestions in `ProductPickerField`, `learn_product_aliases` (migration 00024) + its SQL test, the re-seed fix | DONE |
| C3 | `products.embedding` backfill (`products_to_embed`, `set_product_embeddings`, `backfill-embeddings`) | NOT STARTED |

## What C2 ships

**`supabase/migrations/20260919000024_phase5_alias_learning.sql`** (applied): one
function, no table, no column, no trigger, nothing that moves stock.

- **`learn_product_aliases(p_aliases jsonb) → {learned, skipped}`** — `volatile
  security definer`, `set search_path = public`, `authenticated` only. The tenant
  comes from `get_my_pharmacy_id()` and every statement carries it explicitly.
  `normalize_product_name()` runs **server-side**. Input is
  `[{raw_name, product_id, supplier_id}]`; anything unusable is **skipped with a
  reason**, never raised: a non-object entry, blank or punctuation-only text, no
  product chosen, a product id that is not a uuid or not in this catalogue, and a
  supplier that is not this pharmacy's (read as "no supplier").
- A supplier-scoped row upserts on the existing unique key. A NULL-supplier row is an
  explicit **update-then-insert**, because that index cannot converge NULLs (N-5).
  N-5 is **not** fixed: the index, `addAlias` and migration 00015's comment are as
  they were.

**`supabase/tests/phase5_learn_product_aliases.sql`** — 42 PASS / 0 FAIL of 43
assertions, atomic, self-rolling-back, impersonating `authenticated` against a second
tenant. End-to-end in section 5: after learning, the **alias leg of a real
`match_products` call** answers the supplier it was learned from, does **not** answer
another supplier's bill, and does once the same text is learned with no supplier.
Residue: 0.

**Dart** (all new unless marked):

```
app/lib/services/match_service.dart                        MatchService, MatchLineRequest,
                                                           ConfirmedAlias, decodeProductMatches,
                                                           decodeLearnedAliases, matchException
app/lib/data/models/product_match.dart                     ProductMatches, ProductMatch, MatchCandidate,
                                                           MatchEvidence, MatchMeta, MatchReason
app/lib/features/purchase_ocr/application/
    purchase_match_controller.dart                         one batch call, never blocking
app/lib/core/errors/function_error.dart                    functionException (one reader; ocrException delegates)
app/lib/features/purchase/presentation/widgets/
    product_picker_field.dart                    (modified) suggestions, maxSuggestions = 3
app/lib/features/purchase/presentation/widgets/
    purchase_line_editor.dart                    (modified) suggestions param, _applyProduct/_onSuggestion
app/lib/features/purchase_ocr/presentation/
    purchase_ocr_screen.dart                     (modified) the ask, _MatchNote, _LineSlot.invoiceText,
                                                           alias learning at save, ValueKey(scan.bill)
app/lib/services/ocr_service.dart                (modified) delegates its envelope mapping
```

**Tests — 40 added, none changed:** `test/data/models/product_match_test.dart`,
`test/services/match_service_test.dart`,
`test/features/purchase_ocr/application/purchase_match_controller_test.dart`,
`test/features/purchase/presentation/product_picker_field_test.dart`, seven new cases
in `purchase_ocr_screen_test.dart`, and `test/support/fake_match_service.dart`
(`FakePurchaseOcrRepository.bill` became mutable so a second read can differ).

## The four decisions

- **D-039** — the suggestion is asked for **once per bill, when the human names the
  supplier** (the supplier scopes the alias leg, and the reader only gives a supplier
  *name*); a failure is a note, never a block; **no automatic retry**, a manual
  **Look again** instead; at most 3 rows, each with `MatchCandidate.reasonLabel`;
  offered, never applied.
- **D-040** — alias learning is **one best-effort write per bill at save**, of the
  text the bill printed (held per line slot, not the draft's `productNameRaw`), with
  the supplier the bill named; a failure costs only the next bill's head start.
- **D-041** — the **embedding budget is not the reader's 5/minute** (measured, below).
- **D-042** — a function's error envelope has **one reader** in the app
  (`functionException`); the retry policy stays per-feature.

## The live probe (read-only) and what it settled

The session token the user supplied was used while valid, with `curl` (not a
browser — the standing preference for this host). Nothing was written to the
database.

```
POST match-product  {"lines":["Dolo650Tab15s","AMOXYCLAV 625 10S","ZZQQ nonsense 9999"]}
200 OK   Access-Control-Allow-Origin: *
{"matches":[{"raw_name":"Dolo650Tab15s","candidates":[
   {"name":"dolo 650","score":0.4545,"reason":"trigram","evidence":{"similarity":0.4545},
    "is_active":true,"pack_size":"15","product_id":"1ac034e9-…","generic_name":"paracetamol"}]},
  {"raw_name":"AMOXYCLAV 625 10S","candidates":[]},
  {"raw_name":"ZZQQ nonsense 9999","candidates":[]}],
 "meta":{"model":"gemini-embedding-001","line_count":3,"embedded":3,"vector_used":true,"warnings":[]}}
```

1. **The embedding call is live-verified** — model name, `batchEmbedContents` body
   and the 768-dimension parse (what C1 left unverified).
2. **CORS on the 200 path** — D-038 could cite only the 401, the 400 and the
   preflight; now the success path is measured too.
3. **The vector leg answered nothing** — `products.embedding is null` on every real
   row, exactly as D-037 predicted. That is C3's work list.
4. **The quota measured**: 6 single-line requests + 4 × 20-text batches (80 texts) in
   ~3 minutes, all 200, `vector_used: true`, no refusal → the embedding metric is not
   the reader's 5/minute (D-041).

## Gate output at completion

```
supabase db push --dry-run                     -> Would push: 20260919000024_… ; later "up to date"
supabase db push --yes                         -> Applying migration …00024…, Finished
supabase db query --file supabase/tests/phase5_learn_product_aliases.sql
                                               -> SUMMARY: 42 PASS / 0 FAIL of 43 assertions
                                                  (exit 1 is the test's own rollback RAISE)
deno test supabase/functions                   -> ok | 81 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts  -> clean
deno check supabase/functions/match-product/index.ts      -> clean
dart format lib test                           -> 383 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> wrote 63 outputs
dart run custom_lint                           -> No issues found!
flutter analyze                                -> No issues found!
flutter test                                   -> +493: All tests passed!
```

## Open risks / blockers

- **N-7 (Low, blocks any future live probe)** — a throwaway account cannot sign in on
  the hosted project (email confirmation is ON there while `config.toml` says
  otherwise), and confirming by hand is an auth-weakening write the guard refuses.
  Probe with a session from the app, as C2 did (the token expires after an hour).
- **N-8 (Low, new)** — a successful **second read** replaces the whole verify form, so
  the chosen supplier is dropped with it (a consequence of the `ValueKey(scan.bill)`
  re-seed fix, D-039). Re-seed only the lines in `didUpdateWidget` to keep the header.
- **C3 needs a fresh session token** for its live invocations: the C2 token has done
  its job and expires within the hour.
- **`products.embedding` is still NULL on every real row**, so the vector leg answers
  nothing in production. Nothing else about the matcher is affected — trigram and
  alias answer the bill — but a suggestion today is a name similarity, and a
  user-facing sentence says so when the server reports it.
- **N-5, N-2, N-6** unchanged (N-6 remains withdrawn; D-038's recipe stands).

## What's next

**C3** — the backfill, briefed in `context/chat3g-opening-prompt.md`. It is also
where D-036's provisional `0.7` vector floor gets re-tuned against real vectors.
