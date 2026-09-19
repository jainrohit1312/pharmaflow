# Chat 4 / Phase 6 — Testing, Deployment and Documentation

You are continuing work on PharmaFlow, a production-grade Pharmacy ERP built with
Flutter + Supabase (hosted).

> Naming: this is the **thirteenth** chunk brief of Chat 4, and the first of **Phase 6**
> — Chat 4's last phase. Chat 4's overall brief is `context/chat3-opening-prompt.md`;
> the chunk accounts are `chat3a` … `chat3j`, with `context/chat3k-summary.md` covering
> **Chunk E part 2 and the close of Phase 5** — read it first. `PROGRESS.md`'s Chat
> Strategy table is the authority: **Chat 4 = Phase 5 + Phase 6**, and Phase 5 is
> **COMPLETE**.
>
> The handoff files after this chunk are `context/chat3l-summary.md` and
> `context/chat3m-opening-prompt.md`. New decisions continue at **D-056** (D-038 to
> D-055 are taken).
>
> **Phase 6 has no server left to build.** It is the phase that makes what exists
> deployable, documented and measured: the Windows build, the README, the credentials
> nothing has been configured against yet, and the four or five open items that need a
> real catalogue, a real device or a real account.

---

## STEP 0 — READ FIRST (do NOT skip)

1. `PROGRESS.md` — authority on what is done, the gates, and every open item
2. `context/chat3k-summary.md` — **the important one**: what Chunk E part 2 built, and
   the two naming calls it flags for review
3. `MASTER_PLAN.md` — Phase 6's deliverables and add-ons
4. `DECISIONS.md` — especially **D-005** (platform order), **D-007** (the dependency
   pins), **D-029/D-046** (what Phase 5 deliberately left undelivered: push, and the
   alert dispatch triggers), **D-048/D-054** (the utility group in the rail),
   **D-049** (a dispatch answers 200 once the queue row lands), **D-052** (auto-send PO),
   **D-053** (templated phrasing), and **D-045** (measurements never mutate production)
5. `HANDOFF_PROTOCOL.md` — the gate list, one `deno check` per entry point
6. `context/chat3l-opening-prompt.md` — this file

Then output a 5-line understanding check (what Phase 6 covers, what Phase 5 left,
environment, two load-bearing pins, what you are about to build).

---

## ENVIRONMENT (FIXED — do NOT change)

- Workspace: `C:\Projects\PharmaFlow\`
- Supabase: HOSTED only (project ref: `yeroxzkpmodbzcvjlqwd`)
- No Docker, no `supabase start`, no `db reset`
- Migrations: `supabase db push --yes` (the `--yes` matters). `supabase db query
  --linked --file <path>` runs a migration file or a test against the live database.
- Platform priority: Web → Windows → Android → iOS (D-005)
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
them — the way `phase2_stock_triggers.sql` … `phase5_chat_aggregates.sql` do.

**Windows note:** the host runs commands through `cmd.exe`. There is no PowerShell, and
the daemon's shell guard refuses payloads containing `%`. `findstr` is case-sensitive —
use `/I` whenever the question is "is this present?" (D-038 records the false finding
that mistake produced).

---

## WHAT PHASE 5 LEFT YOU (do not re-do, and do not re-open)

- **29 migrations applied, 29/29 local and remote match**; 24 tables, 2 views.
- **Five Edge Functions deployed**, all gated by 181 Deno tests: `ocr-purchase-bill`,
  `match-product`, `backfill-embeddings`, `send-notification` and `chat-sql-agent`.
- **593 Flutter tests**, all green, over Phases 0–5.
- **The app is feature-complete for Phase 5**: the bill reader, the matcher, the
  verify-and-save flow, the notifications inbox with its two live alert sections, the
  chatbot, and a 13-destination shell (D-048, D-054).
- **Phase 5 ends with four things deliberately undelivered**, and each one is Phase 6's:
  dispatch (D-046), push registration (N-1), auto-send PO (D-052) and the Windows build
  (W-1). None of them is a defect in what was built.

**Two permanent rows in production, on purpose**: one `notification_logs` row and one
in-app notification, both marked as probes (D-049's evidence). **Do not delete them.**

---

## SCOPE — Phase 6

### The Phase 6 the master plan names

- **Testing** — expand `app/test/` toward the 80% coverage goal (`flutter test
  --coverage`; the untested list is short and named at the end of `PROGRESS.md`: the
  invoice printer's document builder and `sale_detail_screen.dart`).
- **Deployment** — the Windows build (W-1), an Android APK, iOS TestFlight, the Vercel
  **web** deploy, and the Edge Function secrets that are still unset.
- **Documentation** — the README refresh (R-1) and a user manual under `docs/`.

### The add-ons Phase 5 deferred here

- **Alert dispatch** (D-046/D-049): the credentials (`WHATSAPP_TOKEN`, `SENDGRID_API_KEY`)
  and the triggers that call `send-notification`. The function is built, deployed and
  live-probed **as far as a missing credential allows** — it answers `skipped` naming the
  missing secret and still writes both rows.
- **Push registration** (N-1): the Firebase project, the web service worker, the VAPID
  key, and the call that fills `device_tokens`. `NotificationService.getFcmToken()`
  answers `null` behind a seam (D-035/D-050) precisely so this is a change at one place.
- **Auto-send PO** (D-052): send an approved PO to the supplier over their
  `preferred_channel`. It needs the same WhatsApp/SendGrid credentials the alert
  triggers do, which is why it rides here.

### The open items Phase 6 should close, and the ones it should re-measure

| ID | Issue | Why Phase 6 |
|---|---|---|
| W-1 | Windows build fails (STL1011 — `<experimental/coroutine>` deprecated in VS 2026) | A `windows/CMakeLists.txt` fix; Windows is the second platform and cannot be skipped |
| R-1 | `README.md` still says "Phase 0 (scaffold)" | Documentation is Phase 6's |
| A-1 | `anonKey` deprecated in supabase_flutter 2.17 | A one-line migration to `publishableKey`, best done beside the deploy work |
| N-1 | No push: `device_tokens` is empty | Needs the Firebase project and the web worker |
| D-046 | Nothing dispatches an alert | Needs the credentials and the triggers |
| D-052 | Auto-send PO | Needs the same credentials |
| N-9 | The vector floor (**0.78**) was measured against a **one-product** catalogue | **Re-measure once the catalogue has 50+ products** — D-045 applies: a temporary tenant, never the live function |
| N-5 | `product_aliases`' unique index treats NULL suppliers as distinct | A `NULLS NOT DISTINCT` index plus the two comments that contradict each other |
| I-1 | `InventoryRepository.lowStock` compares two columns in Dart over a 500-row scan | `low_stock_products()` is the server-side answer and the chatbot already calls it live — a one-line switch and the scan bound goes |
| I-3 | A return form offers at most 200 received purchases | A searchable picker, as the product picker already is |
| T-3, T-4, T-5 | The ledger's stale empty page, the sale-return form's dead branches, its loading-vs-empty picker | T-5 is the **rule** the chatbot screen just obeyed; fixing the screen that records it is a small, contained job |
| D-027's residual | Whether to hide `products.embedding` behind column grants | Revisit only with a live REST call in hand — that is what stopped it the first time |
| N-7 | The hosted project requires email confirmation, which contradicts the repo's own belief | **A decision for the user, not a workaround**: either confirm by hand is acceptable policy, or "Confirm email" is turned off in the hosted project, or the app gets a "resend confirmation" affordance |

### What Phase 6 is not

- **Not a new feature phase.** If a Phase 5 surface wants something the server cannot
  give, that is a migration and a review — not a client-side calculation.
- **Not a licence to touch the pins** (D-007): `riverpod_lint`'s range, `custom_lint`,
  `freezed` and `sdk` move only with explicit user approval.
- **Not a reason to delete the two probe rows** (D-049).

**One thing worth carrying into Phase 6 from the phase just closed: the deploy target
and the credentials are the same piece of work.** A Vercel deploy, a Firebase project, a
WhatsApp Meta account and a SendGrid key are four accounts registered against one another
and against the hosted Supabase project, so they want to be done together and in one
order — and **none of them can be done without the user**. Ask for what is needed rather
than inventing a stand-in.

---

## Contract notes you must respect

- **Every DB query is scoped by `pharmacy_id`**, read synchronously from
  `requirePharmacyIdProvider` (D-015). Server-side, from `get_my_pharmacy_id()`.
- **Functions act as the signed-in user** — the caller's JWT, never `service_role` for
  reads (D-004). A provider credential is a *secret*, not an identity change.
- **Stock moves through triggers, never through the client** (D-011/D-013/D-023).
- **A measurement never mutates production** (D-045). N-9's re-measurement happens on a
  temporary tenant; anything that needs a live function invocation needs a session, and
  the guard that refuses a hand-edited `auth.users` row is correct (N-7).
- Freezed for table rows; **plain classes** for an RPC/function envelope.
- **`ref.mounted` after every await** (D-034); a platform capability gets a seam and a
  fake (D-035); a controller test keeps its provider alive with `container.listen(...)`.
- **Riverpod 3 retries a failed provider build by itself** — assert a *state*, never a
  read count (D-051). A derived `AsyncValue` is mapped by hand, in the order
  value → error → loading.
- Provider override lists are inferred (`Override` is not exported by
  `flutter_riverpod`).
- `flutter analyze` is stricter than `dart run custom_lint` and analyzes `test/**` too:
  `avoid_redundant_argument_values` and `unused_element_parameter` bite test fixtures,
  so run `dart format` then `flutter analyze` before declaring a file done.
- Code under `supabase/functions/` stays language-core JavaScript/TypeScript (D-031).

---

## CONTEXT MANAGEMENT

1. **The phase ends in a working, gated state.** Run every gate.
2. **Hand off at ~60-70% context**, or earlier if quality degrades. Phase 6 is a long
   list of small independent jobs — it splits naturally, and a PARTIAL phase with a clean
   tree beats a rushed one.
3. **Each chunk gets its own handoff files:** update `PROGRESS.md`; create
   `context/chat3l-summary.md` and `context/chat3m-opening-prompt.md`; add decisions at
   **D-056+**; leave the tree commit-ready.
4. **Never compress.** Do not stub a screen, do not skip a test, do not tick a
   deliverable that was not verified. The one thing Phase 6 cannot fake is a deploy — if
   a credential is missing, say so and do the part that does not need it.
5. **Everything that needs the user, ask for up front**: the credentials, the accounts,
   and N-7's decision. One question at the start costs a turn; discovering a missing
   secret after three chunks costs a redo.

---

## BEGIN

Read the files in STEP 0, output the 5-line understanding check, then say **how you
intend to sequence Phase 6** — which items you can do with no external input (W-1, R-1,
A-1, I-1, I-3, N-5, T-3/T-4/T-5, the coverage work) and which block on the user (the
credentials, the accounts, the Firebase project, N-9's real catalogue); what you will ask
for and when; and what you will verify and paste. **Wait for approval before starting.**

One shoulder-tap, from the last four chunks: verifying HTTP is done with `curl`
(`findstr /I`), never with a driven browser — and a `%` in a shell payload is refused by
the daemon before it runs.
