# Chat 4 / Chunk C1 summary — the matcher (COMPLETE, server-side)

**Status:** COMPLETE for C1. Chunk C is split three ways and **C1 is done**: the
matching capability and its SQL test, live on the hosted project, with
`match-product` deployed. **C2** (the app's seam, alias learning, the picker's
suggestions) and **C3** (the embedding backfill) are briefed in
`context/chat3f-opening-prompt.md`.
**Date:** 2026-09-19

| Piece | Scope | State |
|---|---|---|
| C1 | migration 00023 (`product_embedding_text`, `match_products`) + a 43-assertion SQL test + the `match-product` Edge Function | DONE — applied, deployed, 81 Deno tests |
| C2 | `MatchService` / `ProductMatch` / provider, alias learning at save, suggestions in `ProductPickerField` | NOT STARTED |
| C3 | `products.embedding` backfill (`products_to_embed`, `set_product_embeddings`, `backfill-embeddings`) | NOT STARTED |

## What C1 ships

**`supabase/migrations/20260919000023_phase5_product_matching.sql`** (applied):
two functions, no table, no column, no trigger, nothing that moves stock.

- **`product_embedding_text(p_name, p_generic_name, p_pack_size) → text`** — the
  catalogue-text convention, `immutable`, in the database so the backfill cannot
  drift from the match (D-037).
- **`match_products(p_queries jsonb, p_limit int) → jsonb`** — `stable security
  definer`, `set search_path = public, extensions`, `authenticated` only. Pharmacy
  from `get_my_pharmacy_id()`, never an argument. `p_limit` clamped to 1…20.

**The RPC's contract** (this is what C2 codes against):

```
p_queries := [ { "raw_name": "Dolo650Tab15s",
                 "supplier_id": "<uuid>" | null,
                 "query_embedding": [ 768 numbers ] | null } ]
p_limit   := 5

→ [ { "raw_name": "Dolo650Tab15s",
      "candidates": [ { "product_id", "name", "generic_name", "pack_size",
                        "is_active", "score", "reason",
                        "evidence": { "alias_name" | "similarity" | "distance" } } ] } ]
```

- **Aligned by position**: one entry per query, in the order asked, and a line with
  no candidates keeps its own empty entry rather than disappearing.
  `raw_name` in the answer is the RPC's own trimmed echo — **look the candidates up
  by position, not by matching the string back**, or a line whose text had
  surrounding spaces will find nothing.
- `reason` is `alias` | `trigram` | `vector`; `score` is 0…1 and the ranking is by
  score, with the leg only an ordered tiebreak (D-036).
- A candidate's keys are **exactly** those eight — no `embedding`, ever (D-027).

**`supabase/functions/match-product/`** (deployed, `verify_jwt` on):

```
POST /functions/v1/match-product
Authorization: Bearer <user jwt>   apikey: <publishable key>
{ "lines": [ { "raw_name": "Dolo650Tab15s", "supplier_id": "<uuid>" } ] }   // a bare string also works

200 { "matches": [ …the RPC's array… ],
      "meta": { "model", "line_count", "embedded", "vector_used", "warnings": [...] } }
4xx/5xx { "error": { "code", "message" } }
```

- **One embedding call per bill** (`batchEmbedContents`) and one RPC call. Up to
  `MAX_MATCH_LINES` (50) lines; past that it **truncates with a warning** rather
  than refusing, so `matches.length` may be shorter than the bill.
- **An embedding failure is not a bill failure**: the response is a 200 with
  `vector_used: false` and a sentence in `meta.warnings`. A missing
  `GEMINI_API_KEY` arrives the same way, named in the warning.
- A blank line keeps its position and spends no embedding slot; a `supplier_id`
  that is not a uuid is dropped before the payload is built.
- `_shared/embedding.ts` (the convention, `outputDimensionality: 768`,
  `RETRIEVAL_DOCUMENT`/`RETRIEVAL_QUERY`) and `_shared/gemini.ts` (one poster for
  every function; `ocr-purchase-bill` was left as it is — deployed and verified).

**`supabase/tests/phase5_match_products.sql`** — 43 assertions, atomic,
self-rolling-back, impersonating `authenticated` against a second tenant whose
product is named *identically* and embedded *identically* to the query vector.

## The measurements that shaped it (do not re-derive these)

```
similarity('Dolo650Tab15s','Dolo 650')          = 0.278   (< pg_trgm's 0.3 default)
word_similarity('Dolo 650','Dolo650Tab15s')     = 0.455   (the direction that works)
similarity('Dolo650Tab15s','Dolo 500')          = 0.211
greatest(name, generic, word_sim) for Dolo 650  = 0.4545
greatest(…) for Dolo 500                        = 0.4444   (0.01 apart — trigram cannot choose)
similarity('AMOXYCLAV 625 10S','Amoxyclav 625') = 0.778
similarity('ZZQQ nonsense 9999','Dolo 650')     = 0.000
```

Thresholds in the function: **trigram ≥ 0.35**, **vector cosine ≥ 0.7** (the
second is provisional — nothing is embedded yet, so C3 re-tunes it against real
vectors and records what it finds).

## Files

```
supabase/migrations/20260919000023_phase5_product_matching.sql   (new, applied)
supabase/tests/phase5_match_products.sql                         (new, 43 assertions)
supabase/functions/_shared/embedding.ts  + embedding_test.ts      (new)
supabase/functions/_shared/gemini.ts     + gemini_test.ts         (new)
supabase/functions/match-product/{index,deps,handler}.ts + handler_test.ts (new, deployed)
context/chat3e-summary.md · context/chat3f-opening-prompt.md      (this handoff)
```

**Modified:** `Makefile` and `HANDOFF_PROTOCOL.md` (the gate block now has one
`deno check` per entry point), `PROGRESS.md` and `DECISIONS.md` (D-036, D-037,
D-038 and open items **N-5**, **N-7** — **N-6 was withdrawn** as a false positive).
**No Dart file changed**, and `dart format lib test` still reports 0 changed.

## Verification evidence

```
supabase db push --dry-run            -> Would push: 20260919000023_…
supabase db push --yes                -> Applying migration …, Finished
supabase db query --file supabase/tests/phase5_match_products.sql
                                      -> PASS 43 / FAIL 0 (exit 1 is the test's own RAISE)
deno test supabase/functions          -> ok | 81 passed | 0 failed
deno check …/ocr-purchase-bill/index.ts  -> clean
deno check …/match-product/index.ts      -> clean
dart format lib test                  -> 372 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> wrote 0 outputs
dart run custom_lint                  -> No issues found!
flutter analyze                       -> No issues found!
flutter test                          -> +453: All tests passed!
```

Post-test residue: 0 ZZTEST products, 0 ZZTEST pharmacies, 0 aliases, 0 embedded
products.

**Live:** deployed (`match-product`, `verify_jwt: true`, alongside
`ocr-purchase-bill` v4) and invoked — a caller with no pharmacy gets the
function's own envelope, `{"error":{"code":"unauthorized","message":"This account
is not linked to a pharmacy yet."}}`, and `{"lines":[]}` gets a 400. The
**embedding call itself has not been made live** (see N-7): the model name, the
`batchEmbedContents` shape and the free-tier embedding quota are still unverified,
and that is C3's first task (D-030: a live call is the verification).

## Open risks / blockers

- **N-7 (Low, blocking a live probe)** — a throwaway account cannot sign in on the
  hosted project: `email_confirmations` are ON there while `config.toml` says
  otherwise (a local-stack-only setting, D-003), and confirming by hand is an
  auth-weakening write to production that the guard rightly refuses. Probe with a
  session from the app, or approve one `update auth.users … email_confirmed_at`.
- **N-6 (WITHDRAWN — it was my measurement error, not a defect).** It claimed a live
  function response carries **no `access-control-allow-origin`**. It does: the
  deployed gateway answers with `Access-Control-Allow-Origin: *` (capitalised) on the
  error paths of both functions and on the preflight, while passing the other three
  CORS headers through lowercased. The original check used a **case-sensitive
  `findstr`**, which hid exactly the one header being looked for. Re-measured with
  full header dumps on the 401, the 400 and the OPTIONS preflight; **no code changed
  and neither function was redeployed**. D-038 records the contract and the recipe
  (`findstr /I`). A browser run when C2 first calls the matcher from Chrome is still
  the pleasant confirmation, not a pending risk.
- **N-5 (Low, pre-existing, untouched)** — `product_aliases`' unique index treats
  NULL suppliers as distinct, so `addAlias` with no supplier inserts a duplicate
  rather than updating, contrary to its own doc comment. The OCR path always names
  a supplier, so chunk C never meets it.
- **N-2 (Medium)** — the free-tier key, still the reason the match is one embedding
  call per bill and degrades rather than failing.
- **Operator note (not a repo issue):** `supabase projects api-keys <ref>` prints
  the legacy **anon and service_role JWTs in full** (only the new `sb_secret_…` is
  masked). It was run once here to obtain the publishable key for the live probe, so
  the legacy service_role key is in this session's transcript. Rotate it from the
  dashboard if that matters; the publishable key (`sb_publishable_…`) is the one to
  prefer in probes.
- `supabase db push` prompts unless given `--yes` (it hung for two minutes without
  it). Mentioned once because it looks like a hang rather than a prompt.

## What's next

**C2** — the app's seam, alias learning and the picker's suggestions — then **C3**,
the backfill, which is also where the embedding quota finally gets measured.
