/// Money math for a sale.
///
/// Pure, and separate from the repository, for the same reason `PurchaseTotals`
/// is: these figures are what the customer is charged and what the ledger posts,
/// so a rounding mistake is money rather than a display glitch.
///
/// Two rules, inherited from the purchase path so the two cannot disagree:
///
///  * every figure is rounded to two decimals *before* it is summed, so the
///    stored `grand_total` always equals the sum of the stored lines;
///  * rounding is half-away-from-zero with an epsilon, which is what Postgres
///    `numeric` does and what a naive `round()` gets wrong on values like `1.005`.
///
/// The rounding itself is `PurchaseTotals.round2` rather than a second copy: one
/// rule, one implementation, both money paths.
library;

import 'package:app/data/models/sale_cart_line.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';

/// The components of one sale line, as the `sale_items` columns want them.
class SaleLineTotals {
  /// Creates line totals.
  const SaleLineTotals({
    required this.taxable,
    required this.discount,
    required this.tax,
    required this.cgst,
    required this.sgst,
    required this.igst,
    required this.total,
  });

  /// Value before tax, after the line discount.
  final double taxable;

  /// Amount the discount took off, for the `discount_amount` column.
  final double discount;

  /// Total tax charged on the line.
  final double tax;

  /// Central share of [tax], or 0 when the supply is inter-state.
  final double cgst;

  /// State share of [tax], or 0 when the supply is intra-state.
  final double sgst;

  /// Integrated tax, or 0 when the supply is intra-state.
  final double igst;

  /// What the customer pays for the line: [taxable] plus [tax].
  final double total;
}

/// The totals a sale document itself stores.
class SaleDocumentTotals {
  /// Creates document totals.
  const SaleDocumentTotals({
    required this.subTotal,
    required this.discountTotal,
    required this.taxTotal,
    required this.grandTotal,
  });

  /// Sum of the lines' taxable values.
  final double subTotal;

  /// Sum of the lines' discounts.
  final double discountTotal;

  /// Sum of the lines' tax.
  final double taxTotal;

  /// Sum of the lines' totals: what the customer is charged.
  final double grandTotal;
}

/// Line and document totals for a sale.
abstract final class SaleTotals {
  /// What a line's discount takes off its gross value.
  static double discountAmount({
    required int qty,
    required double rate,
    required double discountPercent,
  }) => PurchaseTotals.round2(qty * rate * discountPercent / 100);

  /// Value of a line before tax: quantity x rate, less its discount.
  static double taxable({
    required int qty,
    required double rate,
    required double discountPercent,
  }) => PurchaseTotals.round2(
    qty * rate -
        discountAmount(qty: qty, rate: rate, discountPercent: discountPercent),
  );

  /// Tax charged on [taxable] at [gstPercent].
  static double tax({required double taxable, required double gstPercent}) =>
      PurchaseTotals.round2(taxable * gstPercent / 100);

  /// The full breakdown of one cart line.
  static SaleLineTotals forLine(SaleCartLine line, {required TaxSplit split}) {
    final gross = PurchaseTotals.round2(line.qty * line.rate);
    final discount = discountAmount(
      qty: line.qty,
      rate: line.rate,
      discountPercent: line.discountPercent,
    );
    final taxableValue = PurchaseTotals.round2(gross - discount);
    final taxValue = tax(taxable: taxableValue, gstPercent: line.gstPercent);

    // The second half is the difference rather than its own division, so the two
    // halves always add back to the tax: rounding 0.01 in half twice gives 0.01
    // twice, which would charge a paisa that was never due.
    final (cgst, sgst, igst) = switch (split) {
      TaxSplit.intraState => () {
        final half = PurchaseTotals.round2(taxValue / 2);
        return (half, PurchaseTotals.round2(taxValue - half), 0.0);
      }(),
      TaxSplit.interState => (0.0, 0.0, taxValue),
    };

    return SaleLineTotals(
      taxable: taxableValue,
      discount: discount,
      tax: taxValue,
      cgst: cgst,
      sgst: sgst,
      igst: igst,
      total: PurchaseTotals.round2(taxableValue + taxValue),
    );
  }

  /// The document totals for [lines].
  static SaleDocumentTotals forLines(
    List<SaleCartLine> lines, {
    required TaxSplit split,
  }) {
    var subTotal = 0.0;
    var discountTotal = 0.0;
    var taxTotal = 0.0;
    var grandTotal = 0.0;

    for (final line in lines) {
      final totals = forLine(line, split: split);
      subTotal += totals.taxable;
      discountTotal += totals.discount;
      taxTotal += totals.tax;
      grandTotal += totals.total;
    }

    return SaleDocumentTotals(
      subTotal: PurchaseTotals.round2(subTotal),
      discountTotal: PurchaseTotals.round2(discountTotal),
      taxTotal: PurchaseTotals.round2(taxTotal),
      grandTotal: PurchaseTotals.round2(grandTotal),
    );
  }

  /// What a sale of [total] may record as paid, given a tender of [tendered].
  ///
  /// The change a cashier hands back is not revenue, and `checkout_sale()` refuses
  /// a sale paid beyond its total (the `sales_payment_check` trigger). Clamping
  /// here means the counter can take a ₹500 note for a ₹217 bill without the
  /// write being refused: the sale records 217, and the 283 is change.
  static double recordablePaid({
    required double tendered,
    required double total,
  }) {
    if (tendered <= 0 || total <= 0) {
      return 0;
    }
    return tendered > total
        ? PurchaseTotals.round2(total)
        : PurchaseTotals.round2(tendered);
  }

  /// The change owed on a tender, which is never negative.
  static double changeFor({required double tendered, required double total}) {
    final change = PurchaseTotals.round2(tendered - total);
    return change > 0 ? change : 0;
  }
}
