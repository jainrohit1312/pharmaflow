/// Shared test double for the purchase returns screens.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_return.dart';
import 'package:app/data/models/purchase_return_item.dart';
import 'package:app/features/returns/data/purchase_return_totals.dart';
import 'package:app/features/returns/data/purchase_returns_repository.dart';

/// Builds a purchase return with only the fields a test cares about.
PurchaseReturn buildPurchaseReturn({
  String id = 'return-1',
  String purchaseId = 'purchase-1',
  String supplierId = 'sup-1',
  DateTime? returnDate,
  double subTotal = 900,
  double taxTotal = 108,
  double grandTotal = 1008,
  String status = 'completed',
  String? reason,
}) => PurchaseReturn(
  id: id,
  pharmacyId: 'ph-1',
  purchaseId: purchaseId,
  supplierId: supplierId,
  returnDate: returnDate ?? DateTime(2026, 9, 18),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  subTotal: subTotal,
  taxTotal: taxTotal,
  grandTotal: grandTotal,
  status: status,
  reason: reason,
);

/// Builds one stored return line.
PurchaseReturnItem buildReturnItem({
  String id = 'return-item-1',
  String purchaseReturnId = 'return-1',
  String? purchaseItemId = 'item-1',
  String? productId = 'product-1',
  String? batchId = 'batch-1',
  int qty = 4,
  double purchaseRate = 100,
  double mrp = 150,
  double gstPercent = 12,
  double taxAmount = 43.20,
  double totalAmount = 403.20,
}) => PurchaseReturnItem(
  id: id,
  pharmacyId: 'ph-1',
  purchaseReturnId: purchaseReturnId,
  purchaseItemId: purchaseItemId,
  productId: productId,
  batchId: batchId,
  qty: qty,
  purchaseRate: purchaseRate,
  mrp: mrp,
  gstPercent: gstPercent,
  taxAmount: taxAmount,
  totalAmount: totalAmount,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// An in-memory [PurchaseReturnsRepository].
///
/// The money is computed with the real [PurchaseReturnTotals], so a screen test
/// cannot pass against friendlier arithmetic than the write uses. The limits are
/// re-checked here the way the real repository checks them, for the same reason -
/// a form that skipped a check the write enforces should fail in the test.
class FakePurchaseReturnsRepository implements PurchaseReturnsRepository {
  /// Creates a fake over [returns], [items], [purchases] and [returnable].
  FakePurchaseReturnsRepository({
    List<PurchaseReturn> returns = const <PurchaseReturn>[],
    List<PurchaseReturnItem> items = const <PurchaseReturnItem>[],
    List<Purchase> purchases = const <Purchase>[],
    Map<String, List<ReturnableLine>> returnable =
        const <String, List<ReturnableLine>>{},
  }) : returns = List<PurchaseReturn>.of(returns),
       items = List<PurchaseReturnItem>.of(items),
       purchases = List<Purchase>.of(purchases),
       returnable = Map<String, List<ReturnableLine>>.of(returnable);

  /// The documents the fake knows about. `create` inserts at the front.
  final List<PurchaseReturn> returns;

  /// The stored lines. `create` appends to them.
  final List<PurchaseReturnItem> items;

  /// The purchases a return may be raised against.
  final List<Purchase> purchases;

  /// What can go back from each purchase, by purchase id.
  final Map<String, List<ReturnableLine>> returnable;

  /// The quantities the last `create` was given.
  Map<String, int>? lastQuantities;

  /// The reason the last `create` was given.
  String? lastReason;

  /// The date the last `create` was given.
  DateTime? lastReturnDate;

  /// When true the next `list` throws.
  bool failNextList = false;

  /// When set, the next `create` throws it.
  Exception? errorToThrow;

  int _nextId = 0;

  @override
  Future<List<PurchaseReturn>> list({
    required String pharmacyId,
    int limit = PurchaseReturnsRepository.pageSize,
    int offset = 0,
  }) async {
    if (failNextList) {
      failNextList = false;
      throw StateError('the fake was told to fail');
    }
    return returns.skip(offset).take(limit).toList(growable: false);
  }

  @override
  Future<PurchaseReturn?> byId({
    required String pharmacyId,
    required String returnId,
  }) async {
    for (final entry in returns) {
      if (entry.id == returnId) {
        return entry;
      }
    }
    return null;
  }

  @override
  Future<List<PurchaseReturnItem>> itemsFor({
    required String pharmacyId,
    required String returnId,
  }) async => items
      .where((item) => item.purchaseReturnId == returnId)
      .toList(growable: false);

  @override
  Future<List<ReturnableLine>> returnableFor({
    required String pharmacyId,
    required String purchaseId,
  }) async => returnable[purchaseId] ?? const <ReturnableLine>[];

  @override
  Future<PurchaseReturn> create({
    required String pharmacyId,
    required String purchaseId,
    required DateTime returnDate,
    required Map<String, int> quantities,
    String? reason,
  }) async {
    lastQuantities = quantities;
    lastReason = reason;
    lastReturnDate = returnDate;

    final requested = Map<String, int>.fromEntries(
      quantities.entries.where((entry) => entry.value > 0),
    );
    if (requested.isEmpty) {
      throw const ValidationException(
        message: 'Enter how many units are going back.',
      );
    }

    final purchase = _purchase(purchaseId);
    if (purchase.status != PurchaseStatus.received) {
      throw ValidationException(
        message:
            'Goods can only be returned after the purchase has been received, '
            'and this one is ${purchase.status.label.toLowerCase()}.',
      );
    }

    final lines = returnable[purchaseId] ?? const <ReturnableLine>[];
    final byItemId = <String, ReturnableLine>{
      for (final line in lines) line.item.id: line,
    };
    final amounts = <PurchaseReturnLineAmounts>[];
    final created = <PurchaseReturnItem>[];
    final returnId = 'return-${++_nextId}';

    for (final entry in requested.entries) {
      final line = byItemId[entry.key];
      if (line == null) {
        throw const ValidationException(
          message: 'That purchase no longer has the line being returned.',
        );
      }
      final blocked = line.blockedReason;
      if (blocked != null) {
        throw ValidationException(message: blocked);
      }
      if (entry.value > line.returnable) {
        throw ValidationException(
          message:
              'Only ${line.returnable} '
              '${line.returnable == 1 ? 'unit' : 'units'} of '
              '${line.item.productNameRaw} can still go back.',
        );
      }

      final lineAmounts = PurchaseReturnTotals.forLine(
        item: line.item,
        qty: entry.value,
      );
      amounts.add(lineAmounts);
      created.add(
        buildReturnItem(
          id: '$returnId-item-${created.length}',
          purchaseReturnId: returnId,
          purchaseItemId: line.item.id,
          productId: line.item.productId,
          batchId: line.item.batchId,
          qty: entry.value,
          purchaseRate: line.item.purchaseRate,
          mrp: line.item.mrp,
          gstPercent: line.item.gstPercent,
          taxAmount: lineAmounts.tax,
          totalAmount: lineAmounts.total,
        ),
      );
    }

    final error = errorToThrow;
    if (error != null) {
      errorToThrow = null;
      throw error;
    }

    final totals = PurchaseReturnTotals.forLines(amounts);
    final saved = PurchaseReturn(
      id: returnId,
      pharmacyId: 'ph-1',
      purchaseId: purchaseId,
      supplierId: purchase.supplierId,
      returnDate: returnDate,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      subTotal: totals.subTotal,
      taxTotal: totals.taxTotal,
      grandTotal: totals.grandTotal,
      reason: reason,
    );

    returns.insert(0, saved);
    items.addAll(created);
    return saved;
  }

  /// The purchase being returned against.
  Purchase _purchase(String purchaseId) => purchases.firstWhere(
    (purchase) => purchase.id == purchaseId,
    orElse: () => throw StateError('no purchase $purchaseId in the fake'),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
