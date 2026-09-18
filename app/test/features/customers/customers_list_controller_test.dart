/// Tests for the customer list controller, driven by a fake repository.
///
/// Mirrors the product list controller test, because the two controllers are
/// deliberately the same shape: the filter is what drives the query, a full page
/// implies more rows, and a failed "load more" must not blank the list that is
/// already on screen.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/errors/error_message.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/customers/application/customers_list_controller.dart';
import 'package:app/features/customers/data/customers_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_customers_repository.dart';

/// A container with the repository and the tenant scope stubbed out.
///
/// The override list is inferred rather than annotated: `Override` is declared
/// in the `riverpod` package, which is a transitive dependency here, so naming
/// it would mean importing a package this app does not depend on directly.
ProviderContainer _container(CustomersRepository repository) {
  final container = ProviderContainer(
    overrides: [
      customersRepositoryProvider.overrideWithValue(repository),
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('loads the first page and asks for offset 0', () async {
    final repository = FakeCustomersRepository(
      customers: <Customer>[
        buildCustomer('Ramesh Kumar'),
        buildCustomer('Sunita Devi'),
      ],
    );
    final container = _container(repository);

    final page = await container.read(customersListControllerProvider.future);

    expect(page.items.map((item) => item.name), <String>[
      'Ramesh Kumar',
      'Sunita Devi',
    ]);
    expect(page.hasMore, isFalse, reason: 'a partial page means no more rows');
    expect(repository.requestedOffsets, <int>[0]);
  });

  test('a full page reports that more rows exist', () async {
    final repository = FakeCustomersRepository(
      customers: <Customer>[
        for (var index = 0; index < CustomersRepository.pageSize; index++)
          buildCustomer('Customer $index'),
      ],
    );
    final container = _container(repository);

    final page = await container.read(customersListControllerProvider.future);

    expect(page.items, hasLength(CustomersRepository.pageSize));
    expect(page.hasMore, isTrue);
  });

  test('the active filter re-runs the query', () async {
    final repository = FakeCustomersRepository(
      customers: <Customer>[
        buildCustomer('Ramesh Kumar'),
        buildCustomer('Retired account', isActive: false),
      ],
    );
    final container = _container(repository);
    await container.read(customersListControllerProvider.future);

    container
        .read(customersFilterControllerProvider.notifier)
        .activeFilter(value: false);
    final page = await container.read(customersListControllerProvider.future);

    expect(page.items.map((item) => item.name), <String>['Retired account']);
    expect(repository.lastQuery?.isActive, isFalse);
  });

  test('search reaches phone numbers and GSTINs, not just names', () async {
    final repository = FakeCustomersRepository(
      customers: <Customer>[
        buildCustomer('Ramesh Kumar', phone: '9876543210'),
        buildCustomer('Sunita Devi', gstin: '27AAPFU0939F1ZV'),
      ],
    );
    final container = _container(repository);

    container.read(customersFilterControllerProvider.notifier).search('987654');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    var page = await container.read(customersListControllerProvider.future);

    expect(page.items.map((item) => item.name), <String>['Ramesh Kumar']);

    container.read(customersFilterControllerProvider.notifier).search('AAPFU');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    page = await container.read(customersListControllerProvider.future);

    expect(page.items.map((item) => item.name), <String>['Sunita Devi']);
  });

  test('search waits for typing to stop before it is applied', () async {
    final repository = FakeCustomersRepository(
      customers: <Customer>[buildCustomer('Ramesh Kumar')],
    );
    final container = _container(repository);

    container.read(customersFilterControllerProvider.notifier).search('Ramesh');
    expect(
      container.read(customersFilterControllerProvider).search,
      isEmpty,
      reason: 'the term is not applied while the user is still typing',
    );

    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(container.read(customersFilterControllerProvider).search, 'Ramesh');
  });

  test('clear drops every filter at once', () async {
    final repository = FakeCustomersRepository(
      customers: <Customer>[buildCustomer('Ramesh Kumar')],
    );
    final container = _container(repository);

    // Seed both filters, then clear them.
    container
        .read(customersFilterControllerProvider.notifier)
        .activeFilter(value: false);
    container.read(customersFilterControllerProvider.notifier).search('Ram');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(container.read(customersFilterControllerProvider).isActive, isFalse);

    container.read(customersFilterControllerProvider.notifier).clear();

    final cleared = container.read(customersFilterControllerProvider);
    expect(cleared.search, isEmpty);
    expect(cleared.isActive, isNull);
  });

  test('loadMore appends the next page', () async {
    final repository = FakeCustomersRepository(
      customers: <Customer>[
        for (var index = 0; index < 75; index++)
          buildCustomer('Customer $index'),
      ],
    );
    final container = _container(repository);
    await container.read(customersListControllerProvider.future);

    await container.read(customersListControllerProvider.notifier).loadMore();

    final page = container.read(customersListControllerProvider).value!;
    expect(page.items, hasLength(75));
    expect(page.hasMore, isFalse, reason: 'the second page was partial');
    expect(repository.requestedOffsets, <int>[0, CustomersRepository.pageSize]);
  });

  test('loadMore does nothing once the last page is loaded', () async {
    final repository = FakeCustomersRepository(
      customers: <Customer>[buildCustomer('Ramesh Kumar')],
    );
    final container = _container(repository);
    await container.read(customersListControllerProvider.future);

    await container.read(customersListControllerProvider.notifier).loadMore();

    expect(repository.requestedOffsets, <int>[0], reason: 'no second request');
  });

  test('a failed loadMore keeps the rows already on screen', () async {
    final repository = FakeCustomersRepository(
      customers: <Customer>[
        for (var index = 0; index < 75; index++)
          buildCustomer('Customer $index'),
      ],
    );
    final container = _container(repository);
    await container.read(customersListControllerProvider.future);
    repository.failNextList = true;

    await expectLater(
      container.read(customersListControllerProvider.notifier).loadMore(),
      throwsA(isA<Object>()),
    );

    final state = container.read(customersListControllerProvider);
    expect(
      state.hasError,
      isFalse,
      reason: 'the list is not replaced by an error',
    );
    expect(state.value!.items, hasLength(CustomersRepository.pageSize));
    expect(state.value!.isLoadingMore, isFalse);
  });

  test(
    'a missing tenant scope fails the list with a readable message',
    () async {
      final container = ProviderContainer(
        overrides: [
          customersRepositoryProvider.overrideWithValue(
            FakeCustomersRepository(customers: <Customer>[]),
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
      final states = <AsyncValue<CustomerListPage>>[];
      container.listen(
        customersListControllerProvider,
        (previous, next) => states.add(next),
        fireImmediately: true,
      );
      await pumpEventQueue();

      expect(states.last.hasError, isTrue);
      expect(describeError(states.last.error!), 'Not linked to a pharmacy.');
    },
  );
}
