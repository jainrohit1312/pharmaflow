/// Tests for the sale money math.
///
/// These figures are what the customer is charged and what the ledger posts, so
/// the rules under test are the two the purchase path agreed to (and that
/// `SaleTotals` deliberately shares rather than re-implements): round each figure
/// to two decimals *before* summing, and round half away from zero with an
/// epsilon so `1.005` does not come out a paisa short of what Postgres `numeric`
/// would store.
library;

import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale_cart_line.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cart line with only the fields a money assertion cares about.
SaleCartLine _line({
  String productId = 'product-1',
  String batchId = 'batch-1',
  int qty = 1,
  double rate = 100,
  double discountPercent = 0,
  double gstPercent = 0,
}) => SaleCartLine(
  productId: productId,
  productName: 'Dolo 650',
  scheduleType: ScheduleType.otc,
  batchId: batchId,
  batchNo: 'B-1',
  qty: qty,
  rate: rate,
  discountPercent: discountPercent,
  gstPercent: gstPercent,
);

void main() {
  group('a line', () {
    test('is quantity times rate before tax when nothing is discounted', () {
      final totals = SaleTotals.forLine(
        _line(qty: 3, rate: 40, gstPercent: 12),
        split: TaxSplit.intraState,
      );

      expect(totals.discount, 0);
      expect(totals.taxable, 120);
      expect(totals.tax, 14.4);
      expect(totals.total, 134.4);
    });

    test('takes the discount off the gross value, not off the taxed value', () {
      final totals = SaleTotals.forLine(
        _line(qty: 10, discountPercent: 10, gstPercent: 12),
        split: TaxSplit.intraState,
      );

      // 1000 gross, 100 off, so tax is charged on 900.
      expect(totals.discount, 100);
      expect(totals.taxable, 900);
      expect(totals.tax, 108);
      expect(totals.total, 1008);
    });

    test('splits the tax into CGST and SGST for an intra-state supply', () {
      final totals = SaleTotals.forLine(
        _line(gstPercent: 18),
        split: TaxSplit.intraState,
      );

      expect(totals.cgst, 9);
      expect(totals.sgst, 9);
      expect(totals.igst, 0);
    });

    test('charges IGST, and no CGST or SGST, for an inter-state supply', () {
      final totals = SaleTotals.forLine(
        _line(gstPercent: 18),
        split: TaxSplit.interState,
      );

      expect(totals.cgst, 0);
      expect(totals.sgst, 0);
      expect(totals.igst, 18);
    });

    test('the two halves always add back to the tax', () {
      // 17 paise at 6% is 1.02 paise, which rounds to one paisa. Splitting it by
      // rounding each half independently would give 1 + 1 and charge a paisa that
      // was never due - which is why the second half is the difference.
      final totals = SaleTotals.forLine(
        _line(rate: 0.17, gstPercent: 6),
        split: TaxSplit.intraState,
      );

      expect(totals.tax, 0.01);
      expect(PurchaseTotals.round2(totals.cgst + totals.sgst), totals.tax);
      expect(totals.total, 0.18);
    });

    test('rounds a half away from zero, as Postgres numeric does', () {
      // A naive `round()` reads 1.005 as 1.00499999... and gives 1.00; the
      // epsilon in the shared rule is what makes this 1.01, and a sale that
      // disagreed with the column it is stored in would be a stored figure that
      // does not match its own arithmetic.
      expect(SaleTotals.tax(taxable: 1.005, gstPercent: 100), 1.01);
    });
  });

  group('a document', () {
    test('totals are the sum of its lines', () {
      final lines = <SaleCartLine>[
        _line(qty: 2, rate: 150, gstPercent: 12),
        _line(batchId: 'batch-2', qty: 3, rate: 33.35, discountPercent: 5),
      ];

      final totals = SaleTotals.forLines(lines, split: TaxSplit.intraState);
      final perLine = lines
          .map((line) => SaleTotals.forLine(line, split: TaxSplit.intraState))
          .toList(growable: false);

      expect(
        totals.subTotal,
        PurchaseTotals.round2(
          perLine.fold<double>(0, (sum, line) => sum + line.taxable),
        ),
      );
      expect(
        totals.discountTotal,
        PurchaseTotals.round2(
          perLine.fold<double>(0, (sum, line) => sum + line.discount),
        ),
      );
      expect(
        totals.taxTotal,
        PurchaseTotals.round2(
          perLine.fold<double>(0, (sum, line) => sum + line.tax),
        ),
      );
      expect(
        totals.grandTotal,
        PurchaseTotals.round2(
          perLine.fold<double>(0, (sum, line) => sum + line.total),
        ),
        reason: 'the stored grand total must equal the sum of its stored lines',
      );
    });

    test('an empty basket comes to nothing rather than throwing', () {
      final totals = SaleTotals.forLines(
        const <SaleCartLine>[],
        split: TaxSplit.intraState,
      );

      expect(totals.subTotal, 0);
      expect(totals.taxTotal, 0);
      expect(totals.grandTotal, 0);
    });

    test('the tax total is the same whichever way it is split', () {
      final lines = <SaleCartLine>[
        _line(qty: 3, rate: 33.35, gstPercent: 12),
        _line(batchId: 'batch-2', qty: 7, rate: 12.5, gstPercent: 5),
      ];

      final intra = SaleTotals.forLines(lines, split: TaxSplit.intraState);
      final inter = SaleTotals.forLines(lines, split: TaxSplit.interState);

      expect(
        intra.taxTotal,
        inter.taxTotal,
        reason: 'where the goods went changes the heads, not the tax',
      );
      expect(intra.grandTotal, inter.grandTotal);
    });
  });

  group('what a tender may record', () {
    test('a tender below the bill is recorded as tendered', () {
      expect(SaleTotals.recordablePaid(tendered: 100, total: 217.6), 100);
    });

    test('a tender above the bill is clamped to the bill', () {
      // The change handed back is not revenue, and `sales_payment_check` refuses
      // a sale paid beyond its total.
      expect(SaleTotals.recordablePaid(tendered: 500, total: 217.6), 217.6);
      expect(SaleTotals.changeFor(tendered: 500, total: 217.6), 282.4);
    });

    test('nothing recorded and nothing billed is nothing paid', () {
      expect(SaleTotals.recordablePaid(tendered: 0, total: 217.6), 0);
      expect(SaleTotals.recordablePaid(tendered: 500, total: 0), 0);
      expect(SaleTotals.recordablePaid(tendered: -5, total: 217.6), 0);
    });

    test('the change is never negative', () {
      expect(SaleTotals.changeFor(tendered: 100, total: 217.6), 0);
      expect(SaleTotals.changeFor(tendered: 217.6, total: 217.6), 0);
    });
  });
}
