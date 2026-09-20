/// Tests for the catalogue's own categories, which the counter's strip is built
/// from.
library;

import 'package:app/data/models/product.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/application/product_categories.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_products_repository.dart';

void main() {
  test(
    'answers the categories the catalogue records, in the read\u2019s order',
    () async {
      final products = FakeProductsRepository(products: const <Product>[])
        ..categoriesAnswer = <String>['Antibiotics', 'Fever'];
      final container = ProviderContainer(
        overrides: [
          requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
          productsRepositoryProvider.overrideWithValue(products),
        ],
      );
      addTearDown(container.dispose);

      expect(await container.read(productCategoriesProvider.future), <String>[
        'Antibiotics',
        'Fever',
      ]);
    },
  );

  test(
    'is empty for the imported catalogue, whose products carry no category',
    () async {
      final container = ProviderContainer(
        overrides: [
          requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
          productsRepositoryProvider.overrideWithValue(
            FakeProductsRepository(products: const <Product>[]),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(await container.read(productCategoriesProvider.future), isEmpty);
    },
  );
}
