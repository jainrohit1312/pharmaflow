/// Shared test doubles for the purchase screens.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';

/// Builds a purchase with only the fields a test cares about.
Purchase buildPurchase({
  String id = 'purchase-1',
  String supplierId = 'sup-1',
  String invoiceNo = 'INV-1',
  PurchaseStatus status = PurchaseStatus.draft,
  double subTotal = 1000,
  double taxTotal = 120,
  double grandTotal = 1120,
  DateTime? stockPostedAt,
}) => Purchase(
  id: id,
  pharmacyId: 'ph-1',
  supplierId: supplierId,
  invoiceNo: invoiceNo,
  invoiceDate: DateTime(2026),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: status,
  subTotal: subTotal,
  taxTotal: taxTotal,
  grandTotal: grandTotal,
  stockPostedAt: stockPostedAt,
);

/// Builds one stored line of [purchaseId].
PurchaseItem buildItem({
  String id = 'item-1',
  String purchaseId = 'purchase-1',
  String? productId = 'product-1',
  String? productNameRaw = 'Paracetamol 500mg',
  int qty = 10,
  int freeQty = 0,
  double purchaseRate = 100,
  double mrp = 150,
  double gstPercent = 12,
  double cgstAmount = 60,
  double sgstAmount = 60,
  double taxAmount = 120,
  double totalAmount = 1120,
  String? batchNo,
  DateTime? expiryDate,
}) => PurchaseItem(
  id: id,
  pharmacyId: 'ph-1',
  purchaseId: purchaseId,
  qty: qty,
  freeQty: freeQty,
  purchaseRate: purchaseRate,
  mrp: mrp,
  gstPercent: gstPercent,
  cgstAmount: cgstAmount,
  sgstAmount: sgstAmount,
  taxAmount: taxAmount,
  totalAmount: totalAmount,
  productId: productId,
  productNameRaw: productNameRaw,
  batchNo: batchNo,
  expiryDate: expiryDate,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// Builds a supplier with only the fields a test cares about.
Supplier buildSupplier({
  String id = 'sup-1',
  String name = 'Arihant Distributors',
  bool isActive = true,
}) => Supplier(
  id: id,
  pharmacyId: 'ph-1',
  name: name,
  isActive: isActive,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// An in-memory [PurchasesRepository] that applies the query the way one page of
/// the real one would, and records what the writes were given.
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing:
/// `implements` does not require a constructor, so the fake never needs a
/// Supabase client - which is the whole point, because a real `SupabaseClient`
/// cannot be constructed without an initialised backend.
class FakePurchasesRepository implements PurchasesRepository {
  /// Creates a fake holding [purchases], already in display order.
  ///
  /// Both lists are copied, so a caller may hand over a `const` list and the
  /// fake may still append to what it holds.
  FakePurchasesRepository({
    required List<Purchase> purchases,
    List<PurchaseItem> items = const <PurchaseItem>[],
  }) : purchases = List<Purchase>.of(purchases),
       items = List<PurchaseItem>.of(items);

  /// The documents the fake knows about. `create` appends to it.
  final List<Purchase> purchases;

  /// The stored lines. `create`, `updateDraft` and `receive` replace them.
  final List<PurchaseItem> items;

  /// The last query `list` was given.
  PurchasesQuery? lastQuery;

  /// The header the last write was given.
  PurchaseDraft? lastHeader;

  /// The lines the last write was given.
  List<PurchaseLineDraft>? lastLines;

  /// The split the last write was given.
  TaxSplit? lastSplit;

  /// The status the last `setStatus` moved to.
  PurchaseStatus? lastStatus;

  /// The id the last `receive` was called with.
  String? lastReceivedId;

  /// When true the next `list` throws.
  bool failNextList = false;

  /// When set, the next write throws it.
  Exception? errorToThrow;

  @override
  Future<List<Purchase>> list({
    required String pharmacyId,
    required PurchasesQuery query,
    int limit = PurchasesRepository.pageSize,
    int offset = 0,
  }) async {
    lastQuery = query;
    if (failNextList) {
      failNextList = false;
      throw StateError('the fake was told to fail');
    }

    final term = query.search.toLowerCase();
    final matching = purchases.where((purchase) {
      final matchesTerm =
          term.isEmpty ||
          purchase.invoiceNo.toLowerCase().contains(term) ||
          (purchase.notes?.toLowerCase().contains(term) ?? false);
      final matchesSupplier =
          query.supplierId == null || purchase.supplierId == query.supplierId;
      final matchesStatus =
          query.status == null || purchase.status == query.status;
      final matchesFrom =
          query.from == null || !purchase.invoiceDate.isBefore(query.from!);
      final matchesTo =
          query.to == null || !purchase.invoiceDate.isAfter(query.to!);
      return matchesTerm &&
          matchesSupplier &&
          matchesStatus &&
          matchesFrom &&
          matchesTo;
    });

    return matching.skip(offset).take(limit).toList(growable: false);
  }

  @override
  Future<Purchase?> byId({
    required String pharmacyId,
    required String purchaseId,
  }) async {
    for (final purchase in purchases) {
      if (purchase.id == purchaseId) {
        return purchase;
      }
    }
    return null;
  }

  @override
  Future<List<PurchaseItem>> itemsFor({
    required String pharmacyId,
    required String purchaseId,
  }) async {
    return items
        .where((item) => item.purchaseId == purchaseId)
        .toList(growable: false);
  }

  @override
  Future<Purchase> create({
    required String pharmacyId,
    required PurchaseDraft header,
    required List<PurchaseLineDraft> lines,
    required TaxSplit split,
  }) async {
    _record(header: header, lines: lines, split: split);
    _rejectInvalid(lines, requireBatches: false);
    _maybeThrow();
    final saved = _write(purchases.length + 1, header, lines, split);
    purchases.add(saved);
    _replaceItems(saved.id, lines, split);
    return saved;
  }

  @override
  Future<Purchase> updateDraft({
    required String pharmacyId,
    required String purchaseId,
    required PurchaseDraft header,
    required List<PurchaseLineDraft> lines,
    required TaxSplit split,
  }) async {
    _record(header: header, lines: lines, split: split);
    _rejectInvalid(lines, requireBatches: false);
    _maybeThrow();
    // Matching the real repository: an edited document goes back to `draft`.
    final saved = _writeFrom(
      _find(purchaseId),
      header,
      lines,
      split,
      status: PurchaseStatus.draft,
    );
    _replace(purchaseId, saved);
    _replaceItems(purchaseId, lines, split);
    return saved;
  }

  @override
  Future<Purchase> setStatus({
    required String pharmacyId,
    required String purchaseId,
    required PurchaseStatus status,
  }) async {
    lastStatus = status;
    _maybeThrow();
    final saved = _find(purchaseId).copyWith(status: status);
    _replace(purchaseId, saved);
    return saved;
  }

  @override
  Future<Purchase> receive({
    required String pharmacyId,
    required String purchaseId,
    required PurchaseDraft header,
    required List<PurchaseLineDraft> lines,
    required TaxSplit split,
  }) async {
    _record(header: header, lines: lines, split: split);
    lastReceivedId = purchaseId;
    _rejectInvalid(lines, requireBatches: true);
    _maybeThrow();
    final saved = _writeFrom(
      _find(purchaseId),
      header,
      lines,
      split,
      status: PurchaseStatus.received,
      stockPostedAt: DateTime(2026),
    );
    _replace(purchaseId, saved);
    _replaceItems(purchaseId, lines, split);
    return saved;
  }

  /// Builds a brand new document from [header] and [lines].
  Purchase _write(
    int number,
    PurchaseDraft header,
    List<PurchaseLineDraft> lines,
    TaxSplit split,
  ) => _writeFrom(
    Purchase(
      id: 'new-$number',
      pharmacyId: 'ph-1',
      supplierId: header.supplierId,
      invoiceNo: header.invoiceNo,
      invoiceDate: header.invoiceDate,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      notes: header.notes,
    ),
    header,
    lines,
    split,
    status: PurchaseStatus.draft,
  );

  /// Applies [header] and [lines] to [base], with the totals they produce.
  Purchase _writeFrom(
    Purchase base,
    PurchaseDraft header,
    List<PurchaseLineDraft> lines,
    TaxSplit split, {
    required PurchaseStatus status,
    DateTime? stockPostedAt,
  }) {
    final totals = PurchaseTotals.forLines(lines, split: split);
    return base.copyWith(
      supplierId: header.supplierId,
      invoiceNo: header.invoiceNo,
      invoiceDate: header.invoiceDate,
      notes: header.notes,
      status: status,
      subTotal: totals.subTotal,
      taxTotal: totals.taxTotal,
      grandTotal: totals.grandTotal,
      stockPostedAt: stockPostedAt ?? base.stockPostedAt,
    );
  }

  /// Replaces the stored lines of [purchaseId] with [lines].
  void _replaceItems(
    String purchaseId,
    List<PurchaseLineDraft> lines,
    TaxSplit split,
  ) {
    items.removeWhere((item) => item.purchaseId == purchaseId);
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final totals = PurchaseTotals.forLine(line, split: split);
      items.add(
        PurchaseItem(
          id: '$purchaseId-item-$index',
          pharmacyId: 'ph-1',
          purchaseId: purchaseId,
          qty: line.qty,
          freeQty: line.freeQty,
          purchaseRate: line.purchaseRate,
          mrp: line.mrp,
          sellingRate: line.sellingRate,
          discountPercent: line.discountPercent,
          gstPercent: line.gstPercent,
          cgstAmount: totals.cgst,
          sgstAmount: totals.sgst,
          igstAmount: totals.igst,
          taxAmount: totals.tax,
          totalAmount: totals.total,
          productId: line.productId,
          productNameRaw: line.productNameRaw,
          batchNo: line.batchNo,
          expiryDate: line.expiryDate,
          hsnCode: line.hsnCode,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );
    }
  }

  /// Records what a write was handed.
  void _record({
    required PurchaseDraft header,
    required List<PurchaseLineDraft> lines,
    required TaxSplit split,
  }) {
    lastHeader = header;
    lastLines = lines;
    lastSplit = split;
  }

  /// Throws the failure the real repository would raise for [lines].
  ///
  /// The same `validateLines` the repository calls, so a screen that skips a
  /// check the real write enforces fails here rather than in front of a user.
  void _rejectInvalid(
    List<PurchaseLineDraft> lines, {
    required bool requireBatches,
  }) {
    final invalid = PurchasesRepository.validateLines(
      lines,
      requireBatches: requireBatches,
    );
    if (invalid != null) {
      throw ValidationException(message: invalid);
    }
  }

  /// Throws the queued failure, if one was set.
  void _maybeThrow() {
    final error = errorToThrow;
    if (error != null) {
      errorToThrow = null;
      throw error;
    }
  }

  /// The stored document with [purchaseId].
  Purchase _find(String purchaseId) => purchases.firstWhere(
    (purchase) => purchase.id == purchaseId,
    orElse: () => throw StateError('no purchase $purchaseId in the fake'),
  );

  /// Swaps the stored document for [saved].
  void _replace(String purchaseId, Purchase saved) {
    final index = purchases.indexWhere((purchase) => purchase.id == purchaseId);
    if (index < 0) {
      purchases.add(saved);
      return;
    }
    purchases[index] = saved;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
