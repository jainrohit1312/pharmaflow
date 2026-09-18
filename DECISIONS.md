# Architecture Decisions Log

Append-only record of decisions that constrain future chats. A decision
listed here is not re-litigated unless the user explicitly changes it.

---

## D-001 — State Management: Riverpod 3.x

**Date:** 2026-09-18

**Decision:** Riverpod 3.x with codegen (`@riverpod`).

**Rationale:** Less boilerplate than BLoC, compile-time safety, no
`BuildContext` dependency, great for multi-tenant async patterns.

**Consequences:** All new providers use `@riverpod` codegen.
Hand-written `Provider` is allowed only for stubs.

---

## D-002 — Models: Freezed 3.x with abstract class

**Date:** 2026-09-18

**Decision:** All data models use Freezed 3.x with
`abstract class X with _$X`.

**Rationale:** custom_lint 0.8.x forces `freezed_annotation` ^3.0.0.
Freezed 3 generates `_$X` as an abstract mixin, so the class itself must be
declared `abstract`.

**Consequences:** JSON snake_case via
`@JsonSerializable(fieldRename: FieldRename.snake)`. `// ignore:
invalid_annotation_target` on the factory constructor.

---

## D-003 — Backend: Hosted Supabase Only

**Date:** 2026-09-18

**Decision:** Hosted Supabase only. No local stack, no Docker.

**Project ref:** `yeroxzkpmodbzcvjlqwd` (Mumbai, ap-south-1)

**Consequences:** `supabase db push` is the ONLY migration command.
No `supabase start` / `stop` / `status` / `db reset`.

---

## D-004 — Multi-Tenant Isolation via RLS

**Date:** 2026-09-18

**Decision:** Every business table has `pharmacy_id uuid` and RLS policies
scoped by `get_my_pharmacy_id()`.

**Consequences:** Every INSERT includes `pharmacy_id`. AI/Edge Functions
use the user JWT, never `service_role` for reads.

---

## D-005 — Cross-Platform: Web First

**Date:** 2026-09-18

**Decision:** Priority: Web (Chrome) -> Windows -> Android -> iOS.

**Consequences:** Barcode scanner has a web fallback. Thermal print: web
uses PDF, Windows uses native.

---

## D-006 — Auth: Supabase Email + RLS

**Date:** 2026-09-18

**Decision:** Supabase Auth. `auth.users` + `public.profiles`.

**Consequences:** `handle_new_user()` trigger auto-creates a profile with
`role='viewer'`. The first user is manually promoted to owner via the SQL
Editor.

---

## D-007 — Dependency Pins Are Load-Bearing

**Date:** 2026-09-18

**Decision:** These MUST NOT be changed without explicit approval:

```yaml
riverpod_lint: '>=3.0.0 <3.1.0'  # 3.1.8 renamed its entrypoint
custom_lint: ^0.8.0              # forces Freezed 3.x
freezed: ^3.0.0                  # models must be abstract
environment:
  sdk: ^3.8.0                    # json_serializable null-aware elements
```

**Why:** `riverpod_lint` 3.1.8 renamed its public entrypoint from
`lib/riverpod_lint.dart` to `lib/main.dart`, while `custom_lint` 0.8.1 still
generates a plugin client importing
`package:riverpod_lint/riverpod_lint.dart`. Widening the constraint to
`^3.0.0` lets it resolve to 3.1.8 and `dart run custom_lint` then dies with
"Failed to start the plugins". 3.0.3 is the newest release whose entrypoint
custom_lint 0.8.1 can load.

---

## D-008 — Multi-Chat Workflow via Files (1M Context Optimized)

**Date:** 2026-09-18

**Decision:** 4 chats total, 2 phases per chat.

- Chat 1: Phase 0 [done]
- Chat 2: Phase 1 + Phase 2
- Chat 3: Phase 3 + Phase 4
- Chat 4: Phase 5 + Phase 6

Persistent state in: `PROGRESS.md`, `MASTER_PLAN.md`, `DECISIONS.md`,
`HANDOFF_PROTOCOL.md`, `context/chatN-summary.md`,
`context/chat(N+1)-opening-prompt.md`.

**Handoff trigger:** ~600k tokens OR quality degradation.

---

## D-009 — AI Deferred to Phase 5

**Date:** 2026-09-18

**Decision:** AI OCR, fuzzy match, embeddings, and notifications are all
Phase 5.

**Rationale:** AI needs real data. Manual flows must be solid first.


## D-010 — Drift Local DB Deferred to Phase 6+

**Date:** 2026-09-18
**Status:** Active

**Decision:** Drift + offline-first sync is deferred to Phase 6 or later.
All data comes from hosted Supabase directly. No local cache layer in
Phases 1-5.

**Rationale:**
- Retail pharmacies in urban India have stable internet connectivity.
- Online-first is simpler and safer for multi-device consistency.
- Drift adds significant complexity (sync queue, conflict resolution,
  schema drift between local and remote).
- It can be added later without architectural changes — wrap repositories
  with a Drift fallback when the need arises.

**Consequences:**
- `drift`, `drift_flutter`, `sqlite3_flutter_libs` stay in pubspec.yaml
  but are unused. Leave them; do not remove — Phase 6 may use them.
- No local cache in Phase 1-5.
- `app/pubspec.yaml:30` TODO(phase-2) marker is superseded by this
  decision — update the marker to TODO(phase-6+) if it still exists.
- MASTER_PLAN.md Phase 2 scope does NOT include Drift.