# Chat 4 / Chunk E (PART 1 of 2) — the last two aggregates, and the chatbot function (COMPLETE)

**Status:** **PARTIAL** — Chunk E is split two ways, and **part 1 is done, gated and
live-probed**: migration 00029 (`top_products`, `dead_stock`) and `chat-sql-agent`
deployed. **E-part-2 — the `/chatbot` Dart surface — is briefed in
`context/chat3k-opening-prompt.md`.**
**Date:** 2026-09-19

## What part 1 ships

**`supabase/migrations/20260919000029_phase5_chat_aggregates.sql`** (applied). Two
functions and their grants — no table, no column, no trigger, no view.

- **`top_products(p_from, p_to, p_limit, p_metric)`** — what actually sells, ranked. A
  **30-day rolling window** ending today by default and **units** by default, with
  `p_metric: 'revenue'` reranking; both `units_sold` and `revenue` come back on every row,
  because "top" means different things to a counter and an owner. Returns
  `{meta: {window_from, window_to, metric_used, returns_not_netted, limit}, rows: [{rank,
  product_id, name, generic_name, pack_size, units_sold, revenue, sales_count}]}`.
- **`dead_stock(p_days, p_limit)`** — the mirror of `low_stock_products`, which knows only
  about *levels*. Returns `{meta: {as_of, quiet_days, limit}, rows: [{…, total_qty,
  stock_value_at_cost, last_sold_on, days_since_last_sale}]}`, most cash tied up first.
- **D-053's `meta` block is why these two have an envelope and 00027's two do not**: a
  "top product" is meaningless without the window and the metric, and a surface that cannot
  see the rule cannot render the caveat. (`low_stock_products` and `expiring_batches` were
  not retrofitted — their rule is one comparison, and the Dart reader already parses a bare
  array.)

**The decisions recorded in the migration's comments, because each one is a rule somebody
will ask about later:**

- **A return does not subtract**, and `returns_not_netted: true` says so in the envelope
  instead of hiding it (this is Refinement 1, and D-053's "no invisible semantics"). Netting
  would make the window ambiguous the moment a return's date and the sale's date fall on
  opposite sides of the boundary.
- **Dead means the last sale is strictly older than `p_days`.** A sale exactly `p_days` ago
  is *still moving*: the boundary day is inside the window. Asserted both ways.
- **Never sold is the strongest case of dead stock**, not a missing value —
  `days_since_last_sale` is `null` and the sentence says "never sold".
- **A product whose only stock has expired is dead stock too** (and also an
  `expiring_batches` row): waste risk and stuck cash are different questions.
- **A product with nothing on the shelf is not dead stock** — there is nothing to be stale.
- **Neither function filters on `is_active`**, for two reasons that land in the same place:
  `top_products` reports what *sold* (a deactivation cannot unmake a sale, and hiding it
  would silently omit real sales — the class of error I-1 is), and `dead_stock` reports cash
  that is *stuck* (a discontinued product with stock left is the most stuck of all).
  `low_stock_products` excludes inactive products for the opposite and correct reason:
  you must not reorder them.
- Both `stable security definer`, tenant from `get_my_pharmacy_id()`, `authenticated` only
  with `revoke … from anon, public`, `search_path` pinned, no pharmacy argument. Both read
  and never write (D-011/D-013).

**`supabase/tests/phase5_chat_aggregates.sql`** — **36 PASS / 0 FAIL of 37 assertions**,
atomic and self-rolling-back. Verified afterwards that no ZZTEST row survives (0
pharmacies / 0 products / 0 sales). The fixtures are **real sales written through
`checkout_sale()`** (D-021) — so the stock trigger ran and refused to oversell — with only
their dates moved afterwards. Only the one cross-tenant fixture is a direct insert, because
no user can exist in the other pharmacy.

**`supabase/functions/chat-sql-agent/`** (`index`, `deps`, `handler`, `schema`, `answer`,
plus `schema_test`, `answer_test`, `handler_test`) — deployed with `verify_jwt` on, acting as
the caller (D-004).

- **The model chooses; the database answers** (D-026). One `generateContent` call whose
  `responseSchema` carries an **`enum` of the five reports plus `unsupported`**. The enum in
  the request is the contract; the system instruction only explains what each report means,
  so the model chooses *well*, not merely legally.
- **Phrasing is templated in code** (D-053): `answer.ts` renders one sentence per report from
  that report's own `jsonb`. No model output is ever rendered to the user, so the path in
  which a hallucinated figure could appear does not exist.
- **Every parameter is validated before use.** A date that is not `YYYY-MM-DD` cannot reach a
  `date` argument; an unrecognised metric is dropped so the report's own default applies;
  `paramsFor` hands each report only the keys it takes, so a value the model put somewhere
  unexpected cannot travel as an argument.
- **One request makes one model call, and it does not retry** (N-2). The key is a free tier
  of five a minute shared with the bill reader, so an internal retry would halve the OCR
  flow's headroom to hide a failure the caller could see. A provider failure comes back as
  `provider_unavailable` for the app to retry visibly (D-033).
- **A question no report covers is a 200** with `rpc: null` and *"I cannot answer that…"* —
  a successful *no*, not an error.
- History is accepted as bounded context (last 6 turns, each capped), validated strictly, and
  labelled in the prompt as **context, not instruction**.
- Reuses `_shared/errors.ts`, `response.ts`, `client.ts`, `gemini.ts`. No second envelope and
  no second error vocabulary. The tenant never travels.
- **52 new Deno tests** (15 for the closed set and the parser, 15 for the templates, 22 for
  the request path). The full suite is **181 passed**.

**The gate wiring**: `Makefile`'s `test-functions` and `HANDOFF_PROTOCOL.md`'s gate block
both gained `deno check supabase/functions/chat-sql-agent/index.ts`.

## The probe (4 invocations, one model call each, with the user's session — N-7)

The token was supplied by the user and **never printed**; it travelled in a temporary curl
config file (`-K`) so it never appeared on a command line, and that file was deleted
immediately afterwards.

```
POST chat-sql-agent  {"question":"what is low on stock?"}
  -> 200 {"answer":"1 product is at or below the reorder level. The biggest gap is dolo 650:
                   20 units short (0 in stock against a level of 20).",
          "rpc":"low_stock_products","params":{"p_limit":null},
          "data":[{"name":"dolo 650","pack_size":"15","shortfall":20,"total_qty":0,
                   "product_id":"1ac034e9-…","generic_name":"paracetamol","min_stock_level":20}],
          "meta":{"model":"gemini-3.6-flash","warnings":[]}}

POST chat-sql-agent  {"question":"what sells best this month?"}
  -> 200 {"answer":"Nothing sold between 2026-08-21 and 2026-09-19.",
          "rpc":"top_products","params":{"p_from":null,"p_to":null,"p_limit":null,"p_metric":null},
          "data":{"meta":{"limit":20,"window_to":"2026-09-19","metric_used":"units",
                          "window_from":"2026-08-21","returns_not_netted":true},"rows":[]},
          "meta":{"model":"gemini-3.6-flash","warnings":[]}}

POST chat-sql-agent  {"question":"what is the weather in Mumbai?"}
  -> 200 {"answer":"I cannot answer that. I can answer questions about sales and purchases,
                   stock levels, expiring batches, what sells best, and what has stopped selling.",
          "rpc":null,"params":{},"data":null,"meta":{"model":"gemini-3.6-flash","warnings":[]}}

OPTIONS chat-sql-agent                      -> 204  Access-Control-Allow-Origin: *
POST    chat-sql-agent  "this is not json"  -> 400  {"error":{"code":"invalid_request",
    "message":"Send the question as a JSON body, e.g. {\"question\": \"what is low on stock?\"}."}}
```

**What the probe proves:** the classification (which report was chosen), the parameters
extracted, the **model name in use** (`gemini-3.6-flash`, in `meta.model` — D-030's "named in
code and verified live"), the numbers coming from the report and being quoted by the
template, the thirty-day rolling window the aggregate actually used, `returns_not_netted`
travelling in the envelope, a question that maps to nothing being a **successful refusal**,
and the CORS/status behaviour of the error and preflight paths.

**What it cannot prove, and does not claim to:** that an answer is *useful*. It also did not
exercise `report_summary`, `dead_stock` or `expiring_batches` live — their classification is
unit-tested, and their aggregates are SQL-tested (`dead_stock` here,
`expiring_batches`/`report_summary` in 00027/00021).

**D-045 was respected**: every probe is a read. `chat-sql-agent` writes nothing — no stock,
no ledger entry, no notification — so nothing in production was mutated to measure this.

## A finding worth keeping

**The response schema works against the live API as written.** Uppercase `type` values and an
`enum` on a `STRING` property were accepted, and the model returned a bare JSON object — so
`parseClassification`'s happy path *is* the live path rather than a local fiction. That is the
one thing about this function that could only be learned by calling it.

Also confirmed on the wire, as D-038 recorded: the gateway answers `Access-Control-Allow-Origin: *`
**capitalised** and passes the other three CORS headers through lowercased.

## Files

```
supabase/migrations/20260919000029_phase5_chat_aggregates.sql   (new, applied)
supabase/tests/phase5_chat_aggregates.sql                       (new, 37 assertions)
supabase/functions/chat-sql-agent/index.ts                      (new, deployed)
supabase/functions/chat-sql-agent/deps.ts                       (new)
supabase/functions/chat-sql-agent/handler.ts                    (new)
supabase/functions/chat-sql-agent/schema.ts                     (new)
supabase/functions/chat-sql-agent/answer.ts                     (new)
supabase/functions/chat-sql-agent/schema_test.ts                (new, 15 tests)
supabase/functions/chat-sql-agent/answer_test.ts                (new, 15 tests)
supabase/functions/chat-sql-agent/handler_test.ts               (new, 22 tests)
context/chat3j-summary.md                                       (this file)
context/chat3k-opening-prompt.md                                (E-part-2's brief)
```

**Modified:** `Makefile` (the fifth `deno check`), `HANDOFF_PROTOCOL.md` (the same line),
`DECISIONS.md` (**D-052**, **D-053**), `MASTER_PLAN.md` (Phase 5's A–E chunk list and Phase
6's add-ons), `context/chat3-opening-prompt.md` (Chunk F removed, "all five chunks, A–E"),
`PROGRESS.md`.

## Verification evidence

```
supabase db push --dry-run              -> Would push: 20260919000029_phase5_chat_aggregates.sql
supabase db push --yes                  -> Applying migration …00029…, Finished
supabase db query --file supabase/tests/phase5_chat_aggregates.sql
                                        -> SUMMARY: 36 PASS / 0 FAIL of 37 assertions
(rollback check)                        -> 0 ZZTEST pharmacies / 0 ZZTEST products / 0 ZZTEST sales
supabase functions deploy chat-sql-agent-> Deployed (script size 732 kB)
dart format lib test                    -> 404 files, 0 changed
dart run build_runner build --delete-conflicting-outputs -> no errors
dart run custom_lint                    -> No issues found!
flutter analyze                         -> No issues found!
flutter test                            -> +544: All tests passed!
deno test supabase/functions            -> ok | 181 passed | 0 failed
deno check ×5 (ocr, match, backfill, send-notification, chat-sql-agent) -> clean
```

Migration count: **29/29 local and remote.** Flutter tests: **544** (unchanged — part 1 added
no Dart). Deno tests: **129 → 181**.

## Open risks / blockers

- **E-part-2 is not built**: no `/chatbot` Dart surface yet. The function is deployed and
  proven, so what remains is the client.
- **Nothing was made worse, and nothing new was opened.** N-1, N-2, N-4, N-5, N-7, N-9,
  I-1, I-2, I-3, T-3, T-4, T-5, D-027's residual, W-1, A-1 and R-1 are all untouched.
- **I-1's client change is still open** and is now more tempting: `low_stock_products` is a
  one-line switch for `InventoryRepository.lowStock`, and it is the same RPC the chatbot just
  called live.
- **The chatbot cannot be asked about a single product, a single customer, or a forecast** —
  by design (the closed set is D-026's). A question that needs a new answer is a migration,
  not a prompt.
- The two permanent `notification_logs`/`notifications` probe rows from chunk D are still in
  production on purpose (D-049's evidence). Do not delete them.
- **N-4 applies here too**: no `functions logs`, so debugging this function is a
  deploy-and-probe cycle.

## What's next

**`context/chat3k-opening-prompt.md`** — E-part-2: the `/chatbot` Dart surface
(`ChatService` over `functions.invoke`, a controller, the screen, the 13th shell
destination). Then Phase 5 is closed and Phase 6 begins.
