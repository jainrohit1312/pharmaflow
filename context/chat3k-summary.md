# Chat 4 / Chunk E (PART 2 of 2) — the `/chatbot` surface (COMPLETE)

**Status:** **COMPLETE — and this closes Phase 5.** Chunks A–E are done, gated and on
the tree. Next is **Phase 6** (`context/chat3l-opening-prompt.md`), which owns the
Windows build fix, the README, push, the provider credentials, auto-send PO, and the two
measurements Phase 5 left open.
**Date:** 2026-09-19

## What this chunk ships

Dart only. **No migration, no server change, no new report** — E-part-1 had already
deployed and live-probed `chat-sql-agent`, and the brief was explicit that the endpoint
needed no further probing. The whole chunk is the client that types into it.

### 1. `ChatService` — `lib/services/chat_service.dart` (new)

The `OcrService`/`MatchService` shape, one method deep:

- `abstract class ChatService` with `ask({question, history})`, a `SupabaseChatService`
  over `functions.invoke('chat-sql-agent')`, and `@riverpod ChatService chatService` —
  the generated provider the other two services have (D-1's "convert when the feature is
  built").
- **The wire mapping is pure functions**, so a test drives the bodies that matter:
  `decodeChatAnswer` (the shape check) and `chatException`, which is a **thin name over
  `functionException`** (D-042) carrying only this feature's fallback sentence. A
  new function's failures therefore classify with no new vocabulary:
  `unauthorized` → auth, `invalid_request` → validation, everything else — including
  `provider_unavailable` → a server failure in the server's words.
- **Nothing retries.** One request is one model call (N-2). `sb.FunctionsFetchException`
  (nothing came back) becomes `NetworkException(code: 'unreachable')`; the function's
  refusal becomes whatever `functionException` made of it.
- **The tenant never travels** (D-004): there is no `pharmacy_id` in the body, because
  the function and every report derive it from the caller's own JWT.
- `chatHistoryTurns = 6` and `chatHistoryFor(history)` bound the context the client
  sends, mirroring the function's `MAX_HISTORY_TURNS`. Both bounds are "at most", so
  they cannot disagree in a way that matters; the client's copy is what keeps a
  transcript from growing into the request body.
- `isRetryableChatError` — `provider_unavailable` or `unreachable`. It decides a
  **sentence**, never a behaviour (D-033's distinction, kept in the client because the
  client is where a wait can be explained).

### 2. The answer as plain classes — `lib/data/models/` (new)

`ReportSummary`'s precedent: this is a function envelope, not a table row, no migration
owns its shape, and the decode happens once so no screen reaches into raw JSON.

**`ChatResponse`** carries exactly what the envelope promises:

```
answer   the sentence, rendered server-side from the report's own jsonb (D-053)
rpc      one of the five reports, or null for the refusal
params   the arguments the function handed the report
data     the report's jsonb, verbatim and un-modelled
model    the classifier (D-030) — decoded, deliberately not rendered
warnings the server's own sentences about the run
```

- **`rpc: null` is a success.** `ChatResponse.tryDecode` reads it as an answer with no
  report, and the screen renders it as prose.
- **The shape check is the one wrong answer this feature could give.** A body that is not
  an object, or carries no non-empty `answer` *string* (`42` and `'   '` included), makes
  `tryDecode` answer `null`, and `decodeChatAnswer` turns that into a
  `ServerException(code: 'unexpected_response')`. A blank bubble would be
  indistinguishable from a bug; this makes it impossible.
- **`data` is kept as `Object?`** rather than re-modelled into five report shapes:
  nothing on the client reads a figure out of it, and the only thing it is read for is
  provenance.

**`describeAnswerOrigin(response)`** is that provenance, as one line, built entirely from
the envelope:

- the report's name, from `rpc` (`reportLabel`, the app's copy of the server's closed
  set — a name the app does not know is passed through rather than dropped);
- the **non-null** entries of `params`, in words: `from 2026-08-01`, `to 2026-08-31`,
  `within 90 days`, `at most 5 rows`, `by revenue`, and `key value` for anything new. A
  `null` parameter is *the report's default applying*, which its sentence already states;
- the **caveats the report's own `meta` states** — `returns_not_netted: true` →
  `returns are not subtracted`. That is D-053's motivating case: `answer.ts` renders the
  window and the metric from that same `meta`, so they are already in the sentence, while
  the non-netting has no sentence anywhere. This is the line that makes it visible.

For the live probe's own `top_products` answer it reads `Top products · returns are not
subtracted`; for a refusal it is `null` — nothing to attribute.

`meta.model` is decoded and asserted but **not rendered**: it is provenance about the
classifier, and nobody at a counter acts on it.

### 3. `ChatController` — `lib/features/chatbot/application/` (new)

Plain state, not an `AsyncValue` (D-055). `build()` returns `const ChatState()` and
**never throws**, which matters in Riverpod 3: a provider whose *build* threw is re-run on
its own backoff, so an error state reached that way is not stable across pumps (D-051).
Reaching it from a failed write — as here — is.

```
ChatState { messages, asking, failure }
```

- `messages` — turns that **happened**, questions and answers in order. A completed
  `rpc: null` refusal is in here: it is an answer.
- `asking` — the question in flight, held as its own text so the screen keeps showing
  what was asked while it waits.
- `failure` — a `ChatFailure {question, error}`, which is **not** a message: a turn that
  did not happen. It is not added to the transcript, it is never sent as history, and it
  is the only state with a retry. That is the structural difference between *"I cannot
  answer that"* and *"could not ask"*.
- `ask` refuses a blank question and a second question while one is in flight **before
  any call is made**, captures the history before the await, checks **`ref.mounted`**
  after it (D-034), and appends question + answer together on success.
- `retry()` re-asks `failure.question` verbatim — the same question, one more call, on a
  user's tap. Nothing else in the controller re-sends anything.
- A new question supersedes a previous failure (the user has moved on).

### 4. The screen — `lib/features/chatbot/presentation/` (new)

`chatbot_screen.dart` plus `widgets/message_bubble.dart`. **Four situations, four
structures**, which is the heart of the chunk (T-5's lesson):

| situation | structure | what the user sees |
|---|---|---|
| nothing asked yet | `_Invitation` | "Ask about this pharmacy" + five tappable example questions drawn from the report set |
| still waiting | `PendingTurn` | the question bubble + a spinner + *"Still waiting for an answer…"* |
| no answer to that | `MessageBubble` | the server's refusal as **prose**, in an ordinary answer bubble — no error, no retry, no origin note |
| could not ask | `FailedTurn` | error icon + `describeError` + *"Ask again"*, and the retryable sentence only when it is (D-033) |

- **The composer** is `AppTextField` + an Ask button, both wired: Enter submits (desktop)
  and the button exists beside it (a browser has no submit key to rely on — web first,
  D-005). The button is disabled while the field is blank or a turn is in flight, and the
  input gives up its text only when the ask is really taken.
- **The scroll** is brought to the newest turn after the frame that added it, so a long
  conversation does not leave an answer below the fold.
- **Nothing on the screen computes a figure.** The sentence is the server's; the note is
  the envelope's; the only thing a widget decides is where a turn sits and how it looks.
- A failure renders with `describeError` and the `AppButton` primitives `ErrorView` is
  built from, **not** `ErrorView` itself: a failure here is one turn in a transcript and
  the question it belongs to has to stay visible. Retry is offered for every failure
  (re-asking is the only action a failure leaves a user); retryability only adds a
  sentence.

### 5. The shell — the 13th destination (D-054)

- `Routes.chatbot = '/chatbot'` with D-048's reasoning recorded, added to
  `Routes.shellPaths` **after `notifications`, before `settings`**.
- `_navDestinations` gains the thirteenth entry (`inBottomBar: false`), Notifications →
  **Chatbot** → Settings: the utility group stays contiguous and Notifications keeps its
  twelfth position.
- `app_router.dart` declares it as a shell child beside `/notifications`.
- **The tests that had to move**: `dashboard_shell_test.dart`'s `_labels` (12 → 13) and
  the test now named *"the utility destinations stay out of the mobile bottom bar"*
  (asserting both `/notifications` and `/chatbot` are absent while the bar stays at 4);
  `widget_test.dart`'s `hasLength(12)` → `13` with its reason string. The two parity
  tests — `DashboardShell.destinationPaths == Routes.shellPaths` — enforced the rest on
  their own, which is exactly what D-048 built them for.
- **No dashboard card** for the chatbot: D-048's unread count is a number that changes
  without the user asking; a chatbot has nothing to say until asked something.

## Files

```
app/lib/services/chat_service.dart                                    (new)
app/lib/data/models/chat_response.dart                                (new)
app/lib/data/models/chat_message.dart                                 (new)
app/lib/features/chatbot/application/chat_controller.dart             (new)
app/lib/features/chatbot/presentation/chatbot_screen.dart             (new)
app/lib/features/chatbot/presentation/widgets/message_bubble.dart     (new)
app/test/services/chat_service_test.dart                              (new, 28 tests)
app/test/features/chatbot/application/chat_controller_test.dart       (new, 11 tests)
app/test/features/chatbot/presentation/chatbot_screen_test.dart       (new, 10 tests)
app/test/support/fake_chat_service.dart                               (new)
app/test/support/chatbot_test_app.dart                                (new)
context/chat3k-summary.md                                             (this file)
context/chat3l-opening-prompt.md                                      (Phase 6's brief)
```

**Modified:** `app/lib/core/router/routes.dart`, `app/lib/core/router/app_router.dart`,
`app/lib/features/dashboard/presentation/dashboard_shell.dart`,
`app/test/features/dashboard/dashboard_shell_test.dart`, `app/test/widget_test.dart`,
`DECISIONS.md` (**D-054**, **D-055**), `PROGRESS.md`.

## The tests, and what each says

- **`chat_service_test.dart` (28)** — every body is one of the shapes recorded from the
  live function in E-part-1. It pins: the promised 200 reads; **`rpc: null` decodes as a
  success**; a non-object body, a missing `answer`, `answer: 42` and `answer: '   '` are
  all `unexpected_response`; the surrounding fields are read defensively; the exception
  mapping is `functionException`'s; `isRetryableChatError` says yes to the busy and
  unreachable and no to the rest; `describeAnswerOrigin` names the report, renders what
  was asked for and skips the blanks, shows `returns are not subtracted` from the
  report's own `meta`, and is `null` for a refusal; `chatHistoryFor` takes the last six.
- **`chat_controller_test.dart` (11)** — one call per ask with the conversation as the
  next call's history; a blank question is never sent; **a question asked while one is in
  flight spends nothing**; a failure is held as a turn that did not happen, not as a
  message; nothing asks again by itself (asserted after letting the microtask queue
  drain); `retry()` is the same question and one more call; a refusal is a message like
  any other; a new question supersedes a failure; and the D-034 test — a screen that goes
  away mid-flight is not written to.
- **`chatbot_screen_test.dart` (10)** — the invitation is neither a spinner nor an error;
  an example chip asks as it stands; a typed question is trimmed, asked once, and leaves
  the field empty; an answer renders the sentence and the note; the server's warnings
  show beside it; **waiting for an answer looks like neither an answer nor a fault**
  (asserted *during* the call, held open by the fake's gate); a failure shows its own
  sentence, a retry, and the retryable line only when it is; a non-retryable failure does
  not get that line; **the retry asks the same question and the answer lands**; and the
  one this screen exists for — **a refusal and a failure, both on screen at once, never
  look alike** (prose + nothing offered vs. error icon + sentence + exactly one retry).

Two notes for whoever writes the next widget test here:

- `pumpAndSettle` **never returns while a turn is pending** — the spinner animates for
  ever. That test uses `pump()`.
- The screen is pumped on its own (`MaterialApp(home: ChatbotScreen())`), not through a
  router, so GoRouter's pre-first-frame double build cannot consume anything a fake
  hands out once.

## Verification evidence

```
dart format lib test                                     -> 417 files, 0 changed
dart run build_runner build --delete-conflicting-outputs  -> 2 outputs (chat_service.g.dart,
                                                             chat_controller.g.dart), no errors
dart run custom_lint                                     -> No issues found!
flutter analyze                                          -> No issues found!
flutter test                                             -> +593: All tests passed!  (544 -> 593)
deno test supabase/functions                             -> ok | 181 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts    -> clean
deno check supabase/functions/match-product/index.ts        -> clean
deno check supabase/functions/backfill-embeddings/index.ts  -> clean
deno check supabase/functions/send-notification/index.ts    -> clean
deno check supabase/functions/chat-sql-agent/index.ts       -> clean
```

`git status --short` shows exactly the twelve intended paths: 5 modified, 7 new
(`.g.dart` files are gitignored).

**No migration was added**, so there is no `supabase db push` and no new
`supabase/tests/*.sql`. Nothing under `supabase/` changed *at all* — the six Deno gate
lines were run to prove that rather than assume it.

## Decisions recorded

- **D-054** — `/chatbot` is a top-level shell destination: the 13th rail entry, after
  Notifications and before Settings, `inBottomBar: false`. D-048's reasoning applied
  again, harder: the reports it answers from span every domain, so no module owns it.
- **D-055** — a conversation is controller state, not an `AsyncValue`. `messages` /
  `asking` / `failure` are three separate fields because they are three different
  situations; a failure is structurally not a message; one model call per user action
  with nothing retrying on its own; and the note under an answer is read from the
  envelope rather than computed.

## What this chunk deliberately did not do

- **No live end-to-end run, and no token was requested.** E-part-1 probed the endpoint
  itself with the user's session — the classification, the parameters, the model name,
  the figures and the refusal path — and the widget tests here drive those same recorded
  bodies over a fake. What a live run *could* still add is one thing: the app's own
  `functions.invoke` path in a browser, i.e. the real CORS/status path on a **200**. What
  it still could not prove is that an answer is *useful*. It is available on request
  (N-7: ask the user for a session; never work around the guard).
- **No server change.** If the screen ever wants a number the five reports cannot give,
  that is a migration and a new report — never a client-side calculation and never prompt
  engineering.
- **No write path.** The chatbot moves no stock, posts no ledger entry and sends no
  message.
- **No dashboard card, no push, no Phase 6 work.** W-1, R-1, N-1, D-046's credentials and
  triggers and D-052's auto-send PO all wait for Phase 6.

## Open risks / blockers

- **Nothing was made worse, and nothing new was opened.** N-1, N-2, N-4, N-5, N-7, N-9,
  I-1, I-2, I-3, T-3, T-4, T-5, D-027's residual, W-1, A-1 and R-1 are all untouched. The
  two permanent `notification_logs`/`notifications` probe rows from chunk D are still in
  production on purpose (D-049's evidence).
- **I-1 is now the most tempting one-line change left in Phase 5's shadow**:
  `low_stock_products` is a switch for `InventoryRepository.lowStock`, and the chatbot
  calls it live. It is Phase 6's if Phase 6 wants it.
- **The chatbot cannot be asked about a single product, a single customer, or a
  forecast** — by design (the closed set is D-026's). A question that needs a new answer
  is a migration, not a prompt.
- **Two small naming/judgement calls worth a glance in review**, both one-line reversions:
  the rail label and screen title are **"Chatbot"** (matching the route, the brief and
  D-054; the prose copy says "the assistant"), and `describeAnswerOrigin` renders
  `params` as **what was asked**, not as what the report used — which is the honest
  reading, since a report clamps its own limit and states the effective rule in its own
  `meta`.

## What's next

**Phase 6** — `context/chat3l-opening-prompt.md`. Phase 5 is closed; nothing in it is
left pending except the open items the table above lists.
