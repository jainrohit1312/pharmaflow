/// The paginated purchase return list.
library;

import 'package:app/data/models/purchase_return.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/returns/data/purchase_returns_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'purchase_returns_list_controller.g.dart';

/// One loaded page of purchase returns, and whether another exists.
class PurchaseReturnListPage {
  /// Creates a page.
  const PurchaseReturnListPage({
    required this.items,
    required this.hasMore,
    this.isLoadingMore = false,
  });

  /// The returns loaded so far, in display order.
  final List<PurchaseReturn> items;

  /// Whether the last fetch filled a whole page, implying more rows exist.
  final bool hasMore;

  /// Whether a [PurchaseReturnsListController.loadMore] is in flight.
  final bool isLoadingMore;

  /// A copy with individual fields replaced.
  PurchaseReturnListPage copyWith({
    List<PurchaseReturn>? items,
    bool? hasMore,
    bool? isLoadingMore,
  }) => PurchaseReturnListPage(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

/// Purchase returns, newest return date first.
///
/// No filter state, unlike the purchase list: a return is looked up by its
/// invoice or its date, and both are on the card. Searching arrives with the
/// reports that need it rather than here.
@riverpod
class PurchaseReturnsListController extends _$PurchaseReturnsListController {
  @override
  Future<PurchaseReturnListPage> build() async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final items = await ref
        .watch(purchaseReturnsRepositoryProvider)
        .list(pharmacyId: pharmacyId);

    return PurchaseReturnListPage(
      items: items,
      hasMore: items.length == PurchaseReturnsRepository.pageSize,
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

    state = AsyncData<PurchaseReturnListPage>(
      current.copyWith(isLoadingMore: true),
    );
    try {
      final pharmacyId = ref.read(requirePharmacyIdProvider);
      final items = await ref
          .read(purchaseReturnsRepositoryProvider)
          .list(pharmacyId: pharmacyId, offset: current.items.length);

      state = AsyncData<PurchaseReturnListPage>(
        PurchaseReturnListPage(
          items: <PurchaseReturn>[...current.items, ...items],
          hasMore: items.length == PurchaseReturnsRepository.pageSize,
        ),
      );
    } on Object {
      state = AsyncData<PurchaseReturnListPage>(current);
      rethrow;
    }
  }
}
