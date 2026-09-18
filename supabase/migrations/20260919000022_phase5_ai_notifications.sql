-- Migration: 20260919000022_phase5_ai_notifications | Purpose: the Phase 5 AI
-- substrate - pgvector and the catalogue embedding, the device-token and
-- notification-dispatch tables, and the private storage bucket OCR bills live in.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: guarded extension / enum / bucket creation, if-not-exists tables
-- and indexes, drop-policy-if-exists before every policy.
--
-- What this migration is, and what it deliberately is not
-- -------------------------------------------------------
-- It is the storage layer the Phase 5 features read and write: the vector the
-- fuzzy match searches, one row per device a notification can reach, and the
-- delivery record of what was sent. It is not the matching or dispatch logic -
-- that arrives as functions in later migrations of the same phase, so this file
-- stays reviewable as a schema change.
--
-- No triggers, and nothing that moves stock: a purchase created from an OCR read
-- goes through the same write path the screens use (D-011/D-013), and a sale
-- still moves only through checkout_sale (D-023).
--
-- Scope: every new table carries pharmacy_id and is RLS-scoped by
-- get_my_pharmacy_id() (D-004). The bucket is scoped by the same rule, through
-- the object path.

-- ---------------------------------------------------------------------------
-- 1. pgvector, and the catalogue embedding
--
--    Installed into the `extensions` schema (where Supabase keeps extensions)
--    and referenced qualified - `extensions.vector` - rather than unqualified:
--    the migration runs as `postgres`, whose search_path happens to include
--    `extensions`, but nothing else should have to.
--
--    768 dimensions: Gemini's embedding model emits 768, 1536 or 3072, and the
--    dimension is a hard schema constant - changing it later is a new column, a
--    re-embed of the whole catalogue and a reindex (D-027). 768 is ample for a
--    catalogue of a few thousand SKUs, and keeps the index, the row width and
--    the backfill at half of 1536's cost.
--
--    The column is nullable on purpose: NULL means "not embedded yet", which is
--    how the backfill job finds the rows it still owes an embedding.
--
--    Import for the client: a nullable vector here would ride along on every
--    product read, because the Dart repository selects with no column list
--    (`select=*`). A product page would then carry ~8 kB of floats per row that
--    no screen displays. The client names its columns explicitly instead
--    (ProductsRepository.columns); see D-027. Nothing in the app reads this
--    column - the matching functions do, server-side.
-- ---------------------------------------------------------------------------
create schema if not exists extensions;
create extension if not exists vector with schema extensions;

alter table public.products
  add column if not exists embedding extensions.vector(768);

comment on column public.products.embedding is
  'Catalogue-text embedding used by the smart product match. NULL until the backfill (or alias learning) writes it. Read and written server-side only - the Flutter client never selects it (D-027).';

-- ---------------------------------------------------------------------------
-- 2. New closed sets
--    notification_channel already exists (migration 00002) and is reused for a
--    dispatch's channel, so the in-app list and the delivery log cannot
--    disagree about what 'whatsapp' means.
-- ---------------------------------------------------------------------------
do $$ begin
  create type device_platform as enum
    ('web', 'android', 'ios', 'windows', 'macos', 'linux');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type notification_status as enum
    ('queued', 'sent', 'failed', 'skipped');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type notification_recipient_type as enum
    ('customer', 'supplier', 'user', 'other');
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- 3. device_tokens - one row per device a notification can reach.
--
--    The token identifies the app instance, so it is unique across the table
--    rather than per tenant: a client upserts on it, and a device that changes
--    hands is re-pointed at its new user instead of duplicated. Two tenants
--    claiming one token is therefore resolved by the write (RLS refuses the
--    second) rather than stored twice.
-- ---------------------------------------------------------------------------
create table if not exists device_tokens (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  platform device_platform not null,
  token text not null,
  is_active boolean not null default true,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint device_tokens_token_key unique (token)
);

comment on table device_tokens is
  'Registered devices, one per app instance. A row is private to the user signed in on that device, not merely to the tenant: a token can be used to push to the physical device.';

comment on column device_tokens.last_seen_at is
  'Refreshed on every registration. A token that has not been seen for a long time is the one a prune job removes.';

-- ---------------------------------------------------------------------------
-- 4. notification_logs - what was dispatched, to whom, and what happened to it.
--
--    Deliberately a second table next to `notifications` (migration 00008)
--    rather than more columns on it. `notifications` is the in-app list a
--    *recipient* reads, addressed by user_id and not tenant-scoped; this is the
--    delivery record an *operator* audits, addressed by a party or a staff user
--    and tenant-scoped, because "did we tell this supplier about the PO" is a
--    question about the pharmacy, not about one login.
-- ---------------------------------------------------------------------------
create table if not exists notification_logs (
  id uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies(id) on delete cascade,
  notification_id uuid references notifications(id) on delete set null,
  recipient_type notification_recipient_type not null,
  recipient_id uuid,
  channel notification_channel not null,
  destination text,
  subject text,
  body text,
  status notification_status not null default 'queued',
  provider text,
  provider_message_id text,
  error text,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table notification_logs is
  'Delivery record: one row per attempt to reach a party or a user over one channel. The in-app list lives in `notifications`; this is what an operator audits when a message did not arrive.';

comment on column notification_logs.recipient_id is
  'The customer/supplier/profile the dispatch was addressed to. Nullable because a recipient may have no row of their own - a number typed at the counter, an ad-hoc address.';

comment on column notification_logs.destination is
  'The address actually used - phone number, email, push token - not the party id. A delivery failure is about the address.';

comment on column notification_logs.status is
  'queued until a provider answers; sent or failed once it has; skipped when the send was deliberately not attempted (no channel configured, recipient opted out), which is a decision rather than a failure.';

comment on column notification_logs.notification_id is
  'The in-app notification this dispatch also wrote, when there was one. A dispatch may exist with no in-app counterpart (a supplier being emailed a purchase order).';

-- ---------------------------------------------------------------------------
-- 5. Indexes
--    The vector index is HNSW over cosine distance, partial on
--    `embedding is not null` so it holds only the rows that can actually
--    participate in a match while the backfill is still catching up.
--    `device_tokens` already gets a unique index on token from the constraint.
-- ---------------------------------------------------------------------------
create index if not exists products_embedding_idx on public.products
  using hnsw (embedding extensions.vector_cosine_ops)
  where embedding is not null;

create index if not exists device_tokens_pharmacy_id_user_id_idx
  on public.device_tokens (pharmacy_id, user_id);

create index if not exists notification_logs_pharmacy_id_created_at_idx
  on public.notification_logs (pharmacy_id, created_at desc);

create index if not exists notification_logs_pharmacy_id_status_idx
  on public.notification_logs (pharmacy_id, status);

create index if not exists notification_logs_pharmacy_id_recipient_idx
  on public.notification_logs (pharmacy_id, recipient_type, recipient_id);

-- ---------------------------------------------------------------------------
-- 6. Row level security
--
--    RLS is enabled explicitly here. Migration 00012 ran its generic
--    four-policy loop over the tables that existed then, so a table added later
--    gets its policies spelled out in the migration that creates it.
--
--    device_tokens is both tenant- and user-scoped. The tenant scope is the
--    D-004 rule; the user scope is because a token is a way to reach a physical
--    device, so a colleague is not entitled to enumerate or revoke someone
--    else's. A server-side fan-out (sending to a whole pharmacy's staff) will
--    read tokens through a SECURITY DEFINER RPC rather than by widening this
--    policy.
--
--    notification_logs has no delete policy on purpose: a delivery record is
--    appended and annotated, and its status settles when a provider answers
--    (hence update). Nothing in the app deletes one, and a log a client can
--    erase is not a log. A tenant delete still cascades from `pharmacies`,
--    because a foreign-key action runs as the constraint's owner, not as the
--    caller.
-- ---------------------------------------------------------------------------
alter table public.device_tokens     enable row level security;
alter table public.notification_logs enable row level security;

drop policy if exists device_tokens_own_select on public.device_tokens;
create policy device_tokens_own_select on public.device_tokens
  for select using (
    pharmacy_id = public.get_my_pharmacy_id()
    and user_id = auth.uid()
  );

drop policy if exists device_tokens_own_insert on public.device_tokens;
create policy device_tokens_own_insert on public.device_tokens
  for insert with check (
    pharmacy_id = public.get_my_pharmacy_id()
    and user_id = auth.uid()
  );

drop policy if exists device_tokens_own_update on public.device_tokens;
create policy device_tokens_own_update on public.device_tokens
  for update
  using (
    pharmacy_id = public.get_my_pharmacy_id()
    and user_id = auth.uid()
  )
  with check (
    pharmacy_id = public.get_my_pharmacy_id()
    and user_id = auth.uid()
  );

drop policy if exists device_tokens_own_delete on public.device_tokens;
create policy device_tokens_own_delete on public.device_tokens
  for delete using (
    pharmacy_id = public.get_my_pharmacy_id()
    and user_id = auth.uid()
  );

drop policy if exists notification_logs_pharmacy_select on public.notification_logs;
create policy notification_logs_pharmacy_select on public.notification_logs
  for select using (pharmacy_id = public.get_my_pharmacy_id());

drop policy if exists notification_logs_pharmacy_insert on public.notification_logs;
create policy notification_logs_pharmacy_insert on public.notification_logs
  for insert with check (pharmacy_id = public.get_my_pharmacy_id());

drop policy if exists notification_logs_pharmacy_update on public.notification_logs;
create policy notification_logs_pharmacy_update on public.notification_logs
  for update
  using (pharmacy_id = public.get_my_pharmacy_id())
  with check (pharmacy_id = public.get_my_pharmacy_id());

-- ---------------------------------------------------------------------------
-- 7. set_updated_at on both new tables, as on every other business table
--    (migration 00010). notification_logs' updated_at is what dates the status
--    change from queued to sent/failed.
-- ---------------------------------------------------------------------------
drop trigger if exists set_updated_at on public.device_tokens;
create trigger set_updated_at before update on public.device_tokens
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.notification_logs;
create trigger set_updated_at before update on public.notification_logs
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 8. The purchase-bills bucket
--
--    OCR needs bytes that both the tablet and the Edge Function can reach. The
--    function runs with the caller's JWT (D-004), so a stored object has to be
--    readable under the same tenant rule as every table - which means the rule
--    has to be expressible in the object's path. Objects are therefore laid out
--    as <pharmacy_id>/<yyyy>/<file>, and one predicate on the first path segment
--    covers select, insert, update and delete.
--
--    The bucket is private: a supplier invoice is commercially sensitive, and
--    the app displays the image it already holds rather than a public URL. The
--    size cap and the mime list are the bucket's own guard, so a 40 MB HEIC from
--    a phone camera is refused at upload rather than by a function timeout.
--
--    On hosted Supabase this insert is the supported way to create a bucket from
--    a migration. config.toml's [storage.buckets.*] blocks only seed a local
--    stack, which this project does not run (D-003).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'purchase-bills',
  'purchase-bills',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists purchase_bills_select on storage.objects;
create policy purchase_bills_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'purchase-bills'
    and (storage.foldername(name))[1] = public.get_my_pharmacy_id()::text
  );

drop policy if exists purchase_bills_insert on storage.objects;
create policy purchase_bills_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'purchase-bills'
    and (storage.foldername(name))[1] = public.get_my_pharmacy_id()::text
  );

drop policy if exists purchase_bills_update on storage.objects;
create policy purchase_bills_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'purchase-bills'
    and (storage.foldername(name))[1] = public.get_my_pharmacy_id()::text
  )
  with check (
    bucket_id = 'purchase-bills'
    and (storage.foldername(name))[1] = public.get_my_pharmacy_id()::text
  );

drop policy if exists purchase_bills_delete on storage.objects;
create policy purchase_bills_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'purchase-bills'
    and (storage.foldername(name))[1] = public.get_my_pharmacy_id()::text
  );
