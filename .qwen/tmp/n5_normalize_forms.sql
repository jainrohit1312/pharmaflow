-- Open item N-5, Phase 6 chunk 1 (2026-09-19). READ-ONLY probe.
--
-- What the test fixtures may rely on: which printed forms collapse to one
-- normalized key. `product_aliases`' unique key is (pharmacy_id, supplier_id,
-- normalized_name), so two rows collide exactly when their normalized_name is
-- equal - and guessing that from the text is how a test ends up asserting
-- nothing (the first draft of phase6_alias_identity.sql did).
select
  public.normalize_product_name('DOLO-650 TAB')        as dash_print,
  public.normalize_product_name('DOLO 650 TAB')        as space_print,
  public.normalize_product_name('  dolo-650   tab  ')  as padded_lower,
  public.normalize_product_name('DOLO650TAB')          as run_together;
