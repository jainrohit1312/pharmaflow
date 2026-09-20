/// The counter's product list: what a term matches, what was sold recently, and
/// what a category holds, with the batches each can be dispensed from.
///
/// One provider for the whole list rather than one per source, because the counter
/// shows exactly one list at a time and the search field, the strip and the
/// keyboard all have to agree on which - so the choice travels as the key rather
/// than being re-derived at each of the three places that ask.
///
/// Every list exists so the counter can add a product **without a second screen**:
/// pressing Enter takes the batch FEFO would choose, and a row shows that batch's
/// number, expiry and what is left in it *before* it is added. Asking for a
/// different batch is still one tap away (the row's own affordance), which is why a
/// hit carries the batches rather than only the winner.
library;

import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'pos_search.freezed.dart';
part 'pos_search.g.dart';

/// How many products a **search** offers at once.
///
/// Five rather than the twenty a picker elsewhere shows: the counter is typing with
/// a customer waiting, the row wanted is nearly always the first, and a list long
/// enough to need scrolling is one the eye has to search instead of the field.
const int posSearchLimit = 5;

/// How many products a **browse** list (Recent, a category, All) offers.
///
/// Ten: a browse list is read rather than typed into, and Recent is ten by the
/// owner's own words. Only the search narrows to five, because a search is a guess
/// at what was meant rather than a shelf to look along.
const int posBrowseLimit = 10;

/// Which list the counter is showing.
///
/// A value rather than three flags, because it **keys a provider**: `==` is what
/// makes two identical choices the same list rather than two lists that happen to
/// look alike, and Freezed is what gives a key that equality without a hand-written
/// operator.
///
/// It is also the strip's own choice - a tab is a key with no term - so the strip
/// and the list it drives cannot disagree about what has been chosen.
@freezed
abstract class PosListKey with _$PosListKey {
  /// Creates a key.
  ///
  /// The default is the All tab: no term, not Recent, no category.
  const factory PosListKey({
    @Default('') String term,
    @Default(false) bool recent,
    String? category,
  }) = _PosListKey;
}

/// One product the counter may add, with the batches it can be dispensed from.
class PosSearchHit {
  /// Creates a hit.
  const PosSearchHit({required this.product, required this.batches});

  /// The product.
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

/// The products [key] names, each with its batches.
///
/// Four sources, in the order the counter meets them: a typed term searches the
/// whole catalogue and ignores the strip; Recent is the distinct products sold most
/// recently, newest first; a category is that category's active products; and All
/// is the catalogue from the top. Two reads per answer - the products, then the
/// batches of exactly those products - so the list has one async value to render.
@riverpod
Future<List<PosSearchHit>> posList(Ref ref, PosListKey key) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  final products = ref.watch(productsRepositoryProvider);

  final List<Product> rows;
  if (key.term.isNotEmpty) {
    rows = await products.list(
      pharmacyId: pharmacyId,
      query: ProductsQuery(search: key.term, isActive: true),
      limit: posSearchLimit,
    );
  } else if (key.recent) {
    rows = await _recentlySold(ref, pharmacyId: pharmacyId);
  } else if (key.category case final category?) {
    rows = await products.list(
      pharmacyId: pharmacyId,
      query: ProductsQuery(category: category, isActive: true),
      limit: posBrowseLimit,
    );
  } else {
    rows = await products.list(
      pharmacyId: pharmacyId,
      query: const ProductsQuery(isActive: true),
      limit: posBrowseLimit,
    );
  }

  if (rows.isEmpty) {
    return const <PosSearchHit>[];
  }

  final batches = await products.batchesForProducts(
    pharmacyId: pharmacyId,
    productIds: rows.map((product) => product.id).toList(growable: false),
  );

  return <PosSearchHit>[
    for (final product in rows)
      PosSearchHit(
        product: product,
        batches: batches[product.id] ?? const <BatchStatus>[],
      ),
  ];
}

/// The distinct products sold most recently, newest first.
///
/// The read answers ids in the sold order, which is the one thing a product row
/// cannot carry - so the rows are fetched by id and then put back into that order.
Future<List<Product>> _recentlySold(
  Ref ref, {
  required String pharmacyId,
}) async {
  final ids = await ref
      .watch(salesRepositoryProvider)
      .recentlySoldProductIds(
        pharmacyId: pharmacyId,
        // Stated rather than left to the read's own default, which happens to be
        // the same number today: the counter's browse limit is the one that decides
        // how long its Recent list is, and a change here must not wait on a change
        // over there.
        // ignore: avoid_redundant_argument_values
        limit: posBrowseLimit,
      );
  if (ids.isEmpty) {
    return const <Product>[];
  }

  final rows = await ref
      .watch(productsRepositoryProvider)
      .list(
        pharmacyId: pharmacyId,
        query: ProductsQuery(ids: ids, isActive: true),
        limit: posBrowseLimit,
      );
  final byId = <String, Product>{for (final row in rows) row.id: row};

  final ordered = <Product>[];
  for (final id in ids) {
    final product = byId[id];
    if (product != null) {
      ordered.add(product);
    }
  }
  return ordered;
}
