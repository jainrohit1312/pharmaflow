# Chat 4 / Phase 6, chunk 2 — Deployment, credentials and what is left

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **fourteenth** chunk brief of Chat 4, and the **second** of
> **Phase 6** — Chat 4's last phase. The chunk accounts are `chat3a` … `chat3l`, with
> `context/chat3l-summary.md` covering **Phase 6 chunk 1** — read it first. `PROGRESS.md`'s
> Chat Strategy table is the authority: **Chat 4 = Phase 5 + Phase 6**; Phase 5 is
> **COMPLETE** and Phase 6 is **IN PROGRESS (chunk 1 of n, done and gated)**.
>
> The handoff files after this chunk are `context/chat3m-summary.md` and
> `context/chat3n-opening-prompt.md`. New decisions continue at **D-060** (D-038 to
> D-059 are taken).
>
> **Phase 6's first chunk took everything that needed no account.** This one is the
> opposite half: it is mostly *accounts*, *credentials* and *deploys*, and **none of it
> can be done without the user**. Ask up front. The one thing Phase 6 cannot fake is a
> deploy — if a credential is missing, say so and do the part that does not need it.

---

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — authority on what is done, the gates, and every open item. Read the
   **"Chat 4 Progress — Phase 6, chunk 1"** section near the top and the open-items table
2. `context/chat3l-summary.md` — **the important one**: the eleven items chunk 1 closed,
   the two defects it found and fixed on the way (the CGST/SGST paisa, the gone bill),
   and the two judgement calls it flags for review
3. `docs/DEPLOYMENT.md` — the runbook this chunk executes. **Nothing in it has been run**
4. `MASTER_PLAN.md` — Phase 6's deliverables, minus the iOS one D-059 removed
5. `DECISIONS.md` — especially **D-059** (this phase's platform scope: Web → Android, no
   iOS, Windows fixed-but-not-launched — it supersedes the master plan), **D-056**
   (the alias key), **D-057** (the bill's two steps), **D-058** (a failure outranks a
   retained value), **D-007** (the pins), **D-004**/**D-015** (tenant scope), **D-045**
   (measurements never mutate production), **D-046**/**D-049** (dispatch), **D-052**
   (auto-send PO)
6. `HANDOFF_PROTOCOL.md` — the gate list, one `deno check` per entry point
7. `context/chat3m-opening-prompt.md` — this file

Then output a 5-line understanding check (what Phase 6 has left, what chunk 1 closed,
environment, two load-bearing pins, what you are about to build).

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`, no `db reset`
- Migrations: `supabase db push --yes` (the `--yes` matters). `supabase db query
  --linked --file <path>` runs a migration file or a test against the live database.
- Platform priority: **Web → Android → (iOS out of scope) → (Windows not a launch
  target)** (D-005 + **D-059**)
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
them — the way `phase2_stock_triggers.sql` … `phase6_alias_identity.sql` do. Run it
against the **pre-migration** database too: chunk 1's test produced 7 FAILs before the
migration and 0 after, and that is what made it evidence.

**Windows note:** the host runs commands through `cmd.exe`. There is no PowerShell, and
the daemon's shell guard refuses payloads containing `%`. `findstr` is case-sensitive —
use `/I` whenever the question is "is this present?" (D-038 records the false finding
that mistake produced). Keep large outputs small by piping to `findstr`.

---

## WHAT CHUNK 1 LEFT YOU (do not re-do, and do not re-open)

- **Phase 6 chunk 1 is complete and gated**: W-1 (the Windows build), A-1
  (`publishableKey`), I-1 (the reorder list), N-5 (the alias key — **migration 00030,
  30/30 applied**), T-3/T-4/T-5/T-6, the two named coverage gaps (**34 tests**), R-1's
  README, and `docs/USER_MANUAL.md` + `docs/DEPLOYMENT.md`.
- **627 Flutter tests, 181 Deno tests**, all green; `custom_lint` and `flutter analyze`
  clean; **30 migrations, 30/30 local and remote**; **five Edge Functions deployed**.
- **`flutter build windows --debug` works** (`build\windows\x64\runner\Debug\app.exe`).
  The **release** Windows build was deliberately not run — do not "finish" it unless the
  user asks (D-059).
- **The two permanent probe rows stay** (D-049's evidence): one `notification_logs` row
  and one in-app notification, both marked as probes. Do not delete them.
- **Two judgement calls from chunk 1 worth a glance, both one-line reversions**: the
  low-stock tab now shows the **shortfall** and no longer shows the value at cost
  (`low_stock_card.dart`); and the sale-return form's bill picker hint is three-way
  (`Loading the bills…`).

---

## SCOPE — Phase 6, chunk 2

### The deploy works, in D-059's order

| # | Work | Needs |
|---|---|---|
| 1 | **Vercel web deploy** (primary) | A Vercel account/token. Build the bundle, deploy the static output — Vercel has no Flutter, and `.env` is compiled **into** the bundle, so this is a build-time concern (`docs/DEPLOYMENT.md` §2) |
| 2 | **Android release signing + APK/AAB** | A generated upload keystore and its passwords — **the user chose "generate one, you give the password"**, so ask for the password and create it, or take an existing keystore's alias/passwords. Then the `build.gradle.kts` change `docs/DEPLOYMENT.md` §3.2 spells out (release currently signs with the **debug** keys) |
| 3 | **Play Store listing** | A Google Play developer account. Mostly paperwork only the account holder can do; the deliverable here is a tested AAB on an internal track plus the listing runbook |
| 4 | **Edge Function secrets** | `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `SENDGRID_API_KEY`, `SENDGRID_FROM_EMAIL`. `GEMINI_API_KEY` is already set |

### Then the items that were waiting on those credentials

- **D-046's alert dispatch** — the triggers that call `send-notification` for the
  low-stock and expiry alerts. The function is built, deployed and live-probed as far as
  a missing credential allows (it answers `skipped`, names the secret, and still writes
  both rows).
- **D-052's auto-send PO** — send an approved PO to the supplier over their
  `preferred_channel`. Same credentials.
- **N-1's push registration** — the Firebase project, the web service worker, the VAPID
  key, and the call that fills `device_tokens`. `NotificationService.getFcmToken()`
  answers `null` behind a seam (D-035/D-050) precisely so this is a change at one place.

### And the code-only items still open

| ID | Issue | Shape of the work |
|---|---|---|
| I-3 | A return form offers at most 200 received purchases | A searchable purchase picker, as the product picker already is (`features/purchase/presentation/widgets/product_picker_field.dart` is the pattern) |
| N-8 | A successful second read of a bill drops the supplier the human chose | Re-seed only the *lines* in `didUpdateWidget` when the parse changes, keeping the header |
| N-2 | The Gemini key is a free tier of 5 requests/minute, and a burst is shed as `503` | Decide: a paid tier, or a documented retry-once policy with a visible wait. Not a code change until the user decides |
| N-4 | A deployed function's `console.error` is only visible in the dashboard | Accept and probe deliberately, or find a log path for CLI 2.113.0 |
| D-027's residual | Whether to hide `products.embedding` behind column grants | Revisit **only with a live REST call in hand** — that is what stopped it the first time |
| T-1 | `dart run custom_lint` SDK language-version notice | Cosmetic; wait for upstream |
| D-1 | Remaining hand-written providers | Convert as features are touched |

### The ones that need a decision or a real dataset

- **N-7 — the hosted project requires email confirmation**, which contradicts the repo's
  own belief (`config.toml`'s `enable_confirmations = false` is local-stack-only). This is
  **a decision for the user, not a workaround**: confirm by hand is acceptable policy, or
  "Confirm email" is turned off in the hosted project, or the app gets a "resend
  confirmation" affordance. Chunk 1 did not settle it; asking is cheap.
- **N-9 — the vector floor (0.78) was measured against a one-product catalogue.** Re-tune
  once the catalogue has **50+ products**. **D-045 applies**: the measurement happens on a
  temporary tenant, never against the live function, and the open implementation question
  (an identity to act as — the guard correctly refuses a hand-edited `auth.users` row,
  N-7) must be answered *before* it starts.

### The user manual's remaining gap

`docs/USER_MANUAL.md` is written; what it does not yet carry is a **screenshot or a
walkthrough per screen**, which is worth doing once there is a deployed URL to point at
(the deploy comes first, so the manual does not have to be rewritten after it).

### What this chunk is not

- **Not a new feature phase.** A Phase 5 surface that wants something the server cannot
  give is a migration and a review — never a client-side calculation.
- **Not a licence to touch the pins** (D-007).
- **Not a reason to delete the two probe rows** (D-049).
- **Not a reason to re-litigate D-059's platform scope** — iOS needs a Mac; the user has
  said so.

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, read synchronously from
  `requirePharmacyIdProvider` (D-015). Server-side, from `get_my_pharmacy_id()`.
- **Functions act as the signed-in user** — the caller's JWT, never `service_role` for
  reads (D-004). A provider credential is a *secret*, not an identity change.
- **Stock moves through triggers, never through the client** (D-011/D-013/D-023).
- **A measurement never mutates production** (D-045).
- Freezed for table rows; **plain classes** for an RPC/function envelope.
- **`ref.mounted` after every await** (D-034); a platform capability gets a seam and a
  fake (D-035); a controller test keeps its provider alive with `container.listen(...)`.
- **Riverpod 3 retries a failed provider build by itself** — assert a *state*, never a
  read count (D-051). A **second `pumpWidget` in one test does not reliably re-apply a
  *family* provider override** (measured in chunk 1): split the test instead.
- **A failure is decided before a retained value** (D-058), and a screen has **one**
  failure surface.
- `flutter analyze` analyzes `test/**` too, and is stricter than `dart run custom_lint`:
  `avoid_redundant_argument_values`, `unused_element_parameter`, `avoid_escaping_inner_quotes`
  and `unused_import` all bite test files. Run `dart format` then `flutter analyze`
  before declaring a file done.
- **Verifying HTTP is done with `curl`** (`findstr /I`), never with a driven browser —
  and a `%` in a shell payload is refused by the daemon before it runs.

---

## CONTEXT MANAGEMENT

1. **This chunk is mostly external.** Do the code-only items (I-3, N-8) while waiting on
   accounts rather than blocking on them.
2. **Hand off at ~60-70% context**, or earlier if quality degrades. A PARTIAL chunk with
   a clean tree beats a rushed one.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3m-summary.md` and `context/chat3n-opening-prompt.md`; add decisions at
   **D-060+**; leave the tree commit-ready.
4. **Never compress.** Do not stub a screen, do not skip a test, do not tick a deploy
   that was not made. If a credential is missing, say so and do the part that does not
   need it. If a deploy cannot be verified, say what *was* verified and what was not —
   chunk 1's "the release build was not run, by instruction" is the precedent.
5. **Ask for the credentials, the accounts and N-7's decision up front.** One question at
   the start costs a turn; discovering a missing secret after three chunks costs a redo.

---

## BEGIN

Read the files in STEP 0, output the 5-line understanding check, then say **how you
intend to sequence this chunk** — what you can do with no external input (I-3, N-8, the
manual's remaining gap, a local `flutter build web` proof), and what blocks on the user
(the Vercel account, the Android keystore password, the Play account, the WhatsApp/
SendGrid/Firebase credentials, N-7's decision); what you will ask for and when; and what
you will verify and paste. **Wait for approval before starting.**
