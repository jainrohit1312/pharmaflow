/// Search and availability filter state, plus the paged stock list.
library;

import 'package:app/core/utils/debouncer.dart';
import 'package:app/data/models/product_stock.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/inventory/data/inventory_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'stock_list_controller.g.dart';

/// What the stock list is currently filtered by.
///
/// Kept alive: a filter is a browsing context, and the search box emptying
/// itself because the user opened a product and came back would be worse than
/// refetching. Same reasoning as `ProductsFilterController`.
@Riverpod(keepAlive: true)
class StockFilterController extends _$StockFilterController {
  final _searchDebounce = Debouncer();

  @override
  StockQuery build() {
    ref.onDispose(_searchDebounce.dispose);
    return const StockQuery();
  }

  /// Applies a search term once the user stops typing.
  void search(String value) {
    final trimmed = value.trim();
    if (state.search == trimmed) {
      return;
    }
    _searchDebounce.run(() => state = state.withSearch(trimmed));
  }

  /// Restricts the list to one side of zero stock.
  void availability(StockAvailability value) {
    if (state.availability == value) {
      return;
    }
    _searchDebounce.cancel();
    state = state.withAvailability(value);
  }

  /// Drops every filter, cancelling a search that has not been applied yet.
  void clear() {
    _searchDebounce.cancel();
    if (!state.isFiltered) {
      return;
    }
    state = const StockQuery();
  }
}

/// One loaded page of the stock rollup, and whether another exists.
class StockListPage {
  /// Creates a page.
  const StockListPage({
    required this.items,
    required this.hasMore,
    this.isLoadingMore = false,
  });

  /// The rows loaded so far, in display order.
  final List<ProductStock> items;

  /// Whether the last fetch filled a whole page, implying more rows exist.
  final bool hasMore;

  /// Whether a [StockListController.loadMore] is in flight.
  final bool isLoadingMore;

  /// A copy with individual fields replaced.
  StockListPage copyWith({
    List<ProductStock>? items,
    bool? hasMore,
    bool? isLoadingMore,
  }) => StockListPage(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

/// The stock rollup for the current filter.
@riverpod
class StockListController extends _$StockListController {
  @override
  Future<StockListPage> build() async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final query = ref.watch(stockFilterControllerProvider);
    final items = await ref
        .watch(inventoryRepositoryProvider)
        .stockList(pharmacyId: pharmacyId, query: query);

    return StockListPage(
      items: items,
      hasMore: items.length == InventoryRepository.pageSize,
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

    state = AsyncData<StockListPage>(current.copyWith(isLoadingMore: true));
    try {
      final pharmacyId = ref.read(requirePharmacyIdProvider);
      final query = ref.read(stockFilterControllerProvider);
      final items = await ref
          .read(inventoryRepositoryProvider)
          .stockList(
            pharmacyId: pharmacyId,
            query: query,
            offset: current.items.length,
          );

      state = AsyncData<StockListPage>(
        StockListPage(
          items: <ProductStock>[...current.items, ...items],
          hasMore: items.length == InventoryRepository.pageSize,
        ),
      );
    } on Object {
      state = AsyncData<StockListPage>(current);
      rethrow;
    }
  }
}
