-- Migration: 20260918000011_helper_functions | Purpose: RLS helper functions (tenant id, caller role) and product-name normalization
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace function + guarded grants.

-- ---------------------------------------------------------------------------
-- 1. Tenant / identity helpers
--
--    Both readers are SECURITY DEFINER so the profiles lookup inside them is
--    evaluated with the function owner's rights and therefore is NOT blocked
--    by profiles' own RLS policies. This matters: the profiles policies call
--    get_my_pharmacy_id(), so a non-definer version would recurse / self-block.
--    They are still caller-scoped because they read auth.uid(), which always
--    resolves to the *invoking* user regardless of the security context.
--
--    search_path is pinned to avoid hijacking via a caller-controlled path.
-- ---------------------------------------------------------------------------
create or replace function public.get_my_pharmacy_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select pharmacy_id from public.profiles where id = auth.uid();
$$;

create or replace function public.get_my_role()
returns public.app_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- ---------------------------------------------------------------------------
-- 2. Product name normalization
--    Order of operations (matches the alias-matching contract):
--      NULL in -> NULL out
--      lower -> trim -> collapse whitespace runs to one space
--            -> drop everything outside [a-z0-9 ] -> trim again
--    IMMUTABLE so it can back expression indexes and generated columns.
-- ---------------------------------------------------------------------------
create or replace function public.normalize_product_name(p_input text)
returns text
language sql
immutable
as $$
  select case
    when p_input is null then null
    else
      trim(
        both ' ' from
        regexp_replace(
          regexp_replace(
            lower(trim(both ' ' from p_input)),
            '[[:space:]]+',
            ' ',
            'g'
          ),
          '[^a-z0-9 ]',
          '',
          'g'
        )
      )
  end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Execution grants
--    authenticated only: anon has no RLS identity and no business calling
--    these. service_role bypasses RLS entirely and needs no grant.
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.get_my_pharmacy_id() to authenticated';
  execute 'grant execute on function public.get_my_role() to authenticated';
  execute 'grant execute on function public.normalize_product_name(text) to authenticated';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
