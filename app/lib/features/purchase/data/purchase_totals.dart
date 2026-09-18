/// Money math for a purchase document.
///
/// Pure, and separate from the repository, because it is the one part of a
/// receipt that cannot be corrected afterwards: `purchases.grand_total` is what
/// `ledger_auto_entry_purchase()` posts as the supplier payable (D-013), so a
/// rounding mistake becomes a financial figure that only a payment can fix.
///
/// Two rules keep the stored numbers self-consistent:
///
///  * every figure is rounded to two decimals *before* it is summed, so a stored
///    grand total always equals the sum of the stored lines - the columns are
///    `numeric(14,2)`, and Postgres would round each one anyway, but summing
///    unrounded values makes the total disagree with its own lines by a cent;
///  * rounding is half-away-from-zero, with an epsilon, which is both what
///    Postgres `numeric` does and what a naive `round()` gets wrong on values
///    like `1.005` (stored as `1.00499999999999989`, it would round down).
library;

import 'package:app/data/models/purchase_draft.dart';

/// How a document's tax is split between central/state and integrated.
enum TaxSplit {
  /// Supplier and pharmacy in the same state: CGST and SGST, half each.
  intraState,

  /// Different states: IGST alone.
  interState,
}

/// The components of one line, as the `purchase_items` columns want them.
class PurchaseLineTotals {
  /// Creates line totals.
  const PurchaseLineTotals({
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

  /// Amount the line discount took off.
  final double discount;

  /// Total tax charged on the line.
  final double tax;

  /// Central share of [tax], or 0 when the supply is inter-state.
  final double cgst;

  /// State share of [tax], or 0 when the supply is inter-state.
  final double sgst;

  /// Integrated tax, or 0 when the supply is intra-state.
  final double igst;

  /// What the line adds to the invoice: [taxable] plus [tax].
  final double total;
}

/// The totals a purchase document itself stores.
class PurchaseDocumentTotals {
  /// Creates document totals.
  const PurchaseDocumentTotals({
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

  /// Sum of the lines' totals: what the supplier is owed.
  final double grandTotal;
}

/// Line and document totals for a purchase.
abstract final class PurchaseTotals {
  /// Value of a line before tax: quantity x rate, less its discount.
  static double taxable({
    required int qty,
    required double rate,
    required double discountPercent,
  }) => _round2(
    qty * rate -
        _discount(qty: qty, rate: rate, discountPercent: discountPercent),
  );

  /// What a line's discount takes off its gross value.
  static double _discount({
    required int qty,
    required double rate,
    required double discountPercent,
  }) => _round2(qty * rate * discountPercent / 100);

  /// Tax charged on [taxable] at [gstPercent].
  static double tax({required double taxable, required double gstPercent}) =>
      _round2(taxable * gstPercent / 100);

  /// The full breakdown of one line.
  static PurchaseLineTotals forLine(
    PurchaseLineDraft line, {
    required TaxSplit split,
  }) {
    final gross = _round2(line.qty * line.purchaseRate);
    final discount = _discount(
      qty: line.qty,
      rate: line.purchaseRate,
      discountPercent: line.discountPercent,
    );
    final taxableValue = _round2(gross - discount);
    final taxValue = tax(taxable: taxableValue, gstPercent: line.gstPercent);

    // The second half is the difference rather than its own division, so the two
    // halves always add back to the tax: rounding 0.01 in half twice gives 0.01
    // twice, which would charge a paisa that was never due.
    final (cgst, sgst, igst) = switch (split) {
      TaxSplit.intraState => () {
        final half = _round2(taxValue / 2);
        return (half, _round2(taxValue - half), 0.0);
      }(),
      TaxSplit.interState => (0.0, 0.0, taxValue),
    };

    return PurchaseLineTotals(
      taxable: taxableValue,
      discount: discount,
      tax: taxValue,
      cgst: cgst,
      sgst: sgst,
      igst: igst,
      total: _round2(taxableValue + taxValue),
    );
  }

  /// The document totals for [lines].
  static PurchaseDocumentTotals forLines(
    List<PurchaseLineDraft> lines, {
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

    return PurchaseDocumentTotals(
      subTotal: _round2(subTotal),
      discountTotal: _round2(discountTotal),
      taxTotal: _round2(taxTotal),
      grandTotal: _round2(grandTotal),
    );
  }

  /// Decides the split from the two states involved.
  ///
  /// An unknown state falls back to intra-state, because a pharmacy buys from
  /// local distributors far more often than across a border, and because a
  /// half-and-half split is the shape an Indian invoice most often has. The
  /// alternative - guessing IGST - would put a wrong tax head on the common case.
  static TaxSplit splitFor({
    required String? pharmacyState,
    required String? supplierState,
  }) {
    final pharmacy = pharmacyState?.trim().toLowerCase();
    final supplier = supplierState?.trim().toLowerCase();
    if (pharmacy == null ||
        pharmacy.isEmpty ||
        supplier == null ||
        supplier.isEmpty) {
      return TaxSplit.intraState;
    }
    return pharmacy == supplier ? TaxSplit.intraState : TaxSplit.interState;
  }
}

/// Rounds [value] to two decimals, half away from zero.
///
/// The epsilon covers binary representation: `1.005 * 100` is
/// `100.49999999999999`, so without it the value rounds down and the stored
/// figure is a paisa short of what Postgres `numeric` would have made of it.
double _round2(double value) {
  final scaled = value * 100;
  final adjusted = scaled + (scaled.isNegative ? -1e-9 : 1e-9);
  return adjusted.roundToDouble() / 100;
}
