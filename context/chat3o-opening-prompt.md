# Chat 4 / Phase 6, chunk 4 — the first deploy and the credentials

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **sixteenth** chunk brief of Chat 4, and the **fourth** of
> **Phase 6** — Chat 4's last phase. The chunk accounts are `chat3a` … `chat3n`, with
> `context/chat3n-summary.md` covering **Phase 6 chunk 3** — read it first. `PROGRESS.md`'s
> Chat Strategy table is the authority: **Chat 4 = Phase 5 + Phase 6**; Phase 5 is
> **COMPLETE** and Phase 6 is **IN PROGRESS (chunks 1-3 done and gated)**.
>
> The handoff files after this chunk are `context/chat3o-summary.md` and
> `context/chat3p-opening-prompt.md`. New decisions continue at **D-065** (D-038 to
> D-064 are taken).
>
> **What is left in Phase 6 is two things of different kinds**: one deploy that needs the
> **user at a dashboard** (Vercel), and a set of features that need **provider
> credentials** (dispatch, auto-send PO, push). Everything that needed no external input
> has been done. **The one thing Phase 6 cannot fake is a deploy** — if the user has not
> run it, say so and do the part that does not need it.

---

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — authority on what is done, the gates, and every open item. Read the
   **"Phase 6, chunk 3"** section near the top and the open-items table (note **N-13**,
   added last chunk)
2. `context/chat3n-summary.md` — **the important one**: the Vercel config and why it lives
   in `app/`, what the build command does step by step, D-062's counting rule, and the two
   inaccuracies in the chunk-2 commit message
3. `docs/DEPLOY_VERCEL.md` — the runbook this chunk runs. §7 is the recovery map; §8
   explains the `vercel.json` placement
4. `docs/DEPLOYMENT.md` — the wider runbook (§1 gates, §2.3 the `curl` checks, §6 secrets)
5. `MASTER_PLAN.md` — Phase 6's deliverables
6. `DECISIONS.md` — especially **D-056**–**D-064**: the alias key, the bill's two steps, a
   failure outranking a retained value, the platform scope, confirmation by hand, the
   sideload APK, three reads per bill, and where `vercel.json` goes. Also **D-007** (the
   pins), **D-015**/**D-004** (tenant scope), **D-036** (the matcher's one request per
   bill), **D-045** (measurements never mutate production), **D-049** (the probe rows),
   **D-058** (a failure is decided before a retained value)
7. `HANDOFF_PROTOCOL.md` — the gate list, one `deno check` per entry point
8. `context/chat3o-opening-prompt.md` — this file

Then output a 5-line understanding check (what Phase 6 has left, what chunk 3 closed,
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
`bash` is not on `PATH` — the Git Bash at `C:\Program Files\Git\bin\bash.exe` is, and that
is what chunk 3 used to syntax-check the Vercel build command.

---

## WHAT CHUNK 3 LEFT YOU (do not re-do, and do not re-open)

- **665 Flutter tests, 181 Deno tests**, all green; `custom_lint` and `flutter analyze`
  clean; **30 migrations, 30/30 local and remote**; **five Edge Functions deployed**.
- **The Vercel deploy is configured and has never been run**: `app/vercel.json` (build
  config) and `docs/DEPLOY_VERCEL.md` (runbook), both written from Vercel's own
  documentation, neither executed. The account exists; the project does not (D-063).
- **The bill reader offers a re-read**: a small text button with a counter ("Attempt 2 of
  3"), a confirmation dialog ("Re-read? Uses one AI call."), **three reads per bill per
  session**, disabled while a read is out, "Max attempts reached" after the third (D-062).
  N-8's transition is now reachable through the UI.
- **I-3 is done** (D-064), in a commit of its own: the return form's invoice picker is a
  three-way search (invoice number, notes, **distributor name**) with a date window and
  twenty-at-a-time paging; `returnablePurchaseLimit` and its dropdown are gone. **Read
  `context/chat3n-summary.md` §4 before touching it** — the chunk-2 message had claimed
  this shipped, and that misreport cost a chunk, which is why `HANDOFF_PROTOCOL.md` rule 7
  now exists. Do not treat a commit message as evidence about the tree; run the command.
- **N-13 is new**: the three-read limit is enforced on the verify screen and **not** on
  `_ChooseBill`'s failure card, deliberately (that is the D-033 recovery for a first read
  that never succeeded). Closing it is one screen's work.
- **The picker's filter parses live; its *matching* is unproven.** The `or=(…)` mix of
  `ilike` branches and a `supplier_id.in.(…)` list answers **200** against the hosted
  PostgREST (with a malformed `or=()` control answering 400, so the 200s mean something) —
  but **this tenant holds no received invoices and no suppliers**, so no search has ever
  returned a row. If the tenant gets data in this chunk, re-run the three SYN probes in
  `context/chat3n-summary.md` §4 and mark I-3 fully verified; if it does not, say so and
  leave the claim where it is.
- **N-12 was reviewed and deliberately deferred** (the user's instruction, twice).
- **The two permanent probe rows stay** (D-049). Do not delete them.

---

## SCOPE — Phase 6, chunk 4

### 1. The first Vercel deploy — needs the user (N-11)

`docs/DEPLOY_VERCEL.md` is written to be run, and **the user runs the dashboard half**:
they have the Vercel account, and the import is three fields. What this chunk does:

- **Run the gates first** on the commit being deployed and paste the output as usual.
- **Hand over the exact steps**: import `pharmaflow`, Framework Preset **Other**, Root
  Directory **`app`**, `SUPABASE_URL` + `SUPABASE_ANON_KEY` for Production *and* Preview,
  then Deploy. Everything else is in `app/vercel.json`.
- **Ask for the build log or the failure** rather than guessing at it. The predictable
  failures are tabulated in `docs/DEPLOY_VERCEL.md` §7 — a 404 on the Flutter archive
  (wrong `FLUTTER_VERSION`), an empty `.env` (variables not set for that environment), a
  404 on a deep link (the file not being read: wrong Root Directory), and a stale service
  worker.
- **Verify with `curl`** once a URL exists: the app is served, the `.env` asset names the
  right project, the service worker is not cached, and the function gateway answers a POST
  and a preflight **with CORS**. `findstr /I`. Never drive a browser to check HTTP.
- **Then the half only a browser can do**, and say plainly that it is the user's: sign in
  with a real account and work one sale and one purchase end to end.

If the deploy does not happen this chunk, **say so** — "configured, not run" is the honest
status, and it is what `PROGRESS.md` already says.

### 2. The credentials — needs provider accounts

- **D-046's alert dispatch**: the triggers that call `send-notification` for the low-stock
  and expiry alerts. Built, deployed and live-probed as far as a missing credential allows
  (it answers `skipped`, names the secret, and still writes both rows).
- **D-052's auto-send PO**: send an approved PO over the supplier's `preferred_channel`.
- **N-1's push**: the Firebase project, the web service worker, the VAPID key, and the call
  that fills `device_tokens`. `NotificationService.getFcmToken()` answers `null` behind a
  seam (D-035/D-050) precisely so this is a change at one place.

Secrets and the `curl` that proves a dispatch: `docs/DEPLOYMENT.md` §6. A `sent` answer
proves the credential, the provider call and the log row together; a `skipped` answer names
the missing secret.

### The code-only items still open

| ID | Issue | Shape of the work |
|---|---|---|
| N-13 | The three-read limit is not enforced on `_ChooseBill`'s failure card | Show the same cap there, or decide the recovery of an unread bill is worth unlimited reads |
| N-2 | The Gemini key is a free tier of 5 requests/minute, and a burst is shed as `503` | A decision (paid tier, or a documented retry-once policy with a visible wait), not code until it is made |
| N-4 | A deployed function's `console.error` is only visible in the dashboard | Accept and probe deliberately, or find a log path for CLI 2.113.0 |
| D-027's residual | Whether to hide `products.embedding` behind column grants | Only with a live REST call in hand — that is what stopped it the first time |
| I-2 | A purchase return is two statements, so a refused set can leave a header with no lines | An RPC wrapping both, when the ledger next changes |
| T-1 | `dart run custom_lint` SDK language-version notice | Cosmetic; wait for upstream |
| N-10 | `flutter run -d chrome` cannot attach the debugger (Chrome 153 + dwds in Flutter 3.44.8) | `make run-web-server` until the SDK is upgraded |
| N-12 | A Flutter upgrade will fail the Android build (`mobile_scanner` applies KGP) | Reviewed in chunk 3 and deferred; check that plugin's changelog when the SDK is next bumped |
| D-1 | Remaining hand-written providers | Convert as features are touched |

### 3. N-9 — needs a real catalogue

The vector floor (**0.78**) was measured against a **one-product** catalogue, so the window
it sits in rests on one vector and nine query texts. Re-tune it once the catalogue has
**50+ products**. **D-045 applies**: the measurement happens on a **temporary tenant**,
never against the live function, and the open implementation question — an identity to act
as, since the guard correctly refuses a hand-edited `auth.users` row — must be answered
**before** it starts. Nothing depends on the exact value; it is a one-line migration and
the tests move with it.

### What this chunk is not

- **Not a new feature phase.** A Phase 5 surface that wants something the server cannot
  give is a migration and a review — never a client-side calculation.
- **Not a licence to touch the pins** (D-007).
- **Not a reason to delete the two probe rows** (D-049).
- **Not a reason to re-litigate D-059's platform scope, D-061's signing choice, or D-063's
  `vercel.json` placement** — the user has said so, or the documentation settles it.

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
- **A failure is decided before a retained value** (D-058), and a screen has **one** failure
  surface.
- **A count that a limit depends on lives on the state, not in the widget** (D-062), and it
  is incremented when the thing happens, not when it succeeds.
- `flutter analyze` analyzes `test/**` too, and is stricter than `dart run custom_lint`:
  `avoid_redundant_argument_values`, `unused_element_parameter`, `avoid_escaping_inner_quotes`
  and `unused_import` all bite test files. Run `dart format` then `flutter analyze` before
  declaring a file done.
- **Verifying HTTP is done with `curl`** (`findstr /I`), never with a driven browser.
- **Never put a value in a committed file that belongs in a dashboard.** `app/vercel.json`
  and `docs/DEPLOY_VERCEL.md` name `SUPABASE_URL` and `SUPABASE_ANON_KEY` and carry neither.

---

## CONTEXT MANAGEMENT

1. **The deploy first** — it is the phase's last real deliverable and it needs the user,
   so ask for their half early. Then the credential work, then N-13 if it is asked for.
2. **Hand off at ~60-70% context**, or earlier if quality degrades. A PARTIAL chunk with a
   clean tree beats a rushed one.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3o-summary.md` and `context/chat3p-opening-prompt.md`; add decisions at
   **D-064+**; leave the tree commit-ready.
4. **Never compress.** Do not stub a screen, do not skip a test, do not tick a deploy that
   was not made. If something cannot be verified, say what *was* verified and what was not —
   chunk 1's "the release build was not run, by instruction", chunk 2's "the APK has not been
   installed on a device" and chunk 3's "the config parses, the shell syntax is valid, the
   `.env` step produces the right two lines, and nothing more" are the precedents.
5. **Ask for what is needed up front**: the Vercel dashboard work (or the log if it fails),
   the provider credentials, and whether N-13 should be closed now.

---

## BEGIN

Read the files in STEP 0, output the 5-line understanding check, then say **how you intend
to sequence this chunk** — what you can do with no external input (N-13, the review items,
the manual's screenshot pass once a URL exists) and what blocks on the user (the Vercel
import and its two environment variables, the credential accounts, N-9's real catalogue);
what you will ask for and when; and what you will verify and paste. **Wait for approval
before starting.**
