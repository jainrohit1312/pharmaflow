# Chat 3x Summary — the alert envelope, the business clock, and the follow-up chips

**Status:** the owner's chatbot brief is **finished through Phase A, except Hindi script**. The two
items the brief named as its last defects (an exact total, and the day a "today" figure belongs to)
are built and deployed; the follow-up chips are built; the live answer-path probe could not be run
because there is no sanctioned credential, and the product-stock stretch (the brief's §6) was not
started.
**Date:** 2026-09-22
**Commits:** `c434b4a` (the migration and the sentences), `707c5f0` (the app reads the envelope),
`9bed4ad` (two dead-stock fixtures sized to win their page). **All pushed to `origin/main`, the
migration applied to hosted (50 = 50) and `chat-sql-agent` redeployed (version 4).**
**Migrations:** **one** — `20260922000050_phase5_alert_envelope_and_business_clock`.

---

## What this session was asked for

`context/chat3w-opening-prompt.md`: finish the chatbot phase in one long session with **no approval
gate and no checkpoint**, working §1 → §5 in order — the `{meta, rows}` envelope for the two alert
reports and its alert-screen carry, the follow-up chips, the business clock, Hindi script if the
window stayed wide, and a live probe (the owner authorised pushing, deploying and live testing:
*"agat testing krni hai to, wo tum kr skte ho"*). §6 (the product stock lookup) was named as the
legitimate stretch. Phase 6.5b is the owner's *"bilkul last"* and was explicitly out of scope.

## What it did

**§1 and §3 are one migration, deliberately.** Both re-publish the same five `create or replace`
bodies (and the `batch_status` view), so splitting them would mean reproducing — and re-diffing —
each body twice, which is how two copies of a rule start to drift. `build_00050.js` extracts every
body from the migration that owns it and asserts each **load-bearing line** of the original survives
verbatim in the rebuilt one (the predicate, the clamp, the order), which is a stronger check than a
diff for a reshape this size.

- **The envelope.** `low_stock_products` and `expiring_batches` answer `{meta, rows}` —
  `total_count` over the whole candidate set (`count(*) over ()`, cut by `row_number() <= v_limit`,
  so the count and the page come from one predicate and one scan), `returned_count`, `has_more`,
  `limit`, `as_of`, `timezone`, plus `rule` for the first and `horizon_days` for the second.
  `dead_stock` gains the counts it never had; `top_products` the timezone.
- **The clock.** `public.business_today()` = `(now() at time zone 'Asia/Kolkata')::date`, read by
  every report that means "today" **and** by `batch_status`' bucket boundaries — the one
  non-function change, taken because a batch that expired in the pharmacy reading as `critical` for
  five and a half hours a day is the same defect the chunk exists to close.
- **The sentences.** The three counting list sentences state the envelope's total, and say
  **"Showing the N worst of M"** when the page is short of it. `isCapped` is gone; an unreadable
  envelope renders "does not understand" rather than a guessed number.
- **The app.** `AlertPage<T>` (rows + the totals) replaces the bare list through both repositories,
  both providers, the two alert sections and the reorder tab; the decoders return `null` for the old
  bare array, missing totals, a `returned_count` that does not describe the page, or a `has_more`
  that contradicts its own counts. A truncated list now says so.
- **§2, the chips** (Dart only): `chatFollowUps` maps the answering report to one or two questions
  from `chatExampleQuestions`, rendered under the **newest answer only** and asked through the
  screen's own `_ask`.

## Verification evidence (raw)

```
local SQL      reset → stub → run_all (50 migrations, no ERROR) → seed → run_tests
               24 test files produced output, 0 FAIL, none ABORTED, 17 SUMMARY lines
               phase5_alerts            50 PASS / 0 FAIL of 50      (was 26 assertions)
               phase5_chat_aggregates   38 PASS / 0 FAIL of 39
               phase4_report_summary    15 PASS / 0 FAIL (no SUMMARY; its own idiom)
dart format lib test      clean (5 files reformatted on the way)
build_runner build        no tracked output changed (generated Dart is gitignored, .gitignore:22)
dart run custom_lint      No issues found!
flutter analyze           No issues found!
flutter test              1110 passing, 0 failures          (1087 at this session's start)
deno test supabase/functions   209 passed | 0 failed        (unchanged count: re-expressed, not added)
deno check <5 entry points>    all clean

supabase migration list   local 50 = remote 50
supabase functions list   chat-sql-agent ACTIVE, VERSION 4, 2026-09-22 06:02:45 UTC
curl -X OPTIONS .../functions/v1/chat-sql-agent   → 204 + CORS headers

hosted SQL (the three touched files, after the push)
  phase5_alerts            50 PASS / 0 FAIL of 50
  phase5_chat_aggregates   38 PASS / 0 FAIL of 39
  phase4_report_summary    15 PASS / 0 FAIL

live answer-path probe    NOT RUN — no sanctioned credential exists (see below)
```

The two hosted failures the first run found were the pagination class this project has met before:
`dead_stock` orders by stock value and returns 50 rows, and on hosted the owner's own catalogue (253
quiet products) fills that page, so two fixtures valued at a few hundred rupees fell off the end
(`got null`). They were **fixed by sizing the fixture** (in the file's own idiom — its batches
already set `purchase_rate` "deliberately" so a fixture that must appear wins its page), not by
relaxing the assertion. `phase5_chat_aggregates` read 31/5 on hosted at the last handoff and reads
38/0 now.

## Assertions changed, before → after (none deleted, none loosened, no count falls)

- `phase5_alerts.sql` **26 → 50 assertions**: every `jsonb_array_elements(v_result)` reads
  `->'rows'`; the ordering checks moved from "the fixture row is first" to a **relation over the
  page** (`the leader is the maximum`), because hosted shares those tables with the owner's own
  catalogue; added the rule string, `as_of`, `timezone`, the totals and `has_more` **both ways**, the
  clamps for `limit` and `horizon_days`, the two `batch_status` bucket assertions, the boundary by
  arithmetic, and invariance under a session `TimeZone` change. Its summary line now counts
  assertions rather than log lines (the old `array_length(v_log, 1) + 1` counted itself) and asserts
  every logged line is a PASS or a FAIL.
- `phase5_chat_aggregates.sql`: the window and `as_of` assertions moved onto `business_today()`,
  the ranking checks likewise made relational, `dead_stock`'s new totals asserted, the fixtures for
  `v_pnone`/`v_d_quiet`/`v_d_expired` sized to win their page.
- `phase4_report_summary.sql` **+1 section**: no period named means the business day, and the
  envelope says which day and zone.
- `answer_test.ts`: rewritten onto envelopes; 209 → 209 across the suite (assertions re-expressed,
  including the "a full page is at least N" test becoming "a page states the total"), plus one new
  test for the four ways an envelope is unreadable.
- `handler_test.ts`: the default stub answers a real envelope, and the low-stock assertions read
  `body.data.rows[0]`.
- `alert_payloads_test.dart`: rewritten around `AlertPage`, plus the whole-set size, the empty
  envelope, and eight unreadable shapes.
- `notifications_screen_test.dart` / `inventory_screen_test.dart`: the truncation caption both ways.
- `chat_service_test.dart` **+2**: the business day reaching the reader, for a nested `meta` and for
  `report_summary`'s flat envelope.
- `chat_follow_ups_test.dart` (new, 4 tests) and `chatbot_screen_test.dart` **+4**: the map is a
  subset of the closed set, no report offers its own question, the chips appear under the newest
  answer only, a tap asks through `_ask`, and nothing is offered in flight or under a refusal.

## Key decision

**D-090 — a report states its own rule and its own total, and one clock says what day it is.** The
`{meta, rows}` shape for the last two reports that answered a bare array (a live RPC's contract, so
it shipped in the same push as the screens that read it); `business_today()` as the single clock,
`batch_status` included; and the follow-up chips as a structural map where every chip is asserted to
be a question the classifier can answer. Its "what was NOT done" section records Hindi script (the
owner's own two-language choice, and the brief's conditional last item) and the missing credential.

## Open risks / things the next session must know

1. **Hindi script is the last open piece of Phase A.** Adding `'hi'` to `ANSWER_LANGUAGES` fails to
   type-check at every `Sentence` map in `answer.ts` until it has one — compiler-guided, ~40 strings
   — and the client needs one more `AnswerLanguage` value (the chips iterate the enum, so the control
   grows by itself). `validateLanguage('hi')` currently asserts `'en'` and that assertion moves.
2. **The live answer-path probe has still never been run.** There is no signed-in user's token in the
   repository (`app/` holds only `.env.example`; the SQL tests impersonate via
   `set_config('request.jwt.claims', …)`, which is not a token). **Do not invent one.** What that
   leaves unproven: the `subject` enum's prompt-shaped risk (D-089 §3) and the exact shape of a live
   answer.
3. **A page is now caveated, but the caps are still serverside constants.** `low_stock_products`
   clamps to 200 and the app asks for 200; `expiring_batches` clamps to 500 and the alert asks for
   50. A pharmacy past those numbers now *sees* "Showing the 200 worst of 315" rather than reading a
   truncated list as the whole one.
4. **The truncated-list caption is client-side text**, not the server's sentence: the alert screens
   say "Showing the N worst of M" in their own words, while the chatbot's sentence is `answer.ts`'s.
   Two surfaces, two sentences about the same envelope — deliberately, and neither computes a figure.
5. **`report_summary` has no `meta` block** (it is a flat envelope, as it has been since 00021); its
   `as_of`/`timezone` sit beside its `from`/`to`, and `describeAnswerOrigin` reads metadata from
   either shape. A future report should pick one shape and stay in it.
6. **The app must be rebuilt to see any of this.** The function is deployed (version 4) and the
   migration is applied; the running app is whatever the owner last built.
7. **`top_products` still takes no total.** Its sentence claims none ("the top seller is Dolo 650"
   is true of a page and of the whole list alike) — so if a future sentence there ever counts
   anything, the report needs the same three keys the others now carry.

## What's next

`context/chat3y-opening-prompt.md` — **Phase B's first additive slice, which is the one piece of the
brief's §6 that needs no tenancy decision: the product stock lookup** (`product_stock_lookup`, its
§5 row *"specific product stock is outside the five-RPC schema"*; Direction 04's Q025–Q032), with the
rules the brief gives it (the model may extract a product NAME, the report resolves it, never
substitute, refuse an ambiguous name, state which quantity is being shown), plus **Hindi script** as
the small compiler-guided item, and the **live probe** if a credential ever appears. Phase B's
tenancy half (multi-outlet membership) still needs the owner's word on the model, and Phase 6.5b
remains his *"bilkul last"*.

## Every file touched (this session)

1. `supabase/migrations/20260922000050_phase5_alert_envelope_and_business_clock.sql` (new)
2. `supabase/tests/phase5_alerts.sql`
3. `supabase/tests/phase5_chat_aggregates.sql`
4. `supabase/tests/phase4_report_summary.sql`
5. `supabase/functions/chat-sql-agent/answer.ts`
6. `supabase/functions/chat-sql-agent/answer_test.ts`
7. `supabase/functions/chat-sql-agent/handler_test.ts`
8. `app/lib/data/models/alert_payloads.dart`
9. `app/lib/data/models/chat_response.dart`
10. `app/lib/features/notifications/data/notifications_repository.dart`
11. `app/lib/features/notifications/application/alert_providers.dart`
12. `app/lib/features/notifications/presentation/notifications_screen.dart`
13. `app/lib/features/inventory/data/inventory_repository.dart`
14. `app/lib/features/inventory/application/low_stock_controller.dart`
15. `app/lib/features/inventory/presentation/inventory_screen.dart`
16. `app/lib/features/chatbot/presentation/chat_follow_ups.dart` (new)
17. `app/lib/features/chatbot/presentation/chatbot_screen.dart`
18. `app/test/data/models/alert_payloads_test.dart`
19. `app/test/features/notifications/presentation/notifications_screen_test.dart`
20. `app/test/features/inventory/inventory_screen_test.dart`
21. `app/test/services/chat_service_test.dart`
22. `app/test/support/fake_notifications_repository.dart`
23. `app/test/support/fake_inventory_repository.dart`
24. `app/test/features/chatbot/presentation/chat_follow_ups_test.dart` (new)
25. `app/test/features/chatbot/presentation/chatbot_screen_test.dart`
26. `DECISIONS.md` (D-090)
27. `PROGRESS.md`
28. `context/chat3x-summary.md`, `context/chat3y-opening-prompt.md`

Harness plumbing, **not deliverables and not committed**: `.qwen/tmp/pg7a/build_00050.js` (the
assembler, with its `fn50_orig_*`/`fn50_new_*` body pairs for the diff) and
`.qwen/tmp/pg7a/run_all.sql` (the new migration appended).
