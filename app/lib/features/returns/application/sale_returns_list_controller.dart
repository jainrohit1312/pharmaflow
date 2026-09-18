/// The paginated sale-return list.
library;

import 'package:app/data/models/sale_return.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/returns/data/sale_returns_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sale_returns_list_controller.g.dart';

/// One loaded page of sale returns, and whether another exists.
class SaleReturnListPage {
  /// Creates a page.
  const SaleReturnListPage({
    required this.items,
    required this.hasMore,
    this.isLoadingMore = false,
  });

  /// The returns loaded so far, in display order.
  final List<SaleReturn> items;

  /// Whether the last fetch filled a whole page, implying more rows exist.
  final bool hasMore;

  /// Whether a [SaleReturnsListController.loadMore] is in flight.
  final bool isLoadingMore;

  /// A copy with individual fields replaced.
  SaleReturnListPage copyWith({
    List<SaleReturn>? items,
    bool? hasMore,
    bool? isLoadingMore,
  }) => SaleReturnListPage(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

/// Customer returns, newest first.
@riverpod
class SaleReturnsListController extends _$SaleReturnsListController {
  @override
  Future<SaleReturnListPage> build() async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final items = await ref
        .watch(saleReturnsRepositoryProvider)
        .list(pharmacyId: pharmacyId);

    return SaleReturnListPage(
      items: items,
      hasMore: items.length == SaleReturnsRepository.pageSize,
    );
  }

  /// Appends the next page.
  ///
  /// On failure the page already on screen is restored and the error is
  /// rethrown for the caller to report: publishing an `AsyncError` here would
  /// blank the list, and Riverpod 3 marks `copyWithPrevious` as internal.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.isLoadingMore) {
      return;
    }

    state = AsyncData<SaleReturnListPage>(
      current.copyWith(isLoadingMore: true),
    );
    try {
      final pharmacyId = ref.read(requirePharmacyIdProvider);
      final items = await ref
          .read(saleReturnsRepositoryProvider)
          .list(pharmacyId: pharmacyId, offset: current.items.length);

      state = AsyncData<SaleReturnListPage>(
        SaleReturnListPage(
          items: <SaleReturn>[...current.items, ...items],
          hasMore: items.length == SaleReturnsRepository.pageSize,
        ),
      );
    } on Object {
      state = AsyncData<SaleReturnListPage>(current);
      rethrow;
    }
  }
}
