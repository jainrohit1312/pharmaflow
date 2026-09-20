/// The counter's product search: what a term matches, and what each match would
/// be dispensed from.
///
/// The dropdown exists so the counter can add a product **without a second
/// screen**: pressing Enter takes the batch FEFO would choose, and the row shows
/// that batch's number, expiry and what is left in it *before* it is added - so
/// the choice the old batch chooser made is visible without interrupting the
/// common case. Asking for a different batch is still one tap away (the row's own
/// affordance), which is why this carries the batches rather than only the winner.
library;

import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'pos_search.g.dart';

/// How many products the counter's dropdown offers at once.
///
/// Five rather than the twenty a picker elsewhere shows: the counter is typing with
/// a customer waiting, the row wanted is nearly always the first, and a list long
/// enough to need scrolling is one the eye has to search instead of the field.
const int posSearchLimit = 5;

/// One product the search matched, with the batches it can be dispensed from.
class PosSearchHit {
  /// Creates a hit.
  const PosSearchHit({required this.product, required this.batches});

  /// The matched product.
  final Product product;

  /// Every batch of [product], soonest expiry first - in the order
  /// [ProductsRepository.batchesForProducts] returns them.
  final List<BatchStatus> batches;

  /// The batch Enter dispenses from: the first with stock, in FEFO order.
  ///
  /// This is the same pick the batch chooser marks as "dispense this one first",
  /// and it is FEFO by the same convention: an unknown-expiry batch sorts last, so
  /// a batch nobody can date is never the one chosen automatically. `null` when
  /// nothing of the product is left, which is what makes its row a refusal rather
  /// than an add.
  BatchStatus? get dispensable {
    for (final batch in batches) {
      if (batch.hasStock) {
        return batch;
      }
    }
    return null;
  }

  /// Units of the product across every batch.
  int get stock => batches.fold(0, (sum, batch) => sum + batch.qty);
}

/// Products matching [term], each with its batches, for the counter's dropdown.
///
/// Two reads in one provider - the catalogue page, then the batches of exactly the
/// products that page returned - so the dropdown has one async value to render
/// rather than two it would have to sequence itself. An empty [term] matches the
/// first active products, so the counter opens on something to tap rather than an
/// empty box.
@riverpod
Future<List<PosSearchHit>> posSearchResults(Ref ref, String term) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  final repository = ref.watch(productsRepositoryProvider);

  final products = await repository.list(
    pharmacyId: pharmacyId,
    query: ProductsQuery(search: term, isActive: true),
    limit: posSearchLimit,
  );
  if (products.isEmpty) {
    return const <PosSearchHit>[];
  }

  final batches = await repository.batchesForProducts(
    pharmacyId: pharmacyId,
    productIds: products.map((product) => product.id).toList(growable: false),
  );

  return <PosSearchHit>[
    for (final product in products)
      PosSearchHit(
        product: product,
        batches: batches[product.id] ?? const <BatchStatus>[],
      ),
  ];
}
