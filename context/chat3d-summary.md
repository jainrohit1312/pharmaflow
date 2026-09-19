# Chat 4 / Chunk B summary — the OCR core (COMPLETE)

**Status:** COMPLETE. Chunk B is done in all three pieces; the next chunk is **C
(smart matching)**, briefed in `context/chat3e-opening-prompt.md`.
**Date:** 2026-09-19

| Piece | Scope | State |
|---|---|---|
| B1 | `supabase/functions/` — the deployed reader, its `_shared/` module, 45 Deno tests | DONE, **live-verified** (200 + a full parse; see below) |
| B2a | the envelope models, `OcrService`, `PurchaseOcrRepository`, `PurchaseOcrController` | DONE, 45 tests |
| B2b | the verify screen, the save, `/purchase/ocr`, the entry point, the widget tests | DONE, 11 tests |

**End to end, a user can now**: open Purchase → *Read a bill* → photograph or choose
a PDF → watch the reader work (with a visible retry if it is busy) → check the image
against what was read, fix anything, choose a product per line → **Save as a draft**
→ land on the document, where the existing goods receipt is one tap away.

## The three seams, and what sits behind each

1. **The function** (`ocr-purchase-bill`) — takes a storage path, reads the object
   as the caller, asks Gemini, returns `{ document, lines, meta }`. Writes nothing.
   Envelope, error codes, CORS and the live evidence are in
   `context/chat3b-summary.md`. Model: `gemini-3.6-flash` (D-030).
2. **The app's wire seam** — `OcrService.decodeOcrBill`/`ocrException` (pure),
   `PurchaseOcrRepository` (upload + invoke + the bucket's mirrored rules),
   `PurchaseOcrController` (upload → read, **one visible retry** — D-033,
   `ref.mounted` guards — D-034).
3. **The screen** — three states (choose / reading / verify), the save through
   `PurchaseFormController.createPurchase` (a draft), then the detail screen.

## What chunk C will want to know

- **The screen's per-line product picker is `ProductPickerField`**, one per line,
  inside `PurchaseLineEditor(showBatchFields: true)`. Suggestions belong there (or
  in what feeds `selectedName`), which is a change in one place.
- **`OcrLine.rawName` is the invoice text** the matcher must work from, and
  `OcrLine.toDraft()` already carries it into `PurchaseLineDraft.productNameRaw`.
- **`product_aliases`** (raw/normalized/product/supplier + a unique key on
  pharmacy, supplier, normalized name) and `normalize_product_name()` predate this
  phase; migration 00015 added the trigram index. **`products.embedding`** is
  `vector(768)` with an HNSW index, and nothing is embedded yet (D-027).
- **D-026's rule**: no free-form SQL from a model. The four RPCs it names
  (`low_stock_products`, `expiring_batches`, `top_products`, `dead_stock`) are
  chunk E's; a `match-product` capability is chunk C's, and the same shape applies —
  parameterised, `security definer` where it reads across the tenant, and the
  client's word is never a query.

## Files (all created in chunk B; nothing existing was rewritten)

```
supabase/functions/_shared/{errors,response,client,base64}.ts + base64_test.ts
supabase/functions/ocr-purchase-bill/{index,handler,gemini,deps}.ts + {handler,gemini}_test.ts
app/lib/data/models/ocr_purchase_bill.dart
app/lib/services/ocr_service.dart                        (the stub, implemented; codegen provider)
app/lib/features/purchase_ocr/data/bill_picker.dart
app/lib/features/purchase_ocr/data/purchase_ocr_repository.dart
app/lib/features/purchase_ocr/application/purchase_ocr_controller.dart
app/lib/features/purchase_ocr/presentation/purchase_ocr_screen.dart
app/test/data/models/ocr_purchase_bill_test.dart
app/test/services/ocr_service_test.dart
app/test/features/purchase_ocr/{data,application,presentation}/*_test.dart
app/test/support/{fake_purchase_ocr_repository,fake_bill_picker,purchase_ocr_test_app}.dart
context/chat3b-summary.md, context/chat3c-summary.md, context/chat3d-opening-prompt.md
context/chat3d-summary.md · context/chat3e-opening-prompt.md   (this handoff)
```

**Modified** (each additive): `app_router.dart` + `routes.dart` (the `/purchase/ocr`
route), `purchases_screen.dart` (the *Read a bill* action),
`test/support/purchase_test_app.dart` (the route + the two OCR overrides), and the
documentation (`PROGRESS.md`, `DECISIONS.md`, `HANDOFF_PROTOCOL.md`, `Makefile`).

## Verification evidence

```
deno test supabase/functions                    -> ok | 45 passed | 0 failed
deno check supabase/functions/ocr-purchase-bill/index.ts -> clean
dart format lib test                            -> 372 files, 0 changed
dart run custom_lint                            -> No issues found!
flutter analyze                                 -> No issues found!
flutter test                                    -> +453: All tests passed!
```

Live (from B1, unchanged since): `POST /functions/v1/ocr-purchase-bill` → **200**
with a three-line invoice parsed in full, dates converted `DD/MM/YYYY` → ISO,
`warnings: []`, `finish_reason: STOP`.

## Open risks / blockers

- **N-2 (Medium)** — the free-tier Gemini key: five requests a minute, refused as
  `503`. Now visible and bounded in the UI (D-033) but not solved; a busy counter
  will meet it.
- **A photograph of a real bill has still never been tried.** The pipeline is
  proven against a generated PDF; glare, angle and a creased page are unproven.
  The screen says "fill the frame with the item table" because B1 found a 9 pt
  table read as *no line items* while the same bill at 12 pt read completely.
- **N-4 (Low)** — no `functions logs` on this CLI; debugging a function is a
  deploy-and-probe cycle (D-031 records the practice).
- **B2b was not exercised on a device.** The picker seam is faked in tests, so
  "take a photo" has been proven to *dispatch* the right `ImageSource`, not to
  return a photo. That is a five-minute manual check for whoever next runs the app.

## What's next

**Chunk C — smart matching** (`context/chat3e-opening-prompt.md`): `match-product`,
alias learning into `product_aliases`, the `products.embedding` backfill, and
per-line suggestions on the verify screen. Then D (notifications), E (the chatbot)
and F (auto-send the PO).
