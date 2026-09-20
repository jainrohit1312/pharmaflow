/// Unit tests for [ProductBatch]: the nullable expiry and the generated batch
/// number an opening-stock import produces.
library;

import 'package:app/data/models/product_batch.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `product_batches` row with only the fields a test cares about.
ProductBatch _batch({
  String batchNo = 'B-001',
  DateTime? expiryDate,
  bool isUnknownBatch = false,
}) => ProductBatch(
  id: 'b-1',
  pharmacyId: 'ph-1',
  productId: 'p-1',
  batchNo: batchNo,
  expiryDate: expiryDate,
  isUnknownBatch: isUnknownBatch,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  group('ProductBatch.fromJson', () {
    test('decodes a batch whose expiry was recorded', () {
      final batch = ProductBatch.fromJson(<String, dynamic>{
        'id': 'b-1',
        'pharmacy_id': 'ph-1',
        'product_id': 'p-1',
        'batch_no': 'B-001',
        'expiry_date': '2027-01-01',
        'is_unknown_batch': false,
        'qty': 40,
        'purchase_rate': 10.5,
        'mrp': 20,
        'selling_rate': 18.25,
        'created_at': '2026-09-18T00:00:00.000Z',
        'updated_at': '2026-09-18T00:00:00.000Z',
      });

      expect(batch.expiryDate, DateTime(2027));
      expect(batch.isUnknownBatch, isFalse);
      expect(batch.hasKnownExpiry, isTrue);
      expect(batch.qty, 40);
      expect(batch.purchaseRate, 10.5);
    });

    test('decodes the row a batch with no number and no date produces', () {
      // What the opening stock import writes for the owner's 145 rows with no expiry
      // and 138 with no batch number: a generated `OPENING-<uuid8>` identity, no
      // date at all, and `is_unknown_batch` saying the number was invented
      // (migration 00031). This decode used to throw, which took the whole batch
      // list down with it.
      final batch = ProductBatch.fromJson(<String, dynamic>{
        'id': 'b-2',
        'pharmacy_id': 'ph-1',
        'product_id': 'p-2',
        'batch_no': 'OPENING-40b53500',
        'expiry_date': null,
        'is_unknown_batch': true,
        'qty': 12,
        'created_at': '2026-09-18T00:00:00.000Z',
        'updated_at': '2026-09-18T00:00:00.000Z',
      });

      expect(batch.expiryDate, isNull);
      expect(batch.hasKnownExpiry, isFalse);
      expect(batch.isUnknownBatch, isTrue);
      expect(batch.batchNo, 'OPENING-40b53500');
    });

    test('an absent is_unknown_batch key reads as a real batch number', () {
      final batch = ProductBatch.fromJson(<String, dynamic>{
        'id': 'b-3',
        'pharmacy_id': 'ph-1',
        'product_id': 'p-3',
        'batch_no': 'B-003',
        'expiry_date': '2027-01-01',
        'created_at': '2026-09-18T00:00:00.000Z',
        'updated_at': '2026-09-18T00:00:00.000Z',
      });

      expect(batch.isUnknownBatch, isFalse);
    });
  });

  group('ProductBatchX', () {
    test('hasKnownExpiry follows the date', () {
      expect(_batch(expiryDate: DateTime(2027)).hasKnownExpiry, isTrue);
      expect(_batch().hasKnownExpiry, isFalse);
    });

    test('a batch with no expiry is neither expired nor expiring soon', () {
      // "The source did not say" is not "past its date": reporting an unknown expiry
      // as expired would take real stock off the shelf.
      final unknown = _batch(batchNo: 'OPENING-40b53500', isUnknownBatch: true);

      expect(unknown.isExpired, isFalse);
      expect(unknown.isExpiringSoon, isFalse);
      expect(unknown.daysToExpiry, isNull);
    });

    test('daysToExpiry is negative past the date and positive before it', () {
      final past = _batch(
        expiryDate: DateTime.now().subtract(const Duration(days: 5)),
      );
      final future = _batch(
        expiryDate: DateTime.now().add(const Duration(days: 5)),
      );

      expect(past.isExpired, isTrue);
      expect(past.daysToExpiry, lessThan(0));
      expect(future.daysToExpiry, greaterThan(0));
    });

    test('isExpiringSoon is the ninety-day window, and nothing outside it', () {
      final soon = _batch(
        expiryDate: DateTime.now().add(const Duration(days: 30)),
      );
      final later = _batch(
        expiryDate: DateTime.now().add(const Duration(days: 200)),
      );
      final yesterday = _batch(
        expiryDate: DateTime.now().subtract(const Duration(days: 1)),
      );

      expect(soon.isExpiringSoon, isTrue);
      expect(later.isExpiringSoon, isFalse);
      expect(
        yesterday.isExpiringSoon,
        isFalse,
        reason: 'an expired batch is not "expiring soon" - it is gone',
      );
    });
  });
}
