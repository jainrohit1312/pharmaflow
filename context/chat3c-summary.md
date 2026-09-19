# Chat 4 / Chunk B summary — the OCR core

**Status:** PARTIAL — **B1 (the Edge Function) is COMPLETE and live-verified; B2a
(the Dart seam) is COMPLETE; B2b (the verify screen, the save, the route and the
widget tests) has not been started.**
**Date:** 2026-09-19
**Chunk B split twice, at two natural seams:**

| Piece | Scope | State |
|---|---|---|
| B1 | `supabase/functions/` — the deployed reader, its `_shared/` module, 45 Deno tests | DONE, live-verified (see `context/chat3b-summary.md`) |
| B2a | `data/models/ocr_purchase_bill.dart`, `services/ocr_service.dart`, `features/purchase_ocr/data/…` + `application/…` | DONE, 45 new Flutter tests |
| B2b | the verify screen, the save through the existing controllers, `/purchase/ocr`, widget tests | **NEXT** — `context/chat3d-opening-prompt.md` |

Nothing in the Flutter tree calls the reader from a *screen* yet: the seam is
complete and tested, and no widget uses it.

---

## B2a's contract (what B2b builds on)

**The function's envelope** is in `context/chat3b-summary.md`; the Dart side of it
is now:

```dart
// data/models/ocr_purchase_bill.dart — plain classes, not Freezed
OcrPurchaseBill { OcrDocument document; List<OcrLine> lines; OcrMeta meta;
                  bool get isEmpty; List<PurchaseLineDraft> toLineDrafts(); }
OcrDocument     { String? supplierName, gstin, invoiceNo; DateTime? invoiceDate;
                  double? subTotal, taxTotal, grandTotal; }
OcrLine         { String? rawName, batchNo, hsnCode; int? qty, freeQty;
                  double? rate, mrp, gstPercent, confidence; DateTime? expiryDate;
                  bool get isUnsure;   // confidence < 0.7
                  PurchaseLineDraft toDraft(); }
OcrMeta         { String? model, imagePath, finishReason; List<String> warnings;
                  bool get isTruncated; }   // finishReason != 'STOP'
const double defaultOcrGstPercent = 12;
```

**The flow** (`features/purchase_ocr/application/purchase_ocr_controller.dart`):

```dart
purchaseOcrControllerProvider            // @riverpod, auto-dispose
  state: PurchaseOcrState { OcrScan? scan; bool isBusy; bool isRetrying;
                            Object? error; bool errorIsRetryable;
                            bool get hasScan; }
  methods: pickAndScan({required List<int> bytes, required String mimeType,
                        String? fileName})   // upload → read
           rescan()                          // read again, no second upload
           clear()
OcrScan { Uint8List bytes; String mimeType; String storagePath; OcrPurchaseBill bill; }
ocrRetryDelayProvider                    // 3 s; override it in tests
```

`isRetrying` is the "please wait, retrying" state (D-033): it is true only while
the one automatic retry waits, and it is *state*, so the screen renders it. A
failure that survives it has `errorIsRetryable == true` and must be shown as
retryable, never as "that bill could not be read".

**The rules**, as tested statics on `PurchaseOcrRepository` — the screen should use
them for immediate feedback, and the write enforces them anyway:

```dart
static const int maxBillBytes = 10 * 1024 * 1024;
static const List<String> allowedMimeTypes = ['image/jpeg','image/png','image/webp','application/pdf'];
static String? validatePick({required String? mimeType, required int sizeInBytes});
static String extensionFor(String mimeType);
static String newBillFileName({required String mimeType, required DateTime now, int? nonce});
static String storagePath({required String pharmacyId, required DateTime now, required String fileName});
```

**Errors** (`services/ocr_service.dart`): the function's sentence and code reach the
user verbatim; `isRetryableOcrError(error)` is the single retryability rule
(`provider_unavailable`, `unreachable`). `describeError()` unwraps a
`ProviderException` if the error arrives through a provider.

## Two traps B2a already paid for

1. **`ref.mounted` after every await before writing `state` (D-034).** Riverpod 3
   disposes a provider with no listeners, so a screen that navigates away mid-read
   makes the next `state = …` throw from an unawaited future. The controller is
   guarded; a screen that *watches* it is what keeps it alive, and a test that
   drives it directly must `container.listen(...)`.
2. **`Override` is not exported by `flutter_riverpod`.** Provider override lists in
   tests are inferred (`overrides: [ … ]`), never `<Override>[ … ]`.

## Files created (all new)

```
app/lib/data/models/ocr_purchase_bill.dart
app/lib/services/ocr_service.dart                     (the stub, implemented + codegen)
app/lib/services/ocr_service.g.dart                   (generated)
app/lib/features/purchase_ocr/data/purchase_ocr_repository.dart
app/lib/features/purchase_ocr/data/purchase_ocr_repository.g.dart   (generated)
app/lib/features/purchase_ocr/application/purchase_ocr_controller.dart
app/lib/features/purchase_ocr/application/purchase_ocr_controller.g.dart (generated)
app/test/data/models/ocr_purchase_bill_test.dart
app/test/services/ocr_service_test.dart
app/test/features/purchase_ocr/data/purchase_ocr_repository_test.dart
app/test/features/purchase_ocr/application/purchase_ocr_controller_test.dart
app/test/support/fake_purchase_ocr_repository.dart
context/chat3c-summary.md          (this file)
context/chat3d-opening-prompt.md   (B2b's brief)
```

**No existing file was modified** except the documentation below — the seam is
additive, and nothing else in the app references it yet.

## Documentation

```
PROGRESS.md         Chunk B2a section; N-3 marked resolved; Next Action = B2b;
                    442 Flutter tests + 45 Deno tests
DECISIONS.md        D-033 (the retry lives in the app, with a visible wait),
                    D-034 (ref.mounted after an await)
HANDOFF_PROTOCOL.md gate block gained `deno test supabase/functions` and
                    `deno check supabase/functions/ocr-purchase-bill/index.ts` (N-3)
Makefile            a `test-functions` target running both
```

**Note on N-3.** The instruction was that the Deno gates had been added, but
neither `HANDOFF_PROTOCOL` nor the `Makefile` contained them in this working tree,
so they were added here — the two commands are verified from the repository root
(`ok | 45 passed | 0 failed` and a clean `deno check`). If the intended wording
differs, it is a one-line change in two files.

## Verification evidence

```
deno test supabase/functions                                -> ok | 45 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts    -> clean
dart format lib test                                        -> 366 files, 0 changed
flutter analyze                                             -> No issues found!
flutter test                                                -> +442: All tests passed!
```

## Open risks / blockers

- **N-2 (Medium)** — the free-tier quota (5 requests/minute). D-033 makes the
  retry visible and bounded, but a busy counter still meets it. Unchanged.
- **`image_picker`'s mime type**: `XFile.mimeType` is `null` on some platforms, and
  `validatePick` refuses a file with no type. B2b must derive the type from the file
  name's extension (a small helper worth adding to the repository with a test)
  rather than passing `null` through and showing the user "that file has no type".
- **The screen is where the legibility lesson belongs.** B1 found that a 9 pt table
  in a generated PDF read as *no line items* while the same bill at 12 pt read
  completely. The capture UI should say "fill the frame with the item table", and
  `meta.warnings` must be visible rather than logged.
- **Nothing has been tried against a photograph of a real bill yet.** The seam is
  proven against a synthetic PDF; a photo (glare, angle, a creased page) is still
  unproven, and B2b's screen is the first place a person could try one.

## What's next

Chunk **B2b** — `context/chat3d-opening-prompt.md`: the verify screen, the retry
UI, the save through `PurchaseFormController.createPurchase` → draft → the existing
GRN step, the `/purchase/ocr` route, and the widget tests. After B2b, chunk C is
smart matching (`match-product`, `save-purchase-from-ocr`, alias learning, the
embedding backfill).
