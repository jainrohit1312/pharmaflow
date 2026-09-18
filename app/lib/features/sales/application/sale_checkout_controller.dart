/// The checkout write: turns the basket into a sale.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_cart_line.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/inventory/application/stock_readers.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:app/features/sales/application/sales_list_controller.dart';
import 'package:app/features/sales/data/sale_checkout.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sale_checkout_controller.g.dart';

/// Writes the basket as a sale, in one transaction.
///
/// The order of the two things this does is the whole design:
///
///  1. **Availability is re-read and checked before anything is written**, so an
///     out-of-stock line is refused with a message naming the product and what is
///     left. The database refuses it anyway - `stock_update_on_sale()` raises
///     `check_violation` and `checkout_sale()` is one transaction, so nothing
///     partial is ever stored - but its message names a batch id, which is no use
///     to a cashier.
///  2. **The write is one RPC.** A sale's stock posts as each line is inserted, so
///     a header-then-lines write would leave some units taken and some not if a
///     later line were refused.
///
/// On success the basket is emptied and every reader of stock is refreshed: a sale
/// is the movement that most often empties a batch.
@riverpod
class SaleCheckoutController extends _$SaleCheckoutController {
  @override
  Future<Sale?> build() async => null;

  /// Writes [cart] as a sale, with [split] deciding the tax heads.
  Future<Sale> checkout({
    required PosCart cart,
    required TaxSplit split,
  }) async {
    if (cart.isEmpty) {
      throw const ValidationException(
        message: 'Ring something up before taking payment.',
      );
    }

    state = const AsyncLoading<Sale?>();
    try {
      final pharmacyId = ref.read(requirePharmacyIdProvider);
      await _requireStock(pharmacyId: pharmacyId, lines: cart.lines);

      final totals = SaleTotals.forLines(cart.lines, split: split);
      final checkout = SaleCheckout(
        lines: <SaleCheckoutLine>[
          for (final line in cart.lines)
            SaleCheckoutLine.from(
              line: line,
              totals: SaleTotals.forLine(line, split: split),
            ),
        ],
        customerId: cart.customerId,
        paymentMode: cart.paymentMode,
        // What the counter says it took, by the same rule the screen showed:
        // the change handed back is not a payment, and `sales_payment_check`
        // refuses a sale paid beyond its total.
        amountPaid: cart.paidFor(totals.grandTotal),
        placeOfSupply: cart.placeOfSupply,
      );

      if (checkout.amountPaid < totals.grandTotal && cart.customerId == null) {
        throw const ValidationException(
          message:
              'Choose the customer who is owing the balance, or take the '
              'payment in full.',
        );
      }

      final saved = await ref
          .read(salesRepositoryProvider)
          .checkout(pharmacyId: pharmacyId, checkout: checkout);

      ref.read(posControllerProvider.notifier).clear();
      ref.invalidate(salesListControllerProvider);
      refreshStockReaders(ref);
      state = AsyncData<Sale?>(saved);
      return saved;
    } on Object catch (error, stackTrace) {
      state = AsyncError<Sale?>(error, stackTrace);
      rethrow;
    }
  }

  /// Refuses the basket when a line asks for more than its batch holds.
  ///
  /// One read for every batch in the basket, rather than one per line, and the
  /// refusal names what is left so the cashier can act on it instead of guessing.
  Future<void> _requireStock({
    required String pharmacyId,
    required List<SaleCartLine> lines,
  }) async {
    final available = await ref
        .read(productsRepositoryProvider)
        .batchQuantitiesFor(
          pharmacyId: pharmacyId,
          batchIds: lines
              .map((line) => line.batchId)
              .toSet()
              .toList(growable: false),
        );

    for (final line in lines) {
      final left = available[line.batchId] ?? 0;
      if (line.qty > left) {
        throw ValidationException(
          message:
              'Only $left ${left == 1 ? 'unit' : 'units'} of '
              '${line.productName} (batch ${line.batchNo}) are left in stock.',
        );
      }
    }
  }
}
