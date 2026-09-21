/// The paginated sale-return list, and the lines a return can be raised from.
library;

import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_return.dart';
import 'package:app/data/models/write_outcome.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/inventory/application/stock_readers.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/returns/application/sale_returns_list_controller.dart';
import 'package:app/features/returns/data/sale_returns_repository.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sale_return_form_controller.g.dart';

/// How many sales a return form offers to choose from.
///
/// The same trade-off as `returnablePurchaseLimit`: a customer bringing something
/// back does it within days, so the recent sales are the ones that matter. Past it
/// the fix is a searchable picker.
const int returnableSaleLimit = 200;

/// Sales a return may be raised against, newest first.
///
/// Every sale, cancelled ones included: the repository refuses a cancelled sale
/// with a message that says why, which is friendlier than a picker that silently
/// omits the bill the customer is holding.
@riverpod
Future<List<Sale>> returnableSales(Ref ref) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(salesRepositoryProvider)
      .list(
        pharmacyId: pharmacyId,
        query: const SalesQuery(),
        limit: returnableSaleLimit,
      );
}

/// The lines of one sale, joined with the names of what they sold.
///
/// Two repositories, one answer: the lines come from the returns repository (which
/// knows what has already come back) and the names from the products repository
/// (which owns them, and which `sale_items` does not).
typedef SaleReturnable = ({
  List<SaleReturnableLine> lines,
  Map<String, String> names,
});

/// What can come back from one sale, with product names.
@riverpod
Future<SaleReturnable> saleReturnable(Ref ref, String saleId) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  final lines = await ref
      .watch(saleReturnsRepositoryProvider)
      .returnableFor(pharmacyId: pharmacyId, saleId: saleId);

  // Sequential rather than concurrent, for the same reason as elsewhere: a
  // `Future.wait` would surface a `ParallelWaitError` instead of the friendly
  // exception each of these throws.
  final names = await ref
      .watch(productsRepositoryProvider)
      .namesFor(
        pharmacyId: pharmacyId,
        productIds: lines
            .map((line) => line.item.productId)
            .whereType<String>()
            .toSet()
            .toList(growable: false),
      );

  return (lines: lines, names: names);
}

/// The name of one returnable line, falling back to a placeholder.
String saleReturnableName(SaleReturnable data, SaleReturnableLine line) =>
    data.names[line.item.productId] ?? 'Unnamed product';

/// Creates a sale return, and refreshes everything the movement touches.
///
/// A restock moves stock, so it refreshes the same four readers a stock adjustment
/// does (`refreshStockReaders`, the one place that list lives - D-021); the credit
/// note posts itself, through a trigger, so nothing here has to remember the
/// ledger.
@riverpod
class SaleReturnFormController extends _$SaleReturnFormController {
  @override
  Future<SaleReturn?> build() async => null;

  /// Records a return of [quantities] units, keyed by sale-item id.
  ///
  /// **What comes back may be a request rather than a return** (Phase 6.5c): for
  /// anybody but the owner the whole document travels to the owner and nothing is
  /// written, so nothing restocked and no credit note was posted. [WriteOutcome.isStaged]
  /// says which, and the state holds the document only when there is one.
  Future<WriteOutcome<SaleReturn>> createReturn({
    required String saleId,
    required DateTime returnDate,
    required Map<String, int> quantities,
    required bool restock,
    required PaymentMode refundMode,
    String? reason,
  }) async {
    state = const AsyncLoading<SaleReturn?>();
    try {
      final outcome = await ref
          .read(saleReturnsRepositoryProvider)
          .create(
            pharmacyId: ref.read(requirePharmacyIdProvider),
            saleId: saleId,
            returnDate: returnDate,
            quantities: quantities,
            restock: restock,
            refundMode: refundMode,
            reason: reason,
          );
      state = AsyncData<SaleReturn?>(outcome.document);

      if (outcome.isStaged) {
        return outcome;
      }

      ref.invalidate(saleReturnsListControllerProvider);
      refreshStockReaders(ref);
      return outcome;
    } on Object catch (error, stackTrace) {
      state = AsyncError<SaleReturn?>(error, stackTrace);
      rethrow;
    }
  }
}
