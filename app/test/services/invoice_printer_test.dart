/// Tests for the printed GST bill.
///
/// The bill is asserted as **content** (`InvoicePrinter.buildSheet`) rather than as
/// a rendered PDF: what a bill says is a tax document's job, and it is the half of
/// the printer that a test can check without a print channel. The layout gets one
/// test of its own - that it builds, and builds a PDF - because everything past
/// that would be a PDF parser's opinion rather than the app's.
///
/// The batch and the expiry on every line come from `sale_document()` (migration
/// 20260920000039) rather than from a join this app does, so the fixtures describe a
/// **document** - a stored line plus the pack it came out of - and the default pack is
/// an **undated** one, because 145 of the owner's opening-stock batches carry no date.
library;

import 'package:app/data/models/pharmacy.dart';
import 'package:app/data/models/sale_item.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/sale_detail_controller.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:app/services/invoice_printer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_sales_repository.dart';

/// The pharmacy the bill is headed with.
Pharmacy _pharmacy() => Pharmacy(
  id: 'ph-1',
  name: 'Sunrise Medicals',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  address: '12 MG Road',
  city: 'Pune',
  state: 'Maharashtra',
  pincode: '411001',
  gstin: '27AAAAA0000A1Z5',
  drugLicenseNo: 'MH-PN-20B-1234',
);

/// The counter bill every test here prints: two units at 100 with 20% off and 12%
/// GST, settled in cash.
///
/// Chosen so the arithmetic is checkable by hand - 200 less 40 is 160 taxable,
/// 19.20 tax, 179.20 due - and so the tax is an *even* number of paise, which is
/// the easy case for the split. `taxTotal` and `item` are parameters for the cases
/// that are not.
///
/// [batchNo], [expiryDate] and [isUnknownBatch] are the line's **pack**, which the
/// document carries beside the stored line. The defaults are a numbered pack with no
/// expiry recorded, which is what most of this catalogue actually holds.
SaleDetailData _bill({
  double taxTotal = 19.2,
  SaleItem? item,
  String batchNo = 'ZZTEST-39-A',
  DateTime? expiryDate,
  bool isUnknownBatch = false,
  double? amountPaid,
  double? balanceDue,
  String? customerId,
  String? patientName,
  String? patientCode,
  double discountTotal = 40,
}) {
  final grandTotal = PurchaseTotals.round2(160 + taxTotal);
  final sale = buildSale(
    invoiceNo: 'INV-7',
    saleDate: DateTime(2026, 9, 18, 14, 5),
    subTotal: 160,
    taxTotal: taxTotal,
    grandTotal: grandTotal,
    amountPaid: amountPaid ?? grandTotal,
    balanceDue: balanceDue ?? 0,
    customerId: customerId,
  ).copyWith(discountTotal: discountTotal, patientName: patientName);

  final stored =
      item ??
      buildSaleItem(
        taxAmount: taxTotal,
        totalAmount: grandTotal,
      ).copyWith(discountPercent: 20);

  return SaleDetailData(
    sale: sale,
    lines: <SaleDocumentLine>[
      buildSaleDocumentLine(
        item: stored,
        batchNo: batchNo,
        expiryDate: expiryDate,
        isUnknownBatch: isUnknownBatch,
      ),
    ],
    productNames: const <String, String>{'product-1': 'Dolo 650'},
    patientCode: patientCode,
  );
}

/// The value printed against [label].
String? _valueOf(InvoiceSheet sheet, String label) {
  for (final row in sheet.totals.followedBy(sheet.payment)) {
    if (row.label == label) {
      return row.value;
    }
  }
  return null;
}

/// The figure printed against [label], as a number.
double? _amountOf(InvoiceSheet sheet, String label) {
  final value = _valueOf(sheet, label);
  if (value == null) {
    return null;
  }
  return double.tryParse(value.replaceAll('Rs ', '').replaceAll(',', ''));
}

/// The labels printed on the bill, in order.
List<String> _labels(InvoiceSheet sheet) => <String>[
  for (final row in sheet.totals) row.label,
];

void main() {
  const printer = InvoicePrinter();

  group('the seller and the document', () {
    test('is headed by the pharmacy and identifies the bill', () {
      final sheet = printer.buildSheet(data: _bill(), pharmacy: _pharmacy());

      expect(sheet.heading, <String>[
        'Sunrise Medicals',
        '12 MG Road, Pune, Maharashtra, 411001',
        'GSTIN 27AAAAA0000A1Z5',
        'D.L. MH-PN-20B-1234',
      ]);
      expect(sheet.title, 'TAX INVOICE');
      expect(sheet.reference, 'Bill INV-7');
      expect(sheet.issuedAt, '18/09/2026 14:05');
      expect(sheet.footer, InvoicePrinter.footerNote);
    });

    test(
      'prints a placeholder rather than nothing when the pharmacy is gone',
      () {
        final sheet = printer.buildSheet(data: _bill(), pharmacy: null);

        // A customer standing at the counter with goods in hand is not the person to
        // tell that a header row could not be read.
        expect(sheet.heading, <String>['Pharmacy']);
        expect(sheet.reference, 'Bill INV-7');
        expect(sheet.lines, hasLength(1));
        expect(_valueOf(sheet, 'TOTAL'), 'Rs 179.20');
      },
    );

    test('leaves out the details the pharmacy has not filled in', () {
      final sheet = printer.buildSheet(
        data: _bill(),
        pharmacy: Pharmacy(
          id: 'ph-1',
          name: 'Sunrise Medicals',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          city: 'Pune',
        ),
      );

      expect(sheet.heading, <String>['Sunrise Medicals', 'Pune']);
    });
  });

  group('the patient', () {
    test('names the patient and the code the pharmacy minted for them', () {
      final sheet = printer.buildSheet(
        data: _bill(patientName: 'Rohit Jain', patientCode: 'PT-00001'),
        pharmacy: _pharmacy(),
      );

      expect(
        sheet.patient,
        'Rohit Jain · PT-00001',
        reason:
            'the code is the one sale_document() joined, and a Drug-Rules bill is '
            'traceable to the person it was dispensed to',
      );
    });

    test('prints a dash when the pharmacy has no code for the party', () {
      final sheet = printer.buildSheet(
        data: _bill(patientName: 'Package patient'),
        pharmacy: _pharmacy(),
      );

      // A package bill's party is the hospital's account row, and a customer
      // registered before Phase 7a has no code until they are first billed (D-079).
      expect(sheet.patient, 'Package patient · ${InvoicePrinter.unknownMark}');
    });

    test('prints no patient line on a sale that names nobody', () {
      final sheet = printer.buildSheet(data: _bill(), pharmacy: _pharmacy());

      expect(
        sheet.patient,
        isNull,
        reason: 'a transfer moves stock; it is not dispensed to anyone',
      );
    });
  });

  group('the lines', () {
    test('names each line, how it was priced, and what it came to', () {
      final sheet = printer.buildSheet(data: _bill(), pharmacy: _pharmacy());

      expect(sheet.lines, hasLength(1));
      final line = sheet.lines.single;
      expect(line.name, 'Dolo 650');
      expect(line.detail, '2 x Rs 100.00 less 20% + 12% GST');
      expect(line.amount, 'Rs 179.20');
    });

    test('prints the pack each line came out of, and when it expires', () {
      final sheet = printer.buildSheet(
        data: _bill(batchNo: 'ZZTEST-39-B', expiryDate: DateTime(2027, 9, 20)),
        pharmacy: _pharmacy(),
      );

      final line = sheet.lines.single;
      expect(
        line.batch,
        'ZZTEST-39-B',
        reason:
            'a number of its own rather than the fixture default, so the assertion '
            'cannot pass by the two agreeing by accident',
      );
      expect(
        line.expiry,
        '09/27',
        reason:
            'a thermal roll has 32 columns, so the month and the year are enough',
      );
    });

    test('prints a dash for a pack whose expiry nobody recorded', () {
      final sheet = printer.buildSheet(data: _bill(), pharmacy: _pharmacy());

      expect(
        sheet.lines.single.expiry,
        InvoicePrinter.unknownMark,
        reason:
            '145 of the opening-stock batches this catalogue holds carry no date, so '
            'an undated pack is the ordinary case - and a plausible-looking date would '
            'be a claim the pharmacy cannot stand behind',
      );
    });

    test('prints a dash for a pack whose number nobody recorded', () {
      final sheet = printer.buildSheet(
        data: _bill(batchNo: '', isUnknownBatch: true),
        pharmacy: _pharmacy(),
      );

      final line = sheet.lines.single;
      expect(line.batch, InvoicePrinter.unknownMark);
      expect(
        line.batch,
        isNot(anyOf(isEmpty, contains('OPENING'))),
        reason: 'never the raw blank, and never an invented batch number',
      );
    });

    test('leaves off the discount and the GST clause when there are none', () {
      final sheet = printer.buildSheet(
        data: _bill(
          taxTotal: 0,
          discountTotal: 0,
          item: buildSaleItem(gstPercent: 0, taxAmount: 0, totalAmount: 200),
        ),
        pharmacy: _pharmacy(),
      );

      expect(sheet.lines.single.detail, '2 x Rs 100.00');
    });

    test('prints a line whose product name was never recorded', () {
      final sheet = printer.buildSheet(
        data: SaleDetailData(
          sale: _bill().sale,
          lines: <SaleDocumentLine>[
            buildSaleDocumentLine(item: buildSaleItem(productId: null)),
          ],
          productNames: const <String, String>{},
        ),
        pharmacy: _pharmacy(),
      );

      expect(sheet.lines.single.name, 'Unnamed product');
    });
  });

  group('the tax heads', () {
    test('splits an intra-state sale into CGST and SGST, half each', () {
      final sheet = printer.buildSheet(data: _bill(), pharmacy: _pharmacy());

      expect(_valueOf(sheet, 'CGST'), 'Rs 9.60');
      expect(_valueOf(sheet, 'SGST'), 'Rs 9.60');
      expect(_valueOf(sheet, 'IGST'), isNull);
    });

    test('charges IGST instead when the supply crosses a state line', () {
      final sheet = printer.buildSheet(
        data: _bill(),
        pharmacy: _pharmacy(),
        split: TaxSplit.interState,
      );

      expect(_valueOf(sheet, 'IGST'), 'Rs 19.20');
      expect(_valueOf(sheet, 'CGST'), isNull);
      expect(_valueOf(sheet, 'SGST'), isNull);
    });

    test('makes the two halves add up to the tax the bill charged', () {
      // An odd number of paise has no exact half, and rounding both halves of the
      // total separately printed heads that summed to 19.22 on a bill whose tax was
      // 19.21 - the bill disagreeing with itself by a paisa.
      final data = _bill(taxTotal: 19.21);
      final sheet = printer.buildSheet(data: data, pharmacy: _pharmacy());

      expect(_valueOf(sheet, 'CGST'), 'Rs 9.61');
      expect(_valueOf(sheet, 'SGST'), 'Rs 9.60');
      expect(
        _amountOf(sheet, 'CGST')! + _amountOf(sheet, 'SGST')!,
        closeTo(data.sale.taxTotal, 0.0001),
        reason: 'whatever the split, the heads are the tax that was charged',
      );
    });

    test('shows the discount only when the sale had one', () {
      final withDiscount = printer.buildSheet(
        data: _bill(),
        pharmacy: _pharmacy(),
      );
      expect(_valueOf(withDiscount, 'Discount'), '-Rs 40.00');

      final without = printer.buildSheet(
        data: _bill(discountTotal: 0),
        pharmacy: _pharmacy(),
      );
      expect(_valueOf(without, 'Discount'), isNull);
    });

    test('sets the total apart and puts it last', () {
      final sheet = printer.buildSheet(data: _bill(), pharmacy: _pharmacy());

      expect(_labels(sheet).last, 'TOTAL');
      final total = sheet.totals.last;
      expect(total.value, 'Rs 179.20');
      expect(total.emphasis, isTrue);
      expect(total.ruleAbove, isTrue);
      expect(
        sheet.totals.take(sheet.totals.length - 1).map((row) => row.ruleAbove),
        everyElement(isNull),
        reason: 'the rule above the total is the only one',
      );
      expect(_valueOf(sheet, 'Taxable value'), 'Rs 160.00');
    });
  });

  group('how it was settled', () {
    test('names the mode and what was paid', () {
      final sheet = printer.buildSheet(data: _bill(), pharmacy: _pharmacy());

      expect(_valueOf(sheet, 'Cash'), 'Rs 179.20');
      expect(_valueOf(sheet, 'Balance due'), isNull);
    });

    test('shows what is still owed on a part payment', () {
      final sheet = printer.buildSheet(
        data: _bill(amountPaid: 100, balanceDue: 79.2),
        pharmacy: _pharmacy(),
      );

      expect(_valueOf(sheet, 'Cash'), 'Rs 100.00');
      expect(_valueOf(sheet, 'Balance due'), 'Rs 79.20');
    });

    test(
      'says a credit sale is on account rather than naming the customer',
      () {
        final sheet = printer.buildSheet(
          data: _bill(customerId: 'customer-1'),
          pharmacy: _pharmacy(),
        );

        expect(_valueOf(sheet, 'Customer'), 'account sale');
      },
    );

    test('names no customer on a cash sale', () {
      final sheet = printer.buildSheet(data: _bill(), pharmacy: _pharmacy());

      expect(_valueOf(sheet, 'Customer'), isNull);
    });
  });

  group('the layout', () {
    test('draws the sheet as a PDF', () async {
      final document = printer.buildDocument(
        data: _bill(),
        pharmacy: _pharmacy(),
      );

      final bytes = await document.save();
      expect(bytes, isNotEmpty);
      // The one thing about the output worth pinning without a PDF parser: it is
      // the format the print sheet and the browser flow both expect.
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('draws a bill whose pharmacy could not be read', () async {
      final document = printer.buildDocument(data: _bill(), pharmacy: null);

      expect(await document.save(), isNotEmpty);
    });

    test('draws the dash a pack with no number or date prints', () async {
      // The em dash is not ASCII, and the built-in PDF fonts are why this printer
      // spells money `Rs` rather than printing the rupee sign - so the one thing worth
      // proving here is that a bill which *has* to print a dash still draws. That is
      // the ordinary bill at this counter, not an edge case.
      final document = printer.buildDocument(
        data: _bill(batchNo: '', isUnknownBatch: true),
        pharmacy: _pharmacy(),
      );

      expect(await document.save(), isNotEmpty);
    });
  });
}
