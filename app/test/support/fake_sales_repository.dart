/// Shared test double for the sales screens and controllers.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'dart:async';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_item.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/data/sale_checkout.dart';
import 'package:app/features/sales/data/sales_repository.dart';

/// Builds a sale with only the fields a test cares about.
///
/// The money defaults to nothing at all rather than to a plausible bill: a sale
/// fixture that came with figures of its own would have to be overridden by every
/// test that asserts one, and a test that forgot to would pass for the wrong
/// reason.
Sale buildSale({
  String id = 'sale-1',
  String invoiceNo = 'INV-1',
  SaleStatus status = SaleStatus.completed,
  PaymentMode paymentMode = PaymentMode.cash,
  double subTotal = 0,
  double taxTotal = 0,
  double grandTotal = 0,
  double amountPaid = 0,
  double balanceDue = 0,
  DateTime? saleDate,
  String? customerId,
}) => Sale(
  id: id,
  pharmacyId: 'ph-1',
  invoiceNo: invoiceNo,
  saleDate: saleDate ?? DateTime(2026, 9, 18),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: status,
  paymentMode: paymentMode,
  subTotal: subTotal,
  taxTotal: taxTotal,
  grandTotal: grandTotal,
  amountPaid: amountPaid,
  balanceDue: balanceDue,
  customerId: customerId,
);

/// Builds a sold line with only the fields a test cares about.
///
/// [totalAmount] and [taxAmount] are stored on the row, so a fixture has to carry
/// both: every figure a return derives comes from them, not from `qty x rate`
/// (D-020's rule, inherited by the sale side).
SaleItem buildSaleItem({
  String id = 'item-1',
  String saleId = 'sale-1',
  String batchId = 'batch-1',
  String? productId = 'product-1',
  int qty = 2,
  double rate = 100,
  double gstPercent = 12,
  double taxAmount = 24,
  double totalAmount = 224,
}) => SaleItem(
  id: id,
  pharmacyId: 'ph-1',
  saleId: saleId,
  batchId: batchId,
  qty: qty,
  rate: rate,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  gstPercent: gstPercent,
  taxAmount: taxAmount,
  totalAmount: totalAmount,
  productId: productId,
);

/// Builds a document line: the stored line plus the pack it came out of.
///
/// The batch detail is what `sale_document()` adds to a `sale_items` row. Its defaults
/// are a pack with a number and **no expiry** on purpose: 145 of the owner's
/// opening-stock batches carry no date, so an undated pack is the ordinary case here
/// rather than a corner, and a fixture that wants a date asks for one.
SaleDocumentLine buildSaleDocumentLine({
  SaleItem? item,
  String batchNo = 'batch-1',
  DateTime? expiryDate,
  bool isUnknownBatch = false,
}) => SaleDocumentLine(
  item: item ?? buildSaleItem(),
  batchNo: batchNo,
  expiryDate: expiryDate,
  isUnknownBatch: isUnknownBatch,
);

/// An in-memory [SalesRepository].
///
/// `checkout` sums the payload's own lines into the document it returns, which is
/// what `checkout_sale()` does server-side ("the function *sums* these for the
/// header but never recomputes them"). A test can therefore assert that what the
/// counter showed is what the till stored.
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing:
/// `implements` does not require a constructor, so the fake never needs a
/// Supabase client - which is the whole point, because a real `SupabaseClient`
/// cannot be constructed without an initialised backend.
class FakeSalesRepository implements SalesRepository {
  /// Creates a fake over [sales] and [items].
  FakeSalesRepository({List<Sale>? sales, List<SaleItem>? items})
    : sales = List<Sale>.of(sales ?? const <Sale>[]),
      items = List<SaleItem>.of(items ?? const <SaleItem>[]);

  /// The sales the fake holds.
  final List<Sale> sales;

  /// Every sold line the fake holds, for every sale.
  final List<SaleItem> items;

  /// Offsets `list` was asked for, in order.
  final List<int> requestedOffsets = <int>[];

  /// The last query the list was given.
  SalesQuery? lastQuery;

  /// The payloads `checkout` was handed, in order.
  final List<SaleCheckout> checkouts = <SaleCheckout>[];

  /// When true the next `list` call throws.
  bool failNextList = false;

  /// When set, *every* read throws it until the test clears it.
  ///
  /// Persistent rather than one-shot on purpose: a route can be built more than
  /// once before the first frame settles, so a failure that cleared itself would
  /// be retried into a success before a test could look at the error state.
  Exception? errorToThrow;

  /// When set, `list` waits for it before answering.
  ///
  /// A read that can be held open is the only way to look at a *loading* state:
  /// a screen has to render something while the rows are on their way, and that
  /// is the state T-5 is about.
  Completer<void>? listGate;

  /// The products [recentlySoldProductIds] answers with, in sold order.
  ///
  /// Set by a test that wants the counter's Recent strip to have something in it;
  /// the real read works them out from the recent sales and their lines.
  List<String> recentProductIds = const <String>[];

  /// When set, `checkout` waits for it before answering.
  ///
  /// Holds a write open, which is the only way to look at the window between a tap
  /// and its answer - the window a second tap arrives in.
  Completer<void>? checkoutGate;

  /// The patient code the document read answers with.
  ///
  /// `null` by default, which is the honest default: a package bill's party is the
  /// hospital's account row and a customer registered before Phase 7a has no code, so a
  /// fixture that wants one asks for it.
  String? patientCode;

  /// The batch detail `saleDocument` answers with, by item id.
  ///
  /// An item with no entry answers as an undated pack with a number of its own, which is
  /// what `buildSaleDocumentLine` defaults to.
  final Map<String, SaleDocumentLine> documentLines =
      <String, SaleDocumentLine>{};

  @override
  Future<SaleDocument?> saleDocument({required String saleId}) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    for (final sale in sales) {
      if (sale.id == saleId) {
        return SaleDocument(
          sale: sale,
          patientCode: patientCode,
          // Derived from the held lines, so a test that already has a bill gets a
          // document for it without describing the same sale twice - and the batch
          // detail stays overridable per item.
          lines: <SaleDocumentLine>[
            for (final item in items)
              if (item.saleId == saleId)
                documentLines[item.id] ?? buildSaleDocumentLine(item: item),
          ],
        );
      }
    }
    // The real function answers `null` for a sale outside the caller's pharmacy, and
    // the screen reads that as a bill that is not there rather than as a failure.
    return null;
  }

  @override
  Future<List<String>> recentlySoldProductIds({
    required String pharmacyId,
    int limit = 10,
  }) async => recentProductIds.take(limit).toList(growable: false);

  @override
  Future<List<Sale>> list({
    required String pharmacyId,
    required SalesQuery query,
    int limit = SalesRepository.pageSize,
    int offset = 0,
  }) async {
    lastQuery = query;
    requestedOffsets.add(offset);
    final gate = listGate;
    if (gate != null) {
      await gate.future;
    }
    if (failNextList) {
      failNextList = false;
      throw StateError('the fake was told to fail');
    }
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }

    // Filters the way the real query does, including the end-of-day reach on the
    // upper bound - `sale_date` is a timestamp, so `lte midnight` would drop
    // everything sold on the last day of the window.
    final term = query.search.toLowerCase();
    final matching = sales.where((sale) {
      final matchesTerm =
          term.isEmpty || sale.invoiceNo.toLowerCase().contains(term);
      final matchesStatus = query.status == null || sale.status == query.status;
      final from = query.from;
      final to = query.to;
      final matchesFrom = from == null || !sale.saleDate.isBefore(from);
      final matchesTo =
          to == null ||
          !sale.saleDate.isAfter(
            DateTime(to.year, to.month, to.day, 23, 59, 59, 999),
          );
      return matchesTerm && matchesStatus && matchesFrom && matchesTo;
    });

    return matching.skip(offset).take(limit).toList(growable: false);
  }

  @override
  Future<Sale?> byId({
    required String pharmacyId,
    required String saleId,
  }) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    for (final sale in sales) {
      if (sale.id == saleId) {
        return sale;
      }
    }
    return null;
  }

  @override
  Future<List<SaleItem>> itemsFor({
    required String pharmacyId,
    required String saleId,
  }) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    return items.where((item) => item.saleId == saleId).toList(growable: false);
  }

  @override
  Future<Sale> checkout({
    required String pharmacyId,
    required SaleCheckout checkout,
  }) async {
    // The check the real repository makes before it reaches the RPC, so a screen
    // that skips it fails here rather than in front of a user.
    if (checkout.lines.isEmpty) {
      throw const ValidationException(
        message: 'Add at least one line before taking payment.',
      );
    }
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    final gate = checkoutGate;
    if (gate != null) {
      await gate.future;
    }

    checkouts.add(checkout);
    final totals = _sumLines(checkout);
    final saved = Sale(
      id: 'sale-${sales.length + 1}',
      pharmacyId: pharmacyId,
      invoiceNo: 'INV-${sales.length + 1}',
      saleDate: DateTime(2026, 9, 18),
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      status: checkout.amountPaid < totals.grandTotal
          ? SaleStatus.credit
          : SaleStatus.completed,
      paymentMode: checkout.paymentMode,
      subTotal: totals.subTotal,
      discountTotal: totals.discountTotal,
      taxTotal: totals.taxTotal,
      grandTotal: totals.grandTotal,
      amountPaid: checkout.amountPaid,
      balanceDue: PurchaseTotals.round2(
        totals.grandTotal - checkout.amountPaid,
      ),
      customerId: checkout.customerId,
      placeOfSupply: checkout.placeOfSupply,
      // Echoed from the payload, the way `checkout_sale()` stores them: what the
      // counter sent is what a test can then read back off the document.
      saleType: checkout.saleType,
      patientName: checkout.patientName,
      patientMobile: checkout.patientMobile,
      admissionId: checkout.admissionId,
      doctorId: checkout.doctorId,
      doctorName: checkout.doctorName,
      hospitalReference: checkout.hospitalReference,
      fromLocation: checkout.fromLocation,
      toLocation: checkout.toLocation,
      transferReason: checkout.transferReason,
      idempotencyKey: checkout.idempotencyKey,
    );
    sales.insert(0, saved);
    return saved;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}

/// The document totals of a payload, summed from its own lines.
///
/// The same sum `checkout_sale()` does, and the reason the client never sends a
/// grand total: a stored figure that was worked out separately could disagree with
/// the lines it describes.
SaleDocumentTotalSum _sumLines(SaleCheckout checkout) {
  var subTotal = 0.0;
  var discountTotal = 0.0;
  var taxTotal = 0.0;
  var grandTotal = 0.0;
  for (final line in checkout.lines) {
    subTotal += line.totalAmount - line.taxAmount;
    discountTotal += line.discountAmount;
    taxTotal += line.taxAmount;
    grandTotal += line.totalAmount;
  }
  return SaleDocumentTotalSum(
    subTotal: PurchaseTotals.round2(subTotal),
    discountTotal: PurchaseTotals.round2(discountTotal),
    taxTotal: PurchaseTotals.round2(taxTotal),
    grandTotal: PurchaseTotals.round2(grandTotal),
  );
}

/// What a payload's lines add up to.
class SaleDocumentTotalSum {
  /// Creates a sum.
  const SaleDocumentTotalSum({
    required this.subTotal,
    required this.discountTotal,
    required this.taxTotal,
    required this.grandTotal,
  });

  /// Value before tax.
  final double subTotal;

  /// Discounts taken off.
  final double discountTotal;

  /// Tax charged.
  final double taxTotal;

  /// What the customer is charged.
  final double grandTotal;
}
