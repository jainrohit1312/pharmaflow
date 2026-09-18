/// Money math for a purchase return.
///
/// A return is a slice of a line the pharmacy already paid for, so its value is
/// the same slice of what that line *stored* - not a figure recomputed from the
/// rate. That distinction is the whole reason this helper exists:
///
///  * `purchase_return_items` has no `discount_percent` column, so recomputing
///    from `qty x purchase_rate` would credit the supplier for the list price of
///    goods they had already discounted. Ten units at 100 with a 10% discount is
///    900, and returning four of them is 360, not 400;
///  * the purchase line's own `tax_amount` and `total_amount` are what the
///    invoice says, already rounded by the receipt, so scaling them keeps a
///    return's total equal to a proportional share of its invoice line;
///  * scaling by quantity rather than by value keeps a partial return's money
///    proportional to the units, which is what the credit note has to say.
///
/// Pure and separate from the repository for the same reason as the purchase
/// totals: a rounding mistake here becomes a figure the supplier is credited.
library;

import 'package:app/data/models/purchase_item.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';

/// What one returned line is worth.
class PurchaseReturnLineAmounts {
  /// Creates line amounts.
  const PurchaseReturnLineAmounts({
    required this.taxable,
    required this.tax,
    required this.total,
  });

  /// Value before tax.
  final double taxable;

  /// The line's share of the tax that was charged on it.
  final double tax;

  /// What the line credits the supplier: [taxable] plus [tax].
  final double total;
}

/// The three figures a return document stores.
class PurchaseReturnDocumentAmounts {
  /// Creates document amounts.
  const PurchaseReturnDocumentAmounts({
    required this.subTotal,
    required this.taxTotal,
    required this.grandTotal,
  });

  /// Sum of the lines' taxable values.
  final double subTotal;

  /// Sum of the lines' tax.
  final double taxTotal;

  /// Sum of the lines' totals: what the supplier owes back.
  final double grandTotal;
}

/// Line and document amounts for a purchase return.
abstract final class PurchaseReturnTotals {
  /// What returning [qty] units of [item] is worth.
  ///
  /// `purchase_items.qty` carries `check (qty > 0)`, so the share is always a
  /// defined fraction; [qty] itself is validated by the caller against the line
  /// and against what has already gone back.
  static PurchaseReturnLineAmounts forLine({
    required PurchaseItem item,
    required int qty,
  }) {
    final share = qty / item.qty;
    final total = PurchaseTotals.round2(item.totalAmount * share);
    final tax = PurchaseTotals.round2(item.taxAmount * share);
    // Derived by subtraction so the three figures add up: rounding the taxable
    // value separately could leave the line a paisa away from its own total.
    return PurchaseReturnLineAmounts(
      taxable: PurchaseTotals.round2(total - tax),
      tax: tax,
      total: total,
    );
  }

  /// The document amounts for [lines].
  ///
  /// Each line is already rounded, so the sums are rounded once more only to
  /// clear binary noise accumulated by adding them - the same rule the purchase
  /// side follows, and what keeps a stored grand total equal to its own lines.
  static PurchaseReturnDocumentAmounts forLines(
    List<PurchaseReturnLineAmounts> lines,
  ) {
    var subTotal = 0.0;
    var taxTotal = 0.0;
    var grandTotal = 0.0;

    for (final line in lines) {
      subTotal += line.taxable;
      taxTotal += line.tax;
      grandTotal += line.total;
    }

    return PurchaseReturnDocumentAmounts(
      subTotal: PurchaseTotals.round2(subTotal),
      taxTotal: PurchaseTotals.round2(taxTotal),
      grandTotal: PurchaseTotals.round2(grandTotal),
    );
  }
}
