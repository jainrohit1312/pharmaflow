/// What one invoice can still give back, and the return write.
library;

import 'package:app/data/models/purchase_return.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/inventory/application/stock_readers.dart';
import 'package:app/features/returns/application/purchase_returns_list_controller.dart';
import 'package:app/features/returns/data/purchase_returns_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'purchase_return_form_controller.g.dart';

/// The lines of one received purchase, with how much of each can go back.
@riverpod
Future<List<ReturnableLine>> returnableLines(Ref ref, String purchaseId) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(purchaseReturnsRepositoryProvider)
      .returnableFor(pharmacyId: pharmacyId, purchaseId: purchaseId);
}

/// Creates a purchase return, and refreshes everything the movement touches.
///
/// A return decrements a batch, so it refreshes the same four stock readers a
/// stock adjustment does (`refreshStockReaders`, the one place that list lives -
/// D-021). It also invalidates the list it will appear in, which is this
/// feature's own concern.
@riverpod
class PurchaseReturnFormController extends _$PurchaseReturnFormController {
  @override
  Future<PurchaseReturn?> build() async => null;

  /// Records a return of [quantities] units, keyed by purchase-item id.
  ///
  /// The quantities are all the client decides: the amounts, the supplier and the
  /// batch come from the invoice line, and the limit is re-derived by the
  /// repository from the invoice line, the returns already raised against it and
  /// the batch balance - so a stale form cannot talk the write into a larger
  /// credit than the invoice supports.
  Future<PurchaseReturn> createReturn({
    required String purchaseId,
    required DateTime returnDate,
    required Map<String, int> quantities,
    String? reason,
  }) async {
    state = const AsyncLoading<PurchaseReturn?>();
    try {
      final saved = await ref
          .read(purchaseReturnsRepositoryProvider)
          .create(
            pharmacyId: ref.read(requirePharmacyIdProvider),
            purchaseId: purchaseId,
            returnDate: returnDate,
            quantities: quantities,
            reason: reason,
          );
      state = AsyncData<PurchaseReturn?>(saved);
      ref.invalidate(purchaseReturnsListControllerProvider);
      refreshStockReaders(ref);
      return saved;
    } on Object catch (error, stackTrace) {
      state = AsyncError<PurchaseReturn?>(error, stackTrace);
      rethrow;
    }
  }
}
