/// Plain models for the two alert RPCs' answers: `low_stock_products()` and
/// `expiring_batches()` (migration 20260919000027).
///
/// Not Freezed, for the reason `ReportSummary` is not: these are an RPC's response
/// envelope rather than table rows, no migration owns their shape, and the parser
/// below is smaller than the generated code would be. What matters is that each
/// figure is read exactly once, here, so a screen never reaches into raw JSON.
///
/// Both RPCs answer with a `jsonb` **array** (`coalesce(..., '[]')`), so there is a
/// top-level decoder per payload rather than a `fromJson` on an envelope object.
/// The decoders are tolerant about an entry they cannot read and say nothing about
/// it; deciding that the whole answer was unreadable belongs to the repository,
/// which is where the "could not load" sentence comes from.
///
/// Neither payload is a notification, and neither is stored (D-047): an alert is a
/// question answered by an RPC, and it cannot go stale the way a row can.
library;

/// One product at or below its reorder level.
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

  /// Reads one entry of the RPC's array.
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

  /// Reads one entry of the RPC's array.
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

/// The low-stock answer, as a list. An answer that is not a list reads as empty.
List<LowStockProduct> lowStockProductsFrom(Object? raw) =>
    _rows(raw).map(LowStockProduct.fromJson).toList(growable: false);

/// The expiring-batch answer, as a list. An answer that is not a list reads as empty.
List<ExpiringBatch> expiringBatchesFrom(Object? raw) =>
    _rows(raw).map(ExpiringBatch.fromJson).toList(growable: false);

/// The entries of an RPC array that are objects, and nothing else.
Iterable<Map<String, dynamic>> _rows(Object? raw) {
  if (raw is! List) {
    return const <Map<String, dynamic>>[];
  }
  return raw.whereType<Map<Object?, Object?>>().map(
    (row) => row.cast<String, dynamic>(),
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
int _int(Map<String, dynamic> json, String key) {
  final value = json[key];
  return switch (value) {
    final num number => number.round(),
    final String text => int.tryParse(text) ?? 0,
    _ => 0,
  };
}

/// A `date` that Postgres serialises as `YYYY-MM-DD`.
DateTime _date(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is String
      ? DateTime.tryParse(value) ?? DateTime.now()
      : DateTime.now();
}
