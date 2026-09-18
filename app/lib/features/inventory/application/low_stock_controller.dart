/// The reorder list: products below the level they are meant to keep.
library;

import 'package:app/data/models/product_stock.dart';
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
/// The order and the comparison come from the repository, because deciding
/// "below its level" is a query concern - PostgREST cannot compare two columns,
/// so the repository narrows what it can server-side and decides the rest.
@riverpod
Future<List<ProductStock>> lowStockList(Ref ref) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(inventoryRepositoryProvider)
      .lowStock(pharmacyId: pharmacyId);
}
