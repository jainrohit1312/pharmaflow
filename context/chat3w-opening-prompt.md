# Next chat — finishing the chatbot's Phase A, and the two questions that gate it

You are continuing work on PharmaFlow. **This is a long session by design**: the window is 1M, so the
work is sized to fill it rather than to stop at every checkpoint.

## STEP 0 — READ FIRST (do NOT skip)

1. `context/chatbot-owner-brief.md` — **the brief this workstream exists for.** Read it as it was
   written: it is a third-party review pinned 60 commits back, this file records how each of its claims
   reads now, and **its §2 conflicts and §5 open items are the ones that matter most**
2. `context/chat3v-summary.md` — what the last session did in three commits, and its six open items
3. `DECISIONS.md` → **D-089** (the four parts, and what it deliberately did NOT do), D-026/D-053 (the
   rules the chatbot answers under), D-046/D-047 (the alert sources the envelope chunk will touch)
4. `supabase/functions/chat-sql-agent/` — `schema.ts`, `answer.ts`, `handler.ts`, and their three test
   files. **`answer.ts` is where a sentence and the query it describes are decided; read
   `effectiveParams` before changing anything there**
5. `PROGRESS.md` — the "Current Phase" block now carries the reorder, and `MASTER_PLAN.md` → Phase 6.5
   for the receiver app the plan still names next
6. `context/chat3v-opening-prompt.md` — **worth reading for what it scoped and did not get**: it opened
   on Phase 6.5b, and the owner set that aside

Output a 5-line understanding check: the workstream and chunk you are doing, the last session's
deliverables, the environment, two load-bearing dependency pins, and what you are about to build.
**Then put the two questions below to the owner before writing a line.**

## WHERE THE PROJECT STANDS

**Phases 0-5 are done, Phase 6.5a/6.5c are COMPLETE, Phase 7a is COMPLETE, and hosted reads 49 = 49.**
The plan's own sequence names **Phase 6.5b, the receiver app**, next — and it has **no shape written
down** (`MASTER_PLAN.md` is a stub for it).

**On 2026-09-22 the owner set the plan's sequence aside for a new workstream: the chatbot brief.** Its
Phase A is **partly done**, in three local commits (`f9be7d1`, `83cecc6`, `a4022d1`) that are **not
pushed and not deployed**:

| Phase A item | Status |
|---|---|
| Rich answers (bold on the finding, never on a question) | **done** — `f9be7d1` |
| The low-stock copy matching its own predicate | **done** — `f9be7d1` |
| A summary leading with the subject the question named | **done** — `83cecc6` |
| The sentence written from the query that actually ran (horizon, cap, "at least N") | **done** — `a4022d1` |
| **The language templates (`en` / `hi` / `hinglish`)** | **not started** |
| **Follow-up chips after an answer** | **not started** |
| **The exact `total_count` / `has_more`** | **not started** — see §3 |

## ASK FIRST — two questions, and each gates a piece of the work

### 1. What is the language setting, and where does the owner set it?

The brief asks for *"Roman Hindi/Hinglish, Hindi script, or English"*, respecting *"an explicit language
setting"*. Three things need his answer, with a recommendation each:

- **Which languages** — all three (Hinglish, Hindi script, English), or Hinglish + English first? The
  brief's own examples are Hinglish, and the owner writes Hinglish.
- **Where the setting lives** — a control on the chatbot screen (a three-way chip, immediately visible
  and testable) or a `profiles` column (a migration, and it needs a settings screen that does not
  exist). **Recommended: the screen**, because it is where the choice is felt and it needs no
  migration.
- **Whether the *renderer* is all that changes.** Recommending **yes**: the model chooses a report
  whatever language the question is in, and language only selects which template writes the sentence —
  so the Gemini call is untouched and D-053 is untouched. If he wants the classifier told the language
  too, that is a second change and should be asked about separately.

**Record his answers as a decision before building.** The templates are ~6 sentences × 5 reports × 3
languages, so the shape of the answer decides whether this is one chunk or two.

### 2. May this be deployed and pushed?

**This is the question the last session could not answer, and it now blocks more than one thing.** The
owner's brief says in as many words that it is *"not permission to … deploy changes"*, so the last
session pushed nothing and deployed nothing — which means **the owner cannot see any of the last
session's work**: the deployed `chat-sql-agent` still answers with the old sentences, and the app must
be rebuilt to render the marker. And the exact-totals chunk (§3) needs a **migration pushed to hosted**
and its own SQL test re-run there (D-082's lesson), which is a change to the live project.

Put it to him plainly: **the chatbot's Phase A is invisible until the function is deployed and the app
rebuilt — do that now, or leave everything local?** Get an explicit yes for each of: `git push`,
`supabase functions deploy chat-sql-agent`, and `supabase db push`.

## SCOPE — in this order

### 1. The language templates (the biggest remaining Phase A item)

`answer.ts`'s sentences become a function of a language the caller asks for. The shape, unless §1's
answer says otherwise: a `language` field on the request (`en` | `hi` | `hinglish`, defaulting to `en`),
carried on `ChatParams` beside `subject`, **never travelling to a report** (exactly as `subject`
doesn't), and selecting the template that writes the sentence. Every template keeps the emphasis marker
(D-089 §1) and every sentence keeps stating the query that ran (D-089 §4).

**The failure direction must be explicit**: an unknown language is `en`, not a blank sentence — the
same belt `asSubject`/`asDate` already are. And `answer_test.ts` must pin **every** language's sentences
from **one** envelope, the way the subject test does.

### 2. The follow-up chips

The brief asks for *"two useful next questions"* under an answer. Keep it structural, not a model call:
the reports are a closed set (D-026), so the follow-ups are a small map from the report that answered to
one or two questions **that report can answer**, offered as chips that ask the question. No model call
is added, and nothing is invented: a follow-up that could not be answered would be a promise this
feature cannot keep.

### 3. The exact totals — the `{meta, rows}` envelope, and its blast radius

`low_stock_products` and `expiring_batches` (`00027`) answer with a bare `jsonb` array, so the chatbot
can only say "**at least** N" for a full page. Giving them the `{meta, rows}` shape `top_products` and
`dead_stock` already carry (`00029`) is the fix, and it is **a chunk with a carry, not a tail**:

- **The migration** (`00050`) must carry `limit`, `total_count`, `has_more` and — for the expiry one —
  the effective `horizon_days` and `as_of`. **State the rule in the envelope**: `low_stock_products`
  must say `total_qty < min_stock_level`, because the copy and the predicate drifting apart is exactly
  the defect D-089 §2 just repaired by hand. Match `00029`'s own comment style, and put the reason in
  the function's comment.
- **Both Dart readers must move in the same chunk**: `alert_payloads.dart`'s two decoders,
  `notifications_repository.dart`, `inventory_repository.dart`, `low_stock_controller.dart` and the
  cards, plus their fakes and tests. **This is the deployment-ordering hazard** the last session
  deliberately avoided: the SQL change and the app change must land together, or the alert screens break
  between them. **Decide and write down what an old client sees** — and if the answer is "nothing, they
  ship together", say that in the migration's own comment.
- **The four doc comments that still say "at or below"** (`alert_payloads.dart`,
  `alert_providers.dart`, `notifications_repository.dart`, `notifications_screen.dart`) are in the
  blast radius of this chunk and should move with it.
- **A new SQL test, run against hosted**, per D-082.

### 4. Then, from the brief

Phase B onward (`context/chatbot-owner-brief.md` §4). **Phase B's first item is multi-outlet access,
which the brief's §2 records as an open design question the owner has not been asked** — do not start it
from the brief's own sketch. **And do not build the brief's §7 cost-snapshot columns**: that shape is
already D-068's, and the brief's different names for it are the second mechanism this repo forbids.

### 5. If the owner's sequence has moved back to the plan

**Phase 6.5b, the receiver app** — and `MASTER_PLAN.md` is a stub for it, so that session's first
deliverable is a **decision, not a migration**: put the five questions in
`context/chat3v-opening-prompt.md` §1 to him (what does it receive, who runs it, does it talk to the
counter, where does it run, what does it do about the D-046 credentials) and record his answers.

## WHAT MUST NOT BREAK

- **D-026 and D-053**: the model picks from a closed set and never produces a numeral; the sentence is
  code, filled from the report's own envelope. **A language must not become a second place a figure is
  written.**
- **A question is never markup.** The marker is the server's, and the client's reader is the only thing
  that reads it.
- **The sentence and the query it describes come from one object** (`effectiveParams`) — if you add a
  parameter, it goes through there, or the two can drift apart again.
- **The four `meta`-carrying reports and the two bare ones are one interface**, not two: if you retrofit
  the two, every caller moves with them.
- The counter, the approvals rail and the alerts keep working: **the chatbot reads and never writes**,
  and the alerts feature is a *reader* of the same two reports the envelope chunk changes.

## RULES

- Write FULL file contents, never truncate. Reproduce a `create or replace` body from the applied
  migration's own text and **diff it** — `.qwen/tmp/pg7a/build_00048.js` and `build_00049.js` are the
  pattern, and `build_00046.js`'s own header records the `$`-in-a-replacement-string trap.
- One mechanism, never a second one for one action.
- Every changed assertion documented **before → after** in the reply **and the commit message**; no
  assertion deleted, skipped or loosened; the test count may not fall.
- **A file that ERRORs prints no SUMMARY line and no FAIL line**, so a run that greps for `FAIL` reads
  it as green. Count the `psql:/repo/supabase/tests/…` header lines and check none says `ABORTED` as
  well as grepping for FAIL.
- **Run a new SQL test against hosted, not only locally** (D-082's lesson) — and **only if §2's answer
  said you may push**.
- `dart format lib test` before the gates; `flutter analyze` covers `test/**` too.
- **Deploy nothing, push nothing and send nothing without §2's explicit yes.** The last session's
  work is invisible because of it, and that is D-089's recorded consequence rather than an oversight.

## ENVIRONMENT (FIXED)

- Workspace `C:\Projects\PharmaFlow\`; remote `origin` = `https://github.com/jainrohit1312/pharmaflow.git`
  (**`git push` works from here** — when the owner says so).
- Supabase **hosted only** (ref `yeroxzkpmodbzcvjlqwd`), no Docker for Supabase; migrations by
  `supabase db push --yes`. **49 = 49** (the last session wrote no migration).
- The **local SQL harness lives at `.qwen/tmp/pg7a/`** and the container `pharmaflow-pg7a` has been up
  for days — reuse it (memory: *Verify the SQL suite locally*). `run_all.sql` lists `00001`-`00049`;
  **a new `00050` must be added there and its test to `run_tests.sql`** (24 files). Run order:
  `reset` → `stub` → `run_all` → `seed` → `run_tests`.
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0 — **do not touch the pinned ranges**, and do
  not add a package for the language work.
- Gates: `dart format lib test` → `dart run build_runner build --delete-conflicting-outputs` →
  `dart run custom_lint` → `flutter analyze` → `flutter test` → `deno test supabase/functions` → the
  five `deno check` entry points.
- **Baseline at this handoff: 1085 Flutter tests, 203 Deno tests, all passing, at `a4022d1`** (local).
  The SQL suite is 17 files with a SUMMARY line, 0 FAIL and none `ABORTED` at the 49-migration state.

## END-OF-SESSION HANDOFF (when you are near the limit)

Gates run and pasted raw, `PROGRESS.md` updated, a chat summary and the next opening prompt written,
`DECISIONS.md` updated (the language answer is a decision, and the envelope chunk's compatibility rule
is another), and a numbered list of every file touched. **Push before you write the handoff only if the
owner said to** — otherwise say plainly in the handoff that everything is local, and why.
