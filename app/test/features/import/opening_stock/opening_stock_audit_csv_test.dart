/// The audit CSV: what the owner keeps as the record of the import.
library;

import 'package:app/features/import/opening_stock/data/opening_stock_audit_csv.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_opening_stock_repository.dart';

void main() {
  test('the first line is the documented columns', () {
    final csv = buildOpeningStockAuditCsv(buildJob());

    expect(
      csv.split('\n').first,
      'row_number,item_name,batch_no,expiry_date,qty,purchase_rate,mrp,'
      'product_name,stored_batch_no,stored_expiry_date,action',
    );
  });

  test('one line per imported row, in row order', () {
    final csv = buildOpeningStockAuditCsv(
      buildJob(
        rowCount: 2,
        rows: [
          buildJobRow(),
          buildJobRow(
            rowNumber: 2,
            rawItemName: 'PANTOP',
            rawBatchNo: null,
            rawExpiry: null,
            qty: 0,
            purchaseRate: 0,
            mrp: 57.48,
            productName: 'PANTOP',
            batchNo: 'OPENING-7dad2584',
            expiryDate: null,
          ),
        ],
      ),
    );

    final lines = csv.trim().split('\n');
    expect(lines, hasLength(3));
    expect(
      lines[1],
      startsWith('1,Dolo 650mg,DOBS4434,2030-03-31,10,1.38,2.15'),
    );
    expect(lines[2], startsWith('2,PANTOP,,,0,0.00,57.48'));
  });

  test('the file text and what was stored are both kept', () {
    final job = buildJob(
      rows: [
        buildJobRow(
          rawItemName: 'AB Gel',
          rawBatchNo: null,
          rawExpiry: null,
          qty: 0,
          purchaseRate: 80,
          mrp: 104,
          productName: 'AB Gel',
          batchNo: 'OPENING-0fea2029',
          expiryDate: null,
        ),
      ],
    );
    expect(job.rows, hasLength(1));

    final csv = buildOpeningStockAuditCsv(job);

    // The batch number the file did not have is empty; the one the import wrote
    // is beside it, which is what makes a generated reference traceable.
    expect(csv, contains('1,AB Gel,,,0,80.00,104.00'));
    expect(csv, contains(',AB Gel,OPENING-0fea2029,,created'));
  });

  test('money is written to the two places the columns hold', () {
    final csv = buildOpeningStockAuditCsv(
      buildJob(rows: [buildJobRow(purchaseRate: 5, mrp: 7.4)]),
    );

    expect(csv, contains(',10,5.00,7.40,'));
  });

  test('a value holding a comma or a quote is quoted, its quotes doubled', () {
    final csv = buildOpeningStockAuditCsv(
      buildJob(rows: [buildJobRow(rawItemName: 'ACILOC, INJ "500"')]),
    );

    expect(csv, contains('"ACILOC, INJ ""500"""'));
  });

  test('the action column says what the row did', () {
    final csv = buildOpeningStockAuditCsv(
      buildJob(rows: [buildJobRow(action: 'matched')]),
    );

    expect(csv, contains(',matched'));
  });

  test('the file name carries the day it committed', () {
    expect(
      openingStockAuditFileName(buildJob(committedAt: DateTime(2026, 9, 3))),
      'opening-stock-audit-2026-09-03.csv',
    );
  });

  test('a job that never committed still gets a name', () {
    const job = ImportJob(
      jobId: 'job-1',
      sourceFileName: 'PharmaFlow_Opening_Stock.csv',
      rowCount: 0,
      totalQty: 0,
      totalCost: 0,
      status: 'pending',
      committedAt: null,
      rows: <ImportJobRow>[],
    );

    expect(openingStockAuditFileName(job), 'opening-stock-audit-import.csv');
  });
}
