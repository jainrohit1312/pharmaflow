# Chat 4 / Chunk B2b — Phase 5: the OCR verify screen, the save and the route

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **fourth** chunk brief of Chat 4. Chat 4's overall brief is
> `context/chat3-opening-prompt.md`; the chunk accounts are `chat3a-summary.md`
> (the database), `chat3b-summary.md` (the Edge Function, live-verified) and
> `chat3c-summary.md` (**the Dart seam you are building on — read it first**).
> `PROGRESS.md`'s Chat Strategy table is the authority: **Chat 4 = Phase 5 + Phase 6**.
>
> The next handoff files after this chunk are `context/chat3d-summary.md` and
> `context/chat3e-opening-prompt.md`. New decisions continue at **D-035**.

---

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — authority on what is done, the gates, the open items
2. `MASTER_PLAN.md` — Phase 5's place in the roadmap
3. `DECISIONS.md` — especially D-011/D-013, D-015, D-021, D-022, D-023, D-026 … and
   the Phase 5 ones: **D-028 … D-034**
4. `HANDOFF_PROTOCOL.md` — note the gate list now includes the Deno gates (N-3)
5. `context/chat3c-summary.md` — **the important one**: B2a's exact API surface, the
   two traps it paid for, and what is left
6. `context/chat3d-opening-prompt.md` — this file

Then output a 5-line understanding check:

- What B2b covers, and what B1/B2a already finished
- What B2a delivered (the controller's state, the envelope, the rules)
- Environment (hosted Supabase, no Docker, Web-first)
- Two load-bearing dependency pins
- What you are about to build

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`, no `db reset`
- Migrations: `supabase db push` — **B2b should need none**
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

(the last two are the Edge Functions' gates, added with N-3; `make test-functions`
runs both. B2b should not change a function — but the gates run them.)

**Never run two `build_runner` processes at once.** `dart format` is not itself a
gate, but the committed tree *is* formatter output, so run it after writing Dart.

**Analyzer note:** `flutter analyze` covers `test/**` too, and
`avoid_redundant_argument_values` fires on arguments equal to a parameter's own
default *including inside test fixtures*. `find.text` also matches an
`EditableText`'s content — scope such assertions to the card.

---

## WHAT B1 AND B2a DELIVERED (do not re-do)

- **B1**: `ocr-purchase-bill` deployed and live-verified, with `_shared/` (errors,
  envelope + CORS, caller-scoped client, base64) and 45 Deno tests. Its envelope and
  error codes are in `context/chat3b-summary.md`.
- **B2a**: the whole Dart seam — `OcrPurchaseBill`/`OcrDocument`/`OcrLine`/`OcrMeta`,
  `OcrService` over `functions.invoke`, `PurchaseOcrRepository` (upload + invoke +
  the mirrored bucket rules), and `PurchaseOcrController` with the visible retry
  (D-033). 45 new tests. **No screen exists yet, and nothing in the Flutter tree
  calls any of it from a widget.**

Do not re-implement the upload, the decode, the retry policy or the rules. The
screen's job is to *call* them and to show what they say.

---

## SCOPE — Chunk B2b: the screen, the save, the route

### 1. `features/purchase_ocr/presentation/purchase_ocr_screen.dart`

The flow a user sees:

1. **Pick or capture** a bill — `image_picker`, the repo's first use of it. Web is
   the platform that must work first (D-005): `image_picker_for_web` returns bytes,
   a "camera" capture on desktop Chrome is a file dialog. Offer both sources
   (`ImageSource.gallery` / `ImageSource.camera`), and **say in the handoff which
   one you actually tried and on what**.
   **Gotcha:** `XFile.mimeType` can be `null` (it often is outside the browser).
   Derive the type from the file name's extension instead of passing `null` into
   `validatePick` and telling the user their file has no type — add the helper to
   `PurchaseOcrRepository` (a static, tested, mirroring `extensionFor`) and use it
   on both sides.
   Check the pick *before* uploading, with `PurchaseOcrRepository.validatePick`, so
   a 40 MB HEIC is refused with a sentence rather than a round trip.
2. **Show the image** (`Image.memory(scan.bytes)`) beside what was read, and show
   `meta.warnings` and `meta.isTruncated` — a parse nobody can check is a parse
   nobody should trust. A capture hint belongs here too: B1 found a 9 pt table read
   as *no line items* while the same bill at 12 pt read completely, so "fill the
   frame with the item table" is a real instruction, not a platitude.
3. **The wait and the retry** (D-033): while `isBusy && !isRetrying`, "Reading the
   bill…"; while `isRetrying`, *"The reader is busy — retrying…"*; on a failure that
   is `errorIsRetryable`, the message plus a **Try again** control calling
   `rescan()`; on a failure that is not, the message plus **Choose another bill**.
   A failure must be visible on **every** attempt, including a re-read after a
   successful first parse — T-3's shape, which is why the controller keeps the
   previous scan *and* sets the error.
4. **Verify**: the header (supplier, invoice number, invoice date, notes) and the
   lines, all editable, pre-filled from `scan.bill.toLineDrafts()`. Reuse
   `PurchaseLineEditor` with `showBatchFields: true` (batch number + expiry are
   required for a receipt) and its `ProductPickerField` for the product, which every
   line needs — `PurchaseLineDraft.productId` is `null` from the parse on purpose
   (matching is Chunk C), and `validateLines` refuses a line without one.
   Show the model's own confidence where it is low (`OcrLine.isUnsure`) rather than
   hiding it.
5. **The money comes from `PurchaseTotals`** — the same helper the manual form and
   the write use. The reader's totals are context (the header can show them beside
   the computed ones); they are never the record.
6. **Save** through the **existing** controller:
   `ref.read(purchaseFormControllerProvider.notifier).createPurchase(header:, lines:)`,
   which writes a **draft**. Then invalidate `purchasesListControllerProvider` and
   `purchaseWithLinesProvider(saved.id)` and `context.go(Routes.purchaseDetail(saved.id))`
   — exactly what `PurchaseFormScreen` does, so the receipt is the existing GRN step
   one tap away. **Do not** insert into `purchases`/`purchase_items`/`product_batches`
   from this feature, and do not add a second multi-statement write (D-011/D-013,
   I-2). An OCR read that turns out wrong *after* receipt is a purchase return.

### 2. The route

- `Routes.purchaseOcr = '/purchase/ocr'` in `app/lib/core/router/routes.dart`, and
  the route declared in `app_router.dart` **beside** the other `/purchase/...`
  entries, literal segment before the parameterised ones (declaration order is match
  order — `/purchase/ocr` must not be read as a purchase id). D-022: a screen that
  is not a shell destination nests under the one that owns it, so the rail stays on
  Purchase.
- Reached from `features/purchase/presentation/purchases_screen.dart`, where
  `/purchase/new` and `/purchase/grn` are already offered. Add it in the same shape
  (button or action), so the three ways into a purchase read as one set.

### 3. Tests

- `test/features/purchase_ocr/presentation/purchase_ocr_screen_test.dart` — the
  empty state, a picked bill being read, **the visible retry** (with
  `ocrRetryDelayProvider` overridden to zero), a retryable failure offering Try
  again, a non-retryable failure offering another bill, warnings shown, the verify
  form pre-filled, a line with no product refused by the form's own rule, and the
  save's payload (`header.supplierId`, `invoiceNo`, the lines' `productId`/`qty`/
  `batchNo`) followed by the navigation to the purchase.
- `test/support/purchase_ocr_test_app.dart` — a mini-router pump helper in
  `test/support/purchase_test_app.dart`'s shape, wiring
  `purchaseOcrRepositoryProvider`, `requirePharmacyIdProvider`,
  `ocrRetryDelayProvider` and (for the save) the **existing**
  `FakePurchasesRepository` + `supplierOptionsProvider` + `purchaseTaxSplitProvider`
  overrides. Make the window tall (`tester.view.physicalSize`); a button below the
  fold needs `ensureVisible` before `tap`.
- The fake you need already exists: `test/support/fake_purchase_ocr_repository.dart`
  (`parseFailures` is a per-attempt queue; `busyReaderFailure()` and
  `unreadableBillFailure()` are the two canned failures). Have the screen's fake run
  the **real** rules, and keep a failure persistent on purpose rather than one-shot
  — GoRouter builds a route more than once before the first frame settles.
- **Riverpod 3 retries a failed provider build by itself** on a backoff: after
  clearing a failure flag, do not `pumpAndSettle` before asserting the error is gone.

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, read synchronously from
  `requirePharmacyIdProvider` (D-015). The controller already does this.
- **Stock moves through triggers, never through the client** (D-011/D-013, D-023).
- **Money is computed once, by a pure helper** (`PurchaseTotals.round2` is the
  shared rounding rule).
- **A document that has posted stock is corrected by a return, never by an edit.**
- **`check_violation` (23514) messages reach the user verbatim.** Do not swallow them.
- **Never `select *` on `products`** (D-027): it carries the embedding. Use
  `ProductsRepository.columns`.
- **`ref.mounted` after every await before writing state** (D-034), and infer
  provider override lists (`Override` is not exported by `flutter_riverpod`).
- A controller owns its `TextEditingController`s and reports every change through a
  **listener**, not only `onSubmitted` — a browser and a desktop have no submit key.
  The manual purchase form's `_LineSlot` shape is the precedent to copy.
- Shared widgets to reuse: `AppScaffold`, `AppButton`, `AppTextField`,
  `AppDropdownField`, `AppDateField`, `SectionCard`, `StatusBadge`, `AppEmptyView`,
  `ErrorView`, `LoadingView`, `showConfirmDialog`, `AppBackButton`, `Validators`,
  `Formatters.*`, `ProductPickerField`, `PurchaseLineEditor`, `PurchaseTotalsPreview`.

---

## OPEN ITEMS THIS CHUNK MUST NOT MAKE WORSE

| ID | Issue | Why it matters here |
|---|---|---|
| N-2 | Free-tier key, 5 requests/minute, refused as `503` (D-032/D-033) | The screen is where the wait is explained. A user who can tap "read it again" freely is a user who will exhaust the minute. |
| T-3 | A failure after a successful first read keeps the stale value and offers no retry | The second parse failing must show its own error *and* a retry, not a form that looks fine. |
| I-3 | A picker offers at most 200 rows | The per-line product picker is the existing one; note it if the OCR flow makes it feel worse. |

N-1 (push deferred), N-4 (no function logs) and the older items are not this
chunk's business.

---

## CONTEXT MANAGEMENT — YOUR CALL

B2b is one screen, one route and its tests — smaller than B2a, but it is the first
UI for this feature and it has more moving parts than it looks. Rules, unchanged:

1. **Each chunk ends in a working, gated state.** Run every gate (including the
   Deno pair) at the end of every chunk.
2. **Hand off at ~60-70% context**, or earlier if quality visibly degrades.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3d-summary.md` and `context/chat3e-opening-prompt.md`; add decisions
   at **D-035+**; leave the tree commit-ready.
4. **Never compress.** Do not skip tests to save context. If a chunk would need to
   cut corners, split it.
5. **If you finish B2b and context has room**, chunk C (smart matching) may start —
   re-run all gates first, and stop at the same 60-70% rule.

---

## BEGIN

Start by reading the files in STEP 0, output the 5-line understanding check, and
then say how you intend to build B2b — the screen's states, where the save hands
off, how the picker's mime type is resolved, and what you will test — plus anything
you need from the user before writing the screen. Wait for approval before writing
the feature.

Once approved, begin with the screen's states and the retry UI, and keep the save
last.
