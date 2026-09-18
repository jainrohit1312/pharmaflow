-- Migration: 20260918000009_indexes | Purpose: explicit indexes for every RLS hot path and foreign key (tenant-scoped lookups, expiry scans, document line items)
-- Target: PostgreSQL 17 (Supabase)
-- Idempotent: every statement uses CREATE INDEX IF NOT EXISTS.
--
-- Naming convention: <table>_<cols>_idx (index name is truncated by PostgreSQL
-- at 63 bytes, so the widest composites here use abbreviated column tokens).

-- ---------------------------------------------------------------------------
-- products
-- ---------------------------------------------------------------------------
create index if not exists products_pharmacy_id_lower_name_idx on public.products (pharmacy_id, lower(name));
create index if not exists products_pharmacy_id_barcode_idx on public.products (pharmacy_id, barcode) where barcode is not null;
create index if not exists products_pharmacy_id_is_active_idx on public.products (pharmacy_id, is_active);

-- ---------------------------------------------------------------------------
-- product_batches
-- ---------------------------------------------------------------------------
create index if not exists product_batches_product_id_expiry_date_idx on public.product_batches (product_id, expiry_date);
create index if not exists product_batches_pharmacy_id_expiry_date_idx on public.product_batches (pharmacy_id, expiry_date);
create index if not exists product_batches_pharmacy_id_product_id_idx on public.product_batches (pharmacy_id, product_id);

-- ---------------------------------------------------------------------------
-- product_aliases (fuzzy/alias resolution)
-- GIN trigram index requires the pg_trgm extension (created in migration 0001).
-- ---------------------------------------------------------------------------
create index if not exists product_aliases_pharmacy_id_normalized_name_idx on public.product_aliases (pharmacy_id, normalized_name);
create index if not exists product_aliases_normalized_name_trgm_idx on public.product_aliases using gin (normalized_name gin_trgm_ops);
create index if not exists product_aliases_product_id_idx on public.product_aliases (product_id);
create index if not exists product_aliases_supplier_id_idx on public.product_aliases (supplier_id);

-- ---------------------------------------------------------------------------
-- suppliers / customers (tenant scoping)
-- ---------------------------------------------------------------------------
create index if not exists suppliers_pharmacy_id_idx on public.suppliers (pharmacy_id);
create index if not exists customers_pharmacy_id_idx on public.customers (pharmacy_id);

-- ---------------------------------------------------------------------------
-- purchases / purchase_items
-- ---------------------------------------------------------------------------
create index if not exists purchases_supplier_id_invoice_date_idx on public.purchases (supplier_id, invoice_date);
create index if not exists purchases_pharmacy_id_invoice_date_idx on public.purchases (pharmacy_id, invoice_date);
create index if not exists purchases_pharmacy_id_status_idx on public.purchases (pharmacy_id, status);
create index if not exists purchases_supplier_id_created_by_idx on public.purchases (supplier_id, created_by);
create index if not exists purchases_created_by_idx on public.purchases (created_by);

create index if not exists purchase_items_purchase_id_idx on public.purchase_items (purchase_id);
create index if not exists purchase_items_batch_id_idx on public.purchase_items (batch_id);
create index if not exists purchase_items_product_id_idx on public.purchase_items (product_id);

-- ---------------------------------------------------------------------------
-- purchase_returns / purchase_return_items
-- ---------------------------------------------------------------------------
create index if not exists purchase_returns_purchase_id_idx on public.purchase_returns (purchase_id);
create index if not exists purchase_returns_supplier_id_idx on public.purchase_returns (supplier_id);

create index if not exists purchase_return_items_purchase_return_id_idx on public.purchase_return_items (purchase_return_id);
create index if not exists purchase_return_items_purchase_item_id_idx on public.purchase_return_items (purchase_item_id);
create index if not exists purchase_return_items_batch_id_idx on public.purchase_return_items (batch_id);

-- ---------------------------------------------------------------------------
-- sales / sale_items
-- ---------------------------------------------------------------------------
create index if not exists sales_customer_id_sale_date_idx on public.sales (customer_id, sale_date);
create index if not exists sales_pharmacy_id_sale_date_idx on public.sales (pharmacy_id, sale_date);
create index if not exists sales_pharmacy_id_status_idx on public.sales (pharmacy_id, status);
create index if not exists sales_created_by_idx on public.sales (created_by);

create index if not exists sale_items_sale_id_idx on public.sale_items (sale_id);
create index if not exists sale_items_batch_id_idx on public.sale_items (batch_id);
create index if not exists sale_items_product_id_idx on public.sale_items (product_id);

-- ---------------------------------------------------------------------------
-- sale_returns / sale_return_items
-- ---------------------------------------------------------------------------
create index if not exists sale_returns_sale_id_idx on public.sale_returns (sale_id);
create index if not exists sale_returns_customer_id_idx on public.sale_returns (customer_id);

create index if not exists sale_return_items_sale_return_id_idx on public.sale_return_items (sale_return_id);
create index if not exists sale_return_items_sale_item_id_idx on public.sale_return_items (sale_item_id);
create index if not exists sale_return_items_batch_id_idx on public.sale_return_items (batch_id);

-- ---------------------------------------------------------------------------
-- ledger_entries
-- ---------------------------------------------------------------------------
create index if not exists ledger_entries_pharmacy_id_party_sup_cust_idx on public.ledger_entries (pharmacy_id, party_type, supplier_id, customer_id);
create index if not exists ledger_entries_pharmacy_id_entry_date_idx on public.ledger_entries (pharmacy_id, entry_date);
create index if not exists ledger_entries_pharmacy_id_reference_type_idx on public.ledger_entries (pharmacy_id, reference_type);

-- ---------------------------------------------------------------------------
-- payments
-- ---------------------------------------------------------------------------
create index if not exists payments_pharmacy_id_party_type_supplier_id_customer_id_idx on public.payments (pharmacy_id, party_type, supplier_id, customer_id);
create index if not exists payments_pharmacy_id_payment_date_idx on public.payments (pharmacy_id, payment_date);

-- ---------------------------------------------------------------------------
-- expenses
-- ---------------------------------------------------------------------------
create index if not exists expenses_pharmacy_id_expense_date_idx on public.expenses (pharmacy_id, expense_date);
create index if not exists expenses_created_by_idx on public.expenses (created_by);

-- ---------------------------------------------------------------------------
-- stock_adjustments
-- ---------------------------------------------------------------------------
create index if not exists stock_adjustments_pharmacy_id_product_id_idx on public.stock_adjustments (pharmacy_id, product_id);
create index if not exists stock_adjustments_batch_id_idx on public.stock_adjustments (batch_id);

-- ---------------------------------------------------------------------------
-- notifications
-- ---------------------------------------------------------------------------
create index if not exists notifications_user_id_read_at_idx on public.notifications (user_id, read_at);
create index if not exists notifications_user_id_created_at_idx on public.notifications (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- audit_logs
-- ---------------------------------------------------------------------------
create index if not exists audit_logs_pharmacy_id_created_at_idx on public.audit_logs (pharmacy_id, created_at desc);
create index if not exists audit_logs_table_name_record_id_idx on public.audit_logs (table_name, record_id);

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create index if not exists profiles_pharmacy_id_idx on public.profiles (pharmacy_id);
create index if not exists profiles_role_idx on public.profiles (role);
