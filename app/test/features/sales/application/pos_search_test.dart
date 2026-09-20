/// Tests for the counter's search: what a hit says, and which batch it adds.
library;

import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/sales/application/pos_search.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_inventory_repository.dart';
import '../../../support/fake_products_repository.dart';

/// A container with a fake catalogue behind the search's two reads.
ProviderContainer _container(FakeProductsRepository products) {
  final container = ProviderContainer(
    // Left untyped on purpose: `Override` is declared in `riverpod`, which
    // `flutter_riverpod` does not re-export (the same note as the sales test app).
    overrides: [
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      productsRepositoryProvider.overrideWithValue(products),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('PosSearchHit.dispensable', () {
    test('takes the first batch that holds stock', () {
      final hit = PosSearchHit(
        product: buildProduct('Dolo 650'),
        batches: <BatchStatus>[
          // An empty batch first on purpose: FEFO order is the read's job, and the
          // one thing this must not do is stop at a batch that has nothing left -
          // it has to move to the next one.
          buildBatch(id: 'b-empty', batchNo: 'B-0', qty: 0),
          buildBatch(id: 'b-first', qty: 5),
          buildBatch(id: 'b-second', batchNo: 'B-2', qty: 5),
        ],
      );

      expect(hit.dispensable?.id, 'b-first');
    });

    test('is null when nothing of the product is left', () {
      final hit = PosSearchHit(
        product: buildProduct('Dolo 650'),
        batches: <BatchStatus>[buildBatch(qty: 0)],
      );

      expect(
        hit.dispensable,
        isNull,
        reason: 'an unbillable row is a refusal, not an add',
      );
    });

    test('is null when the product has no batch at all', () {
      final hit = PosSearchHit(
        product: buildProduct('Dolo 650'),
        batches: const <BatchStatus>[],
      );

      expect(hit.dispensable, isNull);
    });

    test('sums what every batch holds', () {
      final hit = PosSearchHit(
        product: buildProduct('Dolo 650'),
        batches: <BatchStatus>[
          buildBatch(id: 'b-1', qty: 3),
          buildBatch(id: 'b-2', qty: 4),
        ],
      );

      expect(hit.stock, 7);
    });
  });

  group('posSearchResults', () {
    test('gives each matched product its own batches', () async {
      final products = FakeProductsRepository(
        products: <Product>[buildProduct('Dolo 650')],
      )..batchesByProduct['id-Dolo 650'] = <BatchStatus>[buildBatch()];

      final hits = await _container(
        products,
      ).read(posSearchResultsProvider('dolo').future);

      expect(hits, hasLength(1));
      expect(hits.single.product.name, 'Dolo 650');
      expect(hits.single.dispensable, isNotNull);
    });

    test('answers a hit per product, with no batch recorded', () async {
      final products = FakeProductsRepository(
        products: <Product>[buildProduct('Dolo 650'), buildProduct('Crocin')],
      );

      final hits = await _container(
        products,
      ).read(posSearchResultsProvider('').future);

      expect(hits, hasLength(2));
      // Neither product has a batch recorded, so neither is dispensable - which the
      // dropdown shows rather than hiding the row.
      expect(hits.every((hit) => hit.dispensable == null), isTrue);
      expect(hits.every((hit) => hit.stock == 0), isTrue);
    });

    test('is empty when nothing matches', () async {
      final hits = await _container(
        FakeProductsRepository(products: const <Product>[]),
      ).read(posSearchResultsProvider('nothing').future);

      expect(hits, isEmpty);
    });
  });
}
