/// Whether a sale's tax is intra-state or inter-state.
library;

import 'package:app/core/utils/logger.dart';
import 'package:app/data/repositories/pharmacy_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sale_tax_split.g.dart';

/// Whether a sale to [placeOfSupply] is intra-state (CGST + SGST) or inter-state
/// (IGST).
///
/// A sale's second state comes from the document's own `place_of_supply` rather
/// than from the customer: `customers` has no state column (migration 00004 gives
/// one to suppliers only), so the counter says where the goods are going and the
/// common case - a walk-in, or a customer in the pharmacy's own state - defaults
/// to the pharmacy's own.
///
/// The decision itself is `PurchaseTotals.splitFor`, reused rather than restated:
/// equal states is intra-state whichever direction the goods travel, and two
/// implementations of that rule would eventually disagree about an unknown state.
///
/// Deliberately incapable of failing, like `purchaseTaxSplit`: it is read with
/// `.future` by the write path, and in Riverpod 3 a *failed* build is kept as a
/// result rather than completing that future, so a provider that could fail here
/// would hang every checkout (D-015). A read failure falls back to intra-state,
/// which is safe because the split decides only which tax *head* carries the
/// amount - `grand_total`, the figure the ledger posts, is identical either way.
@riverpod
Future<TaxSplit> saleTaxSplit(Ref ref, String? placeOfSupply) async {
  try {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final pharmacyState = await ref
        .watch(pharmacyRepositoryProvider)
        .stateFor(pharmacyId);

    return PurchaseTotals.splitFor(
      pharmacyState: pharmacyState,
      supplierState: placeOfSupply,
    );
  } on Object catch (error, stackTrace) {
    appLogger.w(
      'Falling back to an intra-state GST split: the two states could not be read',
      error: error,
      stackTrace: stackTrace,
    );
    return TaxSplit.intraState;
  }
}
