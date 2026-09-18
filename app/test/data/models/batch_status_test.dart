/// Unit tests for [BatchStatus] decoding, its expiry buckets and its helpers.
library;

import 'package:app/data/models/batch_status.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [BatchStatus].
///
/// [expiryStatus] and [qty] are required rather than defaulted, so every test
/// states the bucket and balance it is actually exercising.
BatchStatus _batch({
  required ExpiryStatus expiryStatus,
  required int qty,
  DateTime? expiryDate,
}) => BatchStatus(
  id: 'b-1',
  pharmacyId: 'ph-1',
  productId: 'p-1',
  batchNo: 'B-001',
  expiryDate: expiryDate ?? DateTime(2030),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  expiryStatus: expiryStatus,
  qty: qty,
);

void main() {
  group('expiryStatusFromDb', () {
    test('maps each literal the view can emit', () {
      expect(expiryStatusFromDb('safe'), ExpiryStatus.safe);
      expect(expiryStatusFromDb('warning'), ExpiryStatus.warning);
      expect(expiryStatusFromDb('critical'), ExpiryStatus.critical);
      expect(expiryStatusFromDb('expired'), ExpiryStatus.expired);
    });

    test('is case and whitespace insensitive', () {
      expect(expiryStatusFromDb(' EXPIRED '), ExpiryStatus.expired);
      expect(expiryStatusFromDb('Critical'), ExpiryStatus.critical);
    });

    test('falls back to safe for null and unknown literals', () {
      expect(expiryStatusFromDb(null), ExpiryStatus.safe);
      expect(expiryStatusFromDb('nonsense'), ExpiryStatus.safe);
    });
  });

  group('ExpiryStatusX', () {
    test('round-trips through its DB literal', () {
      for (final status in ExpiryStatus.values) {
        expect(expiryStatusFromDb(status.dbValue), status);
      }
    });

    test('labels every bucket', () {
      expect(ExpiryStatus.warning.label, 'Expiring soon');
      expect(ExpiryStatus.expired.label, 'Expired');
    });
  });

  group('BatchStatus.fromJson', () {
    test('decodes a snake_case batch_status row including expiry_status', () {
      final batch = BatchStatus.fromJson(<String, dynamic>{
        'id': 'b-1',
        'pharmacy_id': 'ph-1',
        'product_id': 'p-1',
        'batch_no': 'B-001',
        'mfg_date': '2026-01-01',
        'expiry_date': '2027-01-01',
        'qty': 40,
        'purchase_rate': 10.5,
        'mrp': 20,
        'selling_rate': 18.25,
        'expiry_status': 'critical',
        'created_at': '2026-09-18T00:00:00.000Z',
        'updated_at': '2026-09-18T00:00:00.000Z',
      });

      expect(batch.batchNo, 'B-001');
      expect(batch.qty, 40);
      expect(batch.sellingRate, 18.25);
      expect(batch.expiryStatus, ExpiryStatus.critical);
      expect(batch.mfgDate, DateTime(2026));
    });
  });

  group('BatchStatusX', () {
    test('hasStock follows the quantity', () {
      expect(_batch(expiryStatus: ExpiryStatus.safe, qty: 0).hasStock, isFalse);
      expect(_batch(expiryStatus: ExpiryStatus.safe, qty: 1).hasStock, isTrue);
    });

    test('isExpired follows the server-computed bucket', () {
      expect(
        _batch(expiryStatus: ExpiryStatus.expired, qty: 5).isExpired,
        isTrue,
      );
      expect(
        _batch(expiryStatus: ExpiryStatus.critical, qty: 5).isExpired,
        isFalse,
      );
    });

    test('daysToExpiry is negative in the past and positive in the future', () {
      final past = _batch(
        expiryStatus: ExpiryStatus.expired,
        qty: 5,
        expiryDate: DateTime.now().subtract(const Duration(days: 5)),
      );
      final future = _batch(
        expiryStatus: ExpiryStatus.safe,
        qty: 5,
        expiryDate: DateTime.now().add(const Duration(days: 5)),
      );

      expect(past.daysToExpiry, lessThan(0));
      expect(future.daysToExpiry, greaterThan(0));
    });
  });
}
