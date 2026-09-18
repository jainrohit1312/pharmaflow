/// Filter state and the paginated sale list.
library;

import 'package:app/core/utils/debouncer.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sales_list_controller.g.dart';

/// What the sale list is currently filtered by.
///
/// Kept alive: a filter is a browsing context, and a cashier who filtered to
/// unpaid bills should still be looking at them after opening one and coming
/// back. Same reasoning as `PurchasesFilterController`.
@Riverpod(keepAlive: true)
class SalesFilterController extends _$SalesFilterController {
  final _searchDebounce = Debouncer();

  @override
  SalesQuery build() {
    ref.onDispose(_searchDebounce.dispose);
    return const SalesQuery();
  }

  /// Applies a search term once the user stops typing.
  void search(String value) {
    final trimmed = value.trim();
    if (state.search == trimmed) {
      return;
    }
    _searchDebounce.run(() => state = state.withSearch(trimmed));
  }

  /// Restricts the list to one status, or clears the restriction.
  void status(SaleStatus? value) {
    if (state.status == value) {
      return;
    }
    _searchDebounce.cancel();
    state = state.withStatus(value);
  }

  /// Restricts the list to a sale-date window.
  void dateRange({DateTime? from, DateTime? to}) {
    if (state.from == from && state.to == to) {
      return;
    }
    _searchDebounce.cancel();
    state = state.withDateRange(from: from, to: to);
  }

  /// Drops every filter, cancelling a search that has not been applied yet.
  void clear() {
    _searchDebounce.cancel();
    if (!state.isFiltered) {
      return;
    }
    state = const SalesQuery();
  }
}

/// One loaded page of sales, and whether another exists.
class SaleListPage {
  /// Creates a page.
  const SaleListPage({
    required this.items,
    required this.hasMore,
    this.isLoadingMore = false,
  });

  /// The sales loaded so far, in display order.
  final List<Sale> items;

  /// Whether the last fetch filled a whole page, implying more rows exist.
  final bool hasMore;

  /// Whether a [SalesListController.loadMore] is in flight.
  final bool isLoadingMore;

  /// A copy with individual fields replaced.
  SaleListPage copyWith({
    List<Sale>? items,
    bool? hasMore,
    bool? isLoadingMore,
  }) => SaleListPage(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

/// The sale list for the current filter.
@riverpod
class SalesListController extends _$SalesListController {
  @override
  Future<SaleListPage> build() async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final query = ref.watch(salesFilterControllerProvider);
    final items = await ref
        .watch(salesRepositoryProvider)
        .list(pharmacyId: pharmacyId, query: query);

    return SaleListPage(
      items: items,
      hasMore: items.length == SalesRepository.pageSize,
    );
  }

  /// Appends the next page.
  ///
  /// On failure the page already on screen is restored and the error is
  /// rethrown for the caller to report: publishing an `AsyncError` here would
  /// blank the list, and Riverpod 3 marks `copyWithPrevious` - the API that
  /// would keep the previous data attached - as internal.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.isLoadingMore) {
      return;
    }

    state = AsyncData<SaleListPage>(current.copyWith(isLoadingMore: true));
    try {
      final pharmacyId = ref.read(requirePharmacyIdProvider);
      final query = ref.read(salesFilterControllerProvider);
      final items = await ref
          .read(salesRepositoryProvider)
          .list(
            pharmacyId: pharmacyId,
            query: query,
            offset: current.items.length,
          );

      state = AsyncData<SaleListPage>(
        SaleListPage(
          items: <Sale>[...current.items, ...items],
          hasMore: items.length == SalesRepository.pageSize,
        ),
      );
    } on Object {
      state = AsyncData<SaleListPage>(current);
      rethrow;
    }
  }
}
