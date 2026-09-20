/// Tests for the counter's list: which batch a hit adds, and where each source
/// gets its products.
library;

import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/sales/application/pos_search.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_inventory_repository.dart';
import '../../../support/fake_products_repository.dart';
import '../../../support/fake_sales_repository.dart';

/// A container with the counter's reads behind it.
///
/// The sales double is optional because only the Recent source reads it.
ProviderContainer _container({
  required FakeProductsRepository products,
  FakeSalesRepository? sales,
}) {
  final container = ProviderContainer(
    // Left untyped on purpose: `Override` is declared in `riverpod`, which
    // `flutter_riverpod` does not re-export (the same note as the sales test app).
    overrides: [
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      productsRepositoryProvider.overrideWithValue(products),
      if (sales != null) salesRepositoryProvider.overrideWithValue(sales),
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

  group('PosListKey', () {
    test('two identical choices are the same list', () {
      expect(const PosListKey(recent: true), const PosListKey(recent: true));
      expect(
        const PosListKey(category: 'Fever'),
        const PosListKey(category: 'Fever'),
      );
      expect(
        const PosListKey(term: 'dolo'),
        isNot(const PosListKey(term: 'croc')),
      );
      expect(
        const PosListKey(recent: true),
        isNot(const PosListKey()),
        reason: 'Recent and All are different lists',
      );
    });
  });

  group('posList', () {
    test('a term searches, and gives each match its own batches', () async {
      final products = FakeProductsRepository(
        products: <Product>[buildProduct('Dolo 650')],
      )..batchesByProduct['id-Dolo 650'] = <BatchStatus>[buildBatch()];

      final hits = await _container(
        products: products,
      ).read(posListProvider(const PosListKey(term: 'dolo')).future);

      expect(hits, hasLength(1));
      expect(hits.single.product.name, 'Dolo 650');
      expect(hits.single.dispensable, isNotNull);
    });

    test('All answers a hit per product, with no batch recorded', () async {
      final products = FakeProductsRepository(
        products: <Product>[buildProduct('Dolo 650'), buildProduct('Crocin')],
      );

      final hits = await _container(
        products: products,
      ).read(posListProvider(const PosListKey()).future);

      expect(hits, hasLength(2));
      // Neither product has a batch recorded, so neither is dispensable - which the
      // list shows rather than hiding the row.
      expect(hits.every((hit) => hit.dispensable == null), isTrue);
      expect(hits.every((hit) => hit.stock == 0), isTrue);
    });

    test(
      'Recent reads the sold ids and puts the rows back in that order',
      () async {
        // The read answers ids in sold order, and `list` answers rows in catalogue
        // order: the order is the strip's whole point, so the two must not be
        // confused.
        final products = FakeProductsRepository(
          products: <Product>[buildProduct('Crocin'), buildProduct('Dolo 650')],
        );
        final sales = FakeSalesRepository()
          ..recentProductIds = <String>['id-Dolo 650', 'id-Crocin'];

        final hits = await _container(
          products: products,
          sales: sales,
        ).read(posListProvider(const PosListKey(recent: true)).future);

        expect(hits.map((hit) => hit.product.name), <String>[
          'Dolo 650',
          'Crocin',
        ]);
      },
    );

    test('Recent is empty when nothing has been sold', () async {
      final hits = await _container(
        products: FakeProductsRepository(products: const <Product>[]),
        sales: FakeSalesRepository(),
      ).read(posListProvider(const PosListKey(recent: true)).future);

      expect(hits, isEmpty);
    });

    test('a category lists only that category', () async {
      final products = FakeProductsRepository(
        products: <Product>[
          buildProduct('Dolo 650', category: 'Fever'),
          buildProduct('Crocin'),
        ],
      );

      final hits = await _container(
        products: products,
      ).read(posListProvider(const PosListKey(category: 'Fever')).future);

      expect(hits.map((hit) => hit.product.name), <String>['Dolo 650']);
    });

    test('a term wins over the strip', () async {
      final products = FakeProductsRepository(
        products: <Product>[
          buildProduct('Dolo 650', category: 'Fever'),
          buildProduct('Crocin', category: 'Fever'),
        ],
      );

      // A key that names both: the counter typed while a category tab was chosen.
      final hits = await _container(products: products).read(
        posListProvider(
          const PosListKey(term: 'crocin', category: 'Fever'),
        ).future,
      );

      expect(hits.map((hit) => hit.product.name), <String>['Crocin']);
    });

    test('is empty when nothing matches', () async {
      final hits = await _container(
        products: FakeProductsRepository(products: const <Product>[]),
      ).read(posListProvider(const PosListKey(term: 'nothing')).future);

      expect(hits, isEmpty);
    });
  });
}
