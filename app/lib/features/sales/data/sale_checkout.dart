/// The `jsonb` payload `checkout_sale()` takes.
///
/// Plain classes rather than Freezed models: this shape is written and never read
/// back - what comes home from the RPC is a `sales` row, which has its own model -
/// so there is no JSON round trip to generate, and the payload is the one place
/// where the RPC's field names have to be spelled exactly.
library;

import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_cart_line.dart';
import 'package:app/features/sales/data/sale_totals.dart';

/// One line as `checkout_sale()` expects it.
///
/// Every money column is sent explicitly, computed by [SaleTotals] from what the
/// counter chose. What the server does with them depends on whether the payload
/// names a `sale_type` (migration 00036's compatibility seam): a **typed** payload
/// has its slab, its four tax columns and its totals recomputed server-side, so
/// these figures are the client's *preview* of the same arithmetic rather than the
/// authority - which is exactly why [SaleTotals] replicates the server's basis
/// (D-075) instead of choosing one of its own. An **untyped** payload is the legacy
/// counter sale, and there the figures are stored verbatim, as they always were.
class SaleCheckoutLine {
  /// Creates a checkout line.
  const SaleCheckoutLine({
    required this.productId,
    required this.batchId,
    required this.qty,
    required this.rate,
    required this.scheduleType,
    this.discountPercent = 0,
    this.discountAmount = 0,
    this.gstPercent = 0,
    this.cgstAmount = 0,
    this.sgstAmount = 0,
    this.igstAmount = 0,
    this.taxAmount = 0,
    this.totalAmount = 0,
  });

  /// Builds the payload line for [line], with the money [totals] computed.
  factory SaleCheckoutLine.from({
    required SaleCartLine line,
    required SaleLineTotals totals,
  }) => SaleCheckoutLine(
    productId: line.productId,
    batchId: line.batchId,
    qty: line.qty,
    rate: line.rate,
    scheduleType: line.scheduleType,
    discountPercent: line.discountPercent,
    discountAmount: totals.discount,
    gstPercent: line.gstPercent,
    cgstAmount: totals.cgst,
    sgstAmount: totals.sgst,
    igstAmount: totals.igst,
    taxAmount: totals.tax,
    totalAmount: totals.total,
  );

  /// What was sold.
  final String productId;

  /// The batch it comes out of. Never null: the stock trigger needs it.
  final String batchId;

  /// How many units.
  final int qty;

  /// The rate charged per unit.
  final double rate;

  /// The product's schedule at the moment of sale, for the drug register.
  final ScheduleType scheduleType;

  /// The discount as a percentage, as the counter entered it.
  final double discountPercent;

  /// The discount in money, which is what the column stores.
  final double discountAmount;

  /// The GST slab applied.
  final double gstPercent;

  /// Central share of the tax.
  final double cgstAmount;

  /// State share of the tax.
  final double sgstAmount;

  /// Integrated tax, for an inter-state supply.
  final double igstAmount;

  /// Total tax on the line.
  final double taxAmount;

  /// What the line is charged at: taxable value plus tax.
  final double totalAmount;

  /// The JSON object the RPC reads.
  Map<String, dynamic> toPayload() => <String, dynamic>{
    'product_id': productId,
    'batch_id': batchId,
    'qty': qty,
    'rate': rate,
    'discount_percent': discountPercent,
    'discount_amount': discountAmount,
    'gst_percent': gstPercent,
    'cgst_amount': cgstAmount,
    'sgst_amount': sgstAmount,
    'igst_amount': igstAmount,
    'tax_amount': taxAmount,
    'total_amount': totalAmount,
    'schedule_type': scheduleType.dbValue,
  };
}

/// A whole sale, ready to be written.
class SaleCheckout {
  /// Creates a checkout.
  const SaleCheckout({
    required this.lines,
    this.customerId,
    this.paymentMode = PaymentMode.cash,
    this.amountPaid = 0,
    this.placeOfSupply,
  });

  /// Its lines, in cart order.
  final List<SaleCheckoutLine> lines;

  /// Who bought it, or `null` for a walk-in.
  final String? customerId;

  /// How it was settled.
  final PaymentMode paymentMode;

  /// What was taken. The RPC refuses more than the total, so this is the
  /// clamped figure from [SaleTotals.recordablePaid], not the raw tender.
  final double amountPaid;

  /// The customer's state, for the intra/inter-state tax split.
  final String? placeOfSupply;

  /// The JSON object the RPC reads.
  ///
  /// Document totals are deliberately absent: `checkout_sale()` sums the lines
  /// itself rather than trusting a figure the client worked out, so a stored
  /// grand total cannot disagree with the lines it describes.
  Map<String, dynamic> toPayload() => <String, dynamic>{
    'customer_id': customerId,
    'payment_mode': paymentMode.dbValue,
    'amount_paid': amountPaid,
    'place_of_supply': placeOfSupply,
    'items': lines.map((line) => line.toPayload()).toList(growable: false),
  };
}
