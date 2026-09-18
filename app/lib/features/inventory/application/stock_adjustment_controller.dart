/// The manual stock correction write.
library;

import 'package:app/data/models/stock_adjustment.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/inventory/application/stock_readers.dart';
import 'package:app/features/inventory/data/inventory_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'stock_adjustment_controller.g.dart';

/// Writes a `stock_adjustments` row and refreshes everything that reads stock.
///
/// The write itself is one insert: `stock_apply_adjustment()` moves the batch in
/// the same transaction and refuses a decrease that would take it below zero, so
/// a failure leaves nothing behind. What is *not* one statement is telling the
/// screens, which is why the invalidations live here rather than in the sheet
/// that called it - a screen that forgot one would show a stale quantity with no
/// error to explain it.
///
/// The state carries no value: an adjustment produces an audit row, and the
/// interesting result is the batch's new balance, which is read back through the
/// views like every other quantity on these screens.
@riverpod
class StockAdjustmentController extends _$StockAdjustmentController {
  @override
  Future<void> build() async {}

  /// Records a correction of [qty] units of one batch, and refetches the views.
  ///
  /// [type] gives the direction - `stock_adjustments.qty` is always positive, and
  /// a check constraint enforces that. A non-null [batchId] is what makes the
  /// trigger move anything: the adjustment still records without one, but there
  /// is no balance for a product-level row to move.
  Future<void> adjustStock({
    required String productId,
    required AdjustmentType type,
    required int qty,
    String? batchId,
    String? reason,
  }) async {
    state = const AsyncLoading<void>();
    try {
      await ref
          .read(inventoryRepositoryProvider)
          .adjustStock(
            pharmacyId: ref.read(requirePharmacyIdProvider),
            productId: productId,
            type: type,
            qty: qty,
            batchId: batchId,
            reason: reason,
          );
      state = const AsyncData<void>(null);
      refreshStockReaders(ref);
    } on Object catch (error, stackTrace) {
      state = AsyncError<void>(error, stackTrace);
      rethrow;
    }
  }
}
