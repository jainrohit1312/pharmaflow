/// Filter state and paginated list state for the supplier master.
///
/// The two providers are deliberately separate: the filter is plain synchronous
/// state that a filter bar mutates, and the list is an async resource that
/// rebuilds whenever the filter changes. Nothing has to remember to refresh.
library;

import 'package:app/core/utils/debouncer.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'suppliers_list_controller.g.dart';

/// What the supplier list is currently filtered by.
///
/// Kept alive deliberately. Riverpod 3 disposes providers with no listeners by
/// default, and the filter would then be thrown away every time the user opens
/// a supplier and comes back - losing the search they just typed. The list
/// itself is NOT kept alive, so returning to it re-reads the rows, which is the
/// half that should be fresh.
@Riverpod(keepAlive: true)
class SuppliersFilterController extends _$SuppliersFilterController {
  final _searchDebounce = Debouncer();

  @override
  SuppliersQuery build() {
    ref.onDispose(_searchDebounce.dispose);
    return const SuppliersQuery();
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

  /// Restricts the list to active or inactive suppliers, or clears it.
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
    state = const SuppliersQuery();
  }
}

/// One loaded page of suppliers, and whether another page exists.
class SupplierListPage {
  /// Creates a page.
  const SupplierListPage({
    required this.items,
    required this.hasMore,
    this.isLoadingMore = false,
  });

  /// The suppliers loaded so far, in display order.
  final List<Supplier> items;

  /// Whether the last fetch filled a whole page, implying more rows exist.
  final bool hasMore;

  /// Whether a [SuppliersListController.loadMore] is in flight.
  final bool isLoadingMore;

  /// A copy with individual fields replaced.
  SupplierListPage copyWith({
    List<Supplier>? items,
    bool? hasMore,
    bool? isLoadingMore,
  }) => SupplierListPage(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

/// The supplier list for the current filter.
@riverpod
class SuppliersListController extends _$SuppliersListController {
  @override
  Future<SupplierListPage> build() async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final query = ref.watch(suppliersFilterControllerProvider);
    final items = await ref
        .watch(suppliersRepositoryProvider)
        .list(pharmacyId: pharmacyId, query: query);

    return SupplierListPage(
      items: items,
      hasMore: items.length == SuppliersRepository.pageSize,
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

    state = AsyncData<SupplierListPage>(current.copyWith(isLoadingMore: true));
    try {
      final pharmacyId = ref.read(requirePharmacyIdProvider);
      final query = ref.read(suppliersFilterControllerProvider);
      final items = await ref
          .read(suppliersRepositoryProvider)
          .list(
            pharmacyId: pharmacyId,
            query: query,
            offset: current.items.length,
          );

      state = AsyncData<SupplierListPage>(
        SupplierListPage(
          items: <Supplier>[...current.items, ...items],
          hasMore: items.length == SuppliersRepository.pageSize,
        ),
      );
    } on Object {
      state = AsyncData<SupplierListPage>(current);
      rethrow;
    }
  }
}
