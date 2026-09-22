/// Plain models for the two alert RPCs' answers: `low_stock_products()` and
/// `expiring_batches()`, as migrations 20260919000027 and 20260922000050 define them.
///
/// Not Freezed, for the reason `ReportSummary` is not: these are an RPC's response
/// envelope rather than table rows, no migration owns their shape, and the parser
/// below is smaller than the generated code would be. What matters is that each
/// figure is read exactly once, here, so a screen never reaches into raw JSON.
///
/// Both RPCs answer `{"meta": {...}, "rows": [...]}` (migration 00050), the same shape
/// `top_products` and `dead_stock` already carried. The envelope is not decoration: it
/// states the rule the report applied, the business day it applied it on, and - the part
/// a screen needs - **how big the whole set was**, beside the page that came back. A
/// list of 200 rows that stops at 200 can now say whether that was all of them, which is
/// the whole reason the shape changed.
///
/// [AlertPage] is therefore the decode, not a `List`: the totals are part of the answer
/// and a decoder that dropped them would hand a screen a page it cannot caveat.
///
/// A payload that does not carry the envelope - the old bare array, no `rows`, no
/// totals, or a `returned_count` that does not describe the rows in hand - decodes to
/// `null`, and deciding that the whole answer was unreadable belongs to the repository,
/// which is where the "could not load" sentence comes from. Silence is the one wrong
/// answer here: it reads to a pharmacist as "nothing is low".
///
/// Neither payload is a notification, and neither is stored (D-047): an alert is a
/// question answered by an RPC, and it cannot go stale the way a row can.
library;

/// One alert's answer: the rows, and what the report said about the whole set.
///
/// Generic because both alerts answer the same way and neither's rows are special to the
/// envelope. [totalCount] is the report's own count over everything its rule selected, not
/// the length of [rows] - which is [returnedCount]; [hasMore] is the report's own comparison
/// of the two, carried rather than re-derived here so the database's statement and the
/// screen's caveat cannot disagree (an envelope whose `has_more` contradicts its own counts is
/// rejected by the decoder rather than second-guessed).
class AlertPage<T> {
  /// Creates a page.
  const AlertPage({
    required this.rows,
    required this.totalCount,
    required this.returnedCount,
    required this.hasMore,
  });

  /// The rows this page carries, in the report's own order.
  final List<T> rows;

  /// How many rows the report's rule selected in total, of which [rows] is a page.
  final int totalCount;

  /// How many rows are in [rows] - the report's own count of the page.
  final int returnedCount;

  /// Whether the whole set is bigger than this page, so a reader is not looking at all of it.
  final bool hasMore;

  /// An empty page, for a fake or a test that only cares that there is nothing to show.
  static AlertPage<T> empty<T>() => AlertPage<T>(
    rows: <T>[],
    totalCount: 0,
    returnedCount: 0,
    hasMore: false,
  );
}

/// One product below its reorder level.
class LowStockProduct {
  /// Creates a low-stock alert.
  const LowStockProduct({
    required this.productId,
    required this.name,
    required this.totalQty,
    required this.minStockLevel,
    required this.shortfall,
    this.genericName,
    this.packSize,
  });

  /// Reads one entry of the envelope's `rows`.
  factory LowStockProduct.fromJson(Map<String, dynamic> json) =>
      LowStockProduct(
        productId: _text(json, 'product_id') ?? '',
        name: _text(json, 'name') ?? '',
        genericName: _text(json, 'generic_name'),
        packSize: _text(json, 'pack_size'),
        totalQty: _int(json, 'total_qty'),
        minStockLevel: _int(json, 'min_stock_level'),
        shortfall: _int(json, 'shortfall'),
      );

  /// The product this is about.
  final String productId;

  /// Its name, as the catalogue spells it.
  final String name;

  /// Its generic name, when the catalogue has one.
  final String? genericName;

  /// The pack description, e.g. `'15s'`.
  final String? packSize;

  /// What is actually in stock, across every batch.
  final int totalQty;

  /// The level the pharmacy meant to act at.
  final int minStockLevel;

  /// The units that close the gap - what to order, in other words.
  final int shortfall;
}

/// One batch with stock left that is expiring.
class ExpiringBatch {
  /// Creates an expiry alert.
  const ExpiringBatch({
    required this.batchId,
    required this.productId,
    required this.productName,
    required this.batchNo,
    required this.expiryDate,
    required this.daysLeft,
    required this.qty,
    this.packSize,
  });

  /// Reads one entry of the envelope's `rows`.
  factory ExpiringBatch.fromJson(Map<String, dynamic> json) => ExpiringBatch(
    batchId: _text(json, 'batch_id') ?? '',
    productId: _text(json, 'product_id') ?? '',
    productName: _text(json, 'product_name') ?? '',
    packSize: _text(json, 'pack_size'),
    batchNo: _text(json, 'batch_no') ?? '',
    expiryDate: _date(json, 'expiry_date'),
    daysLeft: _int(json, 'days_left'),
    qty: _int(json, 'qty'),
  );

  /// The batch this is about.
  final String batchId;

  /// The product it belongs to.
  final String productId;

  /// That product's name.
  final String productName;

  /// The pack description, e.g. `'15s'`.
  final String? packSize;

  /// The batch number the supplier printed.
  final String batchNo;

  /// The day it expires.
  final DateTime expiryDate;

  /// Days from today: **negative** when it has already expired, which is the
  /// number a screen wants ("expired 6 days ago") rather than a bucket name.
  final int daysLeft;

  /// How many units are left in it.
  final int qty;

  /// Whether it has already gone off - the one that is already a loss.
  bool get isExpired => daysLeft < 0;
}

/// The low-stock envelope, or `null` when it is not one.
AlertPage<LowStockProduct>? lowStockPageFrom(Object? raw) =>
    _pageFrom(raw, LowStockProduct.fromJson);

/// The expiring-batch envelope, or `null` when it is not one.
AlertPage<ExpiringBatch>? expiringBatchesPageFrom(Object? raw) =>
    _pageFrom(raw, ExpiringBatch.fromJson);

/// One `{meta, rows}` answer, decoded - or `null` if any part of the contract is missing.
///
/// Every requirement here exists because its absence has a wrong-looking-right reading:
/// no `rows` would read as "nothing is low", and no `total_count` would leave a screen
/// unable to say whether the list it holds is the whole of it.
AlertPage<T>? _pageFrom<T>(
  Object? raw,
  T Function(Map<String, dynamic>) decode,
) {
  if (raw is! Map) {
    return null;
  }
  final envelope = raw.cast<String, dynamic>();
  final meta = envelope['meta'];
  final rows = envelope['rows'];
  if (meta is! Map || rows is! List) {
    return null;
  }

  final totalCount = _wholeNumber(meta['total_count']);
  final returnedCount = _wholeNumber(meta['returned_count']);
  final hasMore = meta['has_more'];
  if (totalCount == null || returnedCount == null || hasMore is! bool) {
    return null;
  }
  // The envelope's own count of the page must describe the page in hand, or the total it
  // states is a total about some other answer - and its own `has_more` must agree with the
  // counts it just gave, or there is no reading of it that is not a guess.
  if (returnedCount != rows.length || hasMore != (totalCount > returnedCount)) {
    return null;
  }

  return AlertPage<T>(
    rows: rows
        .whereType<Map<Object?, Object?>>()
        .map((row) => decode(row.cast<String, dynamic>()))
        .toList(growable: false),
    totalCount: totalCount,
    returnedCount: returnedCount,
    hasMore: hasMore,
  );
}

/// A string that may arrive surrounded by nothing at all.
String? _text(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return value?.toString();
}

/// A whole number that may arrive as int, double or a numeric string.
int _int(Map<String, dynamic> json, String key) => _wholeNumber(json[key]) ?? 0;

/// A whole number from any JSON number or numeric string, or `null`.
///
/// `null` rather than `0` for the envelope's own counts: a missing count is not a count of
/// zero, it is an answer this app cannot read.
int? _wholeNumber(Object? value) => switch (value) {
  final num number => number.round(),
  final String text => int.tryParse(text.trim()),
  _ => null,
};

/// A `date` that Postgres serialises as `YYYY-MM-DD`.
DateTime _date(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is String
      ? DateTime.tryParse(value) ?? DateTime.now()
      : DateTime.now();
}
