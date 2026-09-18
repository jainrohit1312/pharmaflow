-- Migration: 20260918000012_rls_policies | Purpose: enable row level security on all 21 public tables and create tenant-scoped + self-scoped policies
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: drop policy if exists before every create policy.

-- ---------------------------------------------------------------------------
-- 0. Note on evaluation semantics
--
--    Policy expressions run as the INVOKING user. get_my_pharmacy_id() and
--    get_my_role() are SECURITY DEFINER, but auth.uid() inside them still
--    resolves to the caller's uid - that is intentional. The definer rights
--    exist solely so the internal profiles lookup is not blocked by (or made
--    to recurse through) profiles' own RLS policies.
--
--    RLS is enabled table-by-table below; the table owner and service_role
--    still bypass it, which is what the backend/edge functions use.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. Enable RLS on every public table (21)
-- ---------------------------------------------------------------------------
alter table public.pharmacies            enable row level security;
alter table public.profiles              enable row level security;
alter table public.suppliers             enable row level security;
alter table public.customers             enable row level security;
alter table public.products              enable row level security;
alter table public.product_batches       enable row level security;
alter table public.product_aliases       enable row level security;
alter table public.purchases             enable row level security;
alter table public.purchase_items        enable row level security;
alter table public.purchase_returns      enable row level security;
alter table public.purchase_return_items enable row level security;
alter table public.sales                 enable row level security;
alter table public.sale_items            enable row level security;
alter table public.sale_returns          enable row level security;
alter table public.sale_return_items     enable row level security;
alter table public.payments              enable row level security;
alter table public.ledger_entries        enable row level security;
alter table public.expenses              enable row level security;
alter table public.stock_adjustments     enable row level security;
alter table public.notifications         enable row level security;
alter table public.audit_logs            enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Tenant-scoped tables (every table that carries a pharmacy_id) get the
--    same four CRUD policies. profiles / pharmacies / notifications are
--    excluded on purpose and handled explicitly in sections 3-5.
--
--    18 tables x 4 policies = 72 policies.
--
--    Note: audit_logs.pharmacy_id is nullable by design (pre-tenant actions).
--    The insert policy therefore requires a non-null tenant; rows written with
--    a NULL pharmacy_id can only come from the owner/service_role, which bypass
--    RLS. Keep it that way - do not relax this to `pharmacy_id is null or ...`.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  v_tables text[] := array[
    'suppliers',
    'customers',
    'products',
    'product_batches',
    'product_aliases',
    'purchases',
    'purchase_items',
    'purchase_returns',
    'purchase_return_items',
    'sales',
    'sale_items',
    'sale_returns',
    'sale_return_items',
    'payments',
    'ledger_entries',
    'expenses',
    'stock_adjustments',
    'audit_logs'
  ];
begin
  foreach t in array v_tables loop
    -- select
    execute format('drop policy if exists %I on public.%I', t || '_pharmacy_select', t);
    execute format(
      'create policy %I on public.%I for select using (pharmacy_id = public.get_my_pharmacy_id())',
      t || '_pharmacy_select', t
    );

    -- insert
    execute format('drop policy if exists %I on public.%I', t || '_pharmacy_insert', t);
    execute format(
      'create policy %I on public.%I for insert with check (pharmacy_id = public.get_my_pharmacy_id())',
      t || '_pharmacy_insert', t
    );

    -- update
    execute format('drop policy if exists %I on public.%I', t || '_pharmacy_update', t);
    execute format(
      'create policy %I on public.%I for update using (pharmacy_id = public.get_my_pharmacy_id()) with check (pharmacy_id = public.get_my_pharmacy_id())',
      t || '_pharmacy_update', t
    );

    -- delete
    execute format('drop policy if exists %I on public.%I', t || '_pharmacy_delete', t);
    execute format(
      'create policy %I on public.%I for delete using (pharmacy_id = public.get_my_pharmacy_id())',
      t || '_pharmacy_delete', t
    );
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. profiles - self access + owner-level access within the tenant.
--    No pharmacy-wide policy without the role check: staff must not be able
--    to enumerate colleagues' profiles.
-- ---------------------------------------------------------------------------
drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles
  for select using (id = auth.uid());

drop policy if exists profiles_select_pharmacy_owner on public.profiles;
create policy profiles_select_pharmacy_owner on public.profiles
  for select using (
    pharmacy_id = public.get_my_pharmacy_id()
    and public.get_my_role() = 'owner'
  );

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update
  using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists profiles_update_pharmacy_owner on public.profiles;
create policy profiles_update_pharmacy_owner on public.profiles
  for update
  using (
    pharmacy_id = public.get_my_pharmacy_id()
    and public.get_my_role() = 'owner'
  )
  with check (
    pharmacy_id = public.get_my_pharmacy_id()
    and public.get_my_role() = 'owner'
  );

-- ---------------------------------------------------------------------------
-- 4. pharmacies - members may read their own tenant row; only the owner may
--    mutate it; onboarding inserts the row itself (any authenticated user).
--    ('owner' literal is coerced to app_role by the comparison operator.)
-- ---------------------------------------------------------------------------
drop policy if exists pharmacies_select_own on public.pharmacies;
create policy pharmacies_select_own on public.pharmacies
  for select using (id = public.get_my_pharmacy_id());

drop policy if exists pharmacies_update_owner on public.pharmacies;
create policy pharmacies_update_owner on public.pharmacies
  for update
  using (id = public.get_my_pharmacy_id() and public.get_my_role() = 'owner')
  with check (id = public.get_my_pharmacy_id() and public.get_my_role() = 'owner');

drop policy if exists pharmacies_insert_authenticated on public.pharmacies;
create policy pharmacies_insert_authenticated on public.pharmacies
  for insert with check (auth.uid() is not null);

-- ---------------------------------------------------------------------------
-- 5. notifications - user-addressed, not tenant-addressed. The nullable
--    pharmacy_id is a routing hint only, so this table deliberately does NOT
--    use the generic pharmacy loop (a pharmacy_id = NULL row would otherwise
--    be invisible to its own recipient).
-- ---------------------------------------------------------------------------
drop policy if exists notifications_select_own on public.notifications;
create policy notifications_select_own on public.notifications
  for select using (user_id = auth.uid());

drop policy if exists notifications_insert_own on public.notifications;
create policy notifications_insert_own on public.notifications
  for insert with check (
    user_id = auth.uid()
    or pharmacy_id = public.get_my_pharmacy_id()
  );

drop policy if exists notifications_update_own on public.notifications;
create policy notifications_update_own on public.notifications
  for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
