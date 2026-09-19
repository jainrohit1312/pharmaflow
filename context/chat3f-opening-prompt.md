# Chat 4 / Chunks C2 and C3 — Phase 5: the seam, the suggestions, and the backfill

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **sixth** chunk brief of Chat 4. Chat 4's overall brief is
> `context/chat3-opening-prompt.md`; the chunk accounts are `chat3a-summary.md`
> (the database), `chat3b-summary.md` (the Edge Function), `chat3c-summary.md` (the
> Dart seam), `chat3d-summary.md` (chunk B complete) and `chat3e-summary.md`
> (**C1 complete — read it first**). `PROGRESS.md`'s Chat Strategy table is the
> authority: **Chat 4 = Phase 5 + Phase 6**.
>
> The next handoff files after these chunks are `context/chat3f-summary.md` and
> `context/chat3g-opening-prompt.md`. New decisions continue at **D-038** (D-036 and
> D-037 are taken).

---

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — authority on what is done, the gates, the open items
2. `MASTER_PLAN.md` — Phase 5's place in the roadmap
3. `DECISIONS.md` — especially **D-026** (RPCs, never free-form SQL), **D-027** (the
   embedding and the explicit projection), D-028 (the bucket), **D-036** (the match
   is one RPC, ranked by score, thresholds measured), **D-037** (the convention
   lives in the database), D-030…D-035, and the older D-011/D-013/D-015/D-021
4. `HANDOFF_PROTOCOL.md` — the gate list, which now has one `deno check` per entry point
5. `context/chat3e-summary.md` — **the important one**: C1's exact contracts
6. `context/chat3f-opening-prompt.md` — this file

Then output a 5-line understanding check:

- What C2 and C3 cover, and what C1 already made work
- What C1 delivered and what it deliberately did not (the Dart layer, the backfill,
  and the live embedding call)
- Environment (hosted Supabase, no Docker, Web-first)
- Two load-bearing dependency pins
- What you are about to build

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`, no `db reset`
- Migrations: `supabase db push --yes` (the `--yes` matters: without it the command
  waits on an interactive prompt and looks like a hang). `supabase db query --linked
  --file <path>` runs a migration file or a test against the live database and is how
  a `create or replace` migration is re-applied while iterating.
- Platform priority: Web → Windows → Android → iOS
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0
- **DO NOT modify**: the `riverpod_lint` range, `custom_lint`, `freezed`, or the
  `sdk` pin (D-007)

### Gates — all must pass before any handoff

```
dart format lib test
dart run build_runner build --delete-conflicting-outputs
dart run custom_lint
flutter analyze
flutter test
deno test supabase/functions
deno check supabase/functions/ocr-purchase-bill/index.ts
deno check supabase/functions/match-product/index.ts
```

(plus `supabase db push --dry-run` before pushing, and a new `supabase/tests/*.sql`
if a migration lands — atomic, self-rolling-back, asserting its numbers and printing
them, the way `phase2_stock_triggers.sql` … `phase5_match_products.sql` do.
`make test-functions` runs the three Deno lines.)

**Edge Functions without Docker**: develop by deploying and invoking the deployed
function (B1's practice, D-031). This CLI has no `functions logs` (N-4), so a
temporary `detail` on an internal error, one deploy, one invocation, then removed, is
the established way to see inside. **A live invocation needs a signed-in user**: the
hosted project requires email confirmation (N-7), so a throwaway signup cannot sign
in and confirming it by hand is refused as an auth-weakening write — ask the user for
a session from the app rather than working around it.

---

## WHAT C1 LEFT YOU (do not re-do)

- **`match_products(p_queries jsonb, p_limit int)` is live**, ranked by score with
  `reason` and `evidence` per candidate, candidates from named columns only, an
  alias scoped to the supplier or to none, and a deactivated product never offered.
- **`match-product` is deployed** (`verify_jwt` on): `{ lines: […] }` →
  `{ matches: […], meta: { model, line_count, embedded, vector_used, warnings } }`,
  one embedding call per bill, degrading to alias+trigram on any embedding failure.
- **`product_embedding_text()`** is the catalogue-text convention; the query text is
  the invoice text as printed (D-037).
- **The answer is aligned by position** with the lines sent. Look candidates up by
  position; `raw_name` is the RPC's trimmed echo and is not a key.
- **Nothing in the Flutter tree calls the matcher yet**, and **nothing is embedded
  yet** (`products.embedding is null` on every real row), so the vector leg answers
  nothing in production until C3 runs.
- **The live embedding call has still never been made**: the model name, the
  `batchEmbedContents` body shape and the free-tier embedding quota are unverified.
  C3's first act is one live call (D-030).

---

## SCOPE — C2: the app's seam, alias learning, and the picker's suggestions

The goal: the second bill from a supplier needs almost no human help, because the
first one taught the system everything the human did.

### 1. The Dart seam

- `MatchService` over `functions.invoke('match-product')`, with the wire mapping as
  **pure functions** (`decodeProductMatches`, `matchException`) the way
  `OcrService` does it (B2a), and a plain `ProductMatch`/`MatchCandidate` model —
  **plain classes, not Freezed**: this is an RPC envelope, no migration owns its shape
  (`ReportSummary`'s and `OcrPurchaseBill`'s precedent).
- Reuse `isRetryableOcrError`'s lesson, not its code blindly: decide what deserves a
  retry here, and remember the quota is per minute.
- **A batch, not a per-line loop.** One call for the whole bill, so twenty lines are
  one round trip and one embedding request. A failure is not an error state the
  screen blocks on: **no suggestion is not a failure**.

### 2. The suggestions (the last thing to build, as the briefs have said twice)

- They belong in `PurchaseLineEditor(showBatchFields: true)`'s `ProductPickerField`
  or in what feeds it, so the change is in one place.
- **A suggestion is offered, never applied.** The human still chooses — a wrong
  auto-fill on a received invoice is a stock error, not a typo.
- **The reason is visible enough to trust**: an alias hit can say *also called
  DOLO-650*, a trigram hit *87% similar*, a vector hit that it looks similar. The
  `reason`/`evidence` fields exist for exactly this.
- The screen must not block on matching: a bill with twenty lines must be saveable
  while the match is still in flight, and a match that never returns must not stop
  the save.
- Traps already paid for in this project: **Riverpod 3 retries a failed provider
  build by itself** (so an error state is not stable across pumps, and a *one-shot*
  failure flag is consumed by an earlier build), and **GoRouter builds a route more
  than once before the first frame settles**. Widget tests must be written with both
  in mind.

### 3. Alias learning

- At **save**, not at pick: the human's confirmed choice, in **one
  `learn_product_aliases(jsonb)` call per bill** (new migration — parameterised,
  `security definer`, tenant from `get_my_pharmacy_id()`, `normalize_product_name()`
  server-side, upserting on the table's existing unique key).
- **Best effort**: a failed learning write must never fail the save. Say in the
  handoff what the user loses when it fails.
- A wrong alias is worse than no alias, so only the human's choice creates one; and
  **an alias is scoped to the supplier when one is known**, because C1 proved two
  suppliers' abbreviations are different evidence (D-036).
- Say in the handoff what happens when the same invoice text arrives for a different
  supplier (C1's answer: a supplier-scoped alias does not answer it; a pharmacy-wide
  one does).
- **N-5 is not yours to fix**: `product_aliases`' NULL-supplier unique-key trap. The
  OCR path always names a supplier. Leave `ProductsRepository.addAlias` alone.

---

## SCOPE — C3: the embedding backfill

`products.embedding is null` is the work list (D-027 — there is no marker column).
The backfill needs to:

- **measure the quota first, live**, before designing the loop (N-2 is about the
  reader's key: five requests a minute; an embedding has its own metric and probably
  its own limit, and the answer to "how many?" is one live call away);
- be **resumable and tenant-safe**: `NULL` is the marker, so a second run continues,
  and the write must not reach across tenants;
- be **operator-paced**: one Edge Function invocation embeds **one batch** and
  returns `{ embedded, remaining }`, so the operator loops and can stop it. No
  internal loop, and never at the same time as a bill is being read;
- use the **one convention** (D-037): the catalogue text comes from
  `product_embedding_text()`, the task type is `RETRIEVAL_DOCUMENT`, the dimension
  is 768;
- write through a `security definer` RPC rather than a raw PostgREST vector write —
  how PostgREST marshals a `vector` is exactly the kind of unverifiable behaviour
  D-027 refused to depend on;
- **re-tune D-036's `0.7` vector floor** against the real vectors it produces, and
  record what it found (that constant is marked provisional in the migration);
- paste the evidence: counts before and after, the invocation output, a second run
  proving it resumes rather than repeating, and the quota it observed.

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, read synchronously from
  `requirePharmacyIdProvider` (D-015). Server-side, from `get_my_pharmacy_id()`.
- **Functions act as the signed-in user** — the caller's JWT, never `service_role`
  for reads (D-004).
- **Stock moves through triggers, never through the client** (D-011/D-013, D-023):
  nothing C2 or C3 adds may write `product_batches.qty`.
- **Money is computed once, by a pure helper** (`PurchaseTotals.round2`).
- **`check_violation` (23514) messages reach the user verbatim.**
- **A new column on a table is not visible through a view** (D-021's trap) — if you
  add one, say so in the SQL test. C1 added none.
- Freezed for table rows; **plain classes** for an RPC envelope, a payload, a
  ranking result.
- `ref.mounted` after every await before writing state (D-034); a platform
  capability gets a seam and a fake (D-035); a controller test keeps its provider
  alive with `container.listen(...)`; provider override lists are inferred
  (`Override` is not exported by `flutter_riverpod`).
- A platform for this feature means **Web first** (D-005).

---

## OPEN ITEMS THIS CHUNK SHOULD NOT MAKE WORSE

| ID | Issue | Why it matters here |
|---|---|---|
| N-6 | A live function response carries **no `access-control-allow-origin`** (measured on both deployed functions) | C2 is the first code that will read a function response from a browser. If Chrome blocks it, that is a platform CORS setting, not `response.ts` — and it affects the OCR screen too |
| N-7 | Hosted auth requires email confirmation, so a throwaway probe cannot sign in; confirming by hand is refused | A live matcher probe needs a session from the app |
| N-2 | The Gemini key is free-tier (5 requests a minute), shared with the reader | One embedding call per bill is deliberate (D-036/D-037). Do not add a second |
| N-5 | `product_aliases`' unique index treats NULL suppliers as distinct | Leave it; the OCR path always names a supplier. Recorded for Phase 6 |
| I-3 | A picker offers at most 200 rows; the matcher's own limit is 5 | A suggestion list is not a search box |
| I-1 | `lowStock` compares two columns in Dart over at most 500 candidates | Unrelated, but the same "the comparison belongs in SQL" instinct |
| D-027's residual note | Whether to hide `products.embedding` behind column grants is unresolved | C3 reads and writes that column server-side; keep every client projection explicit |

N-1 (push deferred to Phase 6), N-4 (no function logs) and the older items are not
these chunks' business.

---

## CONTEXT MANAGEMENT — YOUR CALL

Rules, unchanged:

1. **Each chunk ends in a working, gated state.** Run every gate (the three Deno
   lines included) at the end of every chunk.
2. **Hand off at ~60-70% context**, or earlier if quality visibly degrades.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3f-summary.md` and `context/chat3g-opening-prompt.md`; add decisions
   at **D-038+**; leave the tree commit-ready.
4. **Never compress.** Do not skip the SQL test for a migration, do not skip widget
   tests, do not stub an Edge Function. If a chunk would need to cut corners, split
   it — C2 splits naturally at the picker (seam + learning / the suggestions).
5. **If you finish C2 and C3 and context has room**, chunk D (notifications) may
   start — re-run all gates first, and stop at the same 60-70% rule.

---

## BEGIN

Start by reading the files in STEP 0, output the 5-line understanding check, and then
say how you intend to build C2 — where the suggestions render and what the widget
does with a candidate, what the screen shows while the batch call is in flight and
what it shows when the call fails, exactly what the alias-learning write sends and
when, and what you will verify — plus anything you need from the user. Wait for
approval before writing the migration or the widget. Then do C3 the same way.
