/// Search and paging for the purchase pickers (I-3).
library;

import 'package:app/data/models/purchase.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'purchase_picker_controller.g.dart';

/// How many purchases a picker offers at once.
///
/// A picker answers "which invoice are these goods from", so it wants a short
/// list to choose from rather than a browsable ledger - the same reasoning as
/// `productSearchLimit`, and a fifth of what the list screen pages by. What does
/// not fit is a keystroke away, or one "Load more".
const int purchasePickerPageSize = 20;

/// How many suppliers one term is resolved against.
///
/// The supplier branch of a search is an `in.(…)` list inside the filter, so it
/// cannot be unbounded: a term as loose as "a" would otherwise build a filter
/// longer than the request carrying it. A couple of dozen is well past the number
/// of distributors whose name contains anything useful somebody types — and a
/// term that matches more than this is a term that does not identify one yet, at
/// which point the invoice-number branch still answers.
const int purchasePickerSupplierMatchLimit = 25;

/// What the purchase picker is currently searching for.
///
/// Scoped to the picker on purpose. The list screen has its own filter state
/// (`PurchasesFilterController`) and that one is `keepAlive`, because a filter
/// there is a browsing context; a picker inside a return form must not inherit
/// it, disturb it, or outlive the dialog it was typed in. Auto-disposed, so
/// closing the dialog forgets the term.
///
/// [search] applies what it is given rather than debouncing, because the field
/// that calls it owns that delay - the same division `AppSearchField` describes.
/// (The list screen's controller debounces instead, because its search box is a
/// bare `TextField` that reports every keystroke.)
@riverpod
class PurchasePickerFilterController extends _$PurchasePickerFilterController {
  @override
  PurchasesQuery build() {
    // Received only: a draft has no batches and nothing has moved, so
    // `stock_update_on_purchase_return()` would have nothing to receive against
    // and the form could only end in a refusal.
    return const PurchasesQuery(status: PurchaseStatus.received);
  }

  /// Applies a search term.
  void search(String value) {
    final trimmed = value.trim();
    if (state.search == trimmed) {
      return;
    }
    state = state.withSearch(trimmed);
  }

  /// Restricts to an invoice-date window, or clears it.
  void dateRange({DateTime? from, DateTime? to}) {
    if (state.from == from && state.to == to) {
      return;
    }
    state = state.withDateRange(from: from, to: to);
  }
}

/// One page of picker results, and whether another one exists.
class PurchasePickerPage {
  /// Creates a page.
  const PurchasePickerPage({
    required this.items,
    required this.hasMore,
    this.isLoadingMore = false,
  });

  /// The documents loaded so far, in display order.
  final List<Purchase> items;

  /// Whether the last fetch filled a whole page, implying more rows exist.
  final bool hasMore;

  /// Whether a [PurchasePickerController.loadMore] is in flight.
  final bool isLoadingMore;

  /// A copy with individual fields replaced.
  PurchasePickerPage copyWith({
    List<Purchase>? items,
    bool? hasMore,
    bool? isLoadingMore,
  }) => PurchasePickerPage(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

/// The purchases the picker is offering, one page at a time.
///
/// The search covers three things at once, which is what makes it usable past a
/// couple of hundred invoices: the invoice number, the notes somebody wrote on
/// the document, and **the distributor's name** - resolved by asking the
/// suppliers table which ids match the term, then ORing them into the same query
/// (`PurchasesQuery.supplierIds`). A search that could only see the invoice
/// number would be a search that cannot find the invoice whose number nobody
/// remembers.
@riverpod
class PurchasePickerController extends _$PurchasePickerController {
  /// The query this page set was fetched with, supplier branch resolved.
  ///
  /// Kept so [loadMore] pages through the *same* result set rather than resolving
  /// the supplier branch a second time: a different resolution between two pages
  /// of one list would duplicate or skip rows.
  PurchasesQuery? _resolved;

  @override
  Future<PurchasePickerPage> build() async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final purchases = ref.watch(purchasesRepositoryProvider);
    final suppliers = ref.watch(suppliersRepositoryProvider);
    final query = ref.watch(purchasePickerFilterControllerProvider);

    final resolved = await _withSupplierMatches(
      pharmacyId: pharmacyId,
      suppliers: suppliers,
      query: query,
    );
    _resolved = resolved;
    return _page(purchases: purchases, pharmacyId: pharmacyId, query: resolved);
  }

  /// Appends the next page.
  ///
  /// On failure the rows already on screen are restored and the error is
  /// rethrown for the caller to report: publishing an `AsyncError` here would
  /// blank a list the user is reading, and Riverpod 3 marks `copyWithPrevious` -
  /// the API that would keep the previous data attached - as internal. The same
  /// trade as `PurchasesListController.loadMore`, for the same reason.
  Future<void> loadMore() async {
    final current = state.value;
    final resolved = _resolved;
    if (current == null ||
        resolved == null ||
        !current.hasMore ||
        current.isLoadingMore) {
      return;
    }

    state = AsyncData<PurchasePickerPage>(
      current.copyWith(isLoadingMore: true),
    );
    try {
      final page = await _page(
        purchases: ref.read(purchasesRepositoryProvider),
        pharmacyId: ref.read(requirePharmacyIdProvider),
        query: resolved,
        offset: current.items.length,
      );
      state = AsyncData<PurchasePickerPage>(
        PurchasePickerPage(
          items: <Purchase>[...current.items, ...page.items],
          hasMore: page.hasMore,
        ),
      );
    } on Object {
      state = AsyncData<PurchasePickerPage>(current);
      rethrow;
    }
  }

  /// One page of [query].
  Future<PurchasePickerPage> _page({
    required PurchasesRepository purchases,
    required String pharmacyId,
    required PurchasesQuery query,
    int offset = 0,
  }) async {
    final items = await purchases.list(
      pharmacyId: pharmacyId,
      query: query,
      limit: purchasePickerPageSize,
      offset: offset,
    );
    return PurchasePickerPage(
      items: items,
      hasMore: items.length == purchasePickerPageSize,
    );
  }

  /// Adds the ids of every supplier whose name matches the term.
  ///
  /// One extra query per searched term, and only when there is a term. The
  /// supplier list is small and searched with the same `ilike` the master screen
  /// uses; the alternative - a filtered join inside the picker's own request - is
  /// a PostgREST feature whose availability depends on the deployed version,
  /// which is exactly the kind of thing that cannot be checked from here.
  Future<PurchasesQuery> _withSupplierMatches({
    required String pharmacyId,
    required SuppliersRepository suppliers,
    required PurchasesQuery query,
  }) async {
    if (query.search.isEmpty) {
      return query.withSupplierIds(const <String>[]);
    }

    final matches = await suppliers.list(
      pharmacyId: pharmacyId,
      query: SuppliersQuery(search: query.search),
      limit: purchasePickerSupplierMatchLimit,
    );
    return query.withSupplierIds(<String>[
      for (final supplier in matches) supplier.id,
    ]);
  }
}
