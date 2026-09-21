/// Unit tests for the payload `save_purchase()` is handed.
///
/// The whole document is written by one server-side function now, so this payload is the
/// contract between the app and it - and two of its properties are the kind that fail
/// silently if nobody asserts them: a document's money travels as the invoice had it
/// rather than being re-derived, and a cancellation carries nothing but the id.
library;

import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/features/purchase/data/purchase_payload.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:flutter_test/flutter_test.dart';

/// A form line on the 12% slab: 10 at 100, no discount - 1,000 taxable and 120 tax.
PurchaseLineDraft _line({
  int qty = 10,
  double rate = 100,
  double gstPercent = 12,
  String batchNo = 'B-1',
}) => PurchaseLineDraft(
  qty: qty,
  purchaseRate: rate,
  mrp: 150,
  gstPercent: gstPercent,
  productId: 'product-1',
  productNameRaw: 'Dolo 650',
  batchNo: batchNo,
  expiryDate: DateTime(2027, 9, 21),
);

/// A stored line, whose own columns are what a re-save has to copy.
PurchaseItem _storedItem({
  int qty = 10,
  double taxAmount = 120,
  double totalAmount = 1120,
}) => PurchaseItem(
  id: 'item-1',
  pharmacyId: 'ph-1',
  purchaseId: 'purchase-1',
  qty: qty,
  purchaseRate: 100,
  mrp: 150,
  gstPercent: 12,
  cgstAmount: 60,
  sgstAmount: 60,
  taxAmount: taxAmount,
  totalAmount: totalAmount,
  productId: 'product-1',
  productNameRaw: 'Dolo 650',
  batchNo: 'B-1',
  expiryDate: DateTime(2027, 9, 21),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// A stored document whose own grand total is what the ledger posts.
Purchase _storedDocument({
  double subTotal = 1000,
  double taxTotal = 120,
  double grandTotal = 1120,
}) => Purchase(
  id: 'purchase-1',
  pharmacyId: 'ph-1',
  supplierId: 'sup-1',
  invoiceNo: 'INV-1',
  invoiceDate: DateTime(2026, 9, 21),
  notes: 'as ordered',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: PurchaseStatus.ordered,
  subTotal: subTotal,
  taxTotal: taxTotal,
  grandTotal: grandTotal,
);

void main() {
  group('PurchasePayload.save', () {
    test(
      'names the document it is saving, or is a create when it does not',
      () {
        final created = PurchasePayload.save(
          draft: PurchaseDraft(
            supplierId: 'sup-1',
            invoiceNo: ' INV-1 ',
            invoiceDate: DateTime(2026, 9, 21),
          ),
          lines: <PurchaseLineDraft>[_line()],
          split: TaxSplit.intraState,
          totals: PurchaseTotals.forLines(<PurchaseLineDraft>[
            _line(),
          ], split: TaxSplit.intraState),
          status: PurchaseStatus.draft,
        );

        expect(created['purchase_id'], isNull);
        expect(created['status'], 'draft');
        expect(
          created['invoice_no'],
          'INV-1',
          reason:
              'the number is trimmed here rather than stored with its spaces',
        );
        expect(created['invoice_date'], '2026-09-21');
      },
    );

    test('sends the figures the form worked out, per line and per document', () {
      final lines = <PurchaseLineDraft>[_line()];
      final payload = PurchasePayload.save(
        draft: PurchaseDraft(
          supplierId: 'sup-1',
          invoiceNo: 'INV-1',
          invoiceDate: DateTime(2026, 9, 21),
        ),
        lines: lines,
        split: TaxSplit.intraState,
        totals: PurchaseTotals.forLines(lines, split: TaxSplit.intraState),
        status: PurchaseStatus.received,
      );

      // 10 x 100 at 12% intra-state: 1,000 + 60 + 60, and the four tax columns the
      // receipt stores come from the same split the form previewed.
      expect(payload['sub_total'], 1000);
      expect(payload['tax_total'], 120);
      expect(payload['grand_total'], 1120);
      expect(payload['status'], 'received');

      final item =
          (payload['items']! as List<dynamic>).single as Map<String, dynamic>;
      expect(item['qty'], 10);
      expect(item['purchase_rate'], 100);
      expect(item['gst_percent'], 12);
      expect(item['cgst_amount'], 60);
      expect(item['sgst_amount'], 60);
      expect(item['igst_amount'], 0);
      expect(item['tax_amount'], 120);
      expect(item['total_amount'], 1120);
      expect(
        item['batch_no'],
        'B-1',
        reason: 'a receipt line carries the batch it will be booked into',
      );
    });

    test('an inter-state supply puts the whole tax on IGST', () {
      final lines = <PurchaseLineDraft>[_line()];
      final payload = PurchasePayload.save(
        draft: PurchaseDraft(
          supplierId: 'sup-1',
          invoiceNo: 'INV-1',
          invoiceDate: DateTime(2026, 9, 21),
        ),
        lines: lines,
        split: TaxSplit.interState,
        totals: PurchaseTotals.forLines(lines, split: TaxSplit.interState),
        status: PurchaseStatus.draft,
      );

      final item =
          (payload['items']! as List<dynamic>).single as Map<String, dynamic>;
      expect(item['igst_amount'], 120);
      expect(item['cgst_amount'], 0);
      expect(item['sgst_amount'], 0);
    });
  });

  group('PurchasePayload.saveStored', () {
    test('copies the stored columns rather than deriving them again', () {
      // A grand total that the lines would NOT produce: the property being asserted is
      // that a status change re-sends the figure the ledger holds, so the fixture is one
      // where re-deriving would visibly disagree.
      final payload = PurchasePayload.saveStored(
        purchase: _storedDocument(grandTotal: 1234.56),
        items: <PurchaseItem>[_storedItem(totalAmount: 1234.56)],
        status: PurchaseStatus.ordered,
      );

      expect(payload['grand_total'], 1234.56);
      expect(payload['sub_total'], 1000);
      expect(payload['status'], 'ordered');
      expect(payload['purchase_id'], 'purchase-1');
      expect(payload['notes'], 'as ordered');

      final item =
          (payload['items']! as List<dynamic>).single as Map<String, dynamic>;
      expect(item['total_amount'], 1234.56);
      expect(item['tax_amount'], 120);
      expect(
        item['mfg_date'],
        isNull,
        reason:
            'purchase_items has no manufacture date - that belongs to the batch',
      );
    });

    test('stages the status the move is asking for', () {
      final payload = PurchasePayload.saveStored(
        purchase: _storedDocument(),
        items: <PurchaseItem>[_storedItem()],
        status: PurchaseStatus.pendingApproval,
      );

      // Never sent as a save: the server stages by role, not because a client asked it to.
      expect(payload['status'], 'pending_approval');
    });
  });

  group('PurchasePayload.cancel', () {
    test('carries the id and nothing else', () {
      final payload = PurchasePayload.cancel(purchaseId: 'purchase-1');

      expect(payload, hasLength(3));
      expect(payload['purchase_id'], 'purchase-1');
      expect(payload['status'], 'cancelled');
      expect(
        payload.containsKey('items'),
        isFalse,
        reason:
            'a cancellation is not an edit: the server moves the status and '
            'touches nothing else, so sending it lines would describe work that '
            'is not being done',
      );
    });

    test('passes the idempotency key when one is given', () {
      final payload = PurchasePayload.cancel(
        purchaseId: 'purchase-1',
        idempotencyKey: 'key-1',
      );

      expect(payload['idempotency_key'], 'key-1');
    });
  });
}
