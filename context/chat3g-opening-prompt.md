# Chat 4 / Chunk C3 — Phase 5: the embedding backfill

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **eighth** chunk brief of Chat 4. Chat 4's overall brief is
> `context/chat3-opening-prompt.md`; the chunk accounts are `chat3a-summary.md` (the
> database), `chat3b-summary.md` (the Edge Function), `chat3c-summary.md` (the Dart
> seam), `chat3d-summary.md` (chunk B complete), `chat3e-summary.md` (**C1** — the
> matcher) and `chat3f-summary.md` (**C2 — read it first**: the app's seam, the
> suggestions, alias learning, and the live probe). `PROGRESS.md`'s Chat Strategy
> table is the authority: **Chat 4 = Phase 5 + Phase 6**.
>
> The handoff files after this chunk are `context/chat3g-summary.md` and
> `context/chat3h-opening-prompt.md`. New decisions continue at **D-043** (D-038 to
> D-042 are taken).

---

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — authority on what is done, the gates, the open items
2. `context/chat3f-summary.md` — **the important one**: C2's contracts and the live probe
3. `DECISIONS.md` — especially **D-027** (the embedding is a pgvector column the
   client never selects), **D-036** (one RPC, ranked by score, **the provisional 0.7
   vector floor**), **D-037** (the catalogue-text convention is a database function),
   **D-041** (the embedding budget is not the reader's 5/minute — measured), **D-030**
   (a model name is verified live), **D-031** (no recent JS built-ins in a function),
   **D-004/D-026** (the caller's JWT; the tenant is never an argument)
4. `HANDOFF_PROTOCOL.md` — the gate list, one `deno check` per entry point
5. `context/chat3e-summary.md` — C1's exact contracts
6. `context/chat3g-opening-prompt.md` — this file

Then output a 5-line understanding check (what C3 covers, what C1 and C2 already made
work, environment, two load-bearing dependency pins, what you are about to build).

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`, no `db reset`
- Migrations: `supabase db push --yes` (the `--yes` matters: without it the command
  waits on an interactive prompt and looks like a hang). `supabase db query --linked
  --file <path>` runs a migration file or a test against the live database.
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
deno check supabase/functions/backfill-embeddings/index.ts      <- NEW, add it here and to the Makefile
```

(plus `supabase db push --dry-run` before pushing, and a new `supabase/tests/*.sql`
if a migration lands — atomic, self-rolling-back, asserting its numbers and printing
them.)

**Edge Functions without Docker**: develop by deploying and invoking the deployed
function (B1's practice, D-031). This CLI has no `functions logs` (N-4), so a
temporary `detail` on an internal error, one deploy, one invocation, then removed,
is the established way to see inside. **A live invocation needs a signed-in user**
(N-7): the hosted project requires email confirmation, so a throwaway signup cannot
sign in — **ask the user for a session token from the app** rather than working
around it, and use it while it lasts (it expires in about an hour).

---

## WHAT C1 AND C2 LEFT YOU (do not re-do)

- **`match_products()` is live with three legs**, and the **alias** and **trigram**
  legs work in production today. The **vector** leg answers nothing, because
  `products.embedding is null` on every real row — that is this chunk.
- **`product_embedding_text(name, generic_name, pack_size)` is the one catalogue-text
  convention** (D-037), `immutable`, in the database so the backfill cannot drift
  from the match. The backfill embeds **what it returns**.
- **`_shared/embedding.ts` already exists** and is already used by `match-product`:
  `DEFAULT_EMBEDDING_MODEL` (`gemini-embedding-001`), `EMBEDDING_DIMENSIONS` (768),
  `CATALOGUE_TASK_TYPE` (`RETRIEVAL_DOCUMENT`), `buildBatchEmbedContentsBody`,
  `parseEmbeddings` (which refuses a wrong-width vector loudly) and
  `batchEmbedContentsUrl`. Reuse it — do not write a second convention.
- **`_shared/gemini.ts`** is the one poster to the model; it takes the API key as an
  argument and is testable with a stub `fetch`.
- **The embedding call is live-verified** and the **budget measured**: 11 requests /
  80 texts in ~3 minutes, no refusal, including four 20-text batches (D-041). 20 texts
  per request is a measured-safe batch size; the exact ceiling is unmeasured.
- **The 0.7 vector floor in `match_products` is provisional** and marked so in
  migration 00023. This chunk re-tunes it against real vectors and records what it
  found (it is a `create or replace function` migration, re-applied while iterating).
- The app side is done: `MatchService`, the batch controller and the suggestions are
  live in `features/purchase_ocr/` + `lib/services/match_service.dart`, and 493
  Flutter tests pass. **C3 should need no Dart changes at all** (there is no operator
  UI in this chunk — see the scope note below).

---

## SCOPE — C3: the embedding backfill

`products.embedding is null` is the work list (D-027 — there is no marker column).
The provisional names from C1's handoff, to keep or to improve on:

1. **`products_to_embed(p_limit int) → jsonb`** — a `stable security definer` RPC
   returning the un-embedded rows of the caller's own pharmacy: id, the catalogue
   text from `product_embedding_text()`, and whatever the caller needs to show a
   count. Pharmacy from `get_my_pharmacy_id()`, never an argument.
2. **`set_product_embeddings(p_items jsonb) → jsonb`** — the write: `vector(768)`
   per product id, `security definer`, scoped to the caller's pharmacy row by row.
   **Not** a raw PostgREST vector write — how PostgREST marshals a `vector` is exactly
   the unverifiable behaviour D-027 refused to depend on.
3. **`backfill-embeddings`** — the Edge Function. **One invocation embeds one batch
   and returns `{ embedded, remaining }`**, so the operator loops and can stop it.
   No internal loop. Never run it while a bill is being read (the reader and the
   matcher share the key, N-2).

Then:

- **measure before designing**: one live call settles the quota question (D-041 has
  already done most of it — say so, do not re-measure for the sake of it);
- **resumable and tenant-safe**: `NULL` is the marker, so a second run continues
  rather than repeating, and the write must not reach across tenants;
- **one convention** (D-037): the text from `product_embedding_text()`, the task type
  `RETRIEVAL_DOCUMENT`, the dimension **768**;
- **re-tune D-036's `0.7` vector floor** against the vectors this produces, and record
  what it found (a migration, a measured number in `DECISIONS.md`, and an assertion in
  the SQL test);
- **paste the evidence**: counts before and after, the invocation output, **a second
  run proving it resumes rather than repeating**, and the quota it observed.

### A scope question to settle first

The brief has no operator **UI**: the loop is an operator command (a `curl` or a CLI
invocation repeated by hand). Deciding whether Phase 5 needs a screen for it — and
whether that is a small `settings` surface or Phase 6's deployment checklist — is
worth one question to the user before writing any widget. **Ask; do not assume.**

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, read synchronously from
  `requirePharmacyIdProvider` (D-015). Server-side, from `get_my_pharmacy_id()`.
- **Functions act as the signed-in user** — the caller's JWT, never `service_role`
  (D-004). A backfill writes as the caller, which is also what keeps it tenant-safe.
- **Stock moves through triggers, never through the client** (D-011/D-013, D-023):
  nothing C3 adds may write `product_batches.qty`. C3 writes one column on `products`.
- **`check_violation` (23514) messages reach the user verbatim.**
- **A new column on a table is not visible through a view** (D-021's trap): C3 adds
  no column, and no view changes.
- Freezed for table rows; **plain classes** for an RPC envelope, a payload, a result.
- Code under `supabase/functions/` stays language-core JavaScript (D-031).
- `deno check` for the new entry point must be added to `HANDOFF_PROTOCOL.md` and
  `Makefile`'s `test-functions` in the same commit that adds the function.

## OPEN ITEMS THIS CHUNK SHOULD NOT MAKE WORSE

| ID | Issue | Why it matters here |
|---|---|---|
| N-2 | The Gemini key is free-tier and **shared with the reader** | Do not back-fill while a bill is being read; one invocation = one batch |
| D-027's residual | Whether to hide `products.embedding` behind column grants is unresolved | C3 reads and writes that column **server-side only**; every client projection stays explicit |
| N-5 | `product_aliases`' NULL-supplier index trap | Untouched by C3 |
| N-8 | A successful re-read drops the chosen supplier (D-039's consequence) | Untouched by C3 |
| N-7 | A live invocation needs a session from the app | **Ask the user for a token**; do not work around it |
| N-4 | No `functions logs` | Debug by deploy-and-probe (D-031) |

---

## CONTEXT MANAGEMENT

1. **The chunk ends in a working, gated state.** Run every gate at the end —
   including the new `deno check` line.
2. **Hand off at ~60-70% context**, or earlier if quality degrades.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3g-summary.md` and `context/chat3h-opening-prompt.md`; add decisions
   at **D-043+**; leave the tree commit-ready.
4. **Never compress.** Do not skip the SQL test for a migration, do not skip a Deno
   test, do not stub the function. If a chunk would need to cut corners, split it.
5. **If C3 finishes and context has room**, chunk D (notifications) may start —
   re-run all gates first, and stop at the same 60-70% rule.

## BEGIN

Read the files in STEP 0, output the 5-line understanding check, then say how you
intend to build C3 — the RPC pair's exact signatures and return shapes, the batch
size and what the operator's loop looks like command by command, what the function
does when the model is busy or a batch is half-written, how the floor gets re-tuned
and with what numbers, and what you will verify — plus anything you need from the
user (a session token, and the operator-UI question above). **Wait for approval
before writing the migration or the function.**
