-- Migration: 20260920000032_phase6_5a_opening_stock_digest_schema | Purpose:
-- correct the fingerprint's digest() call in opening_stock_classify().
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: create or replace function, guarded grant/revoke.
--
-- Why this is a migration and not an edit to 000031
-- ------------------------------------------------
-- 000031 was applied, so `supabase db push` will never run it again (D-013's
-- finding, learned on 000010: a file the remote history already records is
-- skipped, so fixing it in place leaves the hosted function broken while the
-- repository reads as if it were fixed). The correction therefore arrives as its
-- own version, and the two files together are the record: 000031 created the
-- classifier, this one fixed one expression in it.
--
-- What was wrong
-- --------------
-- `digest()` is not on the pinned `search_path`. Supabase installs pgcrypto into
-- the `extensions` schema — the same place migration 000022 installs `vector`,
-- which is why that migration calls it `extensions.vector(768)` and not plain
-- `vector` — and every function here pins `set search_path = public`. So the
-- unqualified call failed at runtime with `function digest(text, unknown) does
-- not exist`, and it failed *late*: only on a payload with no refused rows, at
-- the point the fingerprint is taken. A CREATE OR REPLACE is enough to validate
-- the body at push time, which is why this only surfaced when the test ran.
--
-- Only that one expression changes. The rest of the function - the defensive
-- parsing, the one-batch-per-product refusal, the ambiguity block - is exactly as
-- 000031 wrote it, and `create or replace` keeps the function's OID, so its
-- privileges and its comment from 000031 survive. They are re-asserted below
-- anyway, because an ACL that matters should be stated where the body is.

create or replace function public.opening_stock_classify(
  p_pharmacy_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rows           jsonb := coalesce(p_rows, '[]'::jsonb);
  v_rec            record;
  v_number         int;
  v_name_raw       text;
  v_name           text;
  v_norm           text;
  v_batch_raw      text;
  v_expiry_raw     text;
  v_expiry         date;
  v_qty_txt        text;
  v_qty            int;
  v_rate_txt       text;
  v_rate           numeric(12,2);
  v_mrp_txt        text;
  v_mrp            numeric(12,2);
  v_note           text;
  v_matches        uuid[];
  v_match_names    text[];
  v_product_id     uuid;
  v_outcome        text;
  v_rows_out       jsonb := '[]'::jsonb;
  v_lines          text[] := array[]::text[];
  v_seen           jsonb := '{}'::jsonb;
  v_seen_row       int;
  v_row_count      int := 0;
  v_total_qty      bigint := 0;
  v_total_cost     numeric(14,2) := 0;
  v_new_count      int := 0;
  v_matched_count  int := 0;
  v_ambiguous      int := 0;
  v_zero_qty       int := 0;
  v_unknown_batch  int := 0;
  v_unknown_expiry int := 0;
  v_expired        int := 0;
  v_errors         int := 0;
  v_fingerprint    text;
begin
  for v_rec in
    select e.payload, e.rownum
      from jsonb_array_elements(v_rows) with ordinality as e(payload, rownum)
  loop
    v_number := v_rec.rownum::int;
    v_note := null;
    v_outcome := null;
    v_product_id := null;
    v_matches := null;
    v_match_names := null;
    v_qty := null;
    v_rate := null;
    v_mrp := null;
    v_expiry := null;

    v_name_raw   := coalesce(v_rec.payload ->> 'item_name', '');
    v_batch_raw  := trim(coalesce(v_rec.payload ->> 'batch_no', ''));
    v_expiry_raw := trim(coalesce(v_rec.payload ->> 'expiry_date', ''));
    v_qty_txt    := trim(coalesce(v_rec.payload ->> 'qty', ''));
    v_rate_txt   := trim(coalesce(v_rec.payload ->> 'purchase_rate', ''));
    v_mrp_txt    := trim(coalesce(v_rec.payload ->> 'mrp', ''));
    v_name       := trim(both ' ' from v_name_raw);

    -- ---- the item name: the only field that must not be blank
    if v_name = '' then
      v_note := 'item_name is blank';
    end if;

    -- ---- qty: a whole, non-negative number. Zero is valid (the owner has 53
    --      of them: a product that exists in the catalogue and holds no stock).
    if v_note is null then
      if v_qty_txt = '' then
        v_note := 'qty is missing';
      elsif v_qty_txt !~ '^[0-9]+$' then
        if v_qty_txt ~ '^-' then
          v_note := format('qty "%s" is negative', v_qty_txt);
        else
          v_note := format('qty "%s" is not a whole number', v_qty_txt);
        end if;
      elsif length(v_qty_txt) > 9 then
        v_note := format('qty "%s" is out of range', v_qty_txt);
      else
        v_qty := v_qty_txt::int;
      end if;
    end if;

    -- ---- purchase_rate and mrp: at most two decimals, which is what the
    --      columns hold. Zero cost is valid (the owner's PANTOP row) - it is a
    --      rate of zero, not a missing one, and only a missing one is refused.
    if v_note is null then
      if v_rate_txt = '' then
        v_note := 'purchase_rate is missing';
      elsif v_rate_txt !~ '^[0-9]+(\.[0-9]{1,2})?$' then
        if v_rate_txt ~ '^-' then
          v_note := format('purchase_rate "%s" is negative', v_rate_txt);
        else
          v_note := format(
            'purchase_rate "%s" is not a number with at most two decimals',
            v_rate_txt
          );
        end if;
      else
        v_rate := v_rate_txt::numeric(12,2);
      end if;
    end if;

    if v_note is null then
      if v_mrp_txt = '' then
        v_note := 'mrp is missing';
      elsif v_mrp_txt !~ '^[0-9]+(\.[0-9]{1,2})?$' then
        if v_mrp_txt ~ '^-' then
          v_note := format('mrp "%s" is negative', v_mrp_txt);
        else
          v_note := format(
            'mrp "%s" is not a number with at most two decimals',
            v_mrp_txt
          );
        end if;
      else
        v_mrp := v_mrp_txt::numeric(12,2);
      end if;
    end if;

    -- ---- expiry: absent is valid and means unknown; present but unreadable is
    --      refused rather than dropped, because silently discarding a date the
    --      owner wrote would hide a broken column in their export.
    if v_note is null and v_expiry_raw <> '' then
      if v_expiry_raw !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_note := format('expiry_date "%s" is not YYYY-MM-DD', v_expiry_raw);
      else
        begin
          v_expiry := v_expiry_raw::date;
        exception
          when others then
            v_note := format('expiry_date "%s" is not a real date', v_expiry_raw);
        end;
      end if;
    end if;

    -- ---- matching, and the one-batch-per-product rule
    if v_note is null then
      v_norm := public.normalize_product_name(v_name);

      v_seen_row := nullif(v_seen ->> v_norm, '')::int;
      if v_seen_row is not null then
        v_note := format(
          'this product name is already row %s - opening stock writes one batch per product',
          v_seen_row
        );
        v_outcome := 'error';
      else
        v_seen := v_seen || jsonb_build_object(v_norm, v_number);

        select array_agg(p.id order by p.created_at, p.id),
               array_agg(p.name order by p.created_at, p.id)
          into v_matches, v_match_names
          from public.products p
         where p.pharmacy_id = p_pharmacy_id
           and public.normalize_product_name(p.name) = v_norm;

        if coalesce(array_length(v_matches, 1), 0) = 0 then
          v_outcome := 'new';
        elsif array_length(v_matches, 1) = 1 then
          v_outcome := 'matched';
          v_product_id := v_matches[1];
        else
          v_outcome := 'ambiguous';
          v_note := format(
            '%s catalogue products share this name - resolve it in the catalogue first',
            array_length(v_matches, 1)
          );
        end if;
      end if;
    end if;

    if v_outcome = 'error' or (v_outcome is null and v_note is not null) then
      v_outcome := 'error';
    end if;

    v_row_count := v_row_count + 1;

    if v_outcome = 'error' then
      v_errors := v_errors + 1;
    else
      v_total_qty := v_total_qty + v_qty;
      v_total_cost := v_total_cost + (v_qty * v_rate);

      if v_outcome = 'new' then
        v_new_count := v_new_count + 1;
      elsif v_outcome = 'matched' then
        v_matched_count := v_matched_count + 1;
      else
        v_ambiguous := v_ambiguous + 1;
      end if;

      if v_qty = 0 then
        v_zero_qty := v_zero_qty + 1;
      end if;
      if v_batch_raw = '' then
        v_unknown_batch := v_unknown_batch + 1;
      end if;
      if v_expiry_raw = '' then
        v_unknown_expiry := v_unknown_expiry + 1;
      elsif v_expiry < current_date then
        v_expired := v_expired + 1;
      end if;

      -- The canonical line the fingerprint is taken over. The name is
      -- normalized, the batch number and the raw expiry are lowercased,
      -- trimmed and compared as text (leading zeros are the point of the
      -- column), and the money is formatted at the precision the columns
      -- store, so a re-export that differs only in whitespace, case or
      -- `27.5` vs `27.50` is the same content.
      v_lines := v_lines || (
        v_norm || '|'
        || lower(v_batch_raw) || '|'
        || lower(v_expiry_raw) || '|'
        || v_qty::text || '|'
        || to_char(v_rate, 'FM999999990.00') || '|'
        || to_char(v_mrp, 'FM999999990.00')
      );
    end if;

    v_rows_out := v_rows_out || jsonb_build_object(
      'row_number', v_number,
      'raw_item_name', v_name_raw,
      'item_name', v_name,
      'normalized_name', v_norm,
      'raw_batch_no', v_batch_raw,
      'raw_expiry', v_expiry_raw,
      'qty', v_qty,
      'purchase_rate', v_rate,
      'mrp', v_mrp,
      'expiry_date', v_expiry,
      'is_unknown_batch', (v_batch_raw = ''),
      'is_expired', case
                      when v_expiry is null then false
                      else v_expiry < current_date
                    end,
      'outcome', v_outcome,
      'product_id', v_product_id,
      'product_names', to_jsonb(v_match_names),
      'error_note', v_note
    );
  end loop;

  if v_errors = 0 and v_row_count > 0 then
    -- `extensions.digest`, not `digest`: pgcrypto lives in the `extensions`
    -- schema on this project and the search_path above is pinned to `public`.
    select encode(
             extensions.digest(string_agg(line, E'\n' order by line), 'sha256'),
             'hex'
           )
      into v_fingerprint
      from unnest(v_lines) as line;
  end if;

  return jsonb_build_object(
    'fingerprint', v_fingerprint,
    'summary', jsonb_build_object(
      'row_count', v_row_count,
      'total_qty', v_total_qty,
      'total_cost', v_total_cost,
      'new_product_count', v_new_count,
      'matched_product_count', v_matched_count,
      'ambiguous_row_count', v_ambiguous,
      'zero_qty_row_count', v_zero_qty,
      'unknown_batch_row_count', v_unknown_batch,
      'unknown_expiry_row_count', v_unknown_expiry,
      'expired_row_count', v_expired,
      'error_row_count', v_errors
    ),
    'rows', v_rows_out
  );
end;
$$;

comment on function public.opening_stock_classify(uuid, jsonb) is
  'Validates, normalizes and classifies opening-stock rows for one pharmacy. Shared by preview_opening_stock() and commit_opening_stock_import() so a preview can never classify differently from the commit. Internal: no role is granted EXECUTE.';

-- Restated rather than assumed: `create or replace` keeps the function's OID and
-- therefore its privileges, but the rule that matters here (no role may call the
-- classifier directly) belongs next to the body it protects.
do $$
begin
  execute 'revoke execute on function public.opening_stock_classify(uuid, jsonb) from anon, authenticated, public';
exception
  when undefined_object then
    -- Role missing in a bare (non-Supabase) cluster: nothing to revoke.
    null;
end $$;
