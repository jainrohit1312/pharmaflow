/// Shared test double for the sale returns screens and controllers.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'dart:async';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_return.dart';
import 'package:app/features/returns/data/sale_return_totals.dart';
import 'package:app/features/returns/data/sale_returns_repository.dart';

/// Builds a sale return with only the fields a test cares about.
///
/// The money defaults to the slice the fixtures in these tests describe: 4 of the
/// 5 units of a line that stored 400 taxable, 48 tax and 448.
SaleReturn buildSaleReturn({
  String id = 'return-1',
  String saleId = 'sale-1',
  DateTime? returnDate,
  PaymentMode refundMode = PaymentMode.cash,
  bool restock = true,
  double subTotal = 320,
  double taxTotal = 38.40,
  double grandTotal = 358.40,
  String status = 'completed',
  String? customerId,
  String? reason,
}) => SaleReturn(
  id: id,
  pharmacyId: 'ph-1',
  saleId: saleId,
  returnDate: returnDate ?? DateTime(2026, 9, 18),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  refundMode: refundMode,
  restock: restock,
  subTotal: subTotal,
  taxTotal: taxTotal,
  grandTotal: grandTotal,
  status: status,
  customerId: customerId,
  reason: reason,
);

/// Builds one stored return line.
///
/// The four money fields are the slice [SaleReturnTotals] worked out from the
/// sold line, which is what the real repository stores.
SaleReturnItem buildSaleReturnItem({
  String id = 'return-item-1',
  String saleReturnId = 'return-1',
  String? saleItemId = 'item-1',
  String? productId = 'product-1',
  String? batchId = 'batch-1',
  int qty = 4,
  double rate = 100,
  double gstPercent = 12,
  double taxAmount = 38.40,
  double totalAmount = 358.40,
}) => SaleReturnItem(
  id: id,
  pharmacyId: 'ph-1',
  saleReturnId: saleReturnId,
  saleItemId: saleItemId,
  productId: productId,
  batchId: batchId,
  qty: qty,
  rate: rate,
  gstPercent: gstPercent,
  taxAmount: taxAmount,
  totalAmount: totalAmount,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// An in-memory [SaleReturnsRepository].
///
/// The money is computed with the real [SaleReturnTotals], and the limits are
/// re-checked here the way the real repository checks them, so a form that skipped
/// a check the write enforces fails in the test rather than in front of a user:
/// the cap is `billed - already returned`, an all-zero set is refused, and a
/// cancelled bill cannot be credited.
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing:
/// `implements` does not require a constructor, so the fake never needs a
/// Supabase client - which is the whole point, because a real `SupabaseClient`
/// cannot be constructed without an initialised backend.
class FakeSaleReturnsRepository implements SaleReturnsRepository {
  /// Creates a fake over [returns], [items], [sales] and [returnable].
  FakeSaleReturnsRepository({
    List<SaleReturn> returns = const <SaleReturn>[],
    List<SaleReturnItem> items = const <SaleReturnItem>[],
    List<Sale> sales = const <Sale>[],
    Map<String, List<SaleReturnableLine>> returnable =
        const <String, List<SaleReturnableLine>>{},
  }) : returns = List<SaleReturn>.of(returns),
       items = List<SaleReturnItem>.of(items),
       sales = List<Sale>.of(sales),
       returnable = Map<String, List<SaleReturnableLine>>.of(returnable);

  /// The documents the fake knows about. `create` inserts at the front.
  final List<SaleReturn> returns;

  /// The stored lines. `create` appends to them.
  final List<SaleReturnItem> items;

  /// The `sales` rows a write reads the bill's status from.
  final List<Sale> sales;

  /// What can come back from each sale, by sale id.
  final Map<String, List<SaleReturnableLine>> returnable;

  /// What the last `create` was asked for, accepted or refused.
  Map<String, int>? lastQuantities;

  /// The restock flag the last `create` was asked for.
  bool? lastRestock;

  /// The refund mode the last `create` was asked for.
  PaymentMode? lastRefundMode;

  /// The reason the last `create` was given.
  String? lastReason;

  /// The date the last `create` was given.
  DateTime? lastReturnDate;

  /// While true, *every* write throws until the test clears it.
  ///
  /// Persistent rather than one-shot on purpose: the form can be submitted more
  /// than once before a test looks at it, and a failure that cleared itself would
  /// be retried into a success.
  bool failCreate = false;

  /// While true, *every* `returnableFor` throws until the test clears it.
  ///
  /// Persistent for the same reason as [failCreate]: GoRouter builds a route more
  /// than once before the first frame settles.
  bool failReturnableFor = false;

  /// When set, `create` waits on it before it writes.
  ///
  /// Lets a test look at the screen while the write is still in flight - the
  /// submit button disables itself and shows a spinner there.
  Completer<void>? createGate;

  int _nextId = 0;

  @override
  Future<List<SaleReturn>> list({
    required String pharmacyId,
    int limit = SaleReturnsRepository.pageSize,
    int offset = 0,
  }) async => returns.skip(offset).take(limit).toList(growable: false);

  @override
  Future<SaleReturn?> byId({
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
  Future<List<SaleReturnItem>> itemsFor({
    required String pharmacyId,
    required String returnId,
  }) async => items
      .where((item) => item.saleReturnId == returnId)
      .toList(growable: false);

  @override
  Future<List<SaleReturnableLine>> returnableFor({
    required String pharmacyId,
    required String saleId,
  }) async {
    if (failReturnableFor) {
      throw const ServerException(
        message: 'Unable to load what can be returned from that sale.',
      );
    }
    return returnable[saleId] ?? const <SaleReturnableLine>[];
  }

  @override
  Future<SaleReturn> create({
    required String pharmacyId,
    required String saleId,
    required DateTime returnDate,
    required Map<String, int> quantities,
    required bool restock,
    required PaymentMode refundMode,
    String? reason,
  }) async {
    lastQuantities = Map<String, int>.of(quantities);
    lastRestock = restock;
    lastRefundMode = refundMode;
    lastReason = reason;
    lastReturnDate = returnDate;

    final gate = createGate;
    if (gate != null) {
      await gate.future;
    }
    if (failCreate) {
      throw const ServerException(
        message: 'Unable to record that sale return.',
      );
    }

    final requested = Map<String, int>.fromEntries(
      quantities.entries.where((entry) => entry.value > 0),
    );
    if (requested.isEmpty) {
      throw const ValidationException(
        message: 'Enter how many units are coming back.',
      );
    }

    final sale = _sale(saleId);
    if (sale.status == SaleStatus.cancelled) {
      throw const ValidationException(
        message: 'That sale was cancelled, so nothing can come back from it.',
      );
    }

    final lines = returnable[saleId] ?? const <SaleReturnableLine>[];
    final byItemId = <String, SaleReturnableLine>{
      for (final line in lines) line.item.id: line,
    };
    final amounts = <SaleReturnLineAmounts>[];
    final created = <SaleReturnItem>[];
    final returnId = 'return-${++_nextId}';

    for (final entry in requested.entries) {
      final line = byItemId[entry.key];
      if (line == null) {
        throw const ValidationException(
          message: 'That sale no longer has the line being returned.',
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
              '${line.returnable == 1 ? 'unit' : 'units'} of that line '
              'can still come back.',
        );
      }

      final lineAmounts = SaleReturnTotals.forLine(
        item: line.item,
        qty: entry.value,
      );
      amounts.add(lineAmounts);
      created.add(
        buildSaleReturnItem(
          id: '$returnId-item-${created.length}',
          saleReturnId: returnId,
          saleItemId: line.item.id,
          productId: line.item.productId,
          batchId: line.item.batchId,
          qty: entry.value,
          rate: line.item.rate,
          gstPercent: line.item.gstPercent,
          taxAmount: lineAmounts.tax,
          totalAmount: lineAmounts.total,
        ),
      );
    }

    final totals = SaleReturnTotals.forLines(amounts);
    final saved = buildSaleReturn(
      id: returnId,
      saleId: saleId,
      returnDate: returnDate,
      refundMode: refundMode,
      restock: restock,
      subTotal: totals.subTotal,
      taxTotal: totals.taxTotal,
      grandTotal: totals.grandTotal,
      customerId: sale.customerId,
      reason: reason,
    );

    returns.insert(0, saved);
    items.addAll(created);
    return saved;
  }

  /// The bill being returned against.
  Sale _sale(String saleId) {
    for (final sale in sales) {
      if (sale.id == saleId) {
        return sale;
      }
    }
    throw const NotFoundException(message: 'That sale no longer exists.');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
