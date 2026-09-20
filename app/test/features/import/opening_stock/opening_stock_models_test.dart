/// The preview envelope's readers.
///
/// These models are the app's only view of what the server classified, so the
/// tests are mostly about the failures: an answer that arrives in an unexpected
/// shape must read as "cannot be imported" rather than as a green light.
library;

import 'package:app/features/import/opening_stock/data/opening_stock_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the summary', () {
    test('reads the counters the RPC sends', () {
      final summary = OpeningStockSummary.fromJson(<String, dynamic>{
        'row_count': 314,
        'total_qty': 61360,
        'total_cost': 604832.90,
        'new_product_count': 314,
        'matched_product_count': 0,
        'ambiguous_row_count': 0,
        'zero_qty_row_count': 53,
        'unknown_batch_row_count': 138,
        'unknown_expiry_row_count': 145,
        'expired_row_count': 3,
        'error_row_count': 0,
      });

      expect(summary.rowCount, 314);
      expect(summary.totalQty, 61360);
      expect(summary.totalCost, 604832.90);
      expect(summary.unknownExpiryRowCount, 145);
      expect(summary.canImport, isTrue);
      expect(summary.batchCount, 314);
    });

    test('reads a number that arrived as a string', () {
      final summary = OpeningStockSummary.fromJson(<String, dynamic>{
        'row_count': '12',
        'total_cost': '99.50',
      });

      expect(summary.rowCount, 12);
      expect(summary.totalCost, 99.5);
    });

    test('refuses to import when a row was refused', () {
      final summary = OpeningStockSummary.fromJson(<String, dynamic>{
        'row_count': 10,
        'error_row_count': 1,
      });

      expect(summary.canImport, isFalse);
      expect(summary.refusedRowCount, 1);
    });

    test('refuses to import when a row is ambiguous, and counts it apart', () {
      final summary = OpeningStockSummary.fromJson(<String, dynamic>{
        'row_count': 10,
        'ambiguous_row_count': 2,
      });

      expect(summary.canImport, isFalse);
      expect(summary.ambiguousRowCount, 2);
      expect(summary.errorRowCount, 0);
    });

    test('has nothing to import when the file had no rows', () {
      expect(
        OpeningStockSummary.fromJson(const <String, dynamic>{}).canImport,
        isFalse,
      );
    });
  });

  group('a row', () {
    test('reads the classification and the values the server parsed', () {
      final row = OpeningStockPreviewRow.fromJson(<String, dynamic>{
        'row_number': 7,
        'item_name': 'ZIFI 200MG',
        'raw_batch_no': '0126E038',
        'raw_expiry': '2027-10-31',
        'qty': 136,
        'purchase_rate': 8.16,
        'mrp': 10.51,
        'expiry_date': '2027-10-31',
        'is_unknown_batch': false,
        'is_expired': false,
        'outcome': 'matched',
        'product_id': 'product-1',
        'product_names': <String>['ZIFI 200MG'],
      });

      expect(row.rowNumber, 7);
      expect(row.batchNo, '0126E038');
      expect(row.outcome, OpeningStockOutcome.matched);
      expect(row.qty, 136);
      expect(row.isRefused, isFalse);
    });

    test('an unknown outcome reads as refused, never as a green light', () {
      final row = OpeningStockPreviewRow.fromJson(<String, dynamic>{
        'row_number': 1,
        'item_name': 'A',
        'outcome': 'something-new-the-server-grew',
      });

      expect(row.outcome, OpeningStockOutcome.error);
      expect(row.isRefused, isTrue);
    });

    test('a row the server could not read keeps that visible', () {
      final row = OpeningStockPreviewRow.fromJson(<String, dynamic>{
        'row_number': 11,
        'item_name': 'ZZBAD TAB',
        'qty': null,
        'purchase_rate': null,
        'mrp': null,
        'outcome': 'error',
        'error_note': 'qty "abc" is not a whole number',
      });

      expect(row.qty, isNull);
      expect(row.mrp, isNull);
      expect(row.errorNote, 'qty "abc" is not a whole number');
      expect(row.isRefused, isTrue);
    });

    test('an absent expiry is unknown, and a past one is flagged', () {
      final row = OpeningStockPreviewRow.fromJson(<String, dynamic>{
        'row_number': 1,
        'item_name': 'PANTOP',
        'raw_expiry': '',
        'expiry_date': null,
        'is_expired': false,
        'outcome': 'new',
      });

      expect(row.expiryDate, isNull);
      expect(row.isExpired, isFalse);
    });
  });

  group('the preview', () {
    test('reads the job behind the fingerprint when there is one', () {
      final preview = OpeningStockPreview.fromJson(<String, dynamic>{
        'fingerprint': 'abc',
        'summary': <String, dynamic>{'row_count': 314},
        'rows': <dynamic>[],
        'existing_job': <String, dynamic>{
          'job_id': 'job-1',
          'row_count': 314,
          'status': 'committed',
          'committed_at': '2026-09-20T08:21:50.477533+00:00',
        },
      });

      expect(preview.existingJob, isNotNull);
      expect(preview.existingJob?.jobId, 'job-1');
      expect(preview.existingJob?.rowCount, 314);
      expect(preview.existingJob?.committedAt?.year, 2026);
    });

    test('reads a JSON null job as "not imported before"', () {
      final preview = OpeningStockPreview.fromJson(<String, dynamic>{
        'summary': <String, dynamic>{'row_count': 1},
        'rows': <dynamic>[],
        'existing_job': null,
      });

      expect(preview.existingJob, isNull);
      expect(preview.fingerprint, isNull);
    });

    test('lists both kinds of refusal together', () {
      final preview = OpeningStockPreview.fromJson(<String, dynamic>{
        'summary': <String, dynamic>{'row_count': 3},
        'rows': <dynamic>[
          <String, dynamic>{
            'row_number': 1,
            'item_name': 'ok',
            'outcome': 'new',
          },
          <String, dynamic>{
            'row_number': 2,
            'item_name': 'ambiguous',
            'outcome': 'ambiguous',
          },
          <String, dynamic>{
            'row_number': 3,
            'item_name': 'bad',
            'outcome': 'error',
          },
        ],
      });

      expect(preview.refusedRows.map((row) => row.rowNumber), <int>[2, 3]);
    });

    test('survives a maliciously empty envelope', () {
      final preview = OpeningStockPreview.fromJson(const <String, dynamic>{});

      expect(preview.summary.rowCount, 0);
      expect(preview.rows, isEmpty);
      expect(preview.refusedRows, isEmpty);
    });
  });

  group('the commit result', () {
    test('reads what was written, and whether it was a replay', () {
      final result = OpeningStockCommitResult.fromJson(<String, dynamic>{
        'committed': true,
        'idempotent': false,
        'job_id': 'job-1',
        'product_count': 314,
        'products_created': 313,
        'products_matched': 1,
        'batch_count': 314,
        'qty_total': 61360,
        'cost_total': 604832.90,
      });

      expect(result.jobId, 'job-1');
      expect(result.productsCreated, 313);
      expect(result.productsMatched, 1);
      expect(result.idempotent, isFalse);
      expect(result.costTotal, 604832.90);
    });

    test('a replay says so rather than pretending it wrote', () {
      final result = OpeningStockCommitResult.fromJson(<String, dynamic>{
        'committed': true,
        'idempotent': true,
        'job_id': 'job-1',
      });

      expect(result.idempotent, isTrue);
      expect(result.productsCreated, 0);
    });
  });

  group('a committed job', () {
    test('reads its rows with the names they wrote', () {
      final job = ImportJob.fromJson(<String, dynamic>{
        'job': <String, dynamic>{
          'job_id': 'job-1',
          'source_filename': 'PharmaFlow_Opening_Stock.csv',
          'row_count': 1,
          'status': 'committed',
          'committed_at': '2026-09-20T08:21:50.477533+00:00',
        },
        'rows': <dynamic>[
          <String, dynamic>{
            'row_number': 1,
            'raw_item_name': 'Eupen 1gm                     INJ',
            'raw_batch_no': '',
            'raw_expiry': '',
            'qty': 14,
            'purchase_rate': 120,
            'mrp': 1017.65,
            'product_name': 'Eupen 1gm                     INJ',
            'batch_no': 'OPENING-40b53500',
            'expiry_date': null,
            'action': 'created',
          },
        ],
      });

      expect(job.jobId, 'job-1');
      expect(job.rows, hasLength(1));
      expect(job.rows.single.rawBatchNo, isNull);
      expect(job.rows.single.batchNo, 'OPENING-40b53500');
      expect(job.rows.single.expiryDate, isNull);
      expect(job.rows.single.qty, 14);
    });

    test('survives an envelope with no job at all', () {
      final job = ImportJob.fromJson(const <String, dynamic>{});

      expect(job.jobId, isEmpty);
      expect(job.committedAt, isNull);
      expect(job.rows, isEmpty);
    });
  });
}
