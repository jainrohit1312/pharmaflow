/// Shared test double for the inventory screens.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/alert_payloads.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product_stock.dart';
import 'package:app/data/models/stock_adjustment.dart';
import 'package:app/data/models/write_outcome.dart';
import 'package:app/features/inventory/data/inventory_repository.dart';

/// Builds a `product_stock` row with only the fields a test cares about.
ProductStock buildStock({
  required String name,
  String? productId,
  int totalQty = 10,
  int minStockLevel = 0,
  double stockValueAtCost = 1000,
  double stockValueAtMrp = 1500,
  String? genericName,
  String? brand,
}) => ProductStock(
  productId: productId ?? 'product-$name',
  pharmacyId: 'ph-1',
  name: name,
  totalQty: totalQty,
  minStockLevel: minStockLevel,
  stockValueAtCost: stockValueAtCost,
  stockValueAtMrp: stockValueAtMrp,
  genericName: genericName,
  brand: brand,
);

/// Builds a `batch_status` row with only the fields a test cares about.
///
/// [expiryDate] defaults to a known date, because most tests want a batch that
/// expires; pass [unknownExpiry] for the row an opening-stock batch whose source
/// recorded no date produces - `expiry_date is null`, which the view reports as the
/// `'unknown'` bucket. The two cannot be told apart through [expiryDate] alone
/// (Dart has no way to default a parameter to "explicitly null" beside a fallback),
/// which is what the flag is for.
BatchStatus buildBatch({
  String id = 'batch-1',
  String productId = 'product-1',
  String batchNo = 'B-1',
  DateTime? expiryDate,
  bool unknownExpiry = false,
  bool isUnknownBatch = false,
  ExpiryStatus expiryStatus = ExpiryStatus.critical,
  int qty = 10,
  double mrp = 150,
  double purchaseRate = 100,
}) => BatchStatus(
  id: id,
  pharmacyId: 'ph-1',
  productId: productId,
  batchNo: batchNo,
  expiryDate: unknownExpiry ? null : (expiryDate ?? DateTime(2026, 10)),
  isUnknownBatch: isUnknownBatch,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  expiryStatus: expiryStatus,
  qty: qty,
  mrp: mrp,
  purchaseRate: purchaseRate,
);

/// FEFO order, with a batch whose expiry nobody recorded last.
///
/// The real reads order by `expiry_date` then `batch_no`, and Postgres sorts NULLs
/// last when ascending - so an unknown-expiry batch is never the one a counter is
/// told to dispense first, which is the property the POS relies on.
int _byExpiry(BatchStatus a, BatchStatus b) {
  final first = a.expiryDate;
  final second = b.expiryDate;
  if (first == null || second == null) {
    if (first == null && second == null) {
      return a.batchNo.compareTo(b.batchNo);
    }
    return first == null ? 1 : -1;
  }
  return first.compareTo(second);
}

/// An in-memory [InventoryRepository] that applies the query the way the real one
/// would, and records what a correction was given.
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing:
/// `implements` does not require a constructor, so the fake never needs a
/// Supabase client - which is the whole point, because a real `SupabaseClient`
/// cannot be constructed without an initialised backend.
class FakeInventoryRepository implements InventoryRepository {
  /// Creates a fake over [stock] and [batches].
  ///
  /// No product names: naming rows is a products-repository job
  /// (`ProductsRepository.namesFor`), so the expiry controllers read names from the
  /// products fake and this one never sees them.
  ///
  /// [isOwner] decides which of the server's two behaviours this fake stands in for: the
  /// owner's correction is written, anybody else's is a request that moves nothing. The
  /// default is the owner, so every test written before the approval existed keeps
  /// asserting what it always asserted.
  FakeInventoryRepository({
    List<ProductStock> stock = const <ProductStock>[],
    List<BatchStatus> batches = const <BatchStatus>[],
    this.isOwner = true,
  }) : stock = List<ProductStock>.of(stock),
       batches = List<BatchStatus>.of(batches);

  /// The rows the stock view holds.
  final List<ProductStock> stock;

  /// The rows the batch view holds.
  final List<BatchStatus> batches;

  /// Whether writes land (the owner) or are raised as requests (everybody else).
  final bool isOwner;

  /// How many corrections the fake sent to the owner instead of writing.
  int stagedSubmissions = 0;

  /// The last query `stockList` was given.
  StockQuery? lastStockQuery;

  /// The product the last correction was recorded against.
  String? lastAdjustedProductId;

  /// The batch the last correction was recorded against.
  String? lastAdjustedBatchId;

  /// The direction of the last correction.
  AdjustmentType? lastAdjustmentType;

  /// The size of the last correction.
  int? lastAdjustedQty;

  /// The reason given to the last correction.
  String? lastAdjustmentReason;

  /// When true the next `stockList` throws.
  bool failNextStockList = false;

  /// When set, the next correction throws it.
  Exception? errorToThrow;

  @override
  Future<List<ProductStock>> stockList({
    required String pharmacyId,
    required StockQuery query,
    int limit = InventoryRepository.pageSize,
    int offset = 0,
  }) async {
    lastStockQuery = query;
    if (failNextStockList) {
      failNextStockList = false;
      throw StateError('the fake was told to fail');
    }

    final term = query.search.toLowerCase();
    final matching = stock.where((row) {
      final matchesTerm =
          term.isEmpty ||
          row.name.toLowerCase().contains(term) ||
          (row.genericName?.toLowerCase().contains(term) ?? false);
      final matchesAvailability = switch (query.availability) {
        StockAvailability.all => true,
        StockAvailability.inStock => row.totalQty > 0,
        StockAvailability.outOfStock => row.totalQty <= 0,
      };
      return matchesTerm && matchesAvailability;
    });

    return matching.skip(offset).take(limit).toList(growable: false);
  }

  @override
  Future<List<LowStockProduct>> lowStock({required String pharmacyId}) async {
    // The server's own rule, in the server's own order: below its level, with
    // a level configured, worst shortfall first and name breaking the tie
    // (migration 20260919000027). The real repository asks the RPC for exactly
    // this, so a test fixture that satisfies the fake satisfies the function.
    final products = stock
        .where((row) => row.minStockLevel > 0 && row.isLowStock)
        .map(
          (row) => LowStockProduct(
            productId: row.productId,
            name: row.name,
            genericName: row.genericName,
            totalQty: row.totalQty,
            minStockLevel: row.minStockLevel,
            shortfall: row.minStockLevel - row.totalQty,
          ),
        )
        .toList(growable: false);
    return products..sort((a, b) {
      final byShortfall = b.shortfall.compareTo(a.shortfall);
      return byShortfall != 0 ? byShortfall : a.name.compareTo(b.name);
    });
  }

  @override
  Future<List<BatchStatus>> expiringBatches({
    required String pharmacyId,
    required Set<ExpiryStatus> statuses,
  }) async =>
      batches
          .where(
            (batch) => batch.qty > 0 && statuses.contains(batch.expiryStatus),
          )
          .toList(growable: false)
        ..sort(_byExpiry);

  @override
  Future<List<BatchStatus>> batchesExpiringBetween({
    required String pharmacyId,
    required DateTime from,
    required DateTime to,
  }) async =>
      batches
          .where((batch) {
            // The real query compares the column, so a batch with no expiry is not
            // in the window - `expiry_date` is nullable since migration 00031.
            final date = batch.expiryDate;
            return batch.qty > 0 &&
                date != null &&
                !date.isBefore(from) &&
                !date.isAfter(to);
          })
          .toList(growable: false)
        ..sort(_byExpiry);

  @override
  Future<WriteOutcome<StockAdjustment>> adjustStock({
    required String pharmacyId,
    required String productId,
    required AdjustmentType type,
    required int qty,
    String? batchId,
    String? reason,
  }) async {
    lastAdjustedProductId = productId;
    lastAdjustedBatchId = batchId;
    lastAdjustmentType = type;
    lastAdjustedQty = qty;
    lastAdjustmentReason = reason;

    final error = errorToThrow;
    if (error != null) {
      errorToThrow = null;
      throw error;
    }

    // A member of staff's correction is a REQUEST (Phase 6.5c): the server writes no
    // row and moves no stock, so the fake reports the same outcome.
    if (!isOwner) {
      stagedSubmissions++;
      return WriteOutcome<StockAdjustment>.staged('ask-$productId');
    }

    return WriteOutcome<StockAdjustment>.recorded(
      StockAdjustment(
        id: 'adjustment-1',
        pharmacyId: 'ph-1',
        productId: productId,
        batchId: batchId,
        adjustmentType: type,
        qty: qty,
        reason: reason,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
