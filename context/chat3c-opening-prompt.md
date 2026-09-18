# Chat 4 / Chunk B2 — Phase 5: the OCR Flutter seam and the verify screen

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **third** chunk brief of Chat 4. Chat 4's overall brief is
> `context/chat3-opening-prompt.md`; chunk A's account is
> `context/chat3a-summary.md`, and chunk B's — which covers what you are building on
> — is `context/chat3b-summary.md`. `PROGRESS.md`'s Chat Strategy table is the
> authority: **Chat 4 = Phase 5 + Phase 6**.
>
> Chunk B was split: **B1 (the Edge Function) is complete, deployed and
> live-verified; you are doing B2 (everything below the HTTP boundary).** The next
> handoff files after this chunk are `context/chat3c-summary.md` and
> `context/chat3d-opening-prompt.md`. New decisions continue at **D-033**.

---

## STEP 0 — READ FIRST (do NOT skip)

Read in this exact order:

1. `PROGRESS.md` — authority on what is done, the gate output, the open items
2. `MASTER_PLAN.md` — Phase 5's place in the roadmap
3. `DECISIONS.md` — especially D-004, D-011/D-013, D-015, D-021, D-022, D-023, and
   the Phase 5 five: **D-026 … D-032** (D-030/D-031/D-032 came out of B1)
4. `HANDOFF_PROTOCOL.md`
5. `context/chat3b-summary.md` — **the important one**: B1's contract, the exact
   envelope, the live evidence, the open items
6. `context/chat3c-opening-prompt.md` — this file

Then output a 5-line understanding check:

- What B2 covers, and what B1 already finished
- What B1 delivered (the function's contract, and what it deliberately does not do)
- Environment (hosted Supabase, no Docker, Web-first)
- Two load-bearing dependency pins
- What you are about to build

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`, no `db reset`
- Migrations: `supabase db push` (the ONLY migration command) — **B2 should need
  none**
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
```

Plus, since B1 added functions that the five gates do not touch (**open item N-3** —
run these yourself even though nothing enforces them yet):

```
deno check supabase/functions/ocr-purchase-bill/index.ts
deno test supabase/functions/_shared/base64_test.ts supabase/functions/ocr-purchase-bill/gemini_test.ts supabase/functions/ocr-purchase-bill/handler_test.ts
```

`dart format` is not itself a gate, but the committed tree *is* formatter output, so
run it after writing Dart and before the gates.

**Never run two `build_runner` processes at once.** If you use parallel subagents,
the main agent runs codegen once at the end. (Two concurrent `flutter test` runs are
also best avoided.)

**Analyzer note:** `flutter analyze` covers `test/**` too, and
`avoid_redundant_argument_values` fires on arguments equal to a parameter's own
default *including inside test fixtures*. `find.text` also matches an
`EditableText`'s content, so scope such assertions to the card.

**Edge Functions, for reference (B1 did this, you should not need to):** develop by
deploying and invoking the deployed function. This CLI has **no `functions logs`**
(N-4), so its `console.error` output is dashboard-only. Never print or commit a
secret.

---

## WHAT B1 DELIVERED (do not re-do)

`ocr-purchase-bill` is deployed and verified against the live model. Its contract —
paste it into your understanding of the task — is in `context/chat3b-summary.md`.
The essentials:

- POST `{ "path": "<pharmacy_id>/<year>/<file>" }` with the user's JWT →
  `{ document, lines, meta }` (200) or `{ error: { code, message } }`.
- snake_case, **every field nullable**, `null` means "the screen must ask".
- `meta.warnings` are human sentences to show; `meta.finish_reason` is `STOP` on a
  complete answer; `meta.image_path` is the object the parse came from.
- `provider_unavailable` is the **retryable** failure (the key is free-tier: five
  requests a minute, and a burst is shed as `503`, see D-032). `not_found` is what
  "not your bill or not there" looks like, deliberately.
- The function **writes nothing** — and that is the whole point (D-011/D-013).

Chunk A (before it) added the private `purchase-bills` bucket, `products.embedding`
and the notification tables. Nothing in the Flutter tree changed in B1: the tree is
green at 397 tests and `app/lib/services/ocr_service.dart` still throws
`UnimplementedError('TODO(phase-5)')`.

---

## SCOPE — Chunk B2: the seam, the screen, the save

### 1. The envelope's Dart models

`app/lib/data/models/ocr_purchase_bill.dart` — **plain classes, not Freezed** (an RPC
envelope: `ReportSummary` is the precedent, and D-025's reasoning applies). Something
like `OcrPurchaseBill` (`document`, `lines`, `model`, `warnings`, `imagePath`,
`finishReason`) and `OcrBillLine`.

- `fromJson` must be as tolerant as the function's normalizer is, because the
  function is not the only thing that can change: a number may arrive as a `num` or
  as a `String`, and a date is an ISO `String` that may be `null`.
- A helper that turns the lines into `PurchaseLineDraft`s belongs here (or beside the
  controller): `productId: null` on every line, because matching is Chunk C — a human
  picks the product in this chunk. `PurchaseDraft`/`PurchaseLineDraft` are Freezed
  and already exist; do not invent a parallel draft.
- The header the user confirms (supplier, invoice number, invoice date) is *not* in
  the envelope's shape as a `PurchaseDraft`: the supplier is a pharmacy concept the
  model never sees, so the controller builds the `PurchaseDraft` from the parse plus
  the user's choices.

### 2. `OcrService`, implemented

`app/lib/services/ocr_service.dart` currently throws. Implement it over
`supabase.functions.invoke('ocr-purchase-bill', body: {'path': ...})`:

- keep the `Provider` seam (a hand-written `Provider` is allowed for a service —
  the stub exception in D-001);
- returning `Map<String, dynamic>` and letting it leak into the UI is the thing to
  avoid: decode into the envelope in **one place**;
- put the **pure response mapper** in its own function so a test can drive it: a 200
  body, an error body, a 200 with no body, a non-JSON body. Map the error envelope's
  `code` to the app's exceptions (`AppException`/`ServerException`/`ValidationException`
  as the repo does elsewhere) and keep **whether it is retryable** — D-032's
  distinction has to survive to the screen, because "the reader is busy" and "this
  bill could not be read" need different words and different buttons;
- `supabase.functions.invoke` returns a `FunctionResponse` whose `.data` is already
  decoded; a non-2xx throws `FunctionException` carrying `status`. Handle both.

### 3. `features/purchase_ocr/` — the repository and the upload

```
data/purchase_ocr_repository.dart      upload + invoke + the pure rules
application/purchase_ocr_controller.dart   @riverpod (codegen only)
presentation/purchase_ocr_screen.dart  pick/capture → parse → verify → save
presentation/widgets/…
```

- **Upload**: `<pharmacy_id>/<year>/<uuid>.<ext>` from `requirePharmacyIdProvider`
  read **synchronously** (D-015), to the `purchase-bills` bucket (D-028).
- **The bucket's limits are mirrored client-side and the mirror is a tested rule**:
  10 MB, and `image/jpeg`, `image/png`, `image/webp`, `application/pdf`. Pre-checking
  turns a storage refusal into a sentence before a round trip — but the bucket stays
  the authority, and **its** refusal must be surfaced verbatim, not swallowed.
- Keep the uploaded path with the parse result: the verify screen shows the image
  *and* the object it came from.
- Two steps, not one (`uploadBill` then `parseBill`): the user should see the image
  while it is being read, and "read it again" must not re-upload.

### 4. The screen

- **Pick or capture** with `image_picker` — the repo's first use of it (declared at
  `app/pubspec.yaml`, never called). Web is the platform that must work first
  (D-005): `image_picker_for_web` returns bytes and a camera "capture" is a file
  dialog. **Say in the handoff what actually happened on the platform you tested.**
- **Show the image** beside what was read. An OCR screen with no visible confidence
  teaches people to trust it blindly; `meta.warnings` are for exactly this, so a
  warning must be visible, not logged.
- **Every field editable**, a **product per line** via the existing
  `ProductPickerField`, batch number and expiry per line (`PurchaseLineEditor` is the
  editor already built for this shape — reuse it, or follow it closely).
- **The money comes from `PurchaseTotals`**, the same helper the purchase form and
  the write use. Not a second implementation, and not a figure the model supplied
  (the model's totals are context, never the record).
- **The save goes through the existing controllers**:
  `purchaseFormControllerProvider.notifier.createPurchase(header:, lines:)` creates a
  **draft**, and the receipt (`GrnController.receive`, i.e. the GRN screen) is the
  step that moves stock and posts the payable. Do not insert into `purchases`,
  `purchase_items` or `product_batches` from this feature, and do not add a second
  multi-statement write (I-2's warning is about exactly that window).
- After saving, hand the user to the next real step in the **existing** flow — the
  created purchase's detail, or `/purchase/:purchaseId/grn` to receive it.
- Route: **`/purchase/ocr`**, declared in `app_router.dart` beside the other
  `/purchase/...` routes, literal segments before parameterised ones, reached from
  the purchase screen (D-022 — a top-level path would leave the rail on Dashboard).
- Re-parsing must not leave a stale result on screen with no way to retry (**T-3**'s
  shape): the second failure needs its own control, and a retryable failure
  (D-032) needs a visible retry.

### 5. Tests

- `test/features/purchase_ocr/…` — the response mapper (the error envelope, the
  retryable code, a body that is not what was promised); the envelope's tolerant
  decode; the controller (the mapping to `PurchaseLineDraft`, the edits, the
  save's payload, a line with no product refused); the screen (no image yet, an
  image with no parse, the verify form, a warning shown, a retryable failure with a
  retry, a refused write left in place).
- `test/support/fake_purchase_ocr_repository.dart` and a mini-router helper,
  following `test/support/`'s shape. Have the fake **run the real rules** (the
  mime/size cap, the money math) so a screen that skips a check fails in a test. Make
  a fake's failure **persistent** until the test clears it, or GoRouter's double
  build retries it into a success before the assertion runs.
- A tall test window in the pump helper (`tester.view.physicalSize`) rather than
  scrolling, because a `SliverList` only mounts what is inside the viewport; a button
  below the fold needs `ensureVisible` before `tap`.
- **Riverpod 3 retries a failed provider build by itself** on a backoff: after
  clearing a failure flag, do not `pumpAndSettle` before asserting the error is gone.

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, taken synchronously from
  `requirePharmacyIdProvider`. Never `await …requirePharmacyIdProvider.future`
  (D-015).
- **Stock moves through triggers, never through the client** (D-011/D-013, D-023).
- **Money is computed once, by a pure helper** (`PurchaseTotals`, with
  `PurchaseTotals.round2` as the shared rounding rule).
- **A document that has posted stock is corrected by a return, never by an edit.** An
  OCR read that turns out wrong *after* receipt is a purchase return (or a corrected
  document) — never a rewrite. Before receipt, editing is fine.
- **`check_violation` (23514) messages reach the user verbatim.** Do not swallow them.
- **Never `select *` on `products`**: it carries the embedding (D-027). Use
  `ProductsRepository.columns`/`.projection`.
- Freezed: `abstract class X with _$X` + `// ignore: invalid_annotation_target` on the
  factory constructor. **Not** for the OCR envelope (plain classes).
- Consumer method names are `<verb><Entity>` (`createPurchase`).
- `describeError()` for provider failures; the raw error arrives wrapped in
  `ProviderException`.
- A controller owns its `TextEditingController`s and reports every change through a
  **listener**, not only `onSubmitted`.
- Shared widgets to reuse: `AppScaffold`, `AppButton`, `AppTextField`,
  `AppDropdownField`, `AppDateField`, `AppSearchField`, `SectionCard`, `StatusBadge`,
  `AppEmptyView`, `ErrorView`, `LoadingView`, `showConfirmDialog`, `AppBackButton`,
  `Validators`, `Formatters.*`, `Debouncer`, `ProductPickerField`,
  `PurchaseLineEditor`, `PurchaseTotalsPreview`.

---

## OPEN ITEMS THIS CHUNK MUST NOT MAKE WORSE

| ID | Issue | Why it matters here |
|---|---|---|
| N-2 | The Gemini key is free-tier, 5 requests/minute, and a burst is refused as `503` rather than `429` (D-032) | The verify screen must present that as **retryable** and distinct from an unreadable bill. A user tapping "read it again" twice is the most likely way to meet the quota. |
| T-3 | A failure after a successful first read keeps the stale value and offers no retry | Exactly the shape of "the first parse worked, the second did not". The screen must offer its own retry control on every failure, not only the first. |
| I-2 | A two-statement purchase write can leave a header with no lines | Do not add a third statement to the purchase write path: create a draft through `createPurchase`, and let the existing receipt step do the rest. |
| I-3 | A picker offers at most 200 rows | The per-line product picker is the existing one; do not make it worse, and note it if the OCR flow makes it feel worse. |

I-1, R-1, T-4, T-5 and **N-1** (push deferred to Phase 6), **N-3** (the Deno suite
is not in the gates) and **N-4** (no function logs) are open but not this chunk's
business — except that you should run the Deno suite anyway, and say so.

---

## CONTEXT MANAGEMENT — YOUR CALL

B2 is smaller than B1 was, but it is a whole feature: models, a service, a repository,
a screen and its tests. Rules, unchanged:

1. **Each chunk ends in a working, gated state.** Run all gates (and the Deno suite)
   at the end of every chunk.
2. **Hand off at ~60-70% context**, or earlier if quality visibly degrades. Do not
   push to 90%.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3c-summary.md` and `context/chat3d-opening-prompt.md`; add decisions
   at **D-033+**; leave the tree commit-ready.
4. **Never compress.** Do not skip tests to save context. If a chunk would need to cut
   corners, split it.
5. **If you finish B2 and context has room**, you may start chunk C — but re-run all
   gates first, and stop at the same 60-70% rule.

---

## BEGIN

Start by reading the files in STEP 0, output the 5-line understanding check, and then
say how you intend to build B2 — the envelope's shape in Dart, where the response
mapper lives, how the screen hands off to the GRN step, and what you will test — and
what (if anything) you need from the user before writing Dart. Wait for approval
before writing the feature.

Once approved, begin with the envelope models and the service behind them, and keep
the UI second.
