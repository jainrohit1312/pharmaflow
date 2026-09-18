# Chat 4 / Chunk A summary — Phase 5 database foundation

**Status:** COMPLETE
**Date:** 2026-09-19
**Scope:** Phase 5, Chunk A only — the storage layer the AI features read and
write. No OCR, matching, dispatch or chatbot logic: those are chunks B-E.

Continues `context/chat3-opening-prompt.md` ("Chat 4 — Phase 5 + Phase 6"), whose
chunk plan this follows. The next chunk's brief is
`context/chat3b-opening-prompt.md`.

---

## Supabase changes

### Migration `20260919000022_phase5_ai_notifications.sql` (new file, applied)

`supabase migration list --linked`: **22/22 local and remote match**. A new file,
never an edit to an applied one — 00021 was the head (D-013).

- **pgvector** installed into the `extensions` schema, referenced qualified
  (`extensions.vector`, `extensions.vector_cosine_ops`) so nothing depends on
  `postgres`'s search_path.
- **`products.embedding`** — `extensions.vector(768)`, nullable, commented. `NULL`
  is the backfill's work list, so no separate marker column.
- **Index** `products_embedding_idx` — HNSW, `vector_cosine_ops`, partial on
  `embedding is not null`.
- **`device_tokens`** — id, pharmacy_id, user_id, platform (`device_platform`),
  token (unique table-wide), is_active, last_seen_at, created_at, updated_at; two
  indexes; RLS tenant- **and** user-scoped (four policies).
- **`notification_logs`** — id, pharmacy_id, notification_id (FK → notifications,
  `on delete set null`), recipient_type (`notification_recipient_type`),
  recipient_id, channel (`notification_channel`, reused from 00002), destination,
  subject, body, status (`notification_status`, default `queued`), provider,
  provider_message_id, error, created_by, created_at, updated_at; three indexes;
  RLS select/insert/update and **no delete policy**.
- **Enums** `device_platform`, `notification_status`,
  `notification_recipient_type` (guarded `create type`).
- **`set_updated_at` triggers** on both new tables (migration 00010's function).
- **Storage**: private bucket `purchase-bills`, 10 MB, mime list =
  `image/jpeg`, `image/png`, `image/webp`, `application/pdf`; four policies on
  `storage.objects` (select/insert/update/delete for `authenticated`) comparing
  `(storage.foldername(name))[1]` with `get_my_pharmacy_id()::text`. Created by the
  migration, because a `config.toml` bucket block only seeds a local stack.

### SQL test `supabase/tests/phase5_ai_notifications.sql` (new)

Atomic, self-rolling-back, impersonates `authenticated` the way
`profile_privileges.sql` does. **29 assertions, all PASS** against the live
database:

```
supabase db query --linked --file supabase/tests/phase5_ai_notifications.sql
```

It proves the extension and the column's exact type
(`extensions.vector(768)`), that a **769-dimension write is refused by the type**
(22000), that `product_stock` does **not** carry the new column yet still resolves
for the caller and reports its batch (D-021's trap), the index's method and partial
predicate, the three enums' labels, that a token cannot be registered twice
(23505), for another tenant (42501) or on behalf of another user (42501), that
another user's token in the same pharmacy and a foreign tenant's dispatch history
are both invisible, that an unknown status label is refused (22P02), that
`notification_id` is a real foreign key (23503), that a delivery record survives a
client `DELETE` (0 rows deleted, still there), and that an object is readable and
writable only under the caller's own pharmacy folder (foreign folder → 42501).

**Residue:** checked after the run — zero ZZTEST pharmacies, zero device tokens,
zero dispatch rows, zero stored objects.

**Probed rather than assumed.** Three facts the test needed were learned from a
throwaway script that raised and rolled back, then deleted: the vector column's
`atttypmod` is 768; an `auth.users` insert auto-creates a profile through
`handle_new_user()`, which is how the test gets a second user *in the same tenant*;
and `storage.objects` accepts a direct insert that the policy then filters. A first
probe of the storage policies "failed" because it used the *user* id as the path's
first segment instead of the *pharmacy* id — the policy was right, the probe was
wrong.

---

## Flutter files created

```
app/lib/data/models/device_token.dart
app/lib/data/models/notification_log.dart
app/lib/data/models/device_token.freezed.dart        (generated)
app/lib/data/models/device_token.g.dart              (generated)
app/lib/data/models/notification_log.freezed.dart    (generated)
app/lib/data/models/notification_log.g.dart          (generated)
app/test/data/models/device_token_test.dart
app/test/data/models/notification_log_test.dart
app/test/features/products/data/products_repository_columns_test.dart
```

## Flutter files modified

```
app/lib/features/products/data/products_repository.dart
```

Added `ProductsRepository.columns` (the 17 client-visible columns) and
`.projection`, and switched four `products` reads — `list`, `byId`, `create`,
`update` — from PostgREST's default `*` to the projection. Without this, every
product read would have started carrying 768 floats (~8 kB) per row on the product
list, the detail screen and every picker. The two view reads
(`product_stock`, `batch_status`) are untouched: neither view carries the vector.

## Documentation

```
PROGRESS.md                        Phase 5 IN PROGRESS (Chunk A); 22/22 migrations; 24 tables;
                                   the Chunk A section; open item N-1; Next Action = Chunk B
DECISIONS.md                       D-026 (the chatbot answers through RPCs, never free-form
                                   SQL), D-027 (the embedding and the explicit projection),
                                   D-028 (the private path-scoped bill bucket), D-029 (push
                                   deferred to Phase 6)
context/chat3a-summary.md          this file
context/chat3b-opening-prompt.md   the Chunk B brief
```

---

## Verification evidence

```
dart format lib test                      -> 3 changed, then
dart format --output=none --set-exit-if-changed lib test
                                          -> 355 files, 0 changed
dart run build_runner build --delete...   -> wrote 164 outputs (T-1 SDK notice only)
dart run custom_lint                      -> No issues found!
flutter analyze                           -> No issues found! (9.6s)
flutter test                              -> +397: All tests passed!
supabase db push --dry-run                -> only 00022 was pending
supabase db push --yes                    -> applied
supabase migration list --linked          -> 22/22 local and remote match
supabase db query --linked --file supabase/tests/phase5_ai_notifications.sql
                                          -> 29 PASS, 0 FAIL
```

(382 tests before; 397 now — 15 added, none changed.)

## Key decisions made

- **D-026** — `chat-sql-agent` does not build SQL. The model classifies and
  extracts parameters; answers come from parameterised RPCs (`report_summary` plus
  four new: `low_stock_products`, `expiring_batches`, `top_products`,
  `dead_stock`). Reason: prompt injection, `security definer` escapes, DoS surface,
  answer inconsistency. The four RPCs are Chunk E work and also give **I-1** its
  server-side fix.
- **D-027** — `products.embedding` is `vector(768)` (Gemini
  `gemini-embedding-001`), HNSW/cosine/partial; the client names its product
  columns instead of taking `*`. Records the rejected alternative (column-level
  SELECT grants, D-017's pattern) and why it was not taken: it rests on two
  behaviours that cannot be verified on this host without Docker.
- **D-028** — the private, path-scoped `purchase-bills` bucket, `<pharmacy_id>/…`,
  created by the migration.
- **D-029** — push (FCM) is deferred to Phase 6; Phase 5 stores tokens and
  dispatches over WhatsApp/Email with an in-app list. Recorded as open item N-1.

## Open risks / blockers

- **N-1 (Medium)** — no push registration until Phase 6; `device_tokens` stays
  empty and `getFcmToken()` returns null.
- **D-027's residual uncertainty** — the projection is the client-side answer to
  the embedding column's payload cost. The alternative (hiding the column from
  `authenticated` with column grants) is the more robust one *if* PostgREST expands
  `*` to exactly the granted columns and `count(*)` still works for a role with
  column-level SELECT only. Both are unverifiable without Docker; revisit with a
  live REST call in hand if the projection ever proves hard to maintain.
- The test's `atttypmod` and storage-policy assertions depend on Supabase internals
  (`storage.buckets.file_size_limit` type, `pg_policies.cmd` labels). They are
  asserted with their observed values in the failure message, so a platform change
  reports what it found rather than just failing.
- Nothing in this chunk was verified in a browser. The migration, the SQL test and
  the gates are the evidence; the products projection is exercised by
  `products_repository_columns_test.dart` and by the existing product screens'
  tests over fakes, not against the live REST API.

## What's next

Chunk B — the AI OCR core: `supabase/functions/ocr-purchase-bill/` (Gemini
Vision), a real `OcrService`, and `features/purchase_ocr/` (pick/capture → upload
to `purchase-bills/<pharmacy_id>/…` → verify → save **through
`PurchasesRepository`**). See `context/chat3b-opening-prompt.md`. Chunk B is the
largest feature of the phase and may itself split into B1 (function + service +
repository) and B2 (verify UI + save).
