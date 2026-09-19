/// Unit tests for the bill reader's envelope decode.
///
/// The fixture is the body the deployed function actually returned (Chunk B1's
/// live verification), trimmed to two lines — so these tests are pinned to the
/// wire format rather than to what the Dart side wishes it were.
library;

import 'package:app/data/models/ocr_purchase_bill.dart';
import 'package:flutter_test/flutter_test.dart';

/// The function's 200 body, as observed.
Map<String, dynamic> _liveBody() => <String, dynamic>{
  'document': <String, dynamic>{
    'supplier_name': 'ARIHANT DISTRIBUTORS',
    'gstin': '27ABCDE1234F1Z5',
    'invoice_no': 'INV-2026-0042',
    'invoice_date': '2026-09-18',
    'sub_total': 2420,
    'tax_total': 264.5,
    'grand_total': 2684.5,
  },
  'lines': <dynamic>[
    <String, dynamic>{
      'raw_name': 'Dolo 650 Tab 15s',
      'qty': 10,
      'free_qty': 1,
      'rate': 100,
      'mrp': 150,
      'gst_percent': 12,
      'batch_no': 'D650-A21',
      'expiry_date': '2027-06-30',
      'hsn_code': '3004',
      'confidence': 0.95,
    },
    <String, dynamic>{
      'raw_name': 'Cetirizine 10mg 10s',
      'qty': 20,
      'free_qty': 2,
      'rate': 18.5,
      'mrp': 30,
      'gst_percent': 5,
      'batch_no': 'CZ10-C3',
      'expiry_date': '2027-02-28',
      'hsn_code': '3004',
      'confidence': 0.4,
    },
  ],
  'meta': <String, dynamic>{
    'model': 'gemini-3.6-flash',
    'warnings': <dynamic>[],
    'image_path': 'ph-1/2026/bill-1.pdf',
    'finish_reason': 'STOP',
  },
};

void main() {
  group('OcrPurchaseBill.fromJson', () {
    test('decodes the body the function actually returns', () {
      final bill = OcrPurchaseBill.fromJson(_liveBody());

      expect(bill.document.supplierName, 'ARIHANT DISTRIBUTORS');
      expect(bill.document.gstin, '27ABCDE1234F1Z5');
      expect(bill.document.invoiceNo, 'INV-2026-0042');
      expect(bill.document.invoiceDate, DateTime(2026, 9, 18));
      expect(bill.document.subTotal, 2420);
      expect(bill.document.taxTotal, 264.5);
      expect(bill.document.grandTotal, 2684.5);

      expect(bill.lines, hasLength(2));
      expect(bill.lines.first.rawName, 'Dolo 650 Tab 15s');
      expect(bill.lines.first.qty, 10);
      expect(bill.lines.first.freeQty, 1);
      expect(bill.lines.first.expiryDate, DateTime(2027, 6, 30));
      expect(bill.lines.first.hsnCode, '3004');

      expect(bill.meta.model, 'gemini-3.6-flash');
      expect(bill.meta.warnings, isEmpty);
      expect(bill.meta.imagePath, 'ph-1/2026/bill-1.pdf');
      expect(bill.meta.finishReason, 'STOP');
      expect(bill.meta.isTruncated, isFalse);
      expect(bill.isEmpty, isFalse);
    });

    test('reads a number that arrived as text', () {
      final bill = OcrPurchaseBill.fromJson(<String, dynamic>{
        'document': <String, dynamic>{'grand_total': '2,684.50'},
        'lines': <dynamic>[
          <String, dynamic>{'raw_name': 'Dolo 650', 'qty': '10', 'rate': '100'},
        ],
      });

      expect(bill.document.grandTotal, 2684.5);
      expect(bill.lines.single.qty, 10);
      expect(bill.lines.single.rate, 100);
    });

    test('an Indian thousands separator is not read as a decimal point', () {
      final bill = OcrPurchaseBill.fromJson(<String, dynamic>{
        'document': <String, dynamic>{
          'sub_total': '1,25,000',
          'tax_total': 'Rs 1,25.50',
        },
      });

      expect(bill.document.subTotal, 125000);
      expect(bill.document.taxTotal, 125.5);
    });

    test('a field the reader could not read stays null, never zero', () {
      final bill = OcrPurchaseBill.fromJson(<String, dynamic>{
        'document': <String, dynamic>{
          'supplier_name': null,
          'invoice_no': '  ',
        },
        'lines': <dynamic>[
          <String, dynamic>{'raw_name': 'Dolo 650', 'qty': null, 'rate': null},
        ],
      });

      expect(bill.document.supplierName, isNull);
      expect(bill.document.invoiceNo, isNull, reason: 'blank text is no text');
      expect(bill.lines.single.qty, isNull);
      expect(bill.lines.single.rate, isNull);
    });

    test('an unreadable date is null rather than a guess', () {
      final bill = OcrPurchaseBill.fromJson(<String, dynamic>{
        'document': <String, dynamic>{'invoice_date': 'sometime in September'},
        'lines': <dynamic>[
          <String, dynamic>{'raw_name': 'Dolo', 'expiry_date': '30/06/2027'},
        ],
      });

      expect(bill.document.invoiceDate, isNull);
      expect(bill.lines.single.expiryDate, isNull);
    });

    test('junk where the parts should be does not throw', () {
      final bill = OcrPurchaseBill.fromJson(<String, dynamic>{
        'document': 'see attached',
        'lines': 'two of them',
        'meta': 7,
      });

      expect(bill.document.invoiceNo, isNull);
      expect(bill.lines, isEmpty);
      expect(bill.meta.warnings, isEmpty);
      expect(bill.isEmpty, isTrue);
    });

    test('junk entries inside lines are skipped, not fatal', () {
      final bill = OcrPurchaseBill.fromJson(<String, dynamic>{
        'lines': <dynamic>[
          null,
          'Dolo 650',
          <String, dynamic>{'raw_name': 'Amoxyclav 625'},
        ],
      });

      expect(bill.lines, hasLength(1));
      expect(bill.lines.single.rawName, 'Amoxyclav 625');
    });

    test('warnings are read as sentences, and non-text ones dropped', () {
      final bill = OcrPurchaseBill.fromJson(<String, dynamic>{
        'meta': <String, dynamic>{
          'warnings': <dynamic>[
            'No invoice number was read from the bill.',
            null,
            12,
            '   ',
          ],
          'finish_reason': 'MAX_TOKENS',
        },
      });

      expect(bill.meta.warnings, <String>[
        'No invoice number was read from the bill.',
      ]);
      expect(bill.meta.isTruncated, isTrue);
    });
  });

  group('OcrLine', () {
    test('is unsure about a line the reader was not confident in', () {
      final bill = OcrPurchaseBill.fromJson(_liveBody());

      expect(bill.lines.first.isUnsure, isFalse);
      expect(bill.lines.last.isUnsure, isTrue);
    });

    test('a line with no confidence is not treated as unsure', () {
      const line = OcrLine(rawName: 'Dolo 650');

      expect(line.confidence, isNull);
      expect(line.isUnsure, isFalse);
    });
  });

  group('OcrPurchaseBill.toLineDrafts', () {
    test('carries what was read into the draft the purchase form uses', () {
      final drafts = OcrPurchaseBill.fromJson(_liveBody()).toLineDrafts();

      expect(drafts, hasLength(2));
      expect(drafts.first.qty, 10);
      expect(drafts.first.purchaseRate, 100);
      expect(drafts.first.mrp, 150);
      expect(drafts.first.freeQty, 1);
      expect(drafts.first.gstPercent, 12);
      expect(drafts.first.productNameRaw, 'Dolo 650 Tab 15s');
      expect(drafts.first.batchNo, 'D650-A21');
      expect(drafts.first.expiryDate, DateTime(2027, 6, 30));
      expect(drafts.first.hsnCode, '3004');
    });

    test('leaves the product for a human to pick', () {
      final drafts = OcrPurchaseBill.fromJson(_liveBody()).toLineDrafts();

      for (final draft in drafts) {
        expect(draft.productId, isNull, reason: 'matching is Chunk C');
      }
    });

    test('a quantity the reader missed becomes 0, so the form refuses it', () {
      final drafts = OcrPurchaseBill.fromJson(<String, dynamic>{
        'lines': <dynamic>[
          <String, dynamic>{
            'raw_name': 'Dolo 650',
            'qty': null,
            'gst_percent': null,
          },
        ],
      }).toLineDrafts();

      expect(drafts.single.qty, 0);
      expect(drafts.single.gstPercent, defaultOcrGstPercent);
    });
  });
}
