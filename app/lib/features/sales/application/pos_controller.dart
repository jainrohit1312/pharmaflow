/// The counter's basket: what is being sold, and how it is being paid.
library;

import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_cart_line.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'pos_controller.g.dart';

/// The GST slab a line starts on.
///
/// The same default the purchase line editor uses, and for the same reason:
/// `products` has no slab column, 0 asserts nothing but is wrong for almost every
/// medicine, and the field is on screen and editable either way.
const double defaultSaleGstPercent = 12;

/// What the counter has rung up, and how it is being paid.
///
/// Immutable, and mutated only through the controller's methods, so a change is a
/// new value rather than an in-place edit Riverpod could miss. [withCustomer] and
/// [withPlaceOfSupply] exist because `copyWith(customerId: null)` cannot be told
/// from "leave it alone" - the same trap `ExpiryCalendarState.withDay` documents.
class PosCart {
  /// Creates a cart.
  const PosCart({
    this.lines = const <SaleCartLine>[],
    this.customerId,
    this.paymentMode = PaymentMode.cash,
    this.tendered = 0,
    this.placeOfSupply,
  });

  /// Its lines, in the order they were added.
  final List<SaleCartLine> lines;

  /// Who is buying, or `null` for a walk-in.
  final String? customerId;

  /// How it is being settled.
  final PaymentMode paymentMode;

  /// What the customer has handed over, before any change is worked out.
  final double tendered;

  /// Where the goods are going, which decides the tax split.
  final String? placeOfSupply;

  /// Whether nothing has been rung up yet.
  bool get isEmpty => lines.isEmpty;

  /// Whether anything is on the counter.
  bool get isNotEmpty => lines.isNotEmpty;

  /// Whether the sale will post a customer receivable.
  ///
  /// True when credit was chosen, or when what was tendered does not cover the
  /// bill - which `checkout_sale()` refuses without a customer to owe it.
  bool get needsCustomer => paymentMode.isOnAccount;

  /// What the sale will record as paid, for a bill of [grandTotal].
  ///
  /// Three cases, in the order the counter meets them:
  ///
  ///  * a tender was typed - record it, clamped to the bill, because the change
  ///    handed back is not revenue;
  ///  * no tender and a mode that settles at the counter (cash, card, UPI, bank,
  ///    wallet) - the counter took the money, so the sale is paid in full;
  ///  * no tender and `credit` - nothing was paid, and the balance becomes a
  ///    receivable.
  ///
  /// The screen and the write both read this, so what the cashier sees beside
  /// "Change" is what gets stored.
  double paidFor(double grandTotal) {
    if (tendered > 0) {
      return SaleTotals.recordablePaid(tendered: tendered, total: grandTotal);
    }
    return paymentMode.isOnAccount
        ? 0
        : SaleTotals.recordablePaid(tendered: grandTotal, total: grandTotal);
  }

  /// A copy with the lines replaced.
  PosCart withLines(List<SaleCartLine> value) => PosCart(
    lines: value,
    customerId: customerId,
    paymentMode: paymentMode,
    tendered: tendered,
    placeOfSupply: placeOfSupply,
  );

  /// A copy with the customer replaced, or cleared by passing `null`.
  PosCart withCustomer(String? value) => PosCart(
    lines: lines,
    customerId: value,
    paymentMode: paymentMode,
    tendered: tendered,
    placeOfSupply: placeOfSupply,
  );

  /// A copy with the place of supply replaced, or cleared by passing `null`.
  PosCart withPlaceOfSupply(String? value) => PosCart(
    lines: lines,
    customerId: customerId,
    paymentMode: paymentMode,
    tendered: tendered,
    placeOfSupply: value,
  );

  /// A copy with the payment mode replaced.
  PosCart withPaymentMode(PaymentMode value) => PosCart(
    lines: lines,
    customerId: customerId,
    paymentMode: value,
    tendered: tendered,
    placeOfSupply: placeOfSupply,
  );

  /// A copy with the tender replaced.
  PosCart withTendered(double value) => PosCart(
    lines: lines,
    customerId: customerId,
    paymentMode: paymentMode,
    tendered: value,
    placeOfSupply: placeOfSupply,
  );
}

/// The basket at the counter.
///
/// Kept alive on purpose: a cashier who opens a product's detail mid-sale - or
/// the invoice of the sale they just rang up - must not come back to an empty
/// counter. `clear()` is the explicit way to start over, and a successful
/// checkout clears it too.
@Riverpod(keepAlive: true)
class PosController extends _$PosController {
  @override
  PosCart build() => const PosCart();

  /// Adds [qty] of one batch to the basket.
  ///
  /// The same product out of the same batch merges into the line already there -
  /// a second scan of one barcode is another unit, not a competing line - while a
  /// different batch of the same product is a line of its own, because the two
  /// have their own expiry and their own stock.
  ///
  /// [rate] defaults to the batch's counter price, falling back to its MRP when no
  /// counter price was ever set; [gstPercent] to the common slab.
  void addLine({
    required Product product,
    required BatchStatus batch,
    required int qty,
    double? rate,
    double? gstPercent,
  }) {
    if (qty <= 0) {
      return;
    }

    final line = SaleCartLine(
      productId: product.id,
      productName: product.name,
      scheduleType: product.scheduleType,
      batchId: batch.id,
      batchNo: batch.batchNo,
      qty: qty,
      rate: rate ?? _defaultRate(batch),
      gstPercent: gstPercent ?? defaultSaleGstPercent,
      expiryDateIso: batch.expiryDate.toIso8601String(),
    );

    final existing = state.lines.indexWhere(
      (candidate) => candidate.isSameLineAs(line),
    );
    if (existing < 0) {
      state = state.withLines(<SaleCartLine>[...state.lines, line]);
      return;
    }

    final merged = state.lines[existing].copyWith(
      qty: state.lines[existing].qty + qty,
    );
    state = state.withLines(<SaleCartLine>[
      for (var index = 0; index < state.lines.length; index++)
        if (index == existing) merged else state.lines[index],
    ]);
  }

  /// Sets a line's quantity, removing it at zero.
  void setQty(String batchId, int qty) {
    if (qty <= 0) {
      removeLine(batchId);
      return;
    }
    _replace(batchId, (line) => line.copyWith(qty: qty));
  }

  /// Sets a line's rate.
  void setRate(String batchId, double rate) =>
      _replace(batchId, (line) => line.copyWith(rate: rate));

  /// Sets a line's discount percentage.
  void setDiscount(String batchId, double percent) =>
      _replace(batchId, (line) => line.copyWith(discountPercent: percent));

  /// Sets a line's GST slab.
  void setGst(String batchId, double percent) =>
      _replace(batchId, (line) => line.copyWith(gstPercent: percent));

  /// Removes a line.
  void removeLine(String batchId) => state = state.withLines(<SaleCartLine>[
    for (final line in state.lines)
      if (line.batchId != batchId) line,
  ]);

  /// Records who is buying, or clears the customer with `null`.
  void setCustomer(String? customerId) =>
      state = state.withCustomer(customerId);

  /// Records where the goods are going, or clears it with `null`.
  void setPlaceOfSupply(String? value) =>
      state = state.withPlaceOfSupply(value);

  /// Records how the sale is being settled.
  void setPaymentMode(PaymentMode mode) => state = state.withPaymentMode(mode);

  /// Records what the customer handed over.
  void setTendered(double amount) => state = state.withTendered(amount);

  /// Empties the basket and forgets everything chosen for it.
  void clear() => state = const PosCart();

  /// Replaces one line in place.
  void _replace(String batchId, SaleCartLine Function(SaleCartLine) change) =>
      state = state.withLines(<SaleCartLine>[
        for (final line in state.lines)
          if (line.batchId == batchId) change(line) else line,
      ]);

  /// The price to charge for a unit of [batch].
  static double _defaultRate(BatchStatus batch) =>
      batch.sellingRate > 0 ? batch.sellingRate : batch.mrp;
}
