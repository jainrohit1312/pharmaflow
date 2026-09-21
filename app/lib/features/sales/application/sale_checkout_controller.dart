/// The checkout write: turns the basket into a sale.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_cart_line.dart';
import 'package:app/data/repositories/pharmacy_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/inventory/application/stock_readers.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:app/features/sales/application/sale_requirements.dart';
import 'package:app/features/sales/application/sales_list_controller.dart';
import 'package:app/features/sales/data/sale_checkout.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sale_checkout_controller.g.dart';

/// Mints the key one submission is identified by.
///
/// Unique within this installation, which is all the server's
/// `(pharmacy_id, idempotency_key)` index needs. A counter is enough rather than a
/// random name because a pharmacy's submissions come from one process; the
/// timestamp is what keeps two installations from colliding on the same counter.
String newSubmissionKey() =>
    'pos-${DateTime.now().microsecondsSinceEpoch}-${_submissionCount++}';

/// How many keys this process has minted, to keep two in the same microsecond
/// apart.
int _submissionCount = 0;

/// The pharmacy's configured package markup, read only when a package sale needs it.
///
/// `null` is a real answer - nobody has configured it - and refuses the sale rather
/// than pricing it at an invented percentage (D-070). A counter sale does not pay for
/// this read.
///
/// One provider rather than a private read inside the write: the counter's confirmation
/// step has to ask the same question **before** the dialog it raises, and two reads of
/// the same setting could answer differently about one basket.
@riverpod
Future<double?> packageMarkupPercent(Ref ref, SaleType saleType) async {
  if (saleType != SaleType.package) {
    return null;
  }
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  final pharmacy = await ref.watch(pharmacyRepositoryProvider).byId(pharmacyId);
  return pharmacy?.packageMarkupPercent;
}

/// Writes the basket as a sale, in one transaction.
///
/// The order of the things this does is the whole design:
///
///  1. **The sale's own requirements are checked first** ([saleRefusal]): the type
///     decides what the bill must carry, so a counter sale with no patient is
///     refused before anything else is even read. The server refuses it too - in
///     the same words - which is where these sentences come from.
///  2. **Availability is re-read and checked before anything is written**, so an
///     out-of-stock line is refused with a message naming the product and what is
///     left. The database refuses it anyway - `stock_update_on_sale()` raises
///     `check_violation` and `checkout_sale()` is one transaction, so nothing
///     partial is ever stored - but its message names a batch id, which is no use
///     to a cashier.
///  3. **The write is one RPC.** A sale's stock posts as each line is inserted, so
///     a header-then-lines write would leave some units taken and some not if a
///     later line were refused.
///
/// A submission carries an **idempotency key** from the moment it starts, so a
/// retry after a timeout is the same sale rather than a second one. Every edit to
/// the basket clears the key (`PosCart`), because the server answers a repeated key
/// with the original sale rather than comparing payloads.
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

      final refusal = saleRefusal(
        cart: cart,
        packageMarkupPercent: await ref.read(
          packageMarkupPercentProvider(cart.saleType).future,
        ),
      );
      if (refusal != null) {
        throw ValidationException(message: refusal);
      }

      await _requireStock(pharmacyId: pharmacyId, lines: cart.lines);

      final totals = SaleTotals.forLines(
        cart.lines,
        split: split,
        saleType: cart.saleType,
      );
      final paid = cart.paidFor(totals.grandTotal);
      // The last line of defence rather than the first: every type that can be left
      // unpaid requires a party (counter and IPD a patient, package an account), so
      // `saleRefusal` has already refused this case. It stays because it is the
      // server's own rule - "a sale with an unpaid balance needs a customer to owe
      // it" - and a future type that allowed one would otherwise reach the till.
      if (cart.saleType != SaleType.transfer &&
          paid < totals.grandTotal &&
          cart.customerId == null) {
        throw const ValidationException(
          message:
              'Choose the customer who is owing the balance, or take the '
              'payment in full.',
        );
      }

      // Minted before the write and left on the cart, so a retry of a submission
      // that timed out is the same sale.
      final key = cart.idempotencyKey ?? newSubmissionKey();
      ref.read(posControllerProvider.notifier).setIdempotencyKey(key);

      final checkout = SaleCheckout(
        lines: <SaleCheckoutLine>[
          for (final line in cart.lines)
            SaleCheckoutLine.from(
              line: line,
              totals: SaleTotals.forLine(
                line,
                split: split,
                saleType: cart.saleType,
              ),
              saleType: cart.saleType,
            ),
        ],
        saleType: cart.saleType,
        customerId: cart.customerId,
        patientName: cart.patientName,
        patientMobile: cart.patientMobile,
        admissionId: cart.admissionId,
        doctorId: cart.doctorId,
        doctorName: cart.doctorName,
        hospitalReference: cart.hospitalReference,
        paymentMode: cart.paymentMode,
        // What the counter says it took, by the same rule the screen showed:
        // the change handed back is not a payment, and `sales_payment_check`
        // refuses a sale paid beyond its total.
        amountPaid: paid,
        placeOfSupply: cart.placeOfSupply,
        fromLocation: cart.fromLocation,
        toLocation: cart.toLocation,
        transferReason: cart.transferReason,
        idempotencyKey: key,
      );

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
