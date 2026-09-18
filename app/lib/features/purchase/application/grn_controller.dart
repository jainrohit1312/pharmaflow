/// Books a purchase in: the goods receipt itself.
library;

import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/application/purchase_tax_split.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'grn_controller.g.dart';

/// Receives purchase documents.
///
/// This is the only path that posts stock and a supplier payable, and the whole
/// write lives in `PurchasesRepository.receive` as one operation with a fixed
/// order. The controller's job is to resolve the GST split and to publish the
/// outcome, so a screen cannot assemble the receipt itself and get the order
/// wrong.
@riverpod
class GrnController extends _$GrnController {
  @override
  Future<Purchase?> build() async => null;

  /// Receives [purchaseId] with [lines], creating their batches.
  ///
  /// Returns the received document, whose `stockPostedAt` now records that the
  /// trigger applied it.
  Future<Purchase> receive({
    required String purchaseId,
    required PurchaseDraft header,
    required List<PurchaseLineDraft> lines,
  }) async {
    state = const AsyncLoading<Purchase?>();
    try {
      final split = await ref.read(
        purchaseTaxSplitProvider(header.supplierId).future,
      );
      final received = await ref
          .read(purchasesRepositoryProvider)
          .receive(
            pharmacyId: ref.read(requirePharmacyIdProvider),
            purchaseId: purchaseId,
            header: header,
            lines: lines,
            split: split,
          );
      state = AsyncData<Purchase?>(received);
      return received;
    } on Object catch (error, stackTrace) {
      state = AsyncError<Purchase?>(error, stackTrace);
      rethrow;
    }
  }
}
