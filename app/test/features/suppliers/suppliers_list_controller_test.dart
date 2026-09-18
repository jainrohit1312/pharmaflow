/// Tests for the supplier list controller, driven by a fake repository.
///
/// Mirrors the product list controller test: the filter is what drives the
/// query, a full page implies more rows, and a failed "load more" must not blank
/// the list that is already on screen.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/errors/error_message.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/suppliers/application/suppliers_list_controller.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_suppliers_repository.dart';

/// A container with the repository and the tenant scope stubbed out.
///
/// The override list is inferred rather than annotated: `Override` is declared
/// in the `riverpod` package, which is a transitive dependency here, so naming
/// it would mean importing a package this app does not depend on directly.
ProviderContainer _container(SuppliersRepository repository) {
  final container = ProviderContainer(
    overrides: [
      suppliersRepositoryProvider.overrideWithValue(repository),
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('loads the first page and asks for offset 0', () async {
    final repository = FakeSuppliersRepository(
      suppliers: <Supplier>[
        buildSupplier('Sun Pharma Distributors'),
        buildSupplier('Cipla Agencies'),
      ],
    );
    final container = _container(repository);

    final page = await container.read(suppliersListControllerProvider.future);

    expect(page.items.map((item) => item.name), <String>[
      'Sun Pharma Distributors',
      'Cipla Agencies',
    ]);
    expect(page.hasMore, isFalse, reason: 'a partial page means no more rows');
    expect(repository.requestedOffsets, <int>[0]);
  });

  test('a full page reports that more rows exist', () async {
    final repository = FakeSuppliersRepository(
      suppliers: <Supplier>[
        for (var index = 0; index < SuppliersRepository.pageSize; index++)
          buildSupplier('Supplier $index'),
      ],
    );
    final container = _container(repository);

    final page = await container.read(suppliersListControllerProvider.future);

    expect(page.items, hasLength(SuppliersRepository.pageSize));
    expect(page.hasMore, isTrue);
  });

  test('the active filter re-runs the query', () async {
    final repository = FakeSuppliersRepository(
      suppliers: <Supplier>[buildSupplier('Sun Pharma Distributors')],
    );
    final container = _container(repository);
    await container.read(suppliersListControllerProvider.future);

    container
        .read(suppliersFilterControllerProvider.notifier)
        .activeFilter(value: false);
    final page = await container.read(suppliersListControllerProvider.future);

    expect(page.items, isEmpty, reason: 'the only supplier is active');
    expect(repository.lastQuery?.isActive, isFalse);
  });

  test('search waits for typing to stop before it is applied', () async {
    final repository = FakeSuppliersRepository(
      suppliers: <Supplier>[buildSupplier('Sun Pharma Distributors')],
    );
    final container = _container(repository);

    container.read(suppliersFilterControllerProvider.notifier).search('Cipla');
    expect(
      container.read(suppliersFilterControllerProvider).search,
      isEmpty,
      reason: 'the term is not applied while the user is still typing',
    );

    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(container.read(suppliersFilterControllerProvider).search, 'Cipla');
  });

  test('a search term narrows the rows the list loads', () async {
    final repository = FakeSuppliersRepository(
      suppliers: <Supplier>[
        buildSupplier('Sun Pharma Distributors', phone: '9812345670'),
        buildSupplier('Cipla Agencies'),
      ],
    );
    final container = _container(repository);
    await container.read(suppliersListControllerProvider.future);

    container
        .read(suppliersFilterControllerProvider.notifier)
        .search('9812345670');
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final page = await container.read(suppliersListControllerProvider.future);
    expect(page.items.map((item) => item.name), <String>[
      'Sun Pharma Distributors',
    ]);
    expect(repository.lastQuery?.search, '9812345670');
  });

  test('clear drops every filter at once', () async {
    final repository = FakeSuppliersRepository(
      suppliers: <Supplier>[buildSupplier('Sun Pharma Distributors')],
    );
    final container = _container(repository);

    // Seed both filters in one chain, then clear them.
    container.read(suppliersFilterControllerProvider.notifier)
      ..search('Sun')
      ..activeFilter(value: false);
    expect(container.read(suppliersFilterControllerProvider).isActive, isFalse);
    expect(
      container.read(suppliersFilterControllerProvider).isFiltered,
      isTrue,
    );

    container.read(suppliersFilterControllerProvider.notifier).clear();

    final cleared = container.read(suppliersFilterControllerProvider);
    expect(cleared.search, isEmpty);
    expect(cleared.isActive, isNull);
    expect(cleared.isFiltered, isFalse);
  });

  test('loadMore appends the next page', () async {
    final repository = FakeSuppliersRepository(
      suppliers: <Supplier>[
        for (var index = 0; index < 75; index++)
          buildSupplier('Supplier $index'),
      ],
    );
    final container = _container(repository);
    await container.read(suppliersListControllerProvider.future);

    await container.read(suppliersListControllerProvider.notifier).loadMore();

    final page = container.read(suppliersListControllerProvider).value!;
    expect(page.items, hasLength(75));
    expect(page.hasMore, isFalse, reason: 'the second page was partial');
    expect(repository.requestedOffsets, <int>[0, SuppliersRepository.pageSize]);
  });

  test('loadMore does nothing once the last page is loaded', () async {
    final repository = FakeSuppliersRepository(
      suppliers: <Supplier>[buildSupplier('Sun Pharma Distributors')],
    );
    final container = _container(repository);
    await container.read(suppliersListControllerProvider.future);

    await container.read(suppliersListControllerProvider.notifier).loadMore();

    expect(repository.requestedOffsets, <int>[0], reason: 'no second request');
  });

  test('a failed loadMore keeps the rows already on screen', () async {
    final repository = FakeSuppliersRepository(
      suppliers: <Supplier>[
        for (var index = 0; index < 75; index++)
          buildSupplier('Supplier $index'),
      ],
    );
    final container = _container(repository);
    await container.read(suppliersListControllerProvider.future);
    repository.failNextList = true;

    await expectLater(
      container.read(suppliersListControllerProvider.notifier).loadMore(),
      throwsA(isA<Object>()),
    );

    final state = container.read(suppliersListControllerProvider);
    expect(
      state.hasError,
      isFalse,
      reason: 'the list is not replaced by an error',
    );
    expect(state.value!.items, hasLength(SuppliersRepository.pageSize));
    expect(state.value!.isLoadingMore, isFalse);
  });

  test(
    'a missing tenant scope fails the list with a readable message',
    () async {
      final container = ProviderContainer(
        overrides: [
          suppliersRepositoryProvider.overrideWithValue(
            FakeSuppliersRepository(suppliers: <Supplier>[]),
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
      final states = <AsyncValue<SupplierListPage>>[];
      container.listen(
        suppliersListControllerProvider,
        (previous, next) => states.add(next),
        fireImmediately: true,
      );
      await pumpEventQueue();

      expect(states.last.hasError, isTrue);
      expect(describeError(states.last.error!), 'Not linked to a pharmacy.');
    },
  );
}
