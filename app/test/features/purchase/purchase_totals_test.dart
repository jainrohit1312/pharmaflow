/// Tests for [PurchaseTotals].
///
/// These pin the two properties that matter downstream: the stored document
/// totals always equal the sum of the stored lines, and the tax split always
/// adds back to the tax. Both feed the ledger, where a discrepancy is not
/// recoverable by editing anything.
library;

import 'package:app/data/models/purchase_draft.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:flutter_test/flutter_test.dart';

/// A line with only the fields a total depends on.
PurchaseLineDraft _line({
  int qty = 10,
  double rate = 100,
  int freeQty = 0,
  double discountPercent = 0,
  double gstPercent = 0,
}) => PurchaseLineDraft(
  qty: qty,
  purchaseRate: rate,
  mrp: rate * 1.5,
  freeQty: freeQty,
  discountPercent: discountPercent,
  gstPercent: gstPercent,
  productId: 'p-1',
  productNameRaw: 'Paracetamol 500mg',
  batchNo: 'B-1',
  expiryDate: DateTime(2027),
);

void main() {
  group('line totals', () {
    test('are gross value when there is no discount and no tax', () {
      final totals = PurchaseTotals.forLine(
        _line(),
        split: TaxSplit.intraState,
      );

      expect(totals.taxable, 1000);
      expect(totals.discount, 0);
      expect(totals.tax, 0);
      expect(totals.total, 1000);
    });

    test('take the discount off before tax, not after', () {
      final totals = PurchaseTotals.forLine(
        _line(discountPercent: 10, gstPercent: 12),
        split: TaxSplit.intraState,
      );

      expect(totals.discount, 100);
      expect(totals.taxable, 900);
      expect(totals.tax, 108, reason: '12% of the discounted value');
      expect(totals.total, 1008);
    });

    test('include no more than the schema does', () {
      final totals = PurchaseTotals.forLine(
        _line(rate: 33.73, gstPercent: 5),
        split: TaxSplit.intraState,
      );

      expect(totals.taxable, 337.3);
      expect(totals.tax, 16.87, reason: '5% of 337.30 is 16.865, half up');
      expect(totals.total, 354.17);
    });
  });

  group('tax split', () {
    test('splits CGST and SGST evenly within a state', () {
      final totals = PurchaseTotals.forLine(
        _line(gstPercent: 12),
        split: TaxSplit.intraState,
      );

      expect(totals.cgst, 60);
      expect(totals.sgst, 60);
      expect(totals.igst, 0);
    });

    test('puts everything in IGST across states', () {
      final totals = PurchaseTotals.forLine(
        _line(gstPercent: 12),
        split: TaxSplit.interState,
      );

      expect(totals.cgst, 0);
      expect(totals.sgst, 0);
      expect(totals.igst, 120);
    });

    test('the halves always add back to the tax, odd paisa included', () {
      for (final gstPercent in <double>[0.25, 5, 12, 18]) {
        final totals = PurchaseTotals.forLine(
          _line(qty: 1, rate: 1, gstPercent: gstPercent),
          split: TaxSplit.intraState,
        );

        expect(
          totals.cgst + totals.sgst,
          closeTo(totals.tax, 0.001),
          reason: 'CGST + SGST must equal the tax at $gstPercent%',
        );
      }
    });

    test('an unknown state is treated as intra-state', () {
      expect(
        PurchaseTotals.splitFor(pharmacyState: null, supplierState: 'MH'),
        TaxSplit.intraState,
      );
      expect(
        PurchaseTotals.splitFor(pharmacyState: 'MH', supplierState: '  '),
        TaxSplit.intraState,
      );
    });

    test('differing states are inter-state, case and spacing aside', () {
      expect(
        PurchaseTotals.splitFor(
          pharmacyState: 'Maharashtra',
          supplierState: 'Gujarat',
        ),
        TaxSplit.interState,
      );
      expect(
        PurchaseTotals.splitFor(pharmacyState: ' mh ', supplierState: 'MH'),
        TaxSplit.intraState,
      );
    });
  });

  group('document totals', () {
    test('are the sum of the rounded lines', () {
      final lines = <PurchaseLineDraft>[
        _line(qty: 3, rate: 33.73, gstPercent: 5),
        _line(qty: 7, rate: 12.5, discountPercent: 5, gstPercent: 12),
      ];

      final totals = PurchaseTotals.forLines(lines, split: TaxSplit.intraState);
      final lineValues = lines
          .map(
            (line) => PurchaseTotals.forLine(line, split: TaxSplit.intraState),
          )
          .toList();

      expect(
        totals.subTotal,
        closeTo(lineValues.fold(0.0, (sum, line) => sum + line.taxable), 0.001),
      );
      expect(
        totals.grandTotal,
        closeTo(lineValues.fold(0.0, (sum, line) => sum + line.total), 0.001),
      );
    });

    test('grand total is the taxable value plus the tax', () {
      final totals = PurchaseTotals.forLines(<PurchaseLineDraft>[
        _line(discountPercent: 7, gstPercent: 18),
      ], split: TaxSplit.intraState);

      expect(
        totals.grandTotal,
        closeTo(totals.subTotal + totals.taxTotal, 0.001),
      );
    });

    test('an empty document totals zero', () {
      final totals = PurchaseTotals.forLines(
        const <PurchaseLineDraft>[],
        split: TaxSplit.intraState,
      );

      expect(totals.subTotal, 0);
      expect(totals.taxTotal, 0);
      expect(totals.grandTotal, 0);
    });
  });

  group('rounding', () {
    test('rounds half away from zero, as Postgres numeric does', () {
      // 3 x 33.335 is 100.005, which a naive round() takes down to 100.00
      // because the double nearest to it is slightly smaller.
      final totals = PurchaseTotals.forLine(
        _line(qty: 3, rate: 33.335),
        split: TaxSplit.intraState,
      );

      expect(totals.taxable, 100.01);
    });
  });
}
