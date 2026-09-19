/// Tests for the two alert RPCs' payloads.
///
/// Both answers are a `jsonb` array, so the decoders have one job each: read the
/// figures the screen shows, and refuse to invent anything. The cases worth
/// asserting are the ones where a naive read would be wrong rather than missing -
/// a number that arrives as a string or a double, and `days_left` being negative
/// for a batch that has already gone off.
library;

import 'package:app/data/models/alert_payloads.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('lowStockProductsFrom', () {
    test('reads the figures, in the order the RPC ranked them', () {
      final products = lowStockProductsFrom(<dynamic>[
        <String, dynamic>{
          'product_id': 'p-1',
          'name': 'Dolo 650',
          'generic_name': 'Paracetamol',
          'pack_size': '15s',
          'total_qty': 6,
          'min_stock_level': 10,
          'shortfall': 4,
        },
        <String, dynamic>{
          'product_id': 'p-2',
          'name': 'Amoxyclav 625',
          'generic_name': null,
          'pack_size': null,
          'total_qty': 0,
          'min_stock_level': 5,
          'shortfall': 5,
        },
      ]);

      expect(products, hasLength(2));
      expect(products.first.productId, 'p-1');
      expect(products.first.name, 'Dolo 650');
      expect(products.first.genericName, 'Paracetamol');
      expect(products.first.packSize, '15s');
      expect(products.first.totalQty, 6);
      expect(products.first.minStockLevel, 10);
      expect(products.first.shortfall, 4);
      // Second, so the RPC's own order is preserved rather than re-sorted here: the
      // ranking is the server's (worst first), and a client that sorted again would
      // be a second opinion nobody asked for.
      expect(products.last.productId, 'p-2');
      expect(products.last.genericName, isNull);
      expect(products.last.packSize, isNull);
      expect(products.last.totalQty, 0);
    });

    test('reads a number that arrives as a double or a numeric string', () {
      final products = lowStockProductsFrom(<dynamic>[
        <String, dynamic>{
          'product_id': 'p-1',
          'name': 'Dolo 650',
          'total_qty': '6',
          'min_stock_level': 10.0,
          'shortfall': '4',
        },
      ]);

      expect(products.single.totalQty, 6);
      expect(products.single.minStockLevel, 10);
      expect(products.single.shortfall, 4);
    });

    test('a missing figure is zero rather than a crash', () {
      final products = lowStockProductsFrom(<dynamic>[
        <String, dynamic>{'product_id': 'p-1', 'name': 'Dolo 650'},
      ]);

      expect(products.single.totalQty, 0);
      expect(products.single.minStockLevel, 0);
      expect(products.single.shortfall, 0);
    });

    test('an answer that is not a list reads as nothing at all', () {
      expect(lowStockProductsFrom(null), isEmpty);
      expect(lowStockProductsFrom(<String, dynamic>{}), isEmpty);
      expect(lowStockProductsFrom('[]'), isEmpty);
    });

    test('an entry that is not an object is skipped, not guessed at', () {
      final products = lowStockProductsFrom(<dynamic>[
        42,
        <String, dynamic>{'product_id': 'p-1', 'name': 'Dolo 650'},
        'Dolo 650',
      ]);

      expect(products, hasLength(1));
      expect(products.single.productId, 'p-1');
    });

    test(
      'an empty answer is an empty list, which is the honest "nothing is low"',
      () {
        expect(lowStockProductsFrom(<dynamic>[]), isEmpty);
      },
    );
  });

  group('expiringBatchesFrom', () {
    test(
      'reads the figures, and a negative days_left is how long it has been gone',
      () {
        final batches = expiringBatchesFrom(<dynamic>[
          <String, dynamic>{
            'batch_id': 'b-1',
            'product_id': 'p-1',
            'product_name': 'Dolo 650',
            'pack_size': '15s',
            'batch_no': 'A-EXPIRED',
            'expiry_date': '2026-09-18',
            'days_left': -1,
            'qty': 2,
          },
          <String, dynamic>{
            'batch_id': 'b-2',
            'product_id': 'p-2',
            'product_name': 'Amoxyclav 625',
            'pack_size': null,
            'batch_no': 'B-1',
            'expiry_date': '2026-09-24',
            'days_left': 5,
            'qty': 4,
          },
        ]);

        expect(batches, hasLength(2));
        expect(batches.first.batchId, 'b-1');
        expect(batches.first.productName, 'Dolo 650');
        expect(batches.first.batchNo, 'A-EXPIRED');
        expect(batches.first.expiryDate, DateTime(2026, 9, 18));
        expect(batches.first.daysLeft, -1);
        expect(batches.first.qty, 2);
        // Already expired, which is what the screen colours and what the sentence
        // "expired 1 day ago" is built from.
        expect(batches.first.isExpired, isTrue);
        expect(batches.last.isExpired, isFalse);
        expect(batches.last.packSize, isNull);
      },
    );

    test('the day it expires is a date, not a timestamp', () {
      final batches = expiringBatchesFrom(<dynamic>[
        <String, dynamic>{
          'batch_id': 'b-1',
          'product_id': 'p-1',
          'product_name': 'Dolo 650',
          'batch_no': 'A-1',
          'expiry_date': '2026-09-24',
          'days_left': 5,
          'qty': 4,
        },
      ]);

      expect(batches.single.expiryDate, DateTime(2026, 9, 24));
      expect(batches.single.expiryDate.isUtc, isFalse);
    });

    test('an answer that is not a list reads as nothing at all', () {
      expect(expiringBatchesFrom(null), isEmpty);
      expect(expiringBatchesFrom(<String, dynamic>{}), isEmpty);
    });

    test(
      'an empty answer is an empty list, which is the honest "nothing is expiring"',
      () {
        expect(expiringBatchesFrom(<dynamic>[]), isEmpty);
      },
    );
  });
}
