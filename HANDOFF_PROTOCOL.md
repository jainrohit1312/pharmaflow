# Handoff Protocol (1M Context Optimized)

The contract that lets work move between chats without losing state. Every
chat starts by reading the handoff files and ends by writing them.

---

## When to Trigger a Handoff

**Primary trigger:** ~600k tokens used in the current chat (60% of 1M).

**Secondary triggers:**

- Response quality visibly degrades
- Response time > 60 seconds consistently
- Chat crashes or disconnects
- Both target phases complete
- Starting a new major domain

**DO NOT:**

- Handoff mid-module (finish the current module first)
- Push past 700k tokens
- Handoff after every phase if quality is still good

---

## Handoff Checklist (End of Chat)

1. Update `PROGRESS.md` (mark completed phases)
2. Create `context/chatN-summary.md` (covers ALL phases done in this chat)
3. Create `context/chat(N+1)-opening-prompt.md`
4. Update `DECISIONS.md` if there are new architecture decisions
5. Run the verification gates and paste raw output:
   ```
   flutter pub get
   dart run build_runner build --delete-conflicting-outputs
   dart run custom_lint
   flutter analyze
   flutter test
   deno test supabase/functions
   deno check supabase/functions/ocr-purchase-bill/index.ts
   deno check supabase/functions/match-product/index.ts
   deno check supabase/functions/backfill-embeddings/index.ts
   deno check supabase/functions/send-notification/index.ts
   ```
   (plus `supabase db push --dry-run` if migrations were added)

   The Deno lines are the Edge Functions' gates (added with N-3): `deno test`
   type-checks and runs every function test it finds, and there is one `deno check`
   per entry point — those cover what no test imports, the entry point and its
   wiring, which is exactly the layer that cannot be exercised locally without a
   container. A new function adds a `deno check` line here and in the Makefile.
   Verified from the repository root; all three need no Docker and no secrets.
6. Output a numbered list of all files created/modified

---

## Chat Summary Template

Save as `context/chatN-summary.md`:

```markdown
# Chat N Summary — Phases X and Y

**Status:** COMPLETE | PARTIAL (X%)
**Date:** YYYY-MM-DD
**Phases done:** Phase X, Phase Y

## Supabase Changes
- Migrations added (list)
- Tables/columns/views/functions created or changed
- RLS policy changes

## Flutter Files Created
(Full list with paths)

## Flutter Files Modified
(Full list with paths)

## Verification Evidence
(Raw output from all gates)

## Key Decisions Made
(Only decisions affecting future phases)

## Open Risks / Blockers
(Unresolved issues)

## What's Next
(Short pointer to next chat)
```

---

## Opening Prompt Template (for Next Chat)

Save as `context/chat(N+1)-opening-prompt.md`:

```markdown
# Chat N+1 — Phases X and Y: <Names>

You are continuing work on PharmaFlow.

## STEP 0 — READ FIRST (do NOT skip)
1. PROGRESS.md
2. MASTER_PLAN.md
3. DECISIONS.md
4. HANDOFF_PROTOCOL.md
5. context/chatN-summary.md (previous chat's summary)
6. context/chat(N+1)-opening-prompt.md (this file)

Output a 5-line understanding check:
- Current phases to do
- Previous chat's deliverables
- Environment (hosted Supabase, no Docker, Web-first)
- Two load-bearing dependency pins
- What you're about to build

## ENVIRONMENT (FIXED)
- Workspace: C:\Projects\PharmaFlow\
- Supabase: HOSTED only (project ref: yeroxzkpmodbzcvjlqwd)
- No Docker, no supabase start
- Migrations: supabase db push
- Platform priority: Web -> Windows -> Android -> iOS
- Riverpod 3.0.3 (codegen), Freezed 3.2.3, Dart SDK ^3.8.0
- DO NOT modify: riverpod_lint range, custom_lint, freezed, sdk

## SCOPE
<Phases X and Y detail, filled by previous chat>

## WORKFLOW RULES
- Write FULL file contents, never truncate
- Use @riverpod codegen for all new providers
- Freezed models: `abstract class X with _$X`
- Every DB query must be pharmacy_id-scoped
- No business logic in widgets
- Run flutter analyze after each module

## END-OF-CHAT HANDOFF
When both phases complete (or context ~600k):
1. Run verification gates, paste raw output
2. Update PROGRESS.md
3. Create context/chat(N+1)-summary.md
4. Create context/chat(N+2)-opening-prompt.md
5. Update DECISIONS.md
6. Numbered file list

Do NOT proceed to the next chat's phases.

## BEGIN
```

---

## Rules Summary

| Situation | Action |
|---|---|
| Context ~600k | Handoff |
| New architecture decision | Add to DECISIONS.md |
| Both phases complete | Full checklist |
| One phase complete, one pending | Mid-chat checkpoint, continue |
| Bug discovered | Add to PROGRESS.md |
| Dependency pin change needed | Ask user first |
