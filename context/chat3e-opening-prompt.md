# Chat 4 / Chunk C — Phase 5: smart matching (products from invoice text)

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **fifth** chunk brief of Chat 4. Chat 4's overall brief is
> `context/chat3-opening-prompt.md`; the chunk accounts are `chat3a-summary.md`
> (the database), `chat3b-summary.md` (the Edge Function, live-verified),
> `chat3c-summary.md` (the Dart seam) and `chat3d-summary.md` (**chunk B complete —
> read it first**). `PROGRESS.md`'s Chat Strategy table is the authority:
> **Chat 4 = Phase 5 + Phase 6**.
>
> The next handoff files after this chunk are `context/chat3e-summary.md` and
> `context/chat3f-opening-prompt.md`. New decisions continue at **D-036**.

---

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — authority on what is done, the gates, the open items
2. `MASTER_PLAN.md` — Phase 5's place in the roadmap
3. `DECISIONS.md` — especially **D-026** (the chatbot answers through RPCs, never
   free-form SQL), **D-027** (the embedding and the explicit projection), D-028
   (the bucket), D-030 … D-035, and the older D-011/D-013/D-015/D-021
4. `HANDOFF_PROTOCOL.md` — the gate list, which now includes the Deno pair (N-3)
5. `context/chat3d-summary.md` — **the important one**: what chunk B left behind,
   and the three seams a matcher has to fit into
6. `context/chat3e-opening-prompt.md` — this file

Then output a 5-line understanding check:

- What chunk C covers, and what chunk B already made work
- What B delivered (the parse, the screen, the seam) and what it deliberately did not
- Environment (hosted Supabase, no Docker, Web-first)
- Two load-bearing dependency pins
- What you are about to build

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`, no `db reset`
- Migrations: `supabase db push` (the ONLY migration command) — chunk C will
  probably need one (a match function/RPC, maybe a backfill helper)
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
```

(plus `supabase db push --dry-run` before pushing, and a new
`supabase/tests/*.sql` if a migration lands — atomic, self-rolling-back, asserting
its numbers, the way `phase2_stock_triggers.sql` … `phase5_ai_notifications.sql` do.
`make test-functions` runs the Deno pair.)

**Edge Functions without Docker**: develop by deploying and invoking the deployed
function (B1's practice, D-031). This CLI has no `functions logs` (N-4), so a
temporary `detail` on an internal error, one deploy, one invocation, then removed,
is the established way to see inside — and Deno 2.9.6 is installed locally, so
`_shared/` logic gets real tests with `deno test` before it is ever deployed.

---

## WHAT CHUNK B LEFT YOU (do not re-do)

- **A bill reads end to end.** `ocr-purchase-bill` is deployed and live-verified;
  its envelope is `{ document, lines, meta }` with `meta.warnings` written for a
  human and `finish_reason` saying whether the answer was complete.
- **The verify screen exists** (`/purchase/ocr`): image beside the fields, warnings
  shown, a product picker per line, the save through
  `PurchaseFormController.createPurchase` → draft → the existing GRN step.
- **Nothing is matched yet.** Every line's product is chosen by hand, which is the
  one thing chunk C is for. `OcrLine.rawName` holds the invoice text and
  `PurchaseLineDraft.productNameRaw` carries it into the draft.
- **Nothing is embedded yet.** `products.embedding` is `vector(768)` with an HNSW
  index and every row is NULL (D-027), so no vector search can work until the
  backfill runs.
- **`product_aliases`** (with `normalize_product_name()` and a unique key on
  pharmacy + supplier + normalized name) and the trigram index have existed since
  migrations 00004/00011/00015 and are written today only by the product detail
  screen's alias tab.

---

## SCOPE — Chunk C: matching invoice text to the catalogue

The goal is that the second bill from a supplier needs almost no human help, and the
first one teaches the system everything the human does.

### 1. `match-product`

Input: the line's `raw_name`, optionally the supplier, and the pharmacy (never an
argument — from the caller's identity, D-004/D-026). Output: ranked candidates from
the pharmacy's own catalogue, each with the product's id/name/pack and *why* it was
suggested (an alias hit, a trigram score, a vector distance).

- **Server-side, parameterised, and never free-form SQL** (D-026). Whichever shape
  you choose — an Edge Function calling a `security definer` RPC, or the RPC alone —
  the model is not in this path at all: this is a lookup, and the only judgement is
  a ranking.
- **Alias first**: an exact hit on `normalize_product_name(raw_name)` for this
  pharmacy (and supplier, when known) is a certainty, not a similarity. Say so in
  the result.
- **Trigram second**: `pg_trgm` similarity over `name`/`generic_name` and the alias
  table, which is what handles `Dolo650Tab15s` → `Dolo 650`.
- **Vector third**: cosine distance over `products.embedding` (D-027). This is the
  half that needs the backfill, and the half that copes with a supplier's own
  abbreviation.
- **Never `select *` on `products`** — it carries the embedding (D-027). Name the
  columns, server-side included.
- A record of the *chosen* match is worth more than the ranking: see alias learning.

### 2. Alias learning

When a human picks a product for a line whose invoice text is not yet an alias for
it, record it: `product_aliases(raw_name, normalized_name, product_id, supplier_id)`.
The table's unique key makes a second write an update rather than an error, and
`normalize_product_name()` is the database's own function, not a reimplementation
(the precedent is `ProductsRepository.addAlias`).

- Do it through the existing repository method if it fits, or extend it — but the
  write belongs in the repository, and the invalidation of anything it changes
  belongs in the controller.
- A wrong alias is worse than no alias (it will auto-fill the wrong product for
  ever), so the *human's* choice is the only thing that creates one.
- Say in the handoff what happens when the same invoice text arrives for a
  different supplier.

### 3. The embedding backfill

`products.embedding is null` is the work list. Something has to fill it —
`gemini-embedding-001` at 768 dimensions (D-027) — and whatever does it must:

- use **one text convention** for both the backfill and the live match (name alone,
  or name + generic + pack size): two conventions produce vectors that are not
  comparable, and the symptom is a matcher that silently ranks at random;
- be **resumable and tenant-safe**: `NULL` is the marker, so a second run continues
  rather than duplicating work, and the write must not reach across tenants;
- be honest about the free-tier quota (N-2: five requests a minute on the OCR key —
  an embedding per product is a different order of magnitude, so check the quota
  before you design a loop, and consider batching).
- `dart run` a throwaway script, or a function invoked per batch — your call, but
  say which, and paste the evidence.

### 4. The verify screen's suggestions

`PurchaseLineEditor(showBatchFields: true)` renders one `ProductPickerField` per
line (chunk B2b). Suggestions belong there or in what feeds it, so the change is one
place. Requirements:

- a suggestion is **offered, never applied**: the human still chooses (a wrong
  auto-fill on a received invoice is a stock error, not a typo);
- the reason is visible enough to trust ("also called DOLO-650", "87% similar");
- no suggestion is not a failure — the picker keeps working exactly as it does now;
- the screen must not block on matching: a bill with twenty lines should not wait
  for twenty round trips before it can be saved.

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, read synchronously from
  `requirePharmacyIdProvider` (D-015). Server-side, from `get_my_pharmacy_id()`.
- **Functions act as the signed-in user** — the caller's JWT, never `service_role`
  for reads (D-004).
- **Stock moves through triggers, never through the client** (D-011/D-013, D-023):
  nothing chunk C adds may write `product_batches.qty`.
- **Money is computed once, by a pure helper** (`PurchaseTotals.round2`).
- **A document that has posted stock is corrected by a return, never by an edit.**
- **`check_violation` (23514) messages reach the user verbatim.**
- **A new column on a table is not visible through a view** (D-021's trap) — if you
  add one, say so in the SQL test.
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
| N-2 | The Gemini key is free-tier: 5 requests a minute, refused as `503` (D-030/D-032) | An embedding backfill over a catalogue is *many* calls, and it shares the key with the reader. Check the quota and design the loop; do not make the reader unreliable by filling the minute with embeddings. |
| I-1 | `lowStock` compares two columns in Dart over at most 500 candidates | Unrelated, but the same "the comparison belongs in SQL" instinct is what chunk C is about. |
| I-3 | A picker offers at most 200 rows | The product picker's search is the same one a matcher has to work with. |
| D-027's residual note | Whether to hide `products.embedding` behind column grants is unresolved (a projection is what protects the payload today) | If chunk C adds *another* server-side reader of `products`, it must name its columns too. |

N-1 (push deferred to Phase 6), N-4 (no function logs) and the older items are not
this chunk's business.

---

## CONTEXT MANAGEMENT — YOUR CALL

Chunk C is a horizontal feature again — a matcher, a learning write, a backfill, and
a suggestion in one widget — and it may need to split (C1: the matching capability
and its SQL test; C2: alias learning and the screen's suggestions; C3: the
backfill). Rules, unchanged:

1. **Each chunk ends in a working, gated state.** Run every gate (the Deno pair
   included) at the end of every chunk.
2. **Hand off at ~60-70% context**, or earlier if quality visibly degrades. Do not
   push to 90%.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3e-summary.md` and `context/chat3f-opening-prompt.md`; add decisions
   at **D-036+**; leave the tree commit-ready.
4. **Never compress.** Do not skip the SQL test for a migration, do not skip widget
   tests, do not stub an Edge Function. If a chunk would need to cut corners, split
   it.
5. **If you finish chunk C and context has room**, chunk D (notifications) may
   start — re-run all gates first, and stop at the same 60-70% rule.

---

## BEGIN

Start by reading the files in STEP 0, output the 5-line understanding check, and
then say how you intend to split chunk C and how you intend to build the matcher —
the shape of the result, which SQL it runs in, how the embedding text convention is
fixed for both sides, how the backfill is bounded against the free-tier quota, and
what you will verify — plus anything you need from the user before writing a
migration. Wait for approval before writing the migration or the function.

Once approved, begin with the matching capability and its SQL test, and keep the
screen's suggestions last.
