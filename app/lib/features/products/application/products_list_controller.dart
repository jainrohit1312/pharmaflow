/// Filter state and paginated list state for the product catalogue.
///
/// The two providers are deliberately separate: the filter is plain synchronous
/// state that a filter bar mutates, and the list is an async resource that
/// rebuilds whenever the filter changes. Nothing has to remember to refresh.
library;

import 'package:app/core/utils/debouncer.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'products_list_controller.g.dart';

/// What the product list is currently filtered by.
///
/// Kept alive deliberately. Riverpod 3 disposes providers with no listeners by
/// default, and the filter would then be thrown away every time the user opens
/// a product and comes back - losing the search they just typed. The list
/// itself is NOT kept alive, so returning to it re-reads stock, which is the
/// half that should be fresh.
@Riverpod(keepAlive: true)
class ProductsFilterController extends _$ProductsFilterController {
  final _searchDebounce = Debouncer();

  @override
  ProductsQuery build() {
    ref.onDispose(_searchDebounce.dispose);
    return const ProductsQuery();
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

  /// Restricts the list to one drug schedule, or clears the restriction.
  void scheduleType(ScheduleType? value) {
    if (state.scheduleType == value) {
      return;
    }
    _searchDebounce.cancel();
    state = state.withSchedule(value);
  }

  /// Restricts the list to active or inactive products, or clears it.
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
    final isAlreadyClear =
        state.search.isEmpty &&
        state.scheduleType == null &&
        state.isActive == null;
    if (isAlreadyClear) {
      return;
    }
    state = const ProductsQuery();
  }
}

/// One loaded page of products, and whether another page exists.
class ProductListPage {
  /// Creates a page.
  const ProductListPage({
    required this.items,
    required this.hasMore,
    this.isLoadingMore = false,
  });

  /// The products loaded so far, in display order.
  final List<Product> items;

  /// Whether the last fetch filled a whole page, implying more rows exist.
  final bool hasMore;

  /// Whether a [ProductsListController.loadMore] is in flight.
  final bool isLoadingMore;

  /// A copy with individual fields replaced.
  ProductListPage copyWith({
    List<Product>? items,
    bool? hasMore,
    bool? isLoadingMore,
  }) => ProductListPage(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

/// The product list for the current filter.
@riverpod
class ProductsListController extends _$ProductsListController {
  @override
  Future<ProductListPage> build() async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final query = ref.watch(productsFilterControllerProvider);
    final items = await ref
        .watch(productsRepositoryProvider)
        .list(pharmacyId: pharmacyId, query: query);

    return ProductListPage(
      items: items,
      hasMore: items.length == ProductsRepository.pageSize,
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

    state = AsyncData<ProductListPage>(current.copyWith(isLoadingMore: true));
    try {
      final pharmacyId = ref.read(requirePharmacyIdProvider);
      final query = ref.read(productsFilterControllerProvider);
      final items = await ref
          .read(productsRepositoryProvider)
          .list(
            pharmacyId: pharmacyId,
            query: query,
            offset: current.items.length,
          );

      state = AsyncData<ProductListPage>(
        ProductListPage(
          items: <Product>[...current.items, ...items],
          hasMore: items.length == ProductsRepository.pageSize,
        ),
      );
    } on Object {
      state = AsyncData<ProductListPage>(current);
      rethrow;
    }
  }
}
