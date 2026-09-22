# Next chat — the product a person names, the third language, and one live answer

You are continuing work on PharmaFlow. **This is a long session by design**: the 1M window is there to
be filled, and **this session has no approval gate and no checkpoint**. The owner's instruction
(2026-09-22) is recorded in `PROGRESS.md` and repeated here:

> *"chatbot phase hi complete krna hai 1 milion context ke hisab se kro, aur kahi bhi rukna na pade"*

and, in the same breath:

> *"ni abb to mene gemini api me amount feed kr diya hai, abb koi delay ni aaiga reply krne me, aur tokens
> use to honge hi agat testing krni hai to, wo tum kr skte ho"* — **pushing, deploying and live testing
> are authorised for this work**, and
> *"receviver app wala 6.5b abhi ni krna hai wo bilkul last me krenge"* — **Phase 6.5b is postponed to
> the very end and is NOT part of this session.**

Do not stop to ask anything. §"Decisions already taken" below answers the questions that would otherwise
have blocked you; take those answers, record them as decisions, and build. The only thing that ends this
session is the window.

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — the "Current Phase" block, and **the chatbot's Phase A paragraph** with its three
   commits and the measured baselines
2. `context/chat3x-summary.md` — what the last session did, and its seven open items. **Item 1 is the
   small chunk this session should finish; item 2 is the one you may finally be able to close.**
3. `context/chatbot-owner-brief.md` — the brief itself, **§3's Direction 04** (current stock and
   availability), **its §5 gap row** *"specific product stock is outside the five-RPC schema"*, and
   **§12's acceptance scenario 8** (an ambiguous product name)
4. `DECISIONS.md` → **D-090** (all three parts, and its "what was NOT done" section), **D-089**
   (especially §4 `effectiveParams` and §5 the language), **D-026** and **D-053** (the rules an answer
   lives under), **D-082** (a new SQL test is run against hosted)
5. `supabase/migrations/20260922000050_phase5_alert_envelope_and_business_clock.sql` — the envelope and
   `business_today()`, which every report this session touches must use rather than `current_date`
6. `supabase/migrations/20260919000023_phase5_product_matching.sql`,
   `…000024_phase5_alias_learning.sql` and `…000026_phase5_vector_floor.sql` —
   **the matcher that already resolves a typed name to a product**, and the similarity floor it was
   measured against. Read all three before you design the lookup: this session must not build a second
   matcher.
7. `supabase/functions/chat-sql-agent/` — `schema.ts`, `answer.ts`, `handler.ts` and their three test
   files. `answer.ts` is where a sentence and the query it describes are decided; read
   `effectiveParams`, `listTotals` and the `Sentence` maps before changing any of them
8. this file

Output a 5-line understanding check: the phase you are doing, the last session's deliverables, the
environment, two load-bearing dependency pins, and what you are about to build. **Then build.**

## WHERE THE PROJECT STANDS

Phases 0-5 done, 6.5a/6.5c COMPLETE, **7a COMPLETE**. Hosted reads **50 = 50**, and **`chat-sql-agent`
is deployed (version 4, 2026-09-22)**. **The chatbot brief's Phase A is COMPLETE except Hindi script**;
the plan's own next phase (6.5b, the receiver app) is **postponed to the very end** by the owner's
instruction above, and Phase B's tenancy half still needs his word on the model.

**Baseline at this handoff: 1110 Flutter tests, 209 Deno tests, all passing, at `9bed4ad`** (pushed).
The SQL suite is 24 files with a SUMMARY line on 17 of them, 0 FAIL and none `ABORTED` at the
50-migration state.

## DECISIONS ALREADY TAKEN — do not stop to ask

| The question that would have blocked you | The answer to build with, and why |
|---|---|
| **How does the lookup resolve a name?** | **With the machinery that already exists** — exact name, then `product_aliases`, then the trigram/vector matcher `match_products()` uses, at the floor migration `00026` measured. A second matcher is the second mechanism this repository forbids, and the OCR flow already learned the corrections this one would have to learn again. Read the three migrations in STEP 0 §6 first and reuse their guts (a shared helper is the right shape if the bodies do not fit inside one report). |
| **What does the model fill in?** | **A product NAME string, and nothing else** — a new declared parameter, scalar, bounded in length (120 is enough for any product name in this catalogue). It never touches SQL. The report takes `p_query text` and does the resolving, inside the caller's own pharmacy. D-026 and D-053 both hold: the model picks a report and fills a declared parameter, and **it never produces a numeral**. |
| **What does an unknown or ambiguous name do?** | **Refuse, in a sentence that names what it could not choose between.** Never substitute: the brief's acceptance scenario 8 is exactly the Dolo 650 / Dolo 500 case, and a confidently wrong medicine is the worst answer this feature could give. An unknown name and a two-way tie are the same *kind* of answer — a refusal — and it is a **200 with `rpc: null`-style honesty or its own sentence**, not an error. |
| **Sellable or physical stock?** | **State which, and why.** `product_stock.total_qty` counts every batch with quantity left, including expired ones, so it is *not* what a pharmacist can sell — the brief's Direction 04 makes that an explicit gap. Return both figures (a sellable quantity and a total) and let the sentence name the one it quotes and say what the other is. An honest sentence beats a definitive one. |
| **Does the app need anything?** | **One line at most.** The chatbot screen renders whatever sentence the server writes, so the only client change is `reportLabel`'s map in `chat_response.dart` gaining the sixth name. That is why this slice is the right stretch: it is additive on both sides. |
| **May the function be deployed and the migration pushed?** | **Yes** — the owner said so, and a new report must reach hosted for its own SQL test (D-082's lesson). Push the commits, deploy the function, and re-verify. |
| **Hindi script — do it this time?** | **Yes, and it is small.** The `Sentence` maps make it compiler-guided: add `'hi'` to `ANSWER_LANGUAGES` and every sentence in `answer.ts` fails to type-check until it has one (~40 strings), plus one `AnswerLanguage` value on the client (the chips iterate the enum, so the control grows by itself). The marker contract and the English-is-byte-identical tests already loop over `ANSWER_LANGUAGES`, so they cover the new language the moment it exists. |
| **Does Phase B start here?** | **No.** Phase B's first half is a **tenancy** change (multi-outlet membership) and it needs the owner's word on the model, which the brief's §2 records as unasked. The lookup below is the one **additive, tenancy-free** Phase B slice, so it is the legitimate part to build. |
| **May anything be sent or posted?** | **No.** The chatbot reads and never writes; nothing in this session sends a message, posts a payment or adjusts stock. |

## SCOPE — in this order, and keep going

### 1. The product stock lookup — MIGRATION `00051`

The brief's most-asked capability that has no report at all. One additive reader, its template, and its
tests. **Read `20260919000023`/`…24`/`…26` before writing anything** — the matcher, the alias table and
the measured floor are already there.

- **`public.product_stock_lookup(p_query text)`**, `stable`, `security definer`, `search_path = public`,
  the tenant from `get_my_pharmacy_id()` and **never an argument** (D-004). It resolves `p_query`
  inside the caller's pharmacy only: an exact (normalised) name, then `product_aliases`, then the
  matcher's own similarity at its measured floor. **`normalize_product_name()` (migration `00011`) is
  the normaliser** — do not write a second one.
- **It answers in the `{meta, rows}` shape with the counts the others carry** (D-090 §1): the resolved
  `query`, the `match` method that resolved it (`exact` / `alias` / `similar`), the candidates it
  considered when it could not choose, and `as_of`/`timezone` from `public.business_today()`. A read
  that means "now" reads the one clock (D-090 §2).
- **Three outcomes, and each is a real answer rather than an error**: resolved (one row per batch with
  its expiry, plus the product's totals), **ambiguous** (the candidates it could not choose between,
  so the sentence can name them), and **unknown**. An ambiguous or unknown answer must be *renderable*
  — the model is not asked for a clarification, and there is no second turn.
- **The sentence is `answer.ts`'s, in each language** (D-053): the resolved product's name, the
  quantity, and **which quantity it is** ("sellable" vs "on the shelf, including batches that have
  expired"). Keep the marker contract — the figures worth circling are marked, and a sentence with no
  finding carries no marker. The refusal sentence **names what it could not choose between**, and is
  its own sentence rather than the generic `UNSUPPORTED`.
- **`schema.ts`**: `SUPPORTED_RPCS` gains `product_stock_lookup`; the enum, the system instruction and
  a new `product_name` field (a bounded scalar) go with it. **`effectiveParams`** gains a case (it
  resolves the length bound and passes nothing else), and **`paramsFor`** maps the name to `p_query`
  and nothing else — the seam D-089 §4 exists for.
- **A SQL test** (`phase5_product_lookup.sql`, added to `run_tests.sql`): an exact name, an alias, a
  near-miss above and below the floor, two products a name could mean (the refusal), a name that
  matches nothing, tenant isolation both directions, that the sellable and total quantities differ for
  a product with an expired batch, and that reading moves nothing. Assertions are **relational** where
  the pharmacy's own catalogue could win a page — hosted holds the owner's real products (this bit the
  last session twice; see `context/chat3x-summary.md`).
- Then **`supabase db push --yes`** and run the new test file **against hosted** (D-082).

### 2. Hindi script — the small compiler-guided chunk

- `ANSWER_LANGUAGES` in `schema.ts` gains `'hi'`; the compiler then names every sentence that has not
  been written in it. Fill all of them, **in Devanagari**, keeping the business nouns in English where
  Hinglish does, and keep the marker contract (the existing tests loop over `ANSWER_LANGUAGES` and will
  check it for you).
- `validateLanguage('hi')` currently returns `'en'` and its assertion in `handler_test.ts` moves to
  `'hi'`; the "unknown language is English" half stays (try `'mr'`).
- The client: `AnswerLanguage` gains `hindi('hi', 'हिंदी')`. The language bar iterates the enum, so the
  control grows by itself — check that its widget test says three chips now, not two.
- **Record the owner's choice**: he picked English + Hinglish on 2026-09-22 (D-089 §5) and has not
  asked for Hindi script since. Building it is the brief's own last item and is harmless — but if you
  decide against it, say so plainly in `DECISIONS.md` rather than leaving it ambiguous.

### 3. Verify live, as far as the repository allows

- **Deploy `chat-sql-agent`** after the last function change and smoke-test it: `curl -X OPTIONS`
  should answer `204` with its CORS headers.
- **Look once more for a sanctioned test credential** in the repo's ignored files (`app/.env`,
  `.qwen/tmp/`) before concluding there is none — the last session found only `app/.env.example`.
  **Never invent or guess one.** If one exists, ask a real question in every language and paste the
  raw responses; that also settles the `subject` enum's prompt-shaped risk, which is the one thing
  tests cannot.
- If there is no token, say so plainly and verify what *can* be verified: the new report through
  `supabase db query --linked` (note that this runs as `postgres`, so it proves the SQL and **not** the
  tenant scoping — the committed test file is what proves that), `supabase migration list`
  (**51 = 51**), and the touched SQL tests on hosted.
- `flutter test` and `deno test supabase/functions` before every commit, not only at the end.

### 4. If the window is genuinely still wide

The brief's Phase B is otherwise a **tenancy** question (multi-outlet membership, its §6) and its
§5 records the owner has not been asked. Do not build it, and do not invent an answer: **record the
question, the two candidate models with their costs, and what it would change**, in `DECISIONS.md`'s
open-questions idiom, so the owner can answer it in one line next time. That is worth more than
another slice, because it is the one thing this session cannot decide for him.

## WHAT MUST NOT BREAK

- **D-026 and D-053**: the model picks from a closed set and never produces a numeral; the sentence is
  code, filled from the report's own envelope. **A new report, a new language or a new figure must not
  become a second place a number is written.**
- **The tenant is never an argument** (D-004), and a caller must not be able to name another
  pharmacy's product into visibility — the lookup resolves **inside** the caller's own pharmacy, which
  is why the same name in two pharmacies is two answers.
- **Never substitute.** An unknown or ambiguous name is a refusal that names what it could not choose
  between. A wrong medicine is the worst answer this feature can give.
- **A question is never markup.** The marker is the server's and the client's reader is the only thing
  that reads it.
- **The sentence and the query it describes come from one object** (`effectiveParams`). A new parameter
  goes through there or the two can drift apart again.
- **One clock**: a report that means "today" reads `public.business_today()`, never `current_date`.
- **The counter, the approvals rail and the alerts keep working** — `low_stock_products` and
  `expiring_batches` now answer `{meta, rows}` and their screens read `AlertPage`, so a change to
  either report's shape moves both.
- **Every business table's write grant is a decision, not an oversight.** This session should not need
  to change one.

## RULES

- Write FULL file contents, never truncate. Reproduce a `create or replace` body from the applied
  migration's own text and **diff it** — `.qwen/tmp/pg7a/build_00050.js` is the pattern (it also
  *asserts* that each load-bearing line of the original survives), and `build_00046.js`'s header
  records the `$`-in-a-replacement-string trap.
- One mechanism, never a second one for one action.
- Every changed assertion documented **before → after** in the reply **and the commit message**; no
  assertion deleted, skipped or loosened; the test count may not fall.
- **A file that ERRORs prints no SUMMARY line and no FAIL line**, so a run that greps for `FAIL` reads
  it as green. Count the `psql:/repo/supabase/tests/…` header lines and check none says `ABORTED` as
  well as grepping for FAIL.
- `dart format lib test` before the gates; `flutter analyze` covers `test/**` too.
- **Commit in coherent chunks and push as you go** — the owner has authorised it, and a pushed commit is
  what survives a lost window.

## ENVIRONMENT (FIXED)

- Workspace `C:\Projects\PharmaFlow\`; remote `origin` = `https://github.com/jainrohit1312/pharmaflow.git`
  (**`git push` works from here**).
- Supabase **hosted only** (ref `yeroxzkpmodbzcvjlqwd`), no Docker for Supabase; migrations by
  `supabase db push --yes`. **50 = 50** now; §1 makes it **51 = 51**.
- The **local SQL harness lives at `.qwen/tmp/pg7a/`** and the container `pharmaflow-pg7a` has been up
  for days — reuse it (memory: *Verify the SQL suite locally*). `run_all.sql` lists `00001`-`00050`:
  **add `00051` there and its test to `run_tests.sql`**. Run order: `reset` → `stub` → `run_all` →
  `seed` → `run_tests`.
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0 — **do not touch the pinned ranges**, and do
  not add a package.
- Gates: `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` → the five
  `deno check` entry points.
- **Baseline: 1110 Flutter tests, 209 Deno tests, at `9bed4ad`.** Generated Dart is gitignored
  (`.gitignore:22`), so codegen output is never part of a commit.
- **The app must be rebuilt to see client changes**; the function must be deployed to see server ones.

## END-OF-SESSION HANDOFF (when you are near the limit)

`PROGRESS.md` updated (the chatbot paragraph, and the "Current Phase" pointer), `DECISIONS.md` updated
(a new D-091 for the lookup and the language; the tenancy question if you got to §4), a chat summary and
the **next** opening prompt written, and a numbered list of every file touched. **Push before you write
the handoff**, so the next session starts from the remote and not from a working tree — the owner has
authorised it. If the window closed mid-chunk, say so plainly and name the exact half-finished file
rather than describing it as done.

**And when the chatbot brief is finished, the plan's own sequence resumes: Phase 6.5b (the receiver
app), then Phase 7b (hospital profit sharing) and 7c (the reports) — 6.5b is the owner's "bilkul last",
so it waits for him to say it is time.**
