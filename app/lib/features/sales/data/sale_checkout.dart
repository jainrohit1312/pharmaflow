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
  ///
  /// [saleType] decides one thing here: a package or transfer line carries **no
  /// discount**, and the server refuses one that does. The cart may still hold a
  /// percentage from an earlier type - it is left out rather than sent, because a
  /// refusal at the till is not a way to discover a field nobody meant to send.
  factory SaleCheckoutLine.from({
    required SaleCartLine line,
    required SaleLineTotals totals,
    required SaleType saleType,
  }) => SaleCheckoutLine(
    productId: line.productId,
    batchId: line.batchId,
    qty: line.qty,
    rate: line.rate,
    scheduleType: line.scheduleType,
    discountPercent: saleType.hasDiscount ? line.discountPercent : 0,
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

  /// What the line is charged at: the price the customer pays for it.
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
    this.saleType = SaleType.counter,
    this.customerId,
    this.patientName,
    this.patientMobile,
    this.admissionId,
    this.doctorId,
    this.doctorName,
    this.hospitalReference,
    this.paymentMode = PaymentMode.cash,
    this.amountPaid = 0,
    this.billDiscount = 0,
    this.placeOfSupply,
    this.fromLocation,
    this.toLocation,
    this.transferReason,
    this.idempotencyKey,
    this.discountApprovalId,
  });

  /// Its lines, in cart order.
  final List<SaleCheckoutLine> lines;

  /// Which of the four kinds of sale this is.
  final SaleType saleType;

  /// The party the bill belongs to: the patient, or a package sale's account.
  final String? customerId;

  /// The patient as the bill prints them.
  final String? patientName;

  /// The patient's contact number as the bill records it.
  final String? patientMobile;

  /// The episode an IPD bill posts its credit to.
  final String? admissionId;

  /// The prescriber's master row, when one was chosen.
  final String? doctorId;

  /// The prescriber's name as the bill prints it.
  final String? doctorName;

  /// The hospital's own number: the admission number on an IPD bill, the case
  /// reference on a package one.
  final String? hospitalReference;

  /// How it was settled.
  final PaymentMode paymentMode;

  /// What was taken. The RPC refuses more than the total, so this is the
  /// clamped figure from [SaleTotals.recordablePaid], not the raw tender.
  final double amountPaid;

  /// The bill-level discount, in rupees, as the counter entered it.
  ///
  /// One amount off the **tax-inclusive** total, which `checkout_sale()` shares across
  /// the lines in proportion to each line's own total (migration 00042). It is the
  /// document's figure and not a line's: the lines carry only their share of it, inside
  /// `discount_amount`, exactly as the server stores them.
  final double billDiscount;

  /// Where the goods are going, for the intra/inter-state tax split.
  final String? placeOfSupply;

  /// Where a transfer moves stock from.
  final String? fromLocation;

  /// Where a transfer moves stock to.
  final String? toLocation;

  /// Why a transfer moves it.
  final String? transferReason;

  /// The key that makes a retried submit the same sale rather than a second one.
  final String? idempotencyKey;

  /// The owner's approval for this bill's above-cap discount, when the counter has one.
  ///
  /// Sent by id: the figures he approved live on the request the server stored, and
  /// `checkout_sale()` matches this bill against THOSE rather than against anything the
  /// client repeats here - so an approval cannot be stretched to a bill he never saw.
  final String? discountApprovalId;

  /// The JSON object the RPC reads.
  ///
  /// Document totals are deliberately absent: `checkout_sale()` sums the lines
  /// itself rather than trusting a figure the client worked out, so a stored
  /// grand total cannot disagree with the lines it describes.
  ///
  /// The type's own fields are sent **per type** rather than as one flat object of
  /// nulls. That is not cosmetic: the RPC copies several of them straight into the
  /// row (`hospital_reference`, `patient_address`, the two locations), so a
  /// leftover value from another type would be *stored* - and a `customer_id` on a
  /// transfer is refused outright. Only what this document is made of travels.
  Map<String, dynamic> toPayload() => <String, dynamic>{
    'sale_type': saleType.dbValue,
    'payment_mode': paymentMode.dbValue,
    // A stock movement takes no payment, and the RPC refuses one that does.
    'amount_paid': saleType == SaleType.transfer ? 0 : amountPaid,
    // The bill's own discount (migration 00042), left out entirely - rather than sent
    // as a zero - for a type that has no discount concept, for the same reason a
    // package line sends none: only what this document is made of travels, and the RPC
    // refuses a discount a package or transfer bill has no business carrying.
    if (saleType.hasDiscount && billDiscount != 0)
      'bill_discount': billDiscount,
    'place_of_supply': placeOfSupply,
    if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
    // The owner's approval, when the counter is quoting one. Left out entirely rather than
    // sent as null, like every other field this document is not made of.
    if (discountApprovalId != null) 'discount_approval_id': discountApprovalId,
    ..._typeFields(),
    'items': lines.map((line) => line.toPayload()).toList(growable: false),
  };

  /// The fields this sale type is made of.
  Map<String, dynamic> _typeFields() => switch (saleType) {
    SaleType.counter => <String, dynamic>{
      'customer_id': customerId,
      'doctor_id': doctorId,
      'doctor_name': doctorName,
    },
    SaleType.ipdAdmission => <String, dynamic>{
      'customer_id': customerId,
      'admission_id': admissionId,
      'hospital_reference': hospitalReference,
      'doctor_id': doctorId,
      'doctor_name': doctorName,
    },
    SaleType.package => <String, dynamic>{
      'customer_id': customerId,
      'patient_name': patientName,
      'patient_mobile': patientMobile,
      'hospital_reference': hospitalReference,
    },
    SaleType.transfer => <String, dynamic>{
      'from_location': fromLocation,
      'to_location': toLocation,
      'transfer_reason': transferReason,
    },
  };
}
