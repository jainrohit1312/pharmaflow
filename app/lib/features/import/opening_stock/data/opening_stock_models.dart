/// Plain models for what the opening-stock RPCs answer.
///
/// Not Freezed, for `ReportSummary`'s reason: these are an RPC's response
/// envelopes rather than table rows, so no migration owns their shape and there
/// is nothing to generate. Every reader is defensive in the same way the RPC's
/// payload is coerced on the server - a field that arrives as `"14"` rather than
/// `14` reads as 14, and a missing one reads as empty rather than throwing.
library;

/// What the preview counted for the whole file.
class OpeningStockSummary {
  /// Creates a summary.
  const OpeningStockSummary({
    required this.rowCount,
    required this.totalQty,
    required this.totalCost,
    required this.newProductCount,
    required this.matchedProductCount,
    required this.ambiguousRowCount,
    required this.zeroQtyRowCount,
    required this.unknownBatchRowCount,
    required this.unknownExpiryRowCount,
    required this.expiredRowCount,
    required this.errorRowCount,
  });

  /// Decodes the RPC's `summary` object.
  factory OpeningStockSummary.fromJson(Map<String, dynamic> json) =>
      OpeningStockSummary(
        rowCount: _int(json, 'row_count'),
        totalQty: _int(json, 'total_qty'),
        totalCost: _double(json, 'total_cost'),
        newProductCount: _int(json, 'new_product_count'),
        matchedProductCount: _int(json, 'matched_product_count'),
        ambiguousRowCount: _int(json, 'ambiguous_row_count'),
        zeroQtyRowCount: _int(json, 'zero_qty_row_count'),
        unknownBatchRowCount: _int(json, 'unknown_batch_row_count'),
        unknownExpiryRowCount: _int(json, 'unknown_expiry_row_count'),
        expiredRowCount: _int(json, 'expired_row_count'),
        errorRowCount: _int(json, 'error_row_count'),
      );

  /// How many rows the file carries.
  final int rowCount;

  /// Units across every row that can be imported.
  final int totalQty;

  /// Sum of `qty x purchase_rate` across those rows.
  final double totalCost;

  /// Products the catalogue does not have yet and the import would create.
  final int newProductCount;

  /// Products the import would attach its batch to.
  final int matchedProductCount;

  /// Rows whose name more than one catalogue product shares.
  ///
  /// Counted apart from [errorRowCount] because the fix is different - this one
  /// ends in the catalogue, not in the file - but both refuse the import.
  final int ambiguousRowCount;

  /// Rows with a quantity of zero. Valid: the product exists and holds no stock.
  final int zeroQtyRowCount;

  /// Rows with no batch number, which get a generated identity.
  final int unknownBatchRowCount;

  /// Rows with no expiry date, which stay NULL.
  final int unknownExpiryRowCount;

  /// Rows whose expiry date has already passed.
  final int expiredRowCount;

  /// Rows the server refused, each with a row-numbered reason.
  final int errorRowCount;

  /// Rows that stop the import, whether because of the file or the catalogue.
  int get refusedRowCount => errorRowCount + ambiguousRowCount;

  /// Whether the commit would be accepted as it stands.
  bool get canImport => rowCount > 0 && refusedRowCount == 0;

  /// How many batches the import would write: one per row.
  int get batchCount => rowCount;
}

/// What the server made of one row.
enum OpeningStockOutcome {
  /// The catalogue has no product of this name; the import creates one.
  created,

  /// The catalogue has exactly one; the batch attaches to it.
  matched,

  /// The catalogue has more than one. Never picked automatically.
  ambiguous,

  /// The row itself cannot be read.
  error,
}

/// Reads a classification literal, defaulting to [OpeningStockOutcome.error].
///
/// An unrecognised word is treated as a refusal rather than as a success: a
/// server that grows a new outcome must not have it silently read as importable.
OpeningStockOutcome openingStockOutcomeFromDb(String? raw) => switch (raw) {
  'new' => OpeningStockOutcome.created,
  'matched' => OpeningStockOutcome.matched,
  'ambiguous' => OpeningStockOutcome.ambiguous,
  _ => OpeningStockOutcome.error,
};

/// One row as the server classified it.
class OpeningStockPreviewRow {
  /// Creates a row.
  const OpeningStockPreviewRow({
    required this.rowNumber,
    required this.itemName,
    required this.batchNo,
    required this.expiryDate,
    required this.qty,
    required this.purchaseRate,
    required this.mrp,
    required this.outcome,
    required this.productId,
    required this.productNames,
    required this.isUnknownBatch,
    required this.isExpired,
    required this.errorNote,
  });

  /// Decodes one entry of the RPC's `rows` array.
  factory OpeningStockPreviewRow.fromJson(Map<String, dynamic> json) =>
      OpeningStockPreviewRow(
        rowNumber: _int(json, 'row_number'),
        itemName: _text(json, 'item_name') ?? '',
        batchNo: _text(json, 'raw_batch_no'),
        expiryDate: _text(json, 'expiry_date'),
        qty: _intOrNull(json, 'qty'),
        purchaseRate: _doubleOrNull(json, 'purchase_rate'),
        mrp: _doubleOrNull(json, 'mrp'),
        outcome: openingStockOutcomeFromDb(_text(json, 'outcome')),
        productId: _text(json, 'product_id'),
        productNames: _strings(json['product_names']),
        isUnknownBatch: _bool(json, 'is_unknown_batch'),
        isExpired: _bool(json, 'is_expired'),
        errorNote: _text(json, 'error_note'),
      );

  /// Which data row this is, counting from 1 after the header.
  final int rowNumber;

  /// The item's name, trimmed.
  final String itemName;

  /// The batch number as the file had it, or `null` when it had none.
  final String? batchNo;

  /// The expiry as the file had it, or `null` when it had none.
  final String? expiryDate;

  /// The quantity, or `null` when the server could not read one.
  final int? qty;

  /// The purchase rate, or `null` when the server could not read one.
  final double? purchaseRate;

  /// The MRP, or `null` when the server could not read one.
  final double? mrp;

  /// What the server decided this row would do.
  final OpeningStockOutcome outcome;

  /// The catalogue product this row would write to, when it matched one.
  final String? productId;

  /// The catalogue products whose name normalizes alike, when more than one.
  final List<String> productNames;

  /// Whether the batch number will be generated rather than taken from the file.
  final bool isUnknownBatch;

  /// Whether the expiry has already passed.
  final bool isExpired;

  /// Why the row was refused, when it was.
  final String? errorNote;

  /// Whether this row stops the import.
  bool get isRefused =>
      outcome == OpeningStockOutcome.error ||
      outcome == OpeningStockOutcome.ambiguous;
}

/// An import of this exact content that has already been committed.
class ExistingImportJob {
  /// Creates a reference to a committed job.
  const ExistingImportJob({
    required this.jobId,
    required this.rowCount,
    required this.status,
    required this.committedAt,
  });

  /// Decodes the RPC's `existing_job` object.
  factory ExistingImportJob.fromJson(Map<String, dynamic> json) =>
      ExistingImportJob(
        jobId: _text(json, 'job_id') ?? '',
        rowCount: _int(json, 'row_count'),
        status: _text(json, 'status') ?? '',
        committedAt: _dateTime(json, 'committed_at'),
      );

  /// The job's id.
  final String jobId;

  /// How many rows it imported.
  final int rowCount;

  /// Its status, which for a job found by fingerprint is `committed`.
  final String status;

  /// When it committed.
  final DateTime? committedAt;
}

/// Everything the preview screen shows, as one value.
class OpeningStockPreview {
  /// Creates a preview.
  const OpeningStockPreview({
    required this.summary,
    required this.rows,
    required this.existingJob,
    required this.fingerprint,
  });

  /// Decodes the RPC's answer.
  factory OpeningStockPreview.fromJson(Map<String, dynamic> json) =>
      OpeningStockPreview(
        summary: OpeningStockSummary.fromJson(_object(json['summary'])),
        rows: _objects(
          json['rows'],
        ).map(OpeningStockPreviewRow.fromJson).toList(growable: false),
        existingJob: json['existing_job'] is Map
            ? ExistingImportJob.fromJson(_object(json['existing_job']))
            : null,
        fingerprint: _text(json, 'fingerprint'),
      );

  /// The counters for the whole file.
  final OpeningStockSummary summary;

  /// Every row, in file order.
  final List<OpeningStockPreviewRow> rows;

  /// The already-committed import of this same content, if there is one.
  final ExistingImportJob? existingJob;

  /// The content's fingerprint, or `null` when a row could not be read.
  final String? fingerprint;

  /// The rows the screen lists as refusals, in file order.
  List<OpeningStockPreviewRow> get refusedRows =>
      rows.where((row) => row.isRefused).toList(growable: false);
}

/// What a commit did, whether it wrote or found the content already imported.
class OpeningStockCommitResult {
  /// Creates a result.
  const OpeningStockCommitResult({
    required this.jobId,
    required this.productCount,
    required this.productsCreated,
    required this.productsMatched,
    required this.batchCount,
    required this.qtyTotal,
    required this.costTotal,
    required this.idempotent,
  });

  /// Decodes the RPC's envelope.
  factory OpeningStockCommitResult.fromJson(Map<String, dynamic> json) =>
      OpeningStockCommitResult(
        jobId: _text(json, 'job_id') ?? '',
        productCount: _int(json, 'product_count'),
        productsCreated: _int(json, 'products_created'),
        productsMatched: _int(json, 'products_matched'),
        batchCount: _int(json, 'batch_count'),
        qtyTotal: _int(json, 'qty_total'),
        costTotal: _double(json, 'cost_total'),
        idempotent: _bool(json, 'idempotent'),
      );

  /// The job that holds this import.
  final String jobId;

  /// Products the import touches: created plus matched.
  final int productCount;

  /// Products this import created.
  final int productsCreated;

  /// Products this import found in the catalogue.
  final int productsMatched;

  /// Batches written.
  final int batchCount;

  /// Units imported.
  final int qtyTotal;

  /// Value at cost.
  final double costTotal;

  /// Whether this content had already been committed, so nothing was written.
  final bool idempotent;
}

/// One line of a committed import's audit trail.
class ImportJobRow {
  /// Creates an audit row.
  const ImportJobRow({
    required this.rowNumber,
    required this.rawItemName,
    required this.rawBatchNo,
    required this.rawExpiry,
    required this.qty,
    required this.purchaseRate,
    required this.mrp,
    required this.productName,
    required this.batchNo,
    required this.expiryDate,
    required this.action,
  });

  /// Decodes one entry of the job's `rows` array.
  factory ImportJobRow.fromJson(Map<String, dynamic> json) => ImportJobRow(
    rowNumber: _int(json, 'row_number'),
    rawItemName: _text(json, 'raw_item_name') ?? '',
    rawBatchNo: _text(json, 'raw_batch_no'),
    rawExpiry: _text(json, 'raw_expiry'),
    qty: _int(json, 'qty'),
    purchaseRate: _double(json, 'purchase_rate'),
    mrp: _double(json, 'mrp'),
    productName: _text(json, 'product_name'),
    batchNo: _text(json, 'batch_no'),
    expiryDate: _text(json, 'expiry_date'),
    action: _text(json, 'action') ?? '',
  );

  /// Which data row this was.
  final int rowNumber;

  /// The item's name as the file printed it.
  final String rawItemName;

  /// The batch number as the file printed it, if any.
  final String? rawBatchNo;

  /// The expiry as the file printed it, if any.
  final String? rawExpiry;

  /// Units imported on this row.
  final int qty;

  /// Landing cost per unit stored for the batch.
  final double purchaseRate;

  /// MRP stored for the batch.
  final double mrp;

  /// The catalogue product the row wrote to.
  final String? productName;

  /// The batch number actually stored (generated when the file had none).
  final String? batchNo;

  /// The expiry actually stored (`null` when unknown).
  final String? expiryDate;

  /// `created` or `matched`.
  final String action;
}

/// A committed import, read back with the names it wrote.
class ImportJob {
  /// Creates a job.
  const ImportJob({
    required this.jobId,
    required this.sourceFileName,
    required this.rowCount,
    required this.totalQty,
    required this.totalCost,
    required this.status,
    required this.committedAt,
    required this.rows,
  });

  /// Decodes the RPC's answer.
  factory ImportJob.fromJson(Map<String, dynamic> json) {
    final job = _object(json['job']);
    return ImportJob(
      jobId: _text(job, 'job_id') ?? '',
      sourceFileName: _text(job, 'source_filename') ?? '',
      rowCount: _int(job, 'row_count'),
      totalQty: _int(job, 'total_qty'),
      totalCost: _double(job, 'total_cost'),
      status: _text(job, 'status') ?? '',
      committedAt: _dateTime(job, 'committed_at'),
      rows: _objects(
        json['rows'],
      ).map(ImportJobRow.fromJson).toList(growable: false),
    );
  }

  /// The job's id.
  final String jobId;

  /// The file it came from.
  final String sourceFileName;

  /// How many rows it imported.
  final int rowCount;

  /// Units it imported.
  final int totalQty;

  /// Value at cost.
  final double totalCost;

  /// Its status.
  final String status;

  /// When it committed.
  final DateTime? committedAt;

  /// Its rows, in file order.
  final List<ImportJobRow> rows;
}

/// A nested object, or an empty one when the key is absent.
Map<String, dynamic> _object(Object? raw) {
  if (raw is Map) {
    return raw.cast<String, dynamic>();
  }
  return <String, dynamic>{};
}

/// The entries of an array that are objects, and nothing else.
Iterable<Map<String, dynamic>> _objects(Object? raw) {
  if (raw is! List) {
    return const <Map<String, dynamic>>[];
  }
  return raw.whereType<Map<Object?, Object?>>().map(
    (row) => row.cast<String, dynamic>(),
  );
}

/// A string, or `null` when it is absent or blank.
String? _text(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return value?.toString();
}

/// A whole number that may arrive as int, double or a numeric string.
int _int(Map<String, dynamic> json, String key) => _intOrNull(json, key) ?? 0;

/// The same, keeping "absent" distinct from zero.
int? _intOrNull(Map<String, dynamic> json, String key) => switch (json[key]) {
  final num number => number.round(),
  final String text => int.tryParse(text),
  _ => null,
};

/// A decimal that may arrive as int, double or a numeric string.
double _double(Map<String, dynamic> json, String key) =>
    _doubleOrNull(json, key) ?? 0;

/// The same, keeping "absent" distinct from zero.
double? _doubleOrNull(Map<String, dynamic> json, String key) =>
    switch (json[key]) {
      final num number => number.toDouble(),
      final String text => double.tryParse(text),
      _ => null,
    };

/// A flag that may arrive as a bool or as its JSON text.
bool _bool(Map<String, dynamic> json, String key) => switch (json[key]) {
  final bool value => value,
  'true' => true,
  _ => false,
};

/// A timestamp, or `null` when absent or unreadable.
DateTime? _dateTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is String ? DateTime.tryParse(value) : null;
}

/// A list of strings, tolerating nulls and blanks.
List<String> _strings(Object? raw) {
  if (raw is! List) {
    return const <String>[];
  }
  return raw
      .whereType<String>()
      .where((value) => value.trim().isNotEmpty)
      .toList(growable: false);
}
