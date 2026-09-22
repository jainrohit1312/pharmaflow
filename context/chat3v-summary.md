# Chat 3v Summary — the chatbot's owner-intelligence brief, Phase A

**Status:** COMPLETE for what it set out to do, and **deployed**. Phase A of the owner's chatbot brief
is **partly done** — readable answers, a summary that leads on what was asked, all three of the brief's
wording/count/horizon defects closed, and the answer sayable in **Hinglish**; the follow-up chips, the
exact-totals envelope and **Hindi script** are not.
**Date:** 2026-09-22
**Commits:** `f9be7d1` (the emphasis marker, and the low-stock wording), `83cecc6` (a summary leads with
its subject), `a4022d1` (the sentence is written from the query that ran), `f3ba021` (the answer can be
said in Hinglish), plus this session's docs commit. **All pushed to `origin/main`, and
`chat-sql-agent` was deployed to hosted the same day.**
**Migrations:** **none.** Hosted still reads **49 = 49**, and the SQL suite was not touched.

---

## What this session was asked for, and what it did

The session opened on `context/chat3v-opening-prompt.md`, whose own scope was **Phase 6.5b (the
receiver app)** — and the owner set that aside in favour of a **new workstream**: a third-party
"owner intelligence" brief (`context/chatbot-owner-brief.md`) whose stated problem was *"answers feel
monotonous and important words/numbers are not bold"*. The reorder is recorded in `PROGRESS.md`,
`DECISIONS.md` (D-089) and `context/chatbot-owner-brief.md`.

**Before writing anything, the brief was checked against the working tree** rather than its own pin
(`25615b0`, 60 commits back), which is where its two substantive conflicts came from — see
`context/chatbot-owner-brief.md` §2. Its *diagnosis* held up in every checkable place; two of its
*design* sections (the cost-snapshot columns, and the four-pharmacy membership model) collided with
D-068 and with the Phase 7 tenancy note, and are recorded as open questions rather than built.

**Two questions were put to the owner before the last chunk**, and both were answered: he allowed the
push and the deploy, and he chose **English + Hinglish** for the language work — not Hindi script, and
not English-only.

## The four commits

| Commit | What it closed | Where |
|---|---|---|
| `f9be7d1` | **Bold cannot render**, and the low-stock copy that disagreed with its own predicate | `chat-sql-agent/answer.ts`, `app/lib/features/chatbot/presentation/answer_emphasis.dart` (new), `message_bubble.dart`, tests |
| `83cecc6` | **Every summary sounds the same** — the model now declares a `subject` and the sentence leads on it | `chat-sql-agent/schema.ts`, `answer.ts`, tests |
| `a4022d1` | **A capped list read as a total**, and a horizon announced that the report clamped | `chat-sql-agent/answer.ts`, `handler.ts`, tests |
| `f3ba021` | **The answer can be said in Hinglish**, and the language is the caller's choice | `chat-sql-agent/schema.ts`, `handler.ts`, `answer.ts`; `app/lib/data/models/answer_language.dart` (new), `chat_service.dart`, `chat_controller.dart`, `chatbot_screen.dart`, tests |

The two new client files are `answer_emphasis.dart` (a hand-written reader for one marker, `**`) and
`answer_language.dart` (the language enum, carrying its wire name and its chip label together). **No
dependency was added** — the alternative for the marker was a markdown package, and this project does
not move its pins for a rendering convenience.

## Files created

- `app/lib/features/chatbot/presentation/answer_emphasis.dart`
- `app/lib/data/models/answer_language.dart`
- `app/test/features/chatbot/presentation/answer_emphasis_test.dart` (9 tests)
- `context/chatbot-owner-brief.md` (the brief, recorded against the current repo)
- `context/chat3v-summary.md`, `context/chat3w-opening-prompt.md`

## Files modified

`supabase/functions/chat-sql-agent/answer.ts`, `schema.ts`, `handler.ts`, `answer_test.ts`,
`schema_test.ts`, `handler_test.ts`; `app/lib/features/chatbot/presentation/widgets/message_bubble.dart`,
`app/lib/features/chatbot/presentation/chatbot_screen.dart`,
`app/lib/features/chatbot/application/chat_controller.dart`, `app/lib/services/chat_service.dart`;
`app/test/features/chatbot/presentation/chatbot_screen_test.dart`,
`app/test/features/chatbot/application/chat_controller_test.dart`,
`app/test/services/chat_service_test.dart`, `app/test/support/fake_chat_service.dart`; `DECISIONS.md`;
`PROGRESS.md`.

## Verification evidence (raw, at `f3ba021`)

```
dart format lib test          clean (a few files reformatted on the way)
build_runner build            no tracked output changed (generated Dart is gitignored, .gitignore:22)
dart run custom_lint          No issues found!
flutter analyze               No issues found!
flutter test                  1087 passing, 0 failures      (1074 at the session's start)
deno test supabase/functions  209 passed | 0 failed         (181 at the session's start)
deno check <5 entry points>   ALL_FIVE_CHECKS_OK
SQL suite                     NOT RUN — no migration and no SQL file was touched
hosted                        49 = 49, unchanged

deployed  supabase functions deploy chat-sql-agent   → deployed to yeroxzkpmodbzcvjlqwd
curl -X OPTIONS .../functions/v1/chat-sql-agent      → 204 + CORS headers (the deployed bundle serves)
curl -X POST ... (no token)                          → 401 UNAUTHORIZED_NO_AUTH_HEADER (expected)
```

Per file, the Deno counts that moved: `answer_test.ts` 15 → 34, `handler_test.ts` 22 → 29,
`schema_test.ts` 15 → 17.

**The answer path was NOT exercised live.** A real call needs a signed-in user's token, and it spends
one of the free tier's five shared Gemini requests a minute (N-2) — so the deployed function was
smoke-tested for reachability only. The rendering itself is covered by the Deno and the Flutter suites.

## Key decision

**D-089 — the chatbot's answers are readable, they lead with what was asked, they describe the query
that ran, and they can be said in Hinglish.** Five parts: the server-owned emphasis marker and the
client's reader (a question is never markup); the low-stock copy matching its predicate; a summary
declaring a `subject` (one more parameter, not one more report, with `everything` byte-identical to the
old sentence and `stock` taking no period); `effectiveParams()` so the arguments and the sentence cannot
describe different queries; and the language, which is the **caller's** choice and never reaches a
report — with every sentence a map keyed by the language union, so a missing language is a compile error
rather than an invisible English sentence.

## Assertions changed, before → after (none deleted, none loosened, no count falls)

- `answer_test.ts` **15 → 34** across the four commits: 19 new tests. Six existing expectations were
  **re-expressed** to the new sentences (the copy and the markers moved; the figures, the window and the
  ranking assertions did not), and `UNSUPPORTED_ANSWER` became `UNSUPPORTED` (a map) with its one
  assertion re-expressed to `UNSUPPORTED.en`. The two marker tests now run over **both** languages.
- `handler_test.ts` **22 → 29**: seven new tests. Three existing assertions were **re-expressed**: the
  two `paramsFor(...).p_days === 90` assertions **moved** to `effectiveParams`, the top-products
  arguments now carry the resolved cap, and the low-stock envelope's `params` reads `{ p_limit: 50 }`.
- `schema_test.ts` **15 → 17**.
- `chatbot_screen_test.dart`: **not one existing assertion changed** across all four commits —
  `find.text` already reads a `Text.rich` by its plain text, which made the untouched widget tests the
  proof that the marker never reaches a reader's eye. Three tested behaviours were added (the bold run,
  a question staying plain, and the language chips).
- `chat_controller_test.dart` **+1**; `chat_service_test.dart` and `fake_chat_service.dart` follow the
  wire and the fake's default answer.

**A correction, and it is mine:** the `a4022d1` commit message says `answer_test.ts` went `26 -> 33`.
The measured counts are `26 -> 31` — five tests were added there, not seven. The suite totals in that
message are right. It is recorded in `PROGRESS.md` under "Baseline correction".

## Open risks / things the next session must know

1. **The follow-up chips and the exact `total_count` are not done.** The totals need the two `00027`
   reports (`low_stock_products`, `expiring_batches`) to answer in the `{meta, rows}` shape the other
   two already carry — a **live RPC's contract**, which must ship together with the alert screens that
   read it (`notifications_repository.dart`, `inventory_repository.dart`, `alert_payloads.dart`). A full
   page therefore says "at least N" rather than "exactly N of M".
2. **Hindi script is deferred by the owner's own answer.** Adding it is compiler-guided: every sentence
   map in `answer.ts` fails to type-check until it has a key.
3. **Four doc comments in the alerts feature still say "at or below"** for the same rule D-089 §2
   corrected in the chatbot — `alert_payloads.dart`, `alert_providers.dart`,
   `notifications_repository.dart`, `notifications_screen.dart`. They are comments, not user-facing
   copy, and were deliberately left alone rather than edited from outside the files the chunks touched.
4. **The `subject` enum is a prompt-shaped risk, not a structural one.** The model may over-apply
   `stock` to a product-level question; the prompt says in as many words that a question about ONE
   product is `unsupported` and that a summary's `stock` is the whole stock, valued — **but that is a
   prompt, and a live probe would be the proof.** None was run (it needs a token and a model call).
5. **The marker now travels in the conversation history** the classifier is handed, deliberately (see
   D-089 §1). If that ever becomes a problem it is one line in `ChatMessage.toJson`.
6. **`top_products` takes no cap** on purpose, because its sentence claims no total — so if a future
   sentence there counts anything, it must take one.
7. **The app must be rebuilt to render the marker.** The function is deployed; the Flutter side is
   committed, but the running app is whatever the owner last built.

## What's next

`context/chat3w-opening-prompt.md` — **finish the chatbot phase** in one long session, with no approval
gate: the exact-totals `{meta, rows}` envelope (and its alert-screen carry), the follow-up chips, the
business clock, Hindi script if the window is wide, and **a live answer-path probe**, which the owner has
authorised. Then Phase B onward of `context/chatbot-owner-brief.md`.

**The owner settled the order on 2026-09-22**, after this summary was first written: **Phase 6.5b (the
receiver app) is postponed to the very end** — *"receviver app wala 6.5b abhi ni krna hai wo bilkul last
me krenge"* — and Phase 7b/7c wait behind it. So the plan's own sequence resumes only when the chatbot
phase is finished and he says the receiver app's turn has come.
