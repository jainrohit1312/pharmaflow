/// Tests for [PurchaseReturnTotals].
///
/// These pin the property the money path depends on: a return line is worth the
/// same *slice* of its invoice line as the units it takes, discount and tax
/// included - not the list price of those units.
library;

import 'package:app/data/models/purchase_item.dart';
import 'package:app/features/returns/data/purchase_return_totals.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_purchases_repository.dart';

/// A purchase line as the invoice stored it: 10 units billed at 100 with a 10%
/// discount and 12% GST, so 900 taxable, 108 tax, 1008 total.
PurchaseItem _line({
  int qty = 10,
  double purchaseRate = 100,
  double mrp = 150,
  double discountPercent = 10,
  double gstPercent = 12,
  double taxAmount = 108,
  double totalAmount = 1008,
}) =>
    buildItem(
      qty: qty,
      purchaseRate: purchaseRate,
      mrp: mrp,
      gstPercent: gstPercent,
    ).copyWith(
      discountPercent: discountPercent,
      taxAmount: taxAmount,
      totalAmount: totalAmount,
    );

void main() {
  test('credits the slice of the invoice line the units represent', () {
    final amounts = PurchaseReturnTotals.forLine(item: _line(), qty: 4);

    expect(amounts.total, 403.20, reason: '40% of what the line cost');
    expect(amounts.tax, 43.20, reason: '40% of the tax on it');
    expect(
      amounts.taxable,
      360,
      reason: 'the discounted value of 4 units, not 4 x 100',
    );
  });

  test('a full return is worth exactly the invoice line', () {
    final amounts = PurchaseReturnTotals.forLine(item: _line(), qty: 10);

    expect(amounts.taxable, 900);
    expect(amounts.tax, 108);
    expect(amounts.total, 1008);
  });

  test('rounds each figure to two decimals', () {
    // A third of 100 and of 10: both are recurring, so both have to land on a
    // paisa the way Postgres would store them.
    final amounts = PurchaseReturnTotals.forLine(
      item: _line(qty: 3, taxAmount: 10, totalAmount: 100),
      qty: 1,
    );

    expect(amounts.total, 33.33);
    expect(amounts.tax, 3.33);
    expect(amounts.taxable, 30);
  });

  test('document totals add up to the sum of their own lines', () {
    final lines = <PurchaseReturnLineAmounts>[
      PurchaseReturnTotals.forLine(item: _line(), qty: 4),
      // The same deal on 5 units: 450 taxable, 54 tax, 504 on the line.
      PurchaseReturnTotals.forLine(
        item: _line(qty: 5, taxAmount: 54, totalAmount: 504),
        qty: 1,
      ),
    ];
    final totals = PurchaseReturnTotals.forLines(lines);

    expect(totals.subTotal, 360 + 90);
    expect(totals.taxTotal, 43.20 + 10.80);
    expect(
      totals.grandTotal,
      totals.subTotal + totals.taxTotal,
      reason: 'a credit note whose three figures disagree cannot be reconciled',
    );
  });

  test('an empty set of lines is worth nothing', () {
    final totals = PurchaseReturnTotals.forLines(
      const <PurchaseReturnLineAmounts>[],
    );

    expect(totals.subTotal, 0);
    expect(totals.taxTotal, 0);
    expect(totals.grandTotal, 0);
  });
}
