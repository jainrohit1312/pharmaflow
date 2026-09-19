# Chat 4 / Phase 6, chunk 3 — I-3, the web deploy, and the credentials

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **fifteenth** chunk brief of Chat 4, and the **third** of
> **Phase 6** — Chat 4's last phase. The chunk accounts are `chat3a` … `chat3m`, with
> `context/chat3m-summary.md` covering **Phase 6 chunk 2** — read it first. `PROGRESS.md`'s
> Chat Strategy table is the authority: **Chat 4 = Phase 5 + Phase 6**; Phase 5 is
> **COMPLETE** and Phase 6 is **IN PROGRESS (chunks 1-2 done and gated)**.
>
> The handoff files after this chunk are `context/chat3n-summary.md` and
> `context/chat3o-opening-prompt.md`. New decisions continue at **D-062** (D-038 to
> D-061 are taken).
>
> **What is left in Phase 6 is three things of different kinds**: code with no external
> dependency (I-3 and what the review turns up), deploys that need **accounts** (Vercel),
> and features that need **provider credentials** (dispatch, auto-send PO, push). Do the
> first while waiting on the other two. **The one thing Phase 6 cannot fake is a deploy** —
> if an account or a credential is missing, say so and do the part that does not need it.

---

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — authority on what is done, the gates, and every open item. Read the
   **"Chat 4 Progress — Phase 6, chunk 2"** section near the top and the open-items table
2. `context/chat3m-summary.md` — **the important one**: the APK and its verification,
   D-060, and N-8 (including the two things it flags: the reachability caveat, and the
   Riverpod life-cycle bug the test caught)
3. `docs/DEPLOYMENT.md` — the runbook. The Android half is **done** (§3.1); the Vercel
   half and the publish-time Android steps are written and **not run**
4. `MASTER_PLAN.md` — Phase 6's deliverables, minus the iOS one D-059 removed
5. `DECISIONS.md` — especially **D-056**–**D-061**: the alias key, the bill's two steps,
   a failure outranking a retained value, the platform scope, confirmation by hand, and
   the sideload APK. Also **D-007** (the pins), **D-015**/**D-004** (tenant scope),
   **D-036** (the matcher's one request per bill), **D-045** (measurements never mutate
   production), **D-046**/**D-052** (dispatch and auto-send PO), **D-049** (the probe rows)
6. `HANDOFF_PROTOCOL.md` — the gate list, one `deno check` per entry point
7. `context/chat3n-opening-prompt.md` — this file

Then output a 5-line understanding check (what Phase 6 has left, what chunks 1-2 closed,
environment, two load-bearing pins, what you are about to build).

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`, no `db reset`
- Migrations: `supabase db push --yes` (the `--yes` matters). `supabase db query
  --linked --file <path>` runs a migration file or a test against the live database.
- Platform priority: **Web → Android → (iOS out of scope) → (Windows not a launch
  target)** (D-005 + D-059)
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
deno check supabase/functions/match-product/index.ts
deno check supabase/functions/backfill-embeddings/index.ts
deno check supabase/functions/send-notification/index.ts
deno check supabase/functions/chat-sql-agent/index.ts
```

(`make test-functions` runs the Deno lines.) A migration, if one lands, needs a new
`supabase/tests/*.sql` that is atomic, self-rolling-back, asserts its numbers and prints
them. Run it against the **pre-migration** database too: chunk 1's test produced 7 FAILs
before its migration and 0 after, and that is what made it evidence rather than decoration.

**Build notes.** `flutter build apk --release` takes ~18 minutes on the first run, so run
it in the background (`is_background: true`) and do documentation while it goes; a
foreground run will hit the 10-minute tool timeout. `flutter build web --release` is much
quicker.

**Windows note:** the host runs commands through `cmd.exe`. There is no PowerShell, and
the daemon's shell guard refuses payloads containing `%` — and it also refuses some
commands that merely *look* like it cannot evaluate them (a quoted absolute path with
spaces plus a pipe, for instance). Keep commands plain, use relative paths where you can,
and pipe to `findstr` **with `/I`** whenever the question is "is this present?" (D-038).

---

## WHAT CHUNKS 1-2 LEFT YOU (do not re-do, and do not re-open)

- **628 Flutter tests, 181 Deno tests**, all green; `custom_lint` and `flutter analyze`
  clean; **30 migrations, 30/30 local and remote**; **five Edge Functions deployed**.
- **The Android APK ships**: `app/build/app/outputs/flutter-apk/app-release.apk`
  (80,295,479 bytes), debug-signed and verified with `apksigner` (D-061). **It has not
  been installed on a device** — that is the one thing no machine here can check.
- **The Windows build is fixed** (debug-verified only; the release build was deliberately
  not run — D-059).
- **The two permanent probe rows stay** (D-049). Do not delete them.
- **Two judgement calls from chunk 1, both one-line reversions**: the low-stock tab shows
  the shortfall and not "at cost"; the sale-return bill picker's hint is three-way.
- **One judgement call from chunk 2**: the verify form re-asks the matcher after a re-read
  when a supplier is already known. It spends one embedding request per re-read — the same
  one the old flow spent after re-picking the dropped supplier.

---

## SCOPE — Phase 6, chunk 3

### 1. I-3 — the searchable purchase picker (no external input; do this first)

The purchase-return form offers at most `returnablePurchaseLimit` (200) received
purchases in a plain dropdown, so a pharmacy with more than 200 received invoices cannot
return goods against an older one. The fix is the pattern the product picker already uses:
a tappable field that opens a **search dialog**
(`app/lib/features/purchase/presentation/widgets/product_picker_field.dart` is the shape —
a field, a dialog with an `AppSearchField`, a debounced term feeding a provider, and three
states for the results: has-value, has-error, loading).

What to watch:

- **The search side**: `PurchasesRepository.list` already takes a query with a search
  term (the purchase list screen has a search field), so check what exists before writing a
  new provider — the purchase list's own search is the thing to reuse, not to re-implement.
- **The three states, told apart**: T-5's lesson (D-058's family). "Still searching" and
  "nothing matches" must not look alike, and a failed search is its own state with its own
  sentence.
- **What the form needs from a choice**: a purchase id, plus enough to show the invoice
  number, the supplier and the date on the closed field. The form currently derives its
  label from the list it holds, so the picker has to carry the choice's label itself.
- Tests in `test/features/returns/presentation/purchase_return_form_screen_test.dart`,
  plus whatever the search itself needs.

### 2. The deploy — needs the user (N-11)

In D-059's order, and **nothing has been run**:

| Target | Needs | Where the steps are |
|---|---|---|
| **Vercel web** (primary) | A Vercel account/project (or a token) | `docs/DEPLOYMENT.md` §2 |
| Android APK | **Done** (D-061) — nothing to do unless a keystore arrives | §3.1 |
| Play publication | A keystore + a Play developer account; and every device reinstalls once | §3.2–3.5 |

Two facts that decide the shape of the web deploy: `.env` is **compiled into the bundle**
(so it must exist at build time, and the publishable key is public by design), and Vercel's
build image has no Flutter (so build the bundle and deploy the static output, or install the
SDK in the build step). Verify the deploy with `curl` — a status line and a header dump —
never by driving a browser.

### 3. The credentials — needs provider accounts

- **D-046's alert dispatch**: the triggers that call `send-notification` for the low-stock
  and expiry alerts. The function is built, deployed and live-probed as far as a missing
  credential allows (it answers `skipped`, names the secret, and still writes both rows).
- **D-052's auto-send PO**: send an approved PO over the supplier's `preferred_channel`.
- **N-1's push**: the Firebase project, the web service worker, the VAPID key, and the call
  that fills `device_tokens`. `NotificationService.getFcmToken()` answers `null` behind a
  seam (D-035/D-050) precisely so this is a change at one place.

Secrets and the `curl` that proves a dispatch: `docs/DEPLOYMENT.md` §6. A `sent` answer
proves the credential, the provider call and the log row together; a `skipped` answer names
the missing secret.

### 4. What the review turns up

Two things flagged and deliberately not settled:

- **N-8's follow-on is a design question, not a bug.** The verify form's "Read it again"
  button sits behind a failure card, and a failure needs a read to have failed — so a bill
  that is already on screen cannot be re-read at all. Either expose a re-read (the N-8 fix
  is the precondition that makes it safe), or accept that a re-read only ever follows a
  failure. **Ask the user which**, rather than adding a button nobody asked for.
- **I-1's trade** (the low-stock tab lost "at cost" and gained the shortfall) and **the
  three-way bill-picker hint** are both one-line reversions if the review disagrees.

### The code-only items still open

| ID | Issue | Shape of the work |
|---|---|---|
| N-2 | The Gemini key is a free tier of 5 requests/minute, and a burst is shed as `503` | A decision (paid tier, or a documented retry-once policy with a visible wait), not code until it is made |
| N-4 | A deployed function's `console.error` is only visible in the dashboard | Accept and probe deliberately, or find a log path for CLI 2.113.0 |
| D-027's residual | Whether to hide `products.embedding` behind column grants | Only with a live REST call in hand — that is what stopped it the first time |
| I-2 | A purchase return is two statements, so a refused set can leave a header with no lines | An RPC wrapping both, when the ledger next changes |
| T-1 | `dart run custom_lint` SDK language-version notice | Cosmetic; wait for upstream |
| N-10 | `flutter run -d chrome` cannot attach the debugger (Chrome 153 + dwds in Flutter 3.44.8) | `make run-web-server` until the SDK is upgraded |
| N-12 | **A Flutter upgrade will fail the Android build**: `mobile_scanner ^5.2.3` still applies the Kotlin Gradle Plugin, and Flutter now says future versions "will fail to build" for such plugins | A warning today (the APK builds, D-061); check that plugin's changelog for a Built-in Kotlin release when the SDK is next bumped |
| D-1 | Remaining hand-written providers | Convert as features are touched |

### 5. N-9 — needs a real catalogue

The vector floor (**0.78**) was measured against a **one-product** catalogue, so the window
it sits in rests on one vector and nine query texts. Re-tune it once the catalogue has
**50+ products**. **D-045 applies**: the measurement happens on a **temporary tenant**,
never against the live function, and the open implementation question — an identity to act
as, since the guard correctly refuses a hand-edited `auth.users` row — must be answered
**before** it starts. Nothing depends on the exact value; it is a one-line migration and the
tests move with it.

### What this chunk is not

- **Not a new feature phase.** A Phase 5 surface that wants something the server cannot
  give is a migration and a review — never a client-side calculation.
- **Not a licence to touch the pins** (D-007).
- **Not a reason to delete the two probe rows** (D-049).
- **Not a reason to re-litigate D-059's platform scope or D-061's signing choice** — the
  user has said so, twice.

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, read synchronously from
  `requirePharmacyIdProvider` (D-015). Server-side, from `get_my_pharmacy_id()`.
- **Functions act as the signed-in user** — the caller's JWT, never `service_role` for
  reads (D-004). A provider credential is a *secret*, not an identity change.
- **Stock moves through triggers, never through the client** (D-011/D-013/D-023).
- **A measurement never mutates production** (D-045).
- Freezed for table rows; **plain classes** for an RPC/function envelope.
- **`ref.mounted` after every await** (D-034); a platform capability gets a seam and a fake
  (D-035); a controller test keeps its provider alive with `container.listen(...)`.
- **Riverpod 3 retries a failed provider build by itself** — assert a *state*, never a read
  count (D-051). A **second `pumpWidget` in one test does not reliably re-apply a *family*
  provider override**: split the test instead. And **never modify a provider from a widget
  life-cycle** (`didUpdateWidget`, `initState`, `build`): it throws, and the fix is a
  post-frame callback (learned the hard way in chunk 2).
- **A failure is decided before a retained value** (D-058), and a screen has **one**
  failure surface.
- `flutter analyze` analyzes `test/**` too, and is stricter than `dart run custom_lint`:
  `avoid_redundant_argument_values`, `unused_element_parameter`, `avoid_escaping_inner_quotes`
  and `unused_import` all bite test files. Run `dart format` then `flutter analyze` before
  declaring a file done.
- **Verifying HTTP is done with `curl`** (`findstr /I`), never with a driven browser.

---

## CONTEXT MANAGEMENT

1. **Do I-3 first**, then the deploy if the accounts exist, then the credential work.
2. **Hand off at ~60-70% context**, or earlier if quality degrades. A PARTIAL chunk with a
   clean tree beats a rushed one.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3n-summary.md` and `context/chat3o-opening-prompt.md`; add decisions at
   **D-062+**; leave the tree commit-ready.
4. **Never compress.** Do not stub a screen, do not skip a test, do not tick a deploy that
   was not made. If a credential is missing, say so and do the part that does not need it.
   If something cannot be verified, say what *was* verified and what was not — chunk 1's
   "the release build was not run, by instruction" and chunk 2's "the APK has not been
   installed on a device" are the precedents.
5. **Ask for what is needed up front**: the Vercel account, the play/keystore decision, the
   provider credentials, and the N-8 follow-on question (expose a re-read, or not).

---

## BEGIN

Read the files in STEP 0, output the 5-line understanding check, then say **how you intend
to sequence this chunk** — what you can do with no external input (I-3, the review items,
the manual's screenshot pass once a URL exists) and what blocks on the user (the Vercel
account, the credential accounts, the N-8 follow-on decision); what you will ask for and
when; and what you will verify and paste. **Wait for approval before starting.**
