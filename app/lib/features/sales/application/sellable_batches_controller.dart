/// The batches a product can be sold from, FEFO.
library;

import 'package:app/data/models/batch_status.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sellable_batches_controller.g.dart';

/// The batches of [productId] that still hold stock, soonest expiry first.
///
/// `batchesFor` already returns every batch in FEFO order; what this adds is the
/// filter. A batch with nothing left cannot be dispensed, and offering it would
/// let the counter pick an empty shelf - which the stock trigger would then refuse
/// at checkout, after the whole basket had been rung up.
@riverpod
Future<List<BatchStatus>> sellableBatches(Ref ref, String productId) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  final batches = await ref
      .watch(productsRepositoryProvider)
      .batchesFor(pharmacyId: pharmacyId, productId: productId);
  return batches.where((batch) => batch.hasStock).toList(growable: false);
}
