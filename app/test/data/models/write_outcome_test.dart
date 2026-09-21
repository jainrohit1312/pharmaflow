/// Unit tests for the envelope a gated write answers with.
///
/// The two shapes are the whole contract between a `record_*()` function and the screen that
/// called it: one says a document exists, the other says the owner has to answer first. Getting
/// them the wrong way round would send a screen to open a document that is not there.
library;

import 'package:app/data/models/purchase_return.dart';
import 'package:app/data/models/write_outcome.dart';
import 'package:flutter_test/flutter_test.dart';

/// A row shaped like the one `record_purchase_return()` answers with.
Map<String, dynamic> _row() => <String, dynamic>{
  'id': 'return-1',
  'pharmacy_id': 'ph-1',
  'purchase_id': 'purchase-1',
  'supplier_id': 'sup-1',
  'return_date': '2026-09-21',
  'sub_total': 800,
  'tax_total': 96,
  'grand_total': 896,
  'status': 'completed',
  'created_at': '2026-09-21T10:00:00Z',
  'updated_at': '2026-09-21T10:00:00Z',
};

void main() {
  group('WriteOutcome', () {
    test('a recorded write carries the document it wrote', () {
      final outcome = WriteOutcome.fromJson(<String, dynamic>{
        'outcome': 'recorded',
        'document': _row(),
        'request_id': null,
      }, PurchaseReturn.fromJson);

      expect(outcome.isStaged, isFalse);
      expect(outcome.requestId, isNull);
      expect(outcome.document, isA<PurchaseReturn>());
      expect(
        outcome.document!.grandTotal,
        896,
        reason: 'the document is decoded, not handed over raw',
      );
    });

    test('a staged write carries the ask, and no document', () {
      final outcome = WriteOutcome.fromJson(<String, dynamic>{
        'outcome': 'staged',
        'document': null,
        'request_id': '4a2f0b7c-0000-0000-0000-000000000001',
      }, PurchaseReturn.fromJson);

      expect(outcome.isStaged, isTrue);
      expect(outcome.document, isNull);
      expect(outcome.requestId, '4a2f0b7c-0000-0000-0000-000000000001');
    });

    test('the decoder is never asked to decode a staged write', () {
      var calls = 0;

      WriteOutcome.fromJson(
        <String, dynamic>{
          'outcome': 'staged',
          'document': null,
          'request_id': 'ask-1',
        },
        (json) {
          calls++;
          return PurchaseReturn.fromJson(json);
        },
      );

      expect(
        calls,
        0,
        reason: 'a staged write has no document, so nothing has to be invented',
      );
    });

    test('the named constructors are the two outcomes the server can send', () {
      expect(const WriteOutcome<int>.staged('ask-1').isStaged, isTrue);
      expect(const WriteOutcome<int>.recorded(7).isStaged, isFalse);
      expect(const WriteOutcome<int>.recorded(7).document, 7);
    });
  });
}
