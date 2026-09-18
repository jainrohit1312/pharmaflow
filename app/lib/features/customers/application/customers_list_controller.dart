/// Filter state and paginated list state for the customer master.
///
/// The two providers are deliberately separate: the filter is plain synchronous
/// state that a filter bar mutates, and the list is an async resource that
/// rebuilds whenever the filter changes. Nothing has to remember to refresh.
library;

import 'package:app/core/utils/debouncer.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/customers/data/customers_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'customers_list_controller.g.dart';

/// What the customer list is currently filtered by.
///
/// Kept alive deliberately. Riverpod 3 disposes providers with no listeners by
/// default, and the filter would then be thrown away every time the user opens
/// a customer and comes back - losing the search they just typed. On this screen
/// that is the common path rather than the exception, because a counter looks a
/// person up by phone and then opens them. The list itself is NOT kept alive, so
/// returning to it re-reads the master.
@Riverpod(keepAlive: true)
class CustomersFilterController extends _$CustomersFilterController {
  final _searchDebounce = Debouncer();

  @override
  CustomersQuery build() {
    ref.onDispose(_searchDebounce.dispose);
    return const CustomersQuery();
  }

  /// Applies a search term once the user stops typing.
  ///
  /// Debounced because every applied term re-runs the query; without it the
  /// list would issue one request per keystroke.
  void search(String value) {
    final trimmed = value.trim();
    if (state.search == trimmed) {
      return;
    }
    _searchDebounce.run(() => state = state.withSearch(trimmed));
  }

  /// Restricts the list to active or inactive customers, or clears it.
  ///
  /// [value] is a named parameter because it is a tri-state: `true`, `false` or
  /// `null` for "both", and a bare `activeFilter(true)` at a call site says
  /// nothing about which of those it means.
  void activeFilter({required bool? value}) {
    if (state.isActive == value) {
      return;
    }
    _searchDebounce.cancel();
    state = state.withActive(value: value);
  }

  /// Drops every filter, cancelling a search that has not been applied yet.
  void clear() {
    _searchDebounce.cancel();
    final isAlreadyClear = state.search.isEmpty && state.isActive == null;
    if (isAlreadyClear) {
      return;
    }
    state = const CustomersQuery();
  }
}

/// One loaded page of customers, and whether another page exists.
class CustomerListPage {
  /// Creates a page.
  const CustomerListPage({
    required this.items,
    required this.hasMore,
    this.isLoadingMore = false,
  });

  /// The customers loaded so far, in display order.
  final List<Customer> items;

  /// Whether the last fetch filled a whole page, implying more rows exist.
  final bool hasMore;

  /// Whether a [CustomersListController.loadMore] is in flight.
  final bool isLoadingMore;

  /// A copy with individual fields replaced.
  CustomerListPage copyWith({
    List<Customer>? items,
    bool? hasMore,
    bool? isLoadingMore,
  }) => CustomerListPage(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

/// The customer list for the current filter.
@riverpod
class CustomersListController extends _$CustomersListController {
  @override
  Future<CustomerListPage> build() async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final query = ref.watch(customersFilterControllerProvider);
    final items = await ref
        .watch(customersRepositoryProvider)
        .list(pharmacyId: pharmacyId, query: query);

    return CustomerListPage(
      items: items,
      hasMore: items.length == CustomersRepository.pageSize,
    );
  }

  /// Appends the next page.
  ///
  /// Grows the loaded list in place instead of restarting `build`. If the fetch
  /// fails the page already on screen is restored and the error is rethrown for
  /// the caller to report: publishing an `AsyncError` here would blank the list,
  /// and Riverpod 3 marks `copyWithPrevious` - the API that would keep the
  /// previous data attached to the error - as internal.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.isLoadingMore) {
      return;
    }

    state = AsyncData<CustomerListPage>(current.copyWith(isLoadingMore: true));
    try {
      final pharmacyId = ref.read(requirePharmacyIdProvider);
      final query = ref.read(customersFilterControllerProvider);
      final items = await ref
          .read(customersRepositoryProvider)
          .list(
            pharmacyId: pharmacyId,
            query: query,
            offset: current.items.length,
          );

      state = AsyncData<CustomerListPage>(
        CustomerListPage(
          items: <Customer>[...current.items, ...items],
          hasMore: items.length == CustomersRepository.pageSize,
        ),
      );
    } on Object {
      state = AsyncData<CustomerListPage>(current);
      rethrow;
    }
  }
}
