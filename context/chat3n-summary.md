# Chat 4 / Phase 6, chunk 3 — the Vercel config and the re-read button (COMPLETE)

**Status:** **COMPLETE** (chunk 3 of n). Phase 6 stays open. This chunk did the two
things the spec asked for: it **wrote the web deploy** — a build config for Vercel and
the runbook that goes with it, neither of which has been run — and it **exposed the
re-read** on the bill reader's verify screen, which is the tap the N-8 fix had been
waiting for since chunk 2. `context/chat3o-opening-prompt.md` is the next chunk.
**Date:** 2026-09-20
**Decisions:** **D-062** (a bill gets three reads, and the first one counts),
**D-063** (`vercel.json` lives in the Root Directory, not the repository root).

---

## What this chunk ships

### 1. The Vercel web deploy, configured and not run (D-063)

Two artifacts, and one correction to the spec:

- **`app/vercel.json`** — the build config: `framework: null` (the "Other" preset), an
  **empty** `installCommand`, a `buildCommand` that does the whole job, and
  `outputDirectory: build/web`, plus the SPA rewrite and a `no-cache` header on
  `flutter_service_worker.js`.
- **`docs/DEPLOY_VERCEL.md`** — the runbook: import the repo, **Framework Preset Other /
  Root Directory `app`**, set `SUPABASE_URL` and `SUPABASE_ANON_KEY`, deploy, verify with
  `curl`, attach a custom domain, and the eight failures worth recognising.
- **No secret in either file.** Both name the variables; neither carries a value.

**The spec asked for `vercel.json` at the repository root, and that would not have
worked.** Vercel reads the file from **the project's root directory** — the Root
Directory setting — and with a Root Directory configured the build *cannot read files
outside it* (Vercel's own wording, quoted in D-063). A root-level copy is silently
ignored, and the failure it produces looks like anything but a misplaced file: no
Flutter SDK, no `build_runner` step, an empty `.env`. It is committed at
`app/vercel.json`, which is where Root Directory `app` makes Vercel look.

**What the build command does, in order** (and why each step is not optional):

1. `FLUTTER_SUPPRESS_ANALYTICS`, and `$HOME/flutter/bin` onto `PATH`.
2. Download the pinned Flutter Linux archive and unpack it — Vercel's build image is
   Amazon Linux 2023 and **ships no Flutter**. Nothing outside the project directory
   survives between builds, so this is paid on every deploy.
3. `git config --global --add safe.directory "$HOME/flutter"` — the SDK is a git
   checkout and its version check shells out to `git`.
4. `flutter --version` — prints the SDK version into the build log.
5. `flutter pub get`.
6. **`dart run build_runner build --delete-conflicting-outputs`** — the
   `.g.dart`/`.freezed.dart` files are **gitignored**, so a clone has none and the app
   does not compile without this. It is the step most likely to be omitted.
7. Write `app/.env` from `SUPABASE_URL` and `SUPABASE_ANON_KEY`. `pubspec.yaml` declares
   `.env` under `assets:`, so the bundle's Supabase project comes from here and nowhere
   else — which is why the variables must exist at **build** time.
8. `flutter build web --release`.

### 2. The re-read is exposed, and N-8 is reachable at last (D-062)

The verify screen's "What the reader saw" card now carries the affordance the chunk-2
fix made safe:

- A small **text** button — `TextButton.icon`, not a filled action — because reading the
  bill was the screen's purpose and this is the small way back to it. It does not compete
  with "Save as a draft".
- **"Re-read? Uses one AI call."** before anything is spent, through the app's existing
  `showConfirmDialog`, with Cancel meaning nothing happens.
- A **counter** under it: *Attempt 2 of 3* on a form that was reached through the first
  read. The number is the attempt a tap **would spend**, which is what makes the limit
  legible before it is hit.
- **Three reads per bill per session**, counted on the **state** (`PurchaseOcrState.reads`,
  incremented when a read *starts* and saturating at `maxReads`), because it is a
  property of the bill and the screen is rebuilt every frame.
- The button is **disabled while a read is out** (and the counter says
  *Reading the bill again…*, because the form is otherwise still for as long as the
  reader takes), and after the third read it reads **"Max attempts reached"**.
- The verify form's **own failure card is capped with it** — a failure does not earn a
  bill a fourth read — and says so when the allowance is gone. Leaving one of the two
  working would have put two re-read controls on one screen contradicting each other.

**N-8's "correct but latent" caveat is now closed.** Chunk 2 fixed the re-read so it
keeps the supplier and the notes while taking the new parse, but nothing a user could tap
produced a second read. This button is that tap, and the test that proves the behaviour
**drives the screen** rather than the controller. The harness's `configure:` hook stays
with its comment rewritten: it is for triggers no widget offers.

### 3. N-12 — reviewed, deliberately deferred

As instructed: no action. It is a warning today (`mobile_scanner` applies the Kotlin
Gradle Plugin), its trigger is a Flutter SDK upgrade that has not happened, and the item
already records what to check when one does. The row in `PROGRESS.md` now says the review
happened.

---

## Files

```
app/vercel.json                        (new) the build config for the Vercel route
docs/DEPLOY_VERCEL.md                  (new) the web deploy runbook
docs/DEPLOYMENT.md                     §2.2 rewritten onto the config; the §0 status note,
                                       §7 checklist context and §8 table updated
docs/USER_MANUAL.md                    the re-read, in the user's words, in the bill section
README.md, PROGRESS.md, DECISIONS.md   status, the chunk section, D-062 and D-063
context/chat3n-summary.md              (this file)
context/chat3o-opening-prompt.md       (Phase 6's next chunk)
```

**Modified:**

```
app/lib/features/purchase_ocr/application/purchase_ocr_controller.dart
    PurchaseOcrState: `reads` + `maxReads` + `canReadAgain` + `nextRead` +
    `withReadStarted()`; every `with*` carries the count; `_read` counts on start;
    `rescan()` documents why it is *not* capped
app/lib/features/purchase_ocr/presentation/purchase_ocr_screen.dart
    the re-read text button, the confirmation dialog, the counter, the cap on both
    failure cards, and `_ReadBack`'s four new parameters
app/test/features/purchase_ocr/presentation/purchase_ocr_screen_test.dart
    5 new widget tests, including the N-8 transition driven by the button (637th…)
app/test/features/purchase_ocr/application/purchase_ocr_controller_test.dart
    4 new controller tests, 'the reads one bill is allowed'
app/test/support/fake_purchase_ocr_repository.dart
    a `gate` Completer, so a test can stand inside a read
app/test/support/purchase_ocr_test_app.dart
    the `configure:` doc comment, corrected
```

No migration, and nothing under `supabase/` changed at all this chunk.

---

## Verification evidence

```
dart format lib test                      -> 421 files, 1 changed, then 0
dart run build_runner build --delete-conflicting-outputs
                                          -> exit 0 (run twice, before and after the final
                                             refactor); its outputs are the gitignored
                                             .g.dart/.freezed.dart files; only the known
                                             "SDK language version 3.12.0 is newer than analyzer
                                             language version 3.11.0" notice (T-1)
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found!
flutter test                              -> +637: All tests passed!   (628 -> 637)
deno test supabase/functions              -> ok | 181 passed | 0 failed (2s)
deno check <each of the five entry points> -> exit 0 (no output)
flutter build web --release               -> exit 0; built build\web in ~5 min, with index.html,
                                             flutter_service_worker.js and assets/.env present
```

The web build is in that list on purpose: it is the last step of the Vercel build command,
it had never been run on this tree, and it corrected a mistake in the runbook — §5's second
check read `/assets/assets/.env`, and the real output is **`assets/.env`** (they differ by a
prefix Flutter does *not* add). The document now says the checked path.

The Vercel side, checked as far as this machine can check it — **the deploy was not run,
and neither was a real Vercel build**:

```
node -e JSON.parse(app/vercel.json)       -> parses; keys: $schema,framework,installCommand,
                                             buildCommand,outputDirectory,rewrites,headers;
                                             outputDirectory: build/web
"C:\Program Files\Git\bin\bash.exe" -n <the buildCommand, extracted from the JSON>
                                          -> exit 0 (POSIX shell syntax is valid)
"C:\Program Files\Git\bin\bash.exe" <the ".env" step, extracted, SUPABASE_URL and
                                             SUPABASE_ANON_KEY set>
                                          -> SUPABASE_URL=https://example.supabase.co
                                             SUPABASE_ANON_KEY=example-anon-key
                                             (exactly the two lines the asset needs)
```

The two scratch scripts used for those last two checks were deleted; they lived in
`.qwen/tmp/`.

**What is NOT verified, and cannot be from here:** that Vercel reads `app/vercel.json`
(rooted in the docs quoted in D-063, not in a run), that the Flutter archive URL resolves
for 3.44.8, and that the whole build succeeds inside Vercel's image. The first deploy is
the test of all three; `docs/DEPLOY_VERCEL.md` §7 is the recovery map.

---

## Decisions recorded

- **D-062 — a bill gets three reads, and the first one counts.** The limit is a cost
  control (the reader's key is a per-minute quota and every read is a paid call); counting
  the first read is what makes "three" a budget for the bill rather than a number that no
  read ever matched; the automatic retry (D-032) is *inside* a read and does not consume
  an attempt; a read that failed still counts. Records the two consequences worth knowing:
  a bill whose first read failed several times arrives with its allowance spent, and the
  recovery path from a first read that never succeeded is **deliberately not capped**
  (**N-13**).
- **D-063 — `vercel.json` lives in the Root Directory, not the repository root.** With the
  docs quoted, plus the table of the two arrangements that work and the one that silently
  does not; records the correction to `docs/DEPLOYMENT.md` §2.2's older
  `outputDirectory: app/build/web` snippet (right only for the empty-Root-Directory
  arrangement) and the build-time `build_runner` requirement.

---

## Open risks / blockers

- **Nothing was deployed.** `app/vercel.json` has never been read by Vercel and
  `docs/DEPLOY_VERCEL.md` has never been followed. The account exists; the project does
  not. **This is the one deliverable Phase 6 cannot fake** — say so rather than tick it.
- **⚠️ I-3 is still open, and the chunk-2 commit message says it is not.** The message
  lists *"I-3: purchase return form's 200-row limit replaced with a searchable picker"*,
  but `git show --stat 25615b0` touches **no file** under `app/lib/features/returns/`, and
  the code still caps at `returnablePurchaseLimit = 200`
  (`purchase_return_form_controller.dart:36`) and renders an `AppDropdownField<String>`
  (`purchase_return_form_screen.dart:234`). The same message describes N-8 backwards
  ("preserves … invoice date, invoice number") where the code replaces those and preserves
  the supplier and the notes. **Neither inaccuracy changed the tree**; both matter because
  a plan built on "I-3 is done" would skip a live defect, and a 200-row cap is a real one
  for any pharmacy with more than 200 received invoices.
- **N-13 is new** (above): the three-read limit is enforced where a bill has been *read*,
  not where it has only been *uploaded*.
- **N-11's Vercel half is configured, not run** — see `docs/DEPLOY_VERCEL.md`.
- **Nothing was made worse.** I-2, N-1, N-2, N-4, N-9, N-10, T-1 and D-027's residual are
  untouched, the pins are untouched (D-007), and the two permanent probe rows are still in
  production on purpose (D-049).

---

## What's next

**Phase 6's remaining work** — `context/chat3o-opening-prompt.md`. In short: **the first
Vercel deploy**, which needs the user at the dashboard (import, environment variables,
then the `curl` checks); then **I-3**, which needs nobody; then the credential work
(D-046's triggers, D-052's auto-send PO, N-1's push); then **N-9**'s re-measurement once
the catalogue has 50+ products; and the user manual's screenshot pass once there is a
deployed URL to point at.
