# Chat 3v Summary — the chatbot's owner-intelligence brief, Phase A (partly)

**Status:** COMPLETE for what it set out to do. **Phase A of the owner's chatbot brief is PARTLY
done** — the readable answers, the summary that leads on what was asked, and all three of the brief's
wording/count/horizon defects are in; the language templates, the follow-up chips and the exact-totals
envelope are not.
**Date:** 2026-09-22
**Commits:** `f9be7d1` (the emphasis marker, and the low-stock wording), `83cecc6` (a summary leads
with its subject), `a4022d1` (the sentence is written from the query that ran), plus this session's
docs commit. **All LOCAL** — nothing pushed, nothing deployed.
**Migrations:** **none.** Hosted still reads **49 = 49**.

---

## What this session was asked for, and what it did

The session opened on `context/chat3v-opening-prompt.md`, whose own scope was **Phase 6.5b (the
receiver app)** — and the owner set that aside in favour of a **new workstream**: a third-party
"owner intelligence" brief (`context/chatbot-owner-brief.md`) whose stated problem was *"answers feel
monotonous and important words/numbers are not bold"*. The reorder is recorded in `PROGRESS.md`,
`DECISIONS.md` (D-089) and `context/chatbot-owner-brief.md`.

**Before writing anything, the brief was checked against the working tree** rather than its own pin
(`25615b0`, 60 commits back), because that is where its two substantive conflicts came from — see
`context/chatbot-owner-brief.md` §2. Its *diagnosis* held up in every checkable place; two of its
*design* sections (the cost-snapshot columns and the four-pharmacy membership model) collided with
D-068 and with the Phase 7 tenancy note, and are recorded as open questions rather than built.

## The three commits

| Commit | What it closed | Where |
|---|---|---|
| `f9be7d1` | **Bold cannot render**, and the low-stock copy that disagreed with its own predicate | `chat-sql-agent/answer.ts`, `app/lib/features/chatbot/presentation/answer_emphasis.dart` (new), `message_bubble.dart`, tests |
| `83cecc6` | **Every summary sounds the same** — the model now declares a `subject` and the sentence leads on it | `chat-sql-agent/schema.ts`, `answer.ts`, tests |
| `a4022d1` | **A capped list read as a total**, and a horizon announced that the report clamped | `chat-sql-agent/answer.ts`, `handler.ts`, tests |

The one new client file is `app/lib/features/chatbot/presentation/answer_emphasis.dart`: a
hand-written reader for one marker (`**`). **No dependency was added** — the alternative was a markdown
package, and this project does not move its pins for a rendering convenience. **No Dart file changed in
the second and third commits**, so the client is untouched by the subject and by the resolver.

## Files created

- `app/lib/features/chatbot/presentation/answer_emphasis.dart`
- `app/test/features/chatbot/presentation/answer_emphasis_test.dart` (9 tests)
- `context/chatbot-owner-brief.md` (the brief, recorded against the current repo)
- `context/chat3v-summary.md`, `context/chat3w-opening-prompt.md`

## Files modified

`supabase/functions/chat-sql-agent/answer.ts`, `schema.ts`, `handler.ts`, `answer_test.ts`,
`schema_test.ts`, `handler_test.ts`; `app/lib/features/chatbot/presentation/widgets/message_bubble.dart`;
`app/test/features/chatbot/presentation/chatbot_screen_test.dart`;
`app/test/services/chat_service_test.dart`; `app/test/support/fake_chat_service.dart`;
`DECISIONS.md`; `PROGRESS.md`.

## Verification evidence (raw, at `a4022d1`)

```
dart format lib test          clean (2 files reformatted on the way)
build_runner build            no tracked output changed
dart run custom_lint          No issues found!
flutter analyze               No issues found!
flutter test                  1085 passing, 0 failures      (1074 at the session's start)
deno test supabase/functions  203 passed | 0 failed         (181 at the session's start)
deno check <5 entry points>   ALL_FIVE_CHECKS_OK
SQL suite                     NOT RUN — no migration and no SQL file was touched
hosted                        49 = 49, unchanged; nothing pushed
```

Per file, the Deno counts that moved: `answer_test.ts` 15 → 33, `handler_test.ts` 22 → 26,
`schema_test.ts` 15 → 17.

## Key decision

**D-089 — the chatbot's answers are readable, they lead with what was asked, and they describe the
query that ran.** Four parts: the server-owned emphasis marker and the client's reader (with a question
never being markup); the low-stock copy matching its predicate; a summary declaring a `subject` (one
more parameter, not one more report, with `everything` byte-identical to the old sentence and `stock`
taking no period); and `effectiveParams()` so the arguments and the sentence cannot describe different
queries. Its consequences name the two things deliberately *not* done: the exact `total_count`, and
deployment.

## Assertions changed, before → after (none deleted, none loosened, no count falls)

- `answer_test.ts` **15 → 33**: **11 new tests** across the three commits (three pinning the marker's
  contract both ways; six for the summary subjects and the empty-period/missing-section rules; one for
  the unexpired countdown; five for the cap/horizon/at-least rules and the resolver). Six existing
  expectations were **re-expressed** to the new sentences — the figures, the window and the ranking
  assertions did not move, only the copy and the markers.
- `handler_test.ts` **22 → 26**: four new tests. Three existing assertions were **re-expressed**: the
  two `paramsFor(...).p_days === 90` assertions **moved** to `effectiveParams` (where the defaults live
  now, and the test says so), the top-products arguments now carry the resolved cap, and the low-stock
  envelope's `params` reads `{ p_limit: 50 }` rather than `{ p_limit: null }`.
- `schema_test.ts` **15 → 17**: two new tests for the `subject` enum and its parsing.
- `chatbot_screen_test.dart`: **not one existing assertion changed** — `find.text` already reads a
  `Text.rich` by its plain text, which made the untouched widget tests the proof that the marker never
  reaches a reader's eye. Two added.
- `chat_service_test.dart` and `fake_chat_service.dart`: the recorded answer body, one history literal
  and the fake's default answer move to the new copy; their intent is unchanged.

## Open risks / things the next session must know

1. **Nothing is deployed.** The committed function source is *not* what `chat-sql-agent` serves until
   `supabase functions deploy` runs, and the app has to be rebuilt to render the marker. The owner's
   brief says in as many words that it is *"not permission to … deploy changes"*, so the session pushed
   nothing and deployed nothing. **The deployed chatbot still answers with the old sentences.**
2. **The exact `total_count` is not done**, and the reason is a deployment-ordering one rather than
   effort: the two `00027` reports (`low_stock_products`, `expiring_batches`) return a bare array, so
   giving them the `{meta, rows}` shape that `top_products` and `dead_stock` already carry changes a
   **live RPC's contract** while the alert screens that read it (`notifications_repository.dart`,
   `inventory_repository.dart`, `alert_payloads.dart`) ship separately. A full page therefore says
   "at least N" rather than "exactly N of M".
3. **Four doc comments in the alerts feature still say "at or below"** for the same rule D-089 §2
   corrected in the chatbot — `alert_payloads.dart`, `alert_providers.dart`,
   `notifications_repository.dart`, `notifications_screen.dart`. They are comments, not user-facing
   copy, and were deliberately left alone rather than edited from outside the files the chunks touched.
4. **The `subject` enum is a prompt-shaped risk, not a structural one.** The model may over-apply
   `stock` to a product-level question; the prompt says in as many words that a question about ONE
   product is `unsupported` and that a summary's `stock` is the whole stock, valued — **but that is a
   prompt, and a live probe would be the proof.** None was run (the function is not deployed).
5. **The marker now travels in the conversation history** the classifier is handed, deliberately (see
   D-089). If that ever becomes a problem it is one line in `ChatMessage.toJson`, not a redesign.
6. **`top_products` takes no cap** on purpose, because its sentence claims no total — so if a future
   sentence there counts anything, it must take one.

## What's next

`context/chat3w-opening-prompt.md` — **finish Phase A** of the chatbot brief: the language templates
(`en` / `hi` / `hinglish`), the follow-up chips, and the exact-totals envelope; then Phase B onward of
`context/chatbot-owner-brief.md`. **The plan's own sequence still names Phase 6.5b (the receiver app)**
as the next phase, and `MASTER_PLAN.md` has only a stub for it — so if the owner's sequence has moved
back there, that session opens by asking what the receiver app IS.
