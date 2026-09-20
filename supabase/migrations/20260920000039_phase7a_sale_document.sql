-- Migration: 20260920000039_phase7a_sale_document | Purpose: one additive read that returns
-- everything an 80mm Drug-Rules receipt has to print - the sale's own row and, per line, the
-- batch number and the expiry it came out of.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create-or-replace function, guarded grants.
--
-- Why a new function rather than a wider one (D-079)
-- --------------------------------------------------
-- `checkout_sale(p_payload jsonb) returns public.sales` (00036) is the sale's WRITE path and
-- returns a composite row, and a composite return type cannot be extended in place: widening it
-- would break `Sale.fromJson(row)` and every committed SQL test that reads the returned row.
--
-- The per-line batch and expiry are not on the sale at all. `sale_items` records `batch_id`
-- alone (00006:24-45), so the "which pack, expiring when" a Drug-Rules bill must print is not in
-- the sale document. Two options were put to the owner on 2026-09-20 and the chosen one is this:
-- an additive read, rather than a PostgREST read-back the client stitches together from two
-- tables that could disagree.
--
-- The patient's code, which `sales` does not carry
-- ------------------------------------------------
-- A receipt prints the patient's `patient_code` (D-074 mints it, `PT-00001`), and that column
-- lives on `customers`. It is JOINED here - one round trip, and the code the row held rather
-- than a second read that could race the master. What falls out of that is correct rather than
-- a gap:
--
--   * for a counter or an IPD sale, `sales.customer_id` IS the patient (D-074), so the code is
--     the patient's;
--   * for a package sale that customer is the HOSPITAL'S ACCOUNT row, whose patient code is
--     legitimately absent - the patient on a package bill is the sale's own `patient_name` /
--     `patient_mobile` snapshot and has no patient row of their own, so the receipt prints the
--     snapshot and no code;
--   * a sale with no customer at all (a transfer) has no code, and neither has a customer
--     registered before Phase 7a until `save_patient()` first touches it (D-074) - the receipt
--     prints an em dash rather than a fabricated code, exactly as an unknown batch prints one
--     rather than `OPENING-…`.
--
-- One read, one tenant guard (D-079)
-- ----------------------------------
-- `security invoker`, so the caller's own RLS policies apply ON TOP OF the explicit
-- `pharmacy_id = get_my_pharmacy_id()` guard: guessing another pharmacy's sale id answers `null`
-- rather than someone else's document. The grant goes to `authenticated` and is revoked from
-- `anon, public`, the idiom migration 00018 settled for this family.
--
-- The arithmetic stays the stored row's (D-075, D-057). This function returns the sale and its
-- lines; it computes no money, sums nothing and rounds nothing. The totals a receipt prints are
-- `sales.sub_total` / `tax_total` / `grand_total` - what the server wrote and the ledger posted.
--
-- The body below is the owner's, approved verbatim on 2026-09-20, with the single `patient_code`
-- key added - which is the question the owner asked this slice to decide (D-079).

-- ---------------------------------------------------------------------------
-- 1. sale_document() - the receipt's one read
-- ---------------------------------------------------------------------------
create or replace function public.sale_document(p_sale_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'sale', to_jsonb(s.*),
    'patient_code', c.patient_code,
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'item', to_jsonb(si.*),
        'batch_no', pb.batch_no,
        'expiry_date', pb.expiry_date,
        'is_unknown_batch', pb.is_unknown_batch
      ) order by si.created_at)
      from sale_items si
      left join product_batches pb on pb.id = si.batch_id
      where si.sale_id = s.id
    ), '[]'::jsonb)
  )
  from sales s
  left join customers c
    on c.id = s.customer_id
   and c.pharmacy_id = s.pharmacy_id
  where s.id = p_sale_id
    and s.pharmacy_id = get_my_pharmacy_id();
$$;

comment on function public.sale_document(uuid) is
  'One sale as the receipt prints it: the sales row itself, the patient''s code (joined on sales.customer_id - absent on a package sale''s hospital account and on a row registered before Phase 7a), and its lines with each line''s batch_no, expiry_date and is_unknown_batch. Tenant-scoped and security invoker, so RLS applies as well as the pharmacy guard; answers null for a sale outside the caller''s pharmacy. Computes no money: the totals are the stored row''s.';

-- ---------------------------------------------------------------------------
-- 2. Grants
-- ---------------------------------------------------------------------------
do $$
begin
  execute 'grant execute on function public.sale_document(uuid) to authenticated';
  execute 'revoke execute on function public.sale_document(uuid) from anon, public';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to grant.
    null;
end $$;
