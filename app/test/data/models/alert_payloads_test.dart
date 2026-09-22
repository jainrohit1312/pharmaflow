/// Tests for the two alert RPCs' envelopes.
///
/// Both answers are `{meta, rows}` (migration 20260922000050), so the decoders have two jobs:
/// read the figures a screen shows out of `rows`, and read the totals the report stated about
/// the whole set out of `meta`. The cases worth asserting are the ones where a naive read
/// would be wrong rather than missing - a number that arrives as a string or a double,
/// `days_left` being negative for a batch that has already gone off, a page that is short of
/// the set, and every way an envelope can be unreadable (the one direction where silence would
/// read as "nothing is low").
library;

import 'package:app/data/models/alert_payloads.dart';
import 'package:flutter_test/flutter_test.dart';

/// One `{meta, rows}` answer, with the counts a test does not care about defaulted.
Map<String, dynamic> envelope(
  List<dynamic> rows, {
  int? totalCount,
  int? returnedCount,
  bool? hasMore,
  Map<String, dynamic> meta = const <String, dynamic>{},
}) {
  final returned = returnedCount ?? rows.length;
  final total = totalCount ?? returned;
  return <String, dynamic>{
    'meta': <String, dynamic>{
      'rule': 'total_qty < min_stock_level',
      'as_of': '2026-09-22',
      'timezone': 'Asia/Kolkata',
      'limit': 50,
      'total_count': total,
      'returned_count': returned,
      'has_more': hasMore ?? total > returned,
      ...meta,
    },
    'rows': rows,
  };
}

void main() {
  group('lowStockPageFrom', () {
    test('reads the figures, in the order the RPC ranked them', () {
      final page = lowStockPageFrom(
        envelope(<dynamic>[
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
        ]),
      );

      expect(page, isNotNull);
      final products = page!.rows;
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

    test("reads the whole set's size, not just the page's", () {
      // The point of the envelope: 2 rows of 120 is a page, and a caller can say so.
      final page = lowStockPageFrom(
        envelope(<dynamic>[
          <String, dynamic>{'product_id': 'p-1', 'name': 'Dolo 650'},
        ], totalCount: 120),
      );

      expect(page, isNotNull);
      expect(page!.returnedCount, 1);
      expect(page.totalCount, 120);
      expect(page.hasMore, isTrue);
    });

    test('a page that is the whole set does not claim there is more', () {
      final page = lowStockPageFrom(
        envelope(<dynamic>[
          <String, dynamic>{'product_id': 'p-1', 'name': 'Dolo 650'},
        ], hasMore: false),
      );

      expect(page!.hasMore, isFalse);
      expect(page.totalCount, 1);
    });

    test('reads a number that arrives as a double or a numeric string', () {
      final page = lowStockPageFrom(
        envelope(
          <dynamic>[
            <String, dynamic>{
              'product_id': 'p-1',
              'name': 'Dolo 650',
              'total_qty': '6',
              'min_stock_level': 10.0,
              'shortfall': '4',
            },
          ],
          totalCount: 9,
          returnedCount: 1,
        ),
      );

      expect(page!.rows.single.totalQty, 6);
      expect(page.rows.single.minStockLevel, 10);
      expect(page.rows.single.shortfall, 4);
      expect(page.totalCount, 9);
    });

    test('a missing figure in a row is zero rather than a crash', () {
      final page = lowStockPageFrom(
        envelope(<dynamic>[
          <String, dynamic>{'product_id': 'p-1', 'name': 'Dolo 650'},
        ]),
      );

      expect(page!.rows.single.totalQty, 0);
      expect(page.rows.single.minStockLevel, 0);
      expect(page.rows.single.shortfall, 0);
    });

    test('an entry that is not an object is skipped, not guessed at', () {
      final page = lowStockPageFrom(
        envelope(<dynamic>[
          42,
          <String, dynamic>{'product_id': 'p-1', 'name': 'Dolo 650'},
          'Dolo 650',
        ], returnedCount: 3),
      );

      expect(page!.rows, hasLength(1));
      expect(page.rows.single.productId, 'p-1');
    });
  });

  group('an envelope this app cannot read is null, never an empty list', () {
    // The whole reason the decoders return `null`: an empty list is indistinguishable from
    // "nothing is low on stock", and that is the one wrong answer a pharmacy would act on.
    // The repository turns this `null` into a failure the screen shows.
    final unreadable = <String, Object?>{
      'the old bare array': <dynamic>[
        <String, dynamic>{'product_id': 'p-1', 'name': 'Dolo 650'},
      ],
      'nothing': null,
      'a string': '{"meta":{}}',
      'an object with no rows': <String, dynamic>{
        'meta': <String, dynamic>{
          'total_count': 0,
          'returned_count': 0,
          'has_more': false,
        },
      },
      'an object with no meta': <String, dynamic>{'rows': <dynamic>[]},
      'no total_count': <String, dynamic>{
        'meta': <String, dynamic>{'returned_count': 0, 'has_more': false},
        'rows': <dynamic>[],
      },
      'no has_more': <String, dynamic>{
        'meta': <String, dynamic>{'total_count': 0, 'returned_count': 0},
        'rows': <dynamic>[],
      },
      // A total that does not describe the page in hand is a total about some other answer.
      'a returned_count that disagrees with the rows': <String, dynamic>{
        'meta': <String, dynamic>{
          'total_count': 9,
          'returned_count': 4,
          'has_more': true,
        },
        'rows': <dynamic>[],
      },
      // As is a `has_more` that contradicts the two counts beside it.
      'a has_more that contradicts its own counts': <String, dynamic>{
        'meta': <String, dynamic>{
          'total_count': 9,
          'returned_count': 1,
          'has_more': false,
        },
        'rows': <dynamic>[
          <String, dynamic>{'product_id': 'p-1', 'name': 'Dolo 650'},
        ],
      },
    };

    for (final entry in unreadable.entries) {
      test(entry.key, () {
        expect(lowStockPageFrom(entry.value), isNull);
        expect(expiringBatchesPageFrom(entry.value), isNull);
      });
    }

    test('an empty envelope is a page of nothing, which is honest', () {
      final page = lowStockPageFrom(envelope(<dynamic>[]))!;

      expect(page.rows, isEmpty);
      expect(page.totalCount, 0);
      expect(page.hasMore, isFalse);
    });
  });

  group('expiringBatchesPageFrom', () {
    test(
      'reads the figures, and a negative days_left is how long it has been gone',
      () {
        final page = expiringBatchesPageFrom(
          envelope(
            <dynamic>[
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
            ],
            meta: <String, dynamic>{'horizon_days': 90},
          ),
        );

        expect(page, isNotNull);
        final batches = page!.rows;
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
      final page = expiringBatchesPageFrom(
        envelope(<dynamic>[
          <String, dynamic>{
            'batch_id': 'b-1',
            'product_id': 'p-1',
            'product_name': 'Dolo 650',
            'batch_no': 'A-1',
            'expiry_date': '2026-09-24',
            'days_left': 5,
            'qty': 4,
          },
        ]),
      );

      expect(page!.rows.single.expiryDate, DateTime(2026, 9, 24));
      expect(page.rows.single.expiryDate.isUtc, isFalse);
    });

    test('the expiry envelope states its own total and horizon too', () {
      final page = expiringBatchesPageFrom(
        envelope(
          <dynamic>[
            <String, dynamic>{
              'batch_id': 'b-1',
              'product_id': 'p-1',
              'product_name': 'Dolo 650',
            },
          ],
          totalCount: 96,
          meta: <String, dynamic>{'horizon_days': 30},
        ),
      );

      expect(page!.returnedCount, 1);
      expect(page.totalCount, 96);
      expect(page.hasMore, isTrue);
      expect(page.rows.single.batchId, 'b-1');
    });
  });
}
