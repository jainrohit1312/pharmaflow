# Chat 4 / Chunk B summary — the OCR core

**Status:** PARTIAL — **B1 (the Edge Function) is COMPLETE and live-verified; B2
(the Flutter seam and the verify screen) has not been started.**
**Date:** 2026-09-19
**Scope:** Phase 5, chunk B, split as its brief allowed (`context/chat3b-opening-prompt.md`
§ CONTEXT MANAGEMENT: "B1 (the function, `OcrService`, the repository, the upload) and
B2 (the verify screen, the save, the tests) is the natural seam"). The seam chosen at
hand-off is the server/client line: **everything above the HTTP boundary is done,
nothing below it is.** `chat3c-opening-prompt.md` is B2's brief.

---

## What B1 delivered

### `supabase/functions/` — created, first function deployed

```
supabase/functions/
  _shared/
    errors.ts          FunctionError + the situation vocabulary
    response.ts        the JSON envelope, status map, and CORS headers
    client.ts          userClient + requirePharmacyId (never service_role, D-004)
    base64.ts          a hand-written encoder (see D-031)
    base64_test.ts
  ocr-purchase-bill/
    gemini.ts          prompt, response schema, request builder, normalizer
    gemini_test.ts
    handler.ts         the request path, every effect injected
    handler_test.ts
    deps.ts            the real world: caller client, bucket, model endpoint
    index.ts           three lines: Deno.serve(createHandler(defaultDeps))
```

**The contract B2 codes against** (verified live, not just in tests):

```
POST https://<ref>.supabase.co/functions/v1/ocr-purchase-bill
Authorization: Bearer <user jwt>   apikey: <anon>
{ "path": "<pharmacy_id>/<year>/<file>" }

200 {
  "document": { "supplier_name", "gstin", "invoice_no", "invoice_date",
                "sub_total", "tax_total", "grand_total" },   // every field nullable
  "lines": [ { "raw_name", "qty", "free_qty", "rate", "mrp", "gst_percent",
               "batch_no", "expiry_date", "hsn_code", "confidence" } ],
  "meta": { "model", "warnings": [...], "image_path", "finish_reason" }
}
4xx/5xx { "error": { "code", "message" } }
```

- snake_case throughout, every field nullable, `null` means **the screen must ask** —
  never zero.
- `meta.warnings` is a list of sentences meant for a human ("Line 3: quantity 2.5 was
  rounded to 3.", "Read line 2's expiry as 30/06/2027 (day first, the Indian
  convention).", "No line items were read from the bill."). The verify screen should
  show them; they are the difference between a parse a user can check and one they
  have to trust.
- `meta.finish_reason` is `STOP` on a complete answer; anything else means the answer
  was cut short, and the function already adds a warning saying so.
- Error codes: `unauthorized`, `forbidden`, `invalid_request`, `not_found`,
  `too_large`, `not_configured`, `provider_unavailable`, `internal`. Of these,
  **`provider_unavailable` is the retryable one** (D-032: a free-tier quota refuses
  as `503`, not `429`), and `not_found` is what a bill that is not yours or not
  there looks like — deliberately indistinguishable.
- What the function does **not** do: write anything. It never touches `purchases`,
  `purchase_items` or `product_batches`.

### Live verification (the part that is normally missing)

`deno check` clean; **45 Deno tests** pass
(`deno test supabase/functions/_shared/base64_test.ts
supabase/functions/ocr-purchase-bill/gemini_test.ts
supabase/functions/ocr-purchase-bill/handler_test.ts` → `ok | 45 passed | 0 failed`),
covering the normalizer's untrusted-input cases, the request path with stubs, and the
encoder against `atob`.

Then the deployed function was exercised for real, through a throwaway tenant made by
public signup + a synthetic invoice PDF (a temporary `pdf`-based generator) uploaded
to the bucket:

```
200  document: ARIHANT DISTRIBUTORS / 27ABCDE1234F1Z5 / INV-2026-0042 / 2026-09-18
             2420 / 264.5 / 2684.5
     lines:    3, with qty, free_qty, rate, mrp, gst_percent, batch numbers and
               expiry dates converted 30/06/2027 -> 2027-06-30
     meta:     gemini-3.6-flash, warnings [], finish_reason STOP
```

**Residue after cleanup: one pharmacy (the real one), one user, zero stored bills.**
All throwaway tooling (the PDF generator, the live-check driver, a model diagnostic
function) was deleted, and the two objects and the tenant were removed. The bucket's
own `protect_delete` guard forced the object cleanup through the Storage API, which
is the correct path.

### Three findings, each worth more than the feature

1. **D-031 — the deployed runtime lacks `Uint8Array#toBase64`** (a TC39 proposal). It
   passed `deno check`, all 45 local tests, and then answered `500` in production.
   Finding it cost three deploys and a bisect through the deployed function (foreign
   path → 403, missing object → 404, narrowing it to the one unwitnessed step). The
   rule that follows: `supabase/functions/` uses language-core JavaScript only, and
   anything newer lives in `_shared/`, hand-written and `deno test`-covered.
2. **D-030 — the model the plan named was already retired.** The first live call
   answered `404 "models/gemini-2.5-flash is no longer available to new users …
   use models/gemini-3.6-flash"`. The name now lives in `DEFAULT_VISION_MODEL` with a
   `GEMINI_VISION_MODEL` secret override, and any change is verified by a live call.
   Also now known: `responseSchema` in the older dialect works (standard
   `responseJsonSchema` does not answer reliably), `inlineData` accepts PNG and PDF,
   and `maxOutputTokens` must be set because thinking shares the budget.
3. **D-032 — the key is free-tier: five requests per minute**, and a burst is shed as
   `503 UNAVAILABLE` rather than `429`. The reader deliberately does not retry; the
   app must present that failure as retryable and distinct from "this bill could not
   be read" (open item **N-2**).

**Also learned, for B2's UX:** the first live read of the same invoice (9 pt table
text) returned the header and tax total and *no lines*, with honest warnings; after
the table text became 12 pt — and a "read every row" instruction and an explicit
output cap were added in the same change — it parsed completely. Three variables
changed at once, so the cause is not isolated, but the lesson for the capture screen
stands: tell the user to fill the frame with the item table, and surface the
warnings.

---

## Files created

```
supabase/functions/_shared/errors.ts
supabase/functions/_shared/response.ts
supabase/functions/_shared/client.ts
supabase/functions/_shared/base64.ts
supabase/functions/_shared/base64_test.ts
supabase/functions/ocr-purchase-bill/index.ts
supabase/functions/ocr-purchase-bill/handler.ts
supabase/functions/ocr-purchase-bill/handler_test.ts
supabase/functions/ocr-purchase-bill/gemini.ts
supabase/functions/ocr-purchase-bill/gemini_test.ts
supabase/functions/ocr-purchase-bill/deps.ts
context/chat3b-summary.md          (this file)
context/chat3c-opening-prompt.md   (B2's brief)
```

**No Dart file changed.** `app/lib/services/ocr_service.dart` still throws
`UnimplementedError('TODO(phase-5)')` — that is B2's first job, with the rest of the
Flutter seam behind it. Temporary files created and deleted during the live check (a
PDF generator, a live-check driver, a diagnostic function) are **not** in the tree.

## Documentation

```
PROGRESS.md     Chunk B1 section; the "one Edge Function deployed" backend bullet;
                open items N-2 (free-tier quota), N-3 (the Deno suite is not in the
                gates), N-4 (no function logs in this CLI); Next Action = Chunk B2
DECISIONS.md    D-030 (the model), D-031 (no proposal-stage built-ins in a function),
                D-032 (the reader does not retry, and why)
```

---

## Verification evidence

```
deno check supabase/functions/ocr-purchase-bill/index.ts \
     supabase/functions/ocr-purchase-bill/{handler,gemini}_test.ts   -> clean
deno test (base64, gemini, handler)  -> ok | 45 passed | 0 failed (575ms)
dart format --output=none --set-exit-if-changed lib test -> 355 files, 0 changed
flutter analyze                      -> No issues found! (11.3s)
flutter test                         -> +397: All tests passed!
supabase functions deploy ocr-purchase-bill -> Deployed (728 kB, verify_jwt on)
live invocation                      -> 200 with the full envelope pasted above
residue check                        -> Arihant Pharmacy | 1 auth user | 1 profile | 0 bills
```

## Open risks / blockers

- **N-2 (Medium)** — the free-tier quota (5/minute) is the real limit on this
  feature at a counter. Decide before B2's verify screen is called done: paid tier,
  or a deliberate retry-once with a visible waiting state (D-032).
- **N-3 (Low)** — the Deno suite is not part of the handoff gates, so it will rot.
  A recommendation is in flight: add `deno check` + `deno test supabase/functions`
  to `HANDOFF_PROTOCOL`'s gate list, which is a change to that contract and needs a
  decision.
- **N-4 (Low)** — a deployed function's `console.error` is dashboard-only on this CLI
  version; debugging is a deploy-and-probe cycle (D-031 records the practice and its
  one temporary diagnostic).
- **Unisolated**: whether the 9 pt table was the reason the first live parse found no
  lines. Three things changed together. B2's screen is the right place to build the
  feedback loop (warnings shown, "photograph the table closely").
- The synthetic PDF is not a photograph of a real bill. The live evidence proves the
  *pipeline*; photo handling (glare, angle, multiple pages) is still unproven and
  should be tried with a real bill before the feature is called finished.

## What's next

Chunk **B2** — `context/chat3c-opening-prompt.md`: the envelope's Dart models,
`OcrService` over `functions.invoke`, `features/purchase_ocr/` (upload + invoke +
verify screen + save through the existing purchase controllers), the `/purchase/ocr`
route, and the widget tests. After B2, chunk C is smart matching (`match-product`,
`save-purchase-from-ocr`, alias learning, the embedding backfill).
