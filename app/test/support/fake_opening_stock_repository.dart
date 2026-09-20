/// Test doubles and builders for the opening stock import.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it. The builders
/// exist so a test can say what it is about ("a file whose row 3 is ambiguous")
/// rather than spelling out a whole preview envelope, and every default is the
/// boring answer: nothing refused, nothing already imported.
library;

import 'dart:async';

import 'package:app/features/import/opening_stock/data/opening_stock_csv.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_models.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_repository.dart';

/// Builds a summary, defaulting every counter to nothing unusual.
OpeningStockSummary buildSummary({
  int rowCount = 2,
  int totalQty = 30,
  double totalCost = 100,
  int newProductCount = 2,
  int matchedProductCount = 0,
  int ambiguousRowCount = 0,
  int zeroQtyRowCount = 0,
  int unknownBatchRowCount = 0,
  int unknownExpiryRowCount = 0,
  int expiredRowCount = 0,
  int errorRowCount = 0,
}) => OpeningStockSummary(
  rowCount: rowCount,
  totalQty: totalQty,
  totalCost: totalCost,
  newProductCount: newProductCount,
  matchedProductCount: matchedProductCount,
  ambiguousRowCount: ambiguousRowCount,
  zeroQtyRowCount: zeroQtyRowCount,
  unknownBatchRowCount: unknownBatchRowCount,
  unknownExpiryRowCount: unknownExpiryRowCount,
  expiredRowCount: expiredRowCount,
  errorRowCount: errorRowCount,
);

/// Builds one previewed row.
OpeningStockPreviewRow buildPreviewRow({
  int rowNumber = 1,
  String itemName = 'Dolo 650mg',
  String? batchNo = 'DOBS4434',
  String? expiryDate = '2030-03-31',
  int? qty = 10,
  double? purchaseRate = 1.38,
  double? mrp = 2.15,
  OpeningStockOutcome outcome = OpeningStockOutcome.created,
  String? productId,
  List<String> productNames = const <String>[],
  bool isUnknownBatch = false,
  bool isExpired = false,
  String? errorNote,
}) => OpeningStockPreviewRow(
  rowNumber: rowNumber,
  itemName: itemName,
  batchNo: batchNo,
  expiryDate: expiryDate,
  qty: qty,
  purchaseRate: purchaseRate,
  mrp: mrp,
  outcome: outcome,
  productId: productId,
  productNames: productNames,
  isUnknownBatch: isUnknownBatch,
  isExpired: isExpired,
  errorNote: errorNote,
);

/// Builds a preview envelope.
///
/// The summary is derived from [rows] when one is not given, so a test that only
/// cares about which rows are refused still gets counters that agree with them.
OpeningStockPreview buildPreview({
  OpeningStockSummary? summary,
  List<OpeningStockPreviewRow>? rows,
  ExistingImportJob? existingJob,
  String? fingerprint = 'fingerprint-1',
}) {
  final resolved = rows ?? <OpeningStockPreviewRow>[buildPreviewRow()];
  return OpeningStockPreview(
    summary: summary ?? buildSummary(rowCount: resolved.length),
    rows: resolved,
    existingJob: existingJob,
    fingerprint: fingerprint,
  );
}

/// Builds a commit result.
OpeningStockCommitResult buildCommitResult({
  String jobId = 'job-1',
  int productCount = 2,
  int productsCreated = 2,
  int productsMatched = 0,
  int batchCount = 2,
  int qtyTotal = 30,
  double costTotal = 100,
  bool idempotent = false,
}) => OpeningStockCommitResult(
  jobId: jobId,
  productCount: productCount,
  productsCreated: productsCreated,
  productsMatched: productsMatched,
  batchCount: batchCount,
  qtyTotal: qtyTotal,
  costTotal: costTotal,
  idempotent: idempotent,
);

/// Builds one audit row.
ImportJobRow buildJobRow({
  int rowNumber = 1,
  String rawItemName = 'Dolo 650mg',
  String? rawBatchNo = 'DOBS4434',
  String? rawExpiry = '2030-03-31',
  int qty = 10,
  double purchaseRate = 1.38,
  double mrp = 2.15,
  String? productName = 'Dolo 650mg',
  String? batchNo = 'DOBS4434',
  String? expiryDate = '2030-03-31',
  String action = 'created',
}) => ImportJobRow(
  rowNumber: rowNumber,
  rawItemName: rawItemName,
  rawBatchNo: rawBatchNo,
  rawExpiry: rawExpiry,
  qty: qty,
  purchaseRate: purchaseRate,
  mrp: mrp,
  productName: productName,
  batchNo: batchNo,
  expiryDate: expiryDate,
  action: action,
);

/// Builds a committed job, read back.
ImportJob buildJob({
  String jobId = 'job-1',
  String sourceFileName = 'PharmaFlow_Opening_Stock.csv',
  int rowCount = 1,
  int totalQty = 10,
  double totalCost = 13.8,
  String status = 'committed',
  DateTime? committedAt,
  List<ImportJobRow>? rows,
}) => ImportJob(
  jobId: jobId,
  sourceFileName: sourceFileName,
  rowCount: rowCount,
  totalQty: totalQty,
  totalCost: totalCost,
  status: status,
  committedAt: committedAt ?? DateTime(2026, 9, 20, 14, 5),
  rows: rows ?? <ImportJobRow>[buildJobRow()],
);

/// A preview of the two rows the default picked CSV carries.
///
/// The default answer of [FakeOpeningStockRepository], so a test that does not
/// care what the server said still gets a preview that agrees with the file the
/// default picker hands over - including the row count on the commit button.
///
/// The row and new-product counts are left at [buildSummary]'s defaults because
/// those defaults are already "two rows, both new"; only the quantities and the
/// money are stated, because they belong to these two rows.
OpeningStockPreview twoRowPreview() => buildPreview(
  summary: buildSummary(totalQty: 1292, totalCost: 1782.96),
  rows: <OpeningStockPreviewRow>[
    buildPreviewRow(),
    buildPreviewRow(
      rowNumber: 2,
      itemName: 'AB Gel',
      batchNo: null,
      expiryDate: null,
      qty: 0,
      purchaseRate: 80,
      mrp: 104,
      isUnknownBatch: true,
    ),
  ],
);

/// A preview summary matching the owner's real 314-row export, for the tests
/// that are about what the screen does with those numbers.
///
/// The figures are the ones the classifier returned for that file: 314 rows,
/// 61,360 units, ₹6,04,832.90 at cost, every row a new product, 53 rows holding
/// no stock, 138 without a batch number, 145 without an expiry, and three
/// already past it.
OpeningStockSummary realExportSummary() => buildSummary(
  rowCount: 314,
  totalQty: 61360,
  totalCost: 604832.90,
  newProductCount: 314,
  zeroQtyRowCount: 53,
  unknownBatchRowCount: 138,
  unknownExpiryRowCount: 145,
  expiredRowCount: 3,
);

/// An in-memory [OpeningStockRepository] that records what it was asked.
///
/// `implements` plus `noSuchMethod` rather than subclassing: `implements` needs
/// no constructor, so the fake never has to build a `SupabaseClient` - which it
/// cannot, without an initialised backend.
class FakeOpeningStockRepository implements OpeningStockRepository {
  /// Creates a fake answering with [previewResult], [result] and [jobResult].
  ///
  /// The answers are named apart from the methods they answer (`preview` the
  /// field would collide with `preview` the method), which is why they read a
  /// little long at the call site.
  FakeOpeningStockRepository({
    OpeningStockPreview? previewResult,
    OpeningStockCommitResult? result,
    ImportJob? jobResult,
  }) : previewResult = previewResult ?? twoRowPreview(),
       result = result ?? buildCommitResult(),
       jobResult = jobResult ?? buildJob();

  /// What every preview call returns.
  OpeningStockPreview previewResult;

  /// What every commit call returns.
  OpeningStockCommitResult result;

  /// What every job call returns.
  ImportJob jobResult;

  /// When set, the preview throws it until the test clears it.
  ///
  /// Persistent rather than one-shot: a route is built more than once before the
  /// first frame settles, so a failure that cleared itself could be retried into
  /// a success before the test could look at the error.
  Exception? previewErrorToThrow;

  /// When set, the commit throws it until the test clears it.
  Exception? commitErrorToThrow;

  /// When set, reading the job throws it until the test clears it.
  Exception? jobErrorToThrow;

  /// When set, every preview waits for it before it answers.
  ///
  /// The one hold in this fake, and it is here for the screen's own sake: a test
  /// that has to look at the processing step has to look *while* the server is
  /// working, and a future the test completes itself is the only honest way to
  /// stop the answer arriving before the assertion.
  Completer<void>? previewGate;

  /// Every payload the preview was handed, in order.
  final List<List<OpeningStockCsvRow>> previewed = <List<OpeningStockCsvRow>>[];

  /// Every payload the commit was handed, in order.
  final List<List<OpeningStockCsvRow>> committed = <List<OpeningStockCsvRow>>[];

  /// Every file name the commit was handed, in order.
  final List<String> committedFileNames = <String>[];

  /// Every job id that was read back.
  final List<String> jobsRead = <String>[];

  @override
  Future<OpeningStockPreview> preview(List<OpeningStockCsvRow> rows) async {
    previewed.add(rows);
    final gate = previewGate;
    if (gate != null) {
      await gate.future;
    }
    final error = previewErrorToThrow;
    if (error != null) {
      throw error;
    }
    return previewResult;
  }

  @override
  Future<OpeningStockCommitResult> commit({
    required List<OpeningStockCsvRow> rows,
    required String fileName,
  }) async {
    committed.add(rows);
    committedFileNames.add(fileName);
    final error = commitErrorToThrow;
    if (error != null) {
      throw error;
    }
    return result;
  }

  @override
  Future<ImportJob> job(String jobId) async {
    jobsRead.add(jobId);
    final error = jobErrorToThrow;
    if (error != null) {
      throw error;
    }
    return jobResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
