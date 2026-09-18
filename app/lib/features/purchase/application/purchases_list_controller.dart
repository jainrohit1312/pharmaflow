/// Filter state and paginated list state for purchase documents.
library;

import 'package:app/core/utils/debouncer.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'purchases_list_controller.g.dart';

/// What the purchase list is currently filtered by.
///
/// Kept alive: a filter is a browsing context, and losing the supplier you were
/// looking at because you opened one of their invoices and came back would be
/// worse than refetching.
@Riverpod(keepAlive: true)
class PurchasesFilterController extends _$PurchasesFilterController {
  final _searchDebounce = Debouncer();

  @override
  PurchasesQuery build() {
    ref.onDispose(_searchDebounce.dispose);
    return const PurchasesQuery();
  }

  /// Applies a search term once the user stops typing.
  void search(String value) {
    final trimmed = value.trim();
    if (state.search == trimmed) {
      return;
    }
    _searchDebounce.run(() => state = state.withSearch(trimmed));
  }

  /// Restricts the list to one supplier, or clears the restriction.
  void supplier(String? value) {
    if (state.supplierId == value) {
      return;
    }
    _searchDebounce.cancel();
    state = state.withSupplier(value);
  }

  /// Restricts the list to one status, or clears the restriction.
  void status(PurchaseStatus? value) {
    if (state.status == value) {
      return;
    }
    _searchDebounce.cancel();
    state = state.withStatus(value);
  }

  /// Restricts the list to an invoice-date window.
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
    state = const PurchasesQuery();
  }
}

/// One loaded page of purchases, and whether another exists.
class PurchaseListPage {
  /// Creates a page.
  const PurchaseListPage({
    required this.items,
    required this.hasMore,
    this.isLoadingMore = false,
  });

  /// The documents loaded so far, in display order.
  final List<Purchase> items;

  /// Whether the last fetch filled a whole page, implying more rows exist.
  final bool hasMore;

  /// Whether a [PurchasesListController.loadMore] is in flight.
  final bool isLoadingMore;

  /// A copy with individual fields replaced.
  PurchaseListPage copyWith({
    List<Purchase>? items,
    bool? hasMore,
    bool? isLoadingMore,
  }) => PurchaseListPage(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

/// The purchase list for the current filter.
@riverpod
class PurchasesListController extends _$PurchasesListController {
  @override
  Future<PurchaseListPage> build() async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final query = ref.watch(purchasesFilterControllerProvider);
    final items = await ref
        .watch(purchasesRepositoryProvider)
        .list(pharmacyId: pharmacyId, query: query);

    return PurchaseListPage(
      items: items,
      hasMore: items.length == PurchasesRepository.pageSize,
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

    state = AsyncData<PurchaseListPage>(current.copyWith(isLoadingMore: true));
    try {
      final pharmacyId = ref.read(requirePharmacyIdProvider);
      final query = ref.read(purchasesFilterControllerProvider);
      final items = await ref
          .read(purchasesRepositoryProvider)
          .list(
            pharmacyId: pharmacyId,
            query: query,
            offset: current.items.length,
          );

      state = AsyncData<PurchaseListPage>(
        PurchaseListPage(
          items: <Purchase>[...current.items, ...items],
          hasMore: items.length == PurchasesRepository.pageSize,
        ),
      );
    } on Object {
      state = AsyncData<PurchaseListPage>(current);
      rethrow;
    }
  }
}
