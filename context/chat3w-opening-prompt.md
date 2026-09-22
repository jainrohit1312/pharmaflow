# Next chat — finishing the chatbot phase: the reports' own totals, the follow-ups, the business clock, and a real live probe

You are continuing work on PharmaFlow. **This is a long session by design**: the 1M window is there to be
filled, and **this session has no approval gate and no checkpoint**. The owner's instruction (2026-09-22)
is in `PROGRESS.md` and repeated here:

> *"aage ka plan bna kr dedo jisko mai new chat me kholu chatbot phase hi complete krna hai 1 milion
> context ke hisab se kro, aur kahi bhi rukna na pade"*

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

1. `PROGRESS.md` — the "Current Phase" block, and the **chatbot's owner-intelligence work** paragraph
   with the four commits and the measured baselines
2. `context/chat3v-summary.md` — what the last session did, and its seven open items. **Item 1 is the
   chunk this session starts with.**
3. `context/chatbot-owner-brief.md` — the brief itself, **its §5 gap table** (which rows are done and
   which are not) and **its §7 time-and-comparison rules** and **§12 acceptance scenarios**
4. `DECISIONS.md` → **D-089** (all five parts), **D-026/D-053** (the rules the chatbot answers under),
   **D-082** (a new SQL test is run against hosted), **D-046/D-047** (the alert sources the envelope
   chunk changes)
5. `supabase/migrations/20260919000027_phase5_alert_sources.sql` and `…000029_phase5_chat_aggregates.sql`
   — **the two reports that already carry `{meta, rows}` and the two that do not.** Read all four before
   you touch any of them
6. `supabase/functions/chat-sql-agent/` — `schema.ts`, `answer.ts`, `handler.ts`, and their three test
   files. `answer.ts` is where a sentence and the query it describes are decided; read `effectiveParams`
   and the `Sentence` maps before changing either
7. this file

Output a 5-line understanding check: the phase you are doing, the last session's deliverables, the
environment, two load-bearing dependency pins, and what you are about to build. **Then build.**

## WHERE THE PROJECT STANDS

Phases 0-5 done, 6.5a/6.5c COMPLETE, **7a COMPLETE**. Hosted reads **49 = 49**, and
**`chat-sql-agent` is deployed** (version 3, 2026-09-22). **The chatbot brief is the live workstream and
its Phase A is ~70% done**; the plan's own next phase (6.5b, the receiver app) is **postponed to the
very end** by the owner's instruction above.

**Baseline at this handoff: 1087 Flutter tests, 209 Deno tests, all passing, at `e860637`** (pushed).
The SQL suite is 17 files with a SUMMARY line, 0 FAIL and none `ABORTED` at the 49-migration state.

## DECISIONS ALREADY TAKEN — do not stop to ask

| The question that would have blocked you | The answer to build with, and why |
|---|---|
| **Which timezone is "today"?** | **`Asia/Kolkata`.** The brief proposes exactly this (*"default Asia/Kolkata for this deployment proposal"*) and the pharmacy's day is an IST day. One mechanism, in SQL (§3) — not a per-report `'Asia/Kolkata'` literal. |
| **What does the exact total cost us?** | **A migration plus the alert screens, in the same chunk.** The two `00027` reports change their return shape, so `alert_payloads.dart`, both repositories and their tests move with them (§1). |
| **May the function be deployed and the reports pushed?** | **Yes** — the owner said so, and the migration must reach hosted for its own SQL test (D-082's lesson). Push the commits, deploy the function, and re-verify. |
| **Hindi script — do it or defer it?** | **Only if the window is still wide after §1–§3** (§4). The owner chose two languages on 2026-09-22, so this is the least urgent item in the phase. |
| **Does Phase B start here?** | **No.** Phase B's first half is a **tenancy** change (multi-outlet membership) and it needs the owner's word on the model, which the brief's §2 records as unasked. §6 below names the one **additive, tenancy-free** slice that is legitimate to start if §1–§4 are all done. |
| **May anything be sent or posted?** | **No.** The chatbot reads and never writes; nothing in this session sends a message, posts a payment or adjusts stock. |

## SCOPE — in this order, and keep going

### 1. The two alert reports state their own rule (the `{meta, rows}` envelope) — MIGRATION `00050`

**This is the last of the three defects the brief found, and the only one still open.** In
`supabase/migrations/20260922000050_phase5_alert_envelope.sql`:

- **`low_stock_products`** and **`expiring_batches`** answer in the **same `{meta, rows}` shape**
  `top_products` and `dead_stock` already carry (`00029`) — no third shape, no flag, no second function.
  A verification enumerator in the envelope is not optional: **`low_stock_products` must state
  `rule: 'total_qty < min_stock_level'`** and `expiring_batches` **`horizon_days`** (the *clamped* value
  it actually queried) and **`as_of`**. The copy and the predicate drifting apart is exactly the defect
  D-089 §2 repaired by hand; this is how it stops being possible.
- **The totals must be the whole set, not the page**: `total_count` from its own aggregate over the same
  predicate, `returned_count` from the page, `has_more` from the two. A `total_count` computed from
  `jsonb_array_length(rows)` would be the same lie in a new place.
- **`limit`** in the envelope is the clamped cap that ran.
- Copy `00027`'s guarded grant/revoke `do $$` block, match `00029`'s comment style, and **update
  `comment on function` for both** — the old comments still say "at or below", which is the rule the copy
  no longer claims.
- **The carry, in the same chunk**: `app/lib/data/models/alert_payloads.dart` (the two decoders read
  `rows`), `notifications_repository.dart`, `inventory_repository.dart`, `low_stock_controller.dart`, the
  cards/screens that read the list, the fakes, and the Dart tests. **The four doc comments that still say
  "at or below"** (`alert_payloads.dart`, `alert_providers.dart`, `notifications_repository.dart`,
  `notifications_screen.dart`) are in this blast radius and move now.
- **`answer.ts`**: the three counting list sentences use the envelope's total. When `has_more` is true
  they say **`Showing the N worst of M`** (with the marker where it belongs); when it is false the count
  is exact. `effectiveParams` keeps resolving the cap — that is what makes `has_more` trustworthy.
- **A SQL test** (`phase5_alerts.sql` re-expressed, or a new file added to `run_tests.sql`): the total is
  the whole set (fixture with more rows than the cap), `has_more` both ways, the effective horizon, the
  rule string, and tenant isolation both directions.
- Then **`supabase db push --yes`** and run the touched test files **against hosted** (D-082). **A hosted
  failure may be pre-existing** — these files assert fixture state and the hosted database holds the
  owner's real catalogue: prove any failure is pre-existing before treating it as a regression.

### 2. The follow-up chips

Under **the newest answer only** (a chip under an old answer mid-conversation is noise — `_Transcript`
knows the order, so pass `isNewest`). Keep it structural: a Dart map from the answering report to one or
two questions, rendered as chips that **ask the question through the screen's existing `_ask`**. No model
call, no new server surface.

**The promise must be structural**: every question the map offers must be one of `chatExampleQuestions`
(the closed set the classifier can answer — D-026), asserted by a test. A follow-up that could not be
answered is a promise this feature cannot keep, and a chip is a promise. The chips are the *user's* words
and are therefore **not** translated (`AnswerLanguage` is about the answer).

### 3. The business clock, and the period the answer states

**Today, in this project, is the database server's UTC day** — so between 00:00 and 05:30 IST every
"aaj" figure belongs to yesterday, and the brief's very first acceptance scenario is about exactly that
boundary. One mechanism, in SQL:

- **A `public.business_today()`** (or equivalently named) function returning
  `(now() at time zone 'Asia/Kolkata')::date`, and **every report that means "today" uses it**:
  `low_stock_products` (nothing, but check), `expiring_batches`'s horizon and `as_of`, `top_products`'s
  rolling window default, `dead_stock`'s `as_of`/`v_cutoff`, and `report_summary`'s
  `coalesce(p_from, current_date)` / `coalesce(p_to, current_date)`. A per-report literal is the second
  mechanism this repo forbids.
- **State it where a reader can see it**: the `timezone` (and, for the list reports, the resolved `as_of`)
  in the envelope's `meta`; the client's provenance line gains it, because the brief asks for
  *"scope and period"* on every answer and a period is meaningless without its boundary.
- **Re-express, never relax**: this changes committed reports' semantics, so the SQL assertions about
  "today" move with it and D-089's `effectiveParams` seam stays exactly as it is.
- A SQL assertion for the boundary itself, so the *reason* for the change is pinned and not just the
  value.

### 4. Hindi script — only if the window is still wide

`ANSWER_LANGUAGES` gains `'hi'`, and then you walk the **compile errors** until every `Sentence` map in
`answer.ts` has one. Nothing else moves: the request field, the wire name and the chips are all there
(one more chip, no layout change). Record either way — built, or deliberately not.

### 5. Verify live, as you go — this is the one thing no session has ever done

The owner has said testing is allowed, so:

- **Deploy `chat-sql-agent`** after the last function change and **smoke-test it**: `curl -X OPTIONS`
  should answer `204` with its CORS headers.
- **Try an answer path probe.** It needs a *signed-in user's* access token; look for a sanctioned test
  credential in the repo's own ignored files (`app/.env`, `.qwen/tmp/`) before concluding there is none,
  and **never invent or guess one**. If there is one, ask a real question in both languages and paste the
  raw responses — that also settles the `subject` enum's prompt-shaped risk (`context/chat3v-summary.md`
  open item 4), which is the one thing tests cannot.
- **If there is no token**, say so plainly and verify what *can* be verified: the reports themselves
  through `supabase db query --linked` (note that this runs as `postgres`, so it proves the SQL and
  **not** the tenant scoping), `supabase migration list` (**50 = 50**), and the touched SQL tests on
  hosted.
- `flutter test` and `deno test supabase/functions` before every commit, not only at the end.

### 6. If the window is genuinely still wide: the product stock lookup

The brief's most-asked capability that has no report at all (`product_stock_lookup`, its §5 row *"specific
product stock is outside the five-RPC schema"*; Direction 04's Q025–Q032). **It is the only Phase B item
that is additive and tenancy-free** — no membership, no cross-outlet scope — so it is the legitimate
stretch. The rules, because a medicine name is the first free-text thing this feature would ever accept:

- **The model may extract a product NAME string** (a new declared parameter, scalar, bounded in length).
  It never touches SQL: the *report* takes `p_query text` and resolves it — exact name, then
  `product_aliases`, then trigram — inside the caller's own pharmacy.
- **Never substitute.** An unknown name, or an ambiguous one (Dolo 650 vs Dolo 500), is a **refusal whose
  sentence names what it could not choose between**. The brief's acceptance scenario 8 is exactly this,
  and a confidently wrong medicine is the worst answer this feature could give.
- **Sellable stock is not physical stock**: state which quantity is being shown and why (the brief's
  Direction 04 makes this an explicit gap, so an honest sentence beats a definitive one).
- Add the report + its template + its tests, keep D-053 (the model produces no numeral), and keep the
  `unsupported` path intact for everything else.

## WHAT MUST NOT BREAK

- **D-026 and D-053**: the model picks from a closed set and never produces a numeral; the sentence is
  code, filled from the report's own envelope. **A language, a timezone or a total must not become a
  second place a figure is written.**
- **A question is never markup.** The marker is the server's and the client's reader is the only thing
  that reads it.
- **The sentence and the query it describes come from one object** (`effectiveParams`). A new parameter
  goes through there or the two can drift apart again.
- **The counter, the approvals rail and the alerts keep working.** The chatbot reads and never writes,
  and the alert screens are readers of the two reports §1 changes — that is why they ship together.
- **Every business table's write grant is a decision, not an oversight.** This session should not need to
  change one.

## RULES

- Write FULL file contents, never truncate. Reproduce a `create or replace` body from the applied
  migration's own text and **diff it** — `.qwen/tmp/pg7a/build_00048.js` and `build_00049.js` are the
  pattern, and `build_00046.js`'s header records the `$`-in-a-replacement-string trap.
- One mechanism, never a second one for one action.
- Every changed assertion documented **before → after** in the reply **and the commit message**; no
  assertion deleted, skipped or loosened; the test count may not fall.
- **A file that ERRORs prints no SUMMARY line and no FAIL line**, so a run that greps for `FAIL` reads it
  as green. Count the `psql:/repo/supabase/tests/…` header lines and check none says `ABORTED` as well
  as grepping for FAIL.
- `dart format lib test` before the gates; `flutter analyze` covers `test/**` too (it has bitten this
  project five times — see the memory note about fixture lints).
- **Commit in coherent chunks and push as you go** — the owner has authorised it, and a pushed commit is
  what survives a lost window.

## ENVIRONMENT (FIXED)

- Workspace `C:\Projects\PharmaFlow\`; remote `origin` = `https://github.com/jainrohit1312/pharmaflow.git`
  (**`git push` works from here**).
- Supabase **hosted only** (ref `yeroxzkpmodbzcvjlqwd`), no Docker for Supabase; migrations by
  `supabase db push --yes`. **49 = 49** now; §1 makes it **50 = 50**.
- The **local SQL harness lives at `.qwen/tmp/pg7a/`** and the container `pharmaflow-pg7a` has been up for
  days — reuse it (memory: *Verify the SQL suite locally*). `run_all.sql` lists `00001`-`00049`:
  **add `00050` there and its test to `run_tests.sql`**. Run order: `reset` → `stub` → `run_all` → `seed`
  → `run_tests`.
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0 — **do not touch the pinned ranges**, and do
  not add a package.
- Gates: `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` → the five
  `deno check` entry points.
- **Baseline: 1087 Flutter tests, 209 Deno tests, at `e860637`.** Generated Dart is gitignored
  (`.gitignore:22`), so codegen output is never part of a commit.
- **The app must be rebuilt to see client changes**; the function must be deployed to see server ones.

## END-OF-SESSION HANDOFF (when you are near the limit)

`PROGRESS.md` updated (the chatbot paragraph, and the "Current Phase" pointer), `DECISIONS.md` updated
(the envelope's shape and its compatibility rule; the business clock; the run of the live probe and what
it proved or could not), a chat summary and the **next** opening prompt written, and a numbered list of
every file touched. **Push before you write the handoff**, so the next session starts from the remote and
not from a working tree — the owner has authorised it. If the window closed mid-chunk, say so plainly and
name the exact half-finished file rather than describing it as done.

**And when the chatbot phase is finished, the plan's own sequence resumes: Phase 6.5b (the receiver app),
then Phase 7b (hospital profit sharing) and 7c (the reports) — 6.5b is the owner's "bilkul last", so it
waits for him to say it is time.**
