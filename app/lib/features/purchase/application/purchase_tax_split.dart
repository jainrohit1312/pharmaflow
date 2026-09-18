/// Whether a purchase's tax is intra-state or inter-state.
library;

import 'package:app/core/utils/logger.dart';
import 'package:app/data/repositories/pharmacy_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'purchase_tax_split.g.dart';

/// Whether a supply from [supplierId] is intra-state (CGST + SGST) or
/// inter-state (IGST).
///
/// Deliberately incapable of failing. It is read with `.future` by the write
/// paths, and in Riverpod 3 a *failed* build is kept as a result rather than
/// completing that future, so a provider that could fail here would hang every
/// save instead of reporting anything (D-015). A read failure falls back to
/// intra-state, which is safe because the split decides only which tax *head*
/// carries the amount: `grand_total` - the figure the ledger posts - is
/// identical either way.
@riverpod
Future<TaxSplit> purchaseTaxSplit(Ref ref, String supplierId) async {
  try {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final pharmacyState = await ref
        .watch(pharmacyRepositoryProvider)
        .stateFor(pharmacyId);
    final supplier = await ref
        .watch(suppliersRepositoryProvider)
        .byId(pharmacyId: pharmacyId, supplierId: supplierId);

    return PurchaseTotals.splitFor(
      pharmacyState: pharmacyState,
      supplierState: supplier?.state,
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
