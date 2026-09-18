-- Migration: 20260918000021_phase4_reporting | Purpose: one server-side aggregate
-- for the reports screen, so a report does not have to fetch every row it is
-- summarising.
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace function + guarded grant.
--
-- Why an RPC rather than PostgREST queries
-- ---------------------------------------
-- PostgREST cannot aggregate: `select sum(grand_total)` is not expressible through
-- the REST API, so every total would otherwise be a page of rows summed in Dart -
-- correct but bounded by `max_rows` (1000), which means a busy month would return
-- a number that is silently short of the truth. A financial report that is wrong
-- in a plausible-looking way is worse than one that is slow, so the sums happen
-- where the data is.
--
-- One function rather than six: the reports screen shows all of these together, and
-- one round trip keeps them consistent with each other (six calls could straddle a
-- sale being rung up between them, and a report whose parts disagree is a report
-- nobody trusts).
--
-- What it covers, and where each figure comes from:
--   sales           - `sales`, for a document count and the money on it
--   collected       - `sales.amount_paid` (the counter takings, walk-ins included)
--   outstanding     - `sales.balance_due` (what customers still owe)
--   purchases       - `purchases` reaching `received` only: a draft or a cancelled
--                     order has moved nothing and owes nothing
--   returns         - both sides, because a return is a credit note either way
--   expenses        - `expenses`
--   stock           - `product_stock`, which already values at landed cost (D-012)
--   expiring        - `batch_status` at MRP, not at cost: that view carries no
--                     landed cost (D-021), and MRP is what the loss is worth at
--                     retail - which is the number a pharmacy decides on.
--
-- Scope: SECURITY DEFINER, so it takes the pharmacy from get_my_pharmacy_id()
-- rather than from an argument, and a caller cannot read another tenant's numbers.

create or replace function public.report_summary(
  p_from date,
  p_to date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pharmacy uuid := public.get_my_pharmacy_id();
  v_from     date := coalesce(p_from, current_date);
  v_to       date := coalesce(p_to, current_date);
begin
  if v_pharmacy is null then
    raise exception 'no pharmacy scope for the signed-in user'
      using errcode = 'insufficient_privilege';
  end if;

  return jsonb_build_object(
    'from', v_from,
    'to', v_to,

    'sales', (
      select jsonb_build_object(
        'count', count(*),
        'sub_total', coalesce(sum(s.sub_total), 0),
        'tax_total', coalesce(sum(s.tax_total), 0),
        'grand_total', coalesce(sum(s.grand_total), 0),
        'collected', coalesce(sum(s.amount_paid), 0),
        'outstanding', coalesce(sum(s.balance_due), 0)
      )
      from public.sales s
      where s.pharmacy_id = v_pharmacy
        and s.status <> 'cancelled'
        and s.sale_date::date between v_from and v_to
    ),

    'purchases', (
      select jsonb_build_object(
        'count', count(*),
        'tax_total', coalesce(sum(p.tax_total), 0),
        'grand_total', coalesce(sum(p.grand_total), 0)
      )
      from public.purchases p
      where p.pharmacy_id = v_pharmacy
        and p.status = 'received'
        and p.invoice_date between v_from and v_to
    ),

    'returns', (
      select jsonb_build_object(
        'sale_count', (
          select count(*) from public.sale_returns r
           where r.pharmacy_id = v_pharmacy
             and r.return_date::date between v_from and v_to
        ),
        'sale_total', (
          select coalesce(sum(r.grand_total), 0) from public.sale_returns r
           where r.pharmacy_id = v_pharmacy
             and r.return_date::date between v_from and v_to
        ),
        'purchase_count', (
          select count(*) from public.purchase_returns r
           where r.pharmacy_id = v_pharmacy
             and r.return_date between v_from and v_to
        ),
        'purchase_total', (
          select coalesce(sum(r.grand_total), 0) from public.purchase_returns r
           where r.pharmacy_id = v_pharmacy
             and r.return_date between v_from and v_to
        )
      )
    ),

    'expenses', (
      select jsonb_build_object(
        'count', count(*),
        'total', coalesce(sum(e.amount), 0)
      )
      from public.expenses e
      where e.pharmacy_id = v_pharmacy
        and e.expense_date between v_from and v_to
    ),

    'stock', (
      select jsonb_build_object(
        'products', count(*),
        'units', coalesce(sum(ps.total_qty), 0),
        'value_at_cost', coalesce(sum(ps.stock_value_at_cost), 0),
        'value_at_mrp', coalesce(sum(ps.stock_value_at_mrp), 0)
      )
      from public.product_stock ps
      where ps.pharmacy_id = v_pharmacy
    ),

    'expiring', (
      select jsonb_build_object(
        'expired_value_at_mrp', coalesce(sum(case when b.expiry_status = 'expired'
          then b.qty * b.mrp else 0 end), 0),
        'critical_value_at_mrp', coalesce(sum(case when b.expiry_status = 'critical'
          then b.qty * b.mrp else 0 end), 0),
        'warning_value_at_mrp', coalesce(sum(case when b.expiry_status = 'warning'
          then b.qty * b.mrp else 0 end), 0)
      )
      from public.batch_status b
      where b.pharmacy_id = v_pharmacy
        and b.qty > 0
    )
  );
end;
$$;

comment on function public.report_summary(date, date) is
  'Every total the reports screen shows, for the caller''s pharmacy and a date range, in one round trip. Sales and purchases by document date, returns and expenses likewise, stock from product_stock (landed cost, D-012) and expiry value from batch_status at MRP (D-021).';

do $$
begin
  execute 'grant execute on function public.report_summary(date, date) to authenticated';
  execute 'revoke execute on function public.report_summary(date, date) from anon, public';
exception
  when undefined_object then
    null;
end $$;
