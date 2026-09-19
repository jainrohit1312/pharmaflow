/// The reorder list: products below the level they are meant to keep.
library;

import 'package:app/data/models/alert_payloads.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/inventory/data/inventory_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'low_stock_controller.g.dart';

/// Products with a reorder level set that are below it, worst shortfall first.
///
/// A plain provider rather than a controller: this list has no filter, no paging
/// and no writes, so the only thing that ever happens to it is a refetch after a
/// stock movement, which `ref.invalidate` already expresses.
///
/// The answer is `low_stock_products()`'s own payload, and both the order and
/// the comparison are its (D-047): the RPC decides "below its level", orders by
/// shortfall and hands back the shortfall itself, so nothing here decides it in
/// Dart over a page of rows (I-1).
///
/// The scope is watched rather than read, and it is watched to *gate* the read:
/// the RPC takes the tenant from the caller's JWT (D-004), so `pharmacyId` is
/// not an argument to the request - but the tab must not answer "nothing is
/// below its level" while the profile is still resolving, which is the same
/// "loading and empty must not look alike" rule the sale-return picker broke
/// (T-5).
@riverpod
Future<List<LowStockProduct>> lowStockList(Ref ref) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(inventoryRepositoryProvider)
      .lowStock(pharmacyId: pharmacyId);
}
