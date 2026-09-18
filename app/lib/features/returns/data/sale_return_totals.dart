/// Money math for a sale return.
///
/// The same rule as the purchase side (D-020), for the same reason: a return is a
/// slice of a line the pharmacy already sold, so its value is the same slice of
/// what that line *stored*, not a figure recomputed from the rate.
///
/// `sale_return_items` has no `discount_percent` column - it stores `rate`,
/// `gst_percent`, `tax_amount` and `total_amount` - so recomputing from
/// `qty x rate` would refund the list price of goods that were discounted.
library;

import 'package:app/data/models/sale_item.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';

/// What one returned line is worth.
class SaleReturnLineAmounts {
  /// Creates line amounts.
  const SaleReturnLineAmounts({
    required this.taxable,
    required this.tax,
    required this.total,
  });

  /// Value before tax.
  final double taxable;

  /// The line's share of the tax that was charged on it.
  final double tax;

  /// What the line refunds: [taxable] plus [tax].
  final double total;
}

/// The three figures a sale return stores.
class SaleReturnDocumentAmounts {
  /// Creates document amounts.
  const SaleReturnDocumentAmounts({
    required this.subTotal,
    required this.taxTotal,
    required this.grandTotal,
  });

  /// Sum of the lines' taxable values.
  final double subTotal;

  /// Sum of the lines' tax.
  final double taxTotal;

  /// Sum of the lines' totals: what the customer is refunded.
  final double grandTotal;
}

/// Line and document amounts for a sale return.
abstract final class SaleReturnTotals {
  /// What refunding [qty] units of [item] is worth.
  ///
  /// `sale_items.qty` carries `check (qty > 0)`, so the share is always defined;
  /// [qty] is validated by the caller against the line and against what has already
  /// come back.
  static SaleReturnLineAmounts forLine({
    required SaleItem item,
    required int qty,
  }) {
    final share = qty / item.qty;
    final total = PurchaseTotals.round2(item.totalAmount * share);
    final tax = PurchaseTotals.round2(item.taxAmount * share);
    return SaleReturnLineAmounts(
      taxable: PurchaseTotals.round2(total - tax),
      tax: tax,
      total: total,
    );
  }

  /// The document amounts for [lines].
  static SaleReturnDocumentAmounts forLines(List<SaleReturnLineAmounts> lines) {
    var subTotal = 0.0;
    var taxTotal = 0.0;
    var grandTotal = 0.0;

    for (final line in lines) {
      subTotal += line.taxable;
      taxTotal += line.tax;
      grandTotal += line.total;
    }

    return SaleReturnDocumentAmounts(
      subTotal: PurchaseTotals.round2(subTotal),
      taxTotal: PurchaseTotals.round2(taxTotal),
      grandTotal: PurchaseTotals.round2(grandTotal),
    );
  }
}
