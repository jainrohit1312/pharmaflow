/// Tests for the product list controller, driven by a fake repository.
///
/// This is the pattern every catalogue module copies, so it is worth pinning:
/// the filter is what drives the query, a full page implies more rows, and a
/// failed "load more" must not blank the list that is already on screen.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/errors/error_message.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/application/products_list_controller.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_products_repository.dart';

/// A container with the repository and the tenant scope stubbed out.
///
/// The override list is inferred rather than annotated: `Override` is declared
/// in the `riverpod` package, which is a transitive dependency here, so naming
/// it would mean importing a package this app does not depend on directly.
ProviderContainer _container(ProductsRepository repository) {
  final container = ProviderContainer(
    overrides: [
      productsRepositoryProvider.overrideWithValue(repository),
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('loads the first page and asks for offset 0', () async {
    final repository = FakeProductsRepository(
      products: <Product>[
        buildProduct('Dolo 650'),
        buildProduct('Paracetamol'),
      ],
    );
    final container = _container(repository);

    final page = await container.read(productsListControllerProvider.future);

    expect(page.items.map((item) => item.name), <String>[
      'Dolo 650',
      'Paracetamol',
    ]);
    expect(page.hasMore, isFalse, reason: 'a partial page means no more rows');
    expect(repository.requestedOffsets, <int>[0]);
  });

  test('a full page reports that more rows exist', () async {
    final repository = FakeProductsRepository(
      products: <Product>[
        for (var index = 0; index < ProductsRepository.pageSize; index++)
          buildProduct('Item $index'),
      ],
    );
    final container = _container(repository);

    final page = await container.read(productsListControllerProvider.future);

    expect(page.items, hasLength(ProductsRepository.pageSize));
    expect(page.hasMore, isTrue);
  });

  test('changing the schedule filter re-runs the query', () async {
    final repository = FakeProductsRepository(
      products: <Product>[
        buildProduct('Dolo 650'),
        buildProduct('Morphine', scheduleType: ScheduleType.narcotic),
      ],
    );
    final container = _container(repository);
    await container.read(productsListControllerProvider.future);

    container
        .read(productsFilterControllerProvider.notifier)
        .scheduleType(ScheduleType.narcotic);
    final page = await container.read(productsListControllerProvider.future);

    expect(page.items.map((item) => item.name), <String>['Morphine']);
    expect(repository.lastQuery?.scheduleType, ScheduleType.narcotic);
  });

  test('the active filter re-runs the query', () async {
    final repository = FakeProductsRepository(
      products: <Product>[buildProduct('Dolo 650')],
    );
    final container = _container(repository);
    await container.read(productsListControllerProvider.future);

    container
        .read(productsFilterControllerProvider.notifier)
        .activeFilter(value: false);
    final page = await container.read(productsListControllerProvider.future);

    expect(page.items, isEmpty, reason: 'the only product is active');
    expect(repository.lastQuery?.isActive, isFalse);
  });

  test('search waits for typing to stop before it is applied', () async {
    final repository = FakeProductsRepository(
      products: <Product>[buildProduct('Dolo 650')],
    );
    final container = _container(repository);

    container.read(productsFilterControllerProvider.notifier).search('Dolo');
    expect(
      container.read(productsFilterControllerProvider).search,
      isEmpty,
      reason: 'the term is not applied while the user is still typing',
    );

    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(container.read(productsFilterControllerProvider).search, 'Dolo');
  });

  test('clear drops every filter at once', () async {
    final repository = FakeProductsRepository(
      products: <Product>[buildProduct('Dolo 650')],
    );
    final container = _container(repository);

    // Seed both filters in one chain, then clear them.
    container.read(productsFilterControllerProvider.notifier)
      ..scheduleType(ScheduleType.h)
      ..activeFilter(value: false);
    expect(
      container.read(productsFilterControllerProvider).scheduleType,
      ScheduleType.h,
    );
    expect(container.read(productsFilterControllerProvider).isActive, isFalse);

    container.read(productsFilterControllerProvider.notifier).clear();

    final cleared = container.read(productsFilterControllerProvider);
    expect(cleared.scheduleType, isNull);
    expect(cleared.isActive, isNull);
    expect(cleared.search, isEmpty);
  });

  test('loadMore appends the next page', () async {
    final repository = FakeProductsRepository(
      products: <Product>[
        for (var index = 0; index < 75; index++) buildProduct('Item $index'),
      ],
    );
    final container = _container(repository);
    await container.read(productsListControllerProvider.future);

    await container.read(productsListControllerProvider.notifier).loadMore();

    final page = container.read(productsListControllerProvider).value!;
    expect(page.items, hasLength(75));
    expect(page.hasMore, isFalse, reason: 'the second page was partial');
    expect(repository.requestedOffsets, <int>[0, ProductsRepository.pageSize]);
  });

  test('loadMore does nothing once the last page is loaded', () async {
    final repository = FakeProductsRepository(
      products: <Product>[buildProduct('Dolo 650')],
    );
    final container = _container(repository);
    await container.read(productsListControllerProvider.future);

    await container.read(productsListControllerProvider.notifier).loadMore();

    expect(repository.requestedOffsets, <int>[0], reason: 'no second request');
  });

  test('a failed loadMore keeps the rows already on screen', () async {
    final repository = FakeProductsRepository(
      products: <Product>[
        for (var index = 0; index < 75; index++) buildProduct('Item $index'),
      ],
    );
    final container = _container(repository);
    await container.read(productsListControllerProvider.future);
    repository.failNextList = true;

    await expectLater(
      container.read(productsListControllerProvider.notifier).loadMore(),
      throwsA(isA<Object>()),
    );

    final state = container.read(productsListControllerProvider);
    expect(
      state.hasError,
      isFalse,
      reason: 'the list is not replaced by an error',
    );
    expect(state.value!.items, hasLength(ProductsRepository.pageSize));
    expect(state.value!.isLoadingMore, isFalse);
  });

  test(
    'a missing tenant scope fails the list with a readable message',
    () async {
      final container = ProviderContainer(
        overrides: [
          productsRepositoryProvider.overrideWithValue(
            FakeProductsRepository(products: <Product>[]),
          ),
          requirePharmacyIdProvider.overrideWith((ref) {
            throw const AuthException(message: 'Not linked to a pharmacy.');
          }),
        ],
      );
      addTearDown(container.dispose);

      // Observed the way a screen observes it. Awaiting `.future` on a provider
      // whose build throws never completes, so that cannot be used to assert an
      // error; a screen reads `AsyncValue` instead.
      final states = <AsyncValue<ProductListPage>>[];
      container.listen(
        productsListControllerProvider,
        (previous, next) => states.add(next),
        fireImmediately: true,
      );
      await pumpEventQueue();

      expect(states.last.hasError, isTrue);
      expect(describeError(states.last.error!), 'Not linked to a pharmacy.');
    },
  );
}
