# Chat 4 / Chunk B — Phase 5: AI OCR core

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this file is the **second** chunk brief of Chat 4. Chat 4's overall brief
> is `context/chat3-opening-prompt.md` ("Chat 4 — Phase 5 + Phase 6"); it was split
> into chunks because Phase 5 does not fit one session. Chunk A is done and its
> account is `context/chat3a-summary.md`. `PROGRESS.md`'s Chat Strategy table is
> the authority for which phases belong to which chat: **Chat 4 = Phase 5 + Phase 6**.
>
> The next handoff files after this chunk are `context/chat3b-summary.md` and
> `context/chat3c-opening-prompt.md`. New decisions continue at **D-030**.

---

## STEP 0 — READ FIRST (do NOT skip)

Read in this exact order:

1. `PROGRESS.md` — authority on what is done, the gate output, the open items
2. `MASTER_PLAN.md` — Phase 5's place in the roadmap
3. `DECISIONS.md` — especially D-004, D-011/D-012/D-013, D-021, D-022, D-023, D-025
   and the Phase 5 four: D-026 … D-029
4. `HANDOFF_PROTOCOL.md`
5. `context/chat3a-summary.md` — what Chunk A built (migration 00022, its SQL test,
   the two models) and what it left uncertain
6. `context/chat3b-opening-prompt.md` — this file

Then output a 5-line understanding check:

- What Chunk B covers
- What Chunk A delivered (and what it deliberately did not)
- Environment (hosted Supabase, no Docker, Web-first)
- Two load-bearing dependency pins
- What you are about to build

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`, no `db reset`
- Migrations: `supabase db push` (the ONLY migration command)
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

`dart format` is not itself a gate, but the committed tree *is* formatter output,
so run it after writing Dart and before the gates. (T-1's SDK language notice from
`build_runner` and `custom_lint` is known and cosmetic.)

**Never run two `build_runner` processes at once** — concurrent runs corrupt
`.dart_tool`. If you use parallel subagents, the main agent runs codegen once at
the end. (Two concurrent `flutter test` runs are also best avoided.)

**Analyzer note:** `flutter analyze` covers `test/**` too, and
`avoid_redundant_argument_values` fires on arguments equal to a parameter's own
default *including inside test fixtures*. `find.text` also matches an
`EditableText`'s content, so a search field holding a term matches the same finder
the results do — scope such assertions to the card.

### Edge Functions without Docker — how to develop them here

`supabase functions serve` runs functions in containers. With no Docker on this
machine, develop an Edge Function by **deploying it and invoking the deployed
one**:

```
supabase functions deploy ocr-purchase-bill
supabase secrets set GEMINI_API_KEY=...        # secrets never go in the repo
```

- Never print, log or commit a secret. The client must never hold
  `GEMINI_API_KEY` either — the whole point of the function is that the key stays
  server-side. `app/.env` is for the public anon key only.
- Say plainly in the handoff **which path you used** to exercise the function
  (deploy + invoke, or the CLI's non-container path), and paste the raw output.
- There is no committed Deno/TypeScript test harness in this repo and no container
  to run one in. The honest verification for a function is a real invocation with a
  real bill image, and its raw response pasted into the summary. Do not claim a unit
  test you did not run, and do not stub the function to make it "testable".
- Deployment requires the CLI's login (already linked; `supabase migration list
  --linked` works).

---

## WHAT CHUNK A DELIVERED (do not re-do)

Migration `20260919000022_phase5_ai_notifications.sql`, applied 22/22, verified by
`supabase/tests/phase5_ai_notifications.sql` (29 assertions, all passing), plus:

- `products.embedding` — `extensions.vector(768)`, HNSW/cosine, partial index
  (D-027). **The client never selects it**; `ProductsRepository.columns/projection`
  exists for exactly that reason. Chunks C and E read it **server-side**.
- The private `purchase-bills` bucket, 10 MB, mime-restricted, with path-scoped
  storage policies: `<pharmacy_id>/<year>/<file>` (D-028). **This is where the OCR
  image goes.**
- `device_tokens` and `notification_logs` (Chunk D's tables).
- Dart models `DeviceToken` (+ `DevicePlatform`) and `NotificationLog` (+ its three
  enums). **Nothing in the app uses them yet** — Chunk D (notifications) does.

`supabase/functions/` does not exist yet. **This chunk creates it.**

---

## SCOPE — Chunk B: the AI OCR core

Take a supplier bill image, read it with Gemini Vision, let a human correct what
was read, and create a purchase through the write path the screens already use.

Chunk B does **not** include smart matching (Chunk C gives `match-product` and
alias learning a home): on this chunk's verify screen the product on each line is
chosen by hand, with the picker that already exists. Design the verify UI so that
swapping a hand-picked product for a suggested one is a small change in one place.

### 1. `supabase/functions/ocr-purchase-bill/` (new)

- Input: the caller's JWT (implicit) plus the **storage path** of an already
  uploaded bill — not a URL, and not the bytes. Validate the path, and read the
  object with a **user-scoped** Supabase client built from the `Authorization`
  header, so the storage policy decides what is readable. **Never `service_role`
  for reads (D-004).** A path outside the caller's tenant simply does not resolve;
  do not trust the path's tenant segment as a substitute for that.
- Then send the image to Gemini Vision with `GEMINI_API_KEY` from a function
  secret, and return structured data — a plain JSON envelope, not rows.
- Suggested envelope (adjust if the model's output suggests better): supplier name,
  invoice number, invoice date, per line `raw_name`, `qty`, `free_qty`, `rate`,
  `mrp`, `gst_percent`, `batch_no`, `expiry_date`, `hsn_code`, plus document totals
  and a per-line confidence if the model provides one. **Every field nullable** —
  the verify screen is where a human fixes what the model could not read — and
  parse defensively: the model's reply is untrusted input, not a contract.
- Record the model name you used as a decision: model names move, and a re-embed /
  re-parse with a different model is a change somebody should have to make on
  purpose. (`text-embedding`-style model choice for embeddings is D-027's; this is
  the vision model.)
- A shared `supabase/functions/_shared/` module for the user-scoped client factory
  and the error envelope is expected, so Chunk C/D/E's functions do not each
  reinvent it. Nothing in `supabase/functions/` imports from `app/`.

### 2. A real `OcrService`

`app/lib/services/ocr_service.dart` is a stub whose only method throws
`UnimplementedError('TODO(phase-5)')`. Implement it over
`supabase.functions.invoke(...)`, keep the `Provider` seam (a hand-written
`Provider` is allowed for a service — this is the "stub" exception in D-001), and
widen the surface only as far as this chunk needs. It should return a plain Dart
class (an RPC envelope — `ReportSummary` is the precedent), not a Freezed model and
not `Map<String, dynamic>` leaking into the UI.

Also expected in `features/purchase_ocr/`:

```
data/purchase_ocr_repository.dart      upload the image, invoke the function,
                                       map the envelope
application/purchase_ocr_controller.dart   @riverpod (codegen only); owns the
                                       picked image, the parse result, the edits
presentation/purchase_ocr_screen.dart  capture/pick → parse → verify → save
presentation/widgets/…
```

### 3. The image

- Pick or capture it with `image_picker` (already a dependency). On **Web** this is
  the platform that must work first (D-005): `image_picker_for_web` returns bytes,
  and a camera capture on desktop Chrome is a file dialog — say what actually
  happened on the platform you tested.
- Upload to the bucket as `<pharmacy_id>/<year>/<uuid>.<ext>` — `pharmacy_id` from
  `requirePharmacyIdProvider`, **read synchronously** (D-015). Keep the size under
  the bucket's 10 MB cap and the type inside its mime list, or the upload is
  refused by the bucket rather than by a function timeout; report *that* refusal
  verbatim, and treat a mime/size refusal as a user-facing message, not a crash.
- Keep the uploaded object's path with the parse result: the verify screen shows the
  image beside what was read, which is the only way a human can check it.

### 4. The verify screen, and the save

- Pre-fill the draft from the parsed envelope, let every field be corrected, and
  show the image next to the fields. An OCR screen with no visible confidence is a
  screen that teaches people to trust it blindly.
- **Saving goes through `PurchasesRepository`** — `create(...)` for the draft, and
  the receipt (`receive`) is the step that moves stock, exactly as the manual flow
  does (D-011/D-013). Do **not** insert into `purchases`/`purchase_items` from the
  OCR feature, and do not write `product_batches.qty` anywhere: quantity lives on
  the batch and moves only through the receipt or `checkout_sale` (D-023).
- The money is computed once by `PurchaseTotals` and both the preview and the write
  use it — the same helper the purchase form uses, not a second implementation.
- Correcting a **received** document is a return, never an edit (D-013, D-019,
  D-023). So an "OCR got it wrong" path on an already-received invoice is a purchase
  return or a corrected document — it is never a rewrite. If the screen allows the
  edit before receipt, that is fine; after receipt, it must not.
- After saving, hand the user to the next real step in the existing flow (the
  created purchase's detail, or the GRN screen that receives it). Do not build a
  parallel purchase UI.
- Route: **`/purchase/ocr`**, declared in `app_router.dart` beside the other
  `/purchase/...` routes and reached from the purchase screen. A screen that is not
  a shell destination nests under the one that owns it (D-022) — a top-level path
  would leave the rail on Dashboard. Literal segments are declared before
  parameterised ones, since declaration order is match order.

### 5. Tests

- `test/features/purchase_ocr/…` — the controller (the envelope's mapping, an
  unreadable field left null rather than defaulted, the edits, the save's payload)
  and the screen (an image with no parse yet, the verify form, a refused write left
  in place, a failed parse offering a retry).
- `test/support/fake_ocr_repository.dart` (or `fake_purchase_ocr_repository.dart`)
  and a mini-router pump helper, following the shape in `test/support/`: make a
  fake's failure **persistent** rather than one-shot, or GoRouter's double build
  will retry it into a success before the assertion runs. Where a real rule exists
  (the money math, the mime/size cap), have the fake **run the real rule** so a
  screen that skips a check fails in a test rather than in front of a user.
- A test window is made tall in the pump helper (`tester.view.physicalSize`) rather
  than scrolled, because a `SliverList` only mounts what is inside the viewport; a
  button below the fold needs `ensureVisible` before `tap`.
- **Riverpod 3 retries a failed provider build by itself** on a backoff: after
  clearing a fake's failure flag, do not `pumpAndSettle` before asserting the
  `ErrorView` is gone — and keep such a flag persistent until the test clears it.

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, taken synchronously from
  `requirePharmacyIdProvider`. Never `await …requirePharmacyIdProvider.future`
  (D-015).
- **Stock moves through triggers, never through the client** (D-011/D-012/D-013,
  D-023).
- **Money is computed once, by a pure helper**, used by both the screen and the
  write (`PurchaseTotals`, with `PurchaseTotals.round2` as the shared rounding rule).
- **A document that has posted stock is corrected by a return, never by an edit.**
- **`check_violation` (23514) messages reach the user verbatim.** Do not swallow
  them.
- **The chatbot's figures come from the database** (D-025, D-026) — if this chunk
  ever shows a figure the user could mistake for a report, it comes from an RPC.
- **Never `select *` on `products`**: it carries the embedding (D-027). The client
  uses `ProductsRepository.columns`; a new server-side reader names its columns too.
- Freezed: `abstract class X with _$X`, with `// ignore: invalid_annotation_target`
  on the factory constructor. A class that is not a table row (this chunk's OCR
  envelope, a draft payload) is a **plain class**, not Freezed.
- Consumer method names are `<verb><Entity>` (`createPurchase`) — the generated
  base class already defines `update`.
- State that must outlive navigation needs `@Riverpod(keepAlive: true)`; a
  kept-alive provider may only depend on kept-alive providers.
- Render provider failures through `describeError()`; the raw error reaches a screen
  wrapped in `ProviderException`.
- A controller owns its `TextEditingController`s and reports every change up through
  a **listener**, not only `onSubmitted` — a browser and a desktop have no submit
  key.
- Shared widgets to reuse rather than re-create: `AppScaffold`, `AppButton`,
  `AppTextField`, `AppDropdownField`, `AppDateField`, `AppSearchField`,
  `SectionCard`, `StatusBadge`, `AppEmptyView`, `ErrorView`, `LoadingView`,
  `showConfirmDialog`, `AppBackButton`, `Validators`,
  `Formatters.currency/dateDdMmmYyyy/monthYear`, `Debouncer`, `ProductPickerField`.

---

## OPEN ITEMS THIS CHUNK SHOULD NOT MAKE WORSE

Read the table in `PROGRESS.md` for the current list. The two that can plausibly
collide with an OCR flow:

| ID | Issue | Why it matters here |
|---|---|---|
| T-3 | The ledger's failure path offers a retry only on a first read. Low. | The same "an error with a stale value" shape will bite a verify screen that shows a parse result: a second failed parse must not leave the first parse's data on screen with no way to retry. |
| I-2 | A purchase return is two statements, so a refused line set can leave a header with no lines. Low. | The OCR flow creates a purchase; make it create a **draft** and let the existing receipt step do the rest, rather than adding a second multi-statement write. |

I-1, I-3, R-1, T-4, T-5 and the new **N-1** (push deferred to Phase 6) are open but
not this chunk's business.

---

## CONTEXT MANAGEMENT — YOUR CALL

Chunk B is the largest single feature of Phase 5: an Edge Function, a service, a new
feature directory and its tests. **It may need to split again** — B1 (the function,
`OcrService`, the repository, the upload) and B2 (the verify screen, the save, the
tests) is the natural seam, and a clean PARTIAL handoff is far better than a rushed
finish.

Rules, unchanged from Chat 4's brief:

1. **Each chunk ends in a working, gated state.** Run all five gates at the end of
   every chunk. If a chunk's work is not shippable, do not end the chunk there.
2. **Hand off at ~60-70% context**, or earlier if response quality visibly degrades.
   Do not push to 90%.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3b-summary.md` (or the next letter) describing what it delivered and
   `context/chat3c-opening-prompt.md` (or the next letter) as the following brief;
   add decisions to `DECISIONS.md` at **D-030+**; leave the tree commit-ready.
4. **Never compress.** Do not skip tests to save context. Do not stub the function
   and call it done. If a chunk would need to cut corners, split it.
5. **If you finish a chunk and context has room**, you may start the next one in the
   same session — but re-run all gates first, and stop at the same 60-70% rule.

---

## BEGIN

Start by reading the files listed in STEP 0, output the 5-line understanding check,
and then say how you intend to split Chunk B (and whether you intend to split it at
all) — how the function is exercised without Docker, what the envelope looks like,
and what you will verify against the live project. Wait for approval before writing
the function.

Once approved, begin with the Edge Function and the `OcrService` behind it, and keep
the verify UI second.
