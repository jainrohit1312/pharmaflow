/// The counter's basket: what is being sold, and how it is being paid.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/admission.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_cart_line.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'pos_controller.g.dart';

/// The GST slab a line falls back to when its product has none recorded.
///
/// The client's copy of the server's `pos_default_gst_percent()` (migration
/// 00036), which is the one named POS default: 5%, the common slab for a pharmacy
/// counter in India. A **product's own slab always wins**, including a recorded
/// zero - [PosController.addLine] takes it from the product first and only falls
/// back here. The old blanket 12% is gone (D-075); the purchase path keeps its own
/// 12%, which is a different question about a different document.
const double defaultSaleGstPercent = 5;

/// What the counter has rung up, and how it is being paid.
///
/// Immutable, and mutated only through the controller's methods, so a change is a
/// new value rather than an in-place edit Riverpod could miss. [withCustomer] and
/// [withPlaceOfSupply] exist because `copyWith(customerId: null)` cannot be told
/// from "leave it alone" - the same trap `ExpiryCalendarState.withDay` documents.
class PosCart {
  /// Creates a cart.
  const PosCart({
    this.lines = const <SaleCartLine>[],
    this.customerId,
    this.patientName,
    this.patientMobile,
    this.paymentMode = PaymentMode.cash,
    this.tendered = 0,
    this.billDiscount = 0,
    this.placeOfSupply,
    this.saleType = SaleType.counter,
    this.admissionId,
    this.admissionNo,
    this.doctorId,
    this.doctorName,
    this.hospitalReference,
    this.fromLocation,
    this.toLocation,
    this.transferReason,
    this.idempotencyKey,
    this.discountApprovalId,
  });

  /// Its lines, in the order they were added.
  final List<SaleCartLine> lines;

  /// The account this bill belongs to: the patient for a counter or IPD sale, and
  /// the hospital's own account row for a package sale, where the hospital is the
  /// debtor (D-067). `null` only for a transfer, which has no party at all.
  final String? customerId;

  /// The patient's name as the bill prints it.
  ///
  /// Taken from the patient row when one is pinned, and typed for a package sale -
  /// where the debtor is the account rather than the patient, and the server
  /// requires the patient's own name and mobile for traceability. It is a
  /// **snapshot**: editing the patient master later never rewrites an old bill.
  final String? patientName;

  /// The patient's contact number, on the same terms as [patientName].
  final String? patientMobile;

  /// How it is being settled.
  final PaymentMode paymentMode;

  /// What the customer has handed over, before any change is worked out.
  final double tendered;

  /// The bill-level discount, in rupees, as the counter typed it (owner, 2026-09-21).
  ///
  /// One amount off the **tax-inclusive** total - the owner's own rule, because the
  /// discount comes off a price that already contains the tax, so the tax is then
  /// computed on the smaller figure. It rides on the *bill* rather than on a line
  /// because he asked for it once near the totals instead of on every row, and
  /// [SaleTotals.price] shares it across the lines the way `checkout_sale()` shares it.
  final double billDiscount;

  /// Where the goods are going, which decides the tax split.
  final String? placeOfSupply;

  /// What kind of sale this is, which decides how its lines are priced.
  ///
  /// One type per document: the server takes a single `sale_type` for the whole
  /// bill. The counter starts on [SaleType.counter], the commonest sale, and the
  /// type is what `SaleTotals` reads - so a change of type re-prices the basket
  /// rather than leaving figures behind from the previous basis.
  final SaleType saleType;

  /// The episode an IPD bill posts its credit to.
  final String? admissionId;

  /// The hospital's own number for that episode - D-067's `hospital_reference`,
  /// which is also what an IPD sale may be identified by instead of an id.
  final String? admissionNo;

  /// The prescriber, when one was chosen from the master.
  final String? doctorId;

  /// The prescriber's name as this bill prints it.
  ///
  /// A snapshot beside [doctorId] for the same reason as [patientName]: the master
  /// converges spellings, and the bill keeps the one it was given (D-072).
  final String? doctorName;

  /// The hospital's own OPD/IPD reference for the sale, when the type carries one.
  final String? hospitalReference;

  /// Where a transfer moves stock from.
  final String? fromLocation;

  /// Where a transfer moves stock to.
  final String? toLocation;

  /// Why a transfer moves it.
  final String? transferReason;

  /// The key that makes a retried submit the same sale rather than a second one.
  ///
  /// Minted when a submission starts and **cleared by every edit to the basket**,
  /// because the server answers a repeated key with the *original sale* rather
  /// than comparing payloads: reusing a key after an edit would hand the counter
  /// back the bill it already wrote instead of the one it just rang up.
  final String? idempotencyKey;

  /// The owner's approval that lets this bill's above-cap discount through (D-071).
  ///
  /// Set when the counter asks him and he grants it, and **dropped by every edit to the
  /// basket** - like [idempotencyKey], and for the same class of reason: the approval is
  /// for a figure on a bill, so a bill that has moved since is a different question.
  /// `checkout_sale()` matches the bill against the approved figures itself and refuses a
  /// mismatch, so a stale id on the cart could only ever produce a refusal.
  final String? discountApprovalId;

  /// Whether nothing has been rung up yet.
  bool get isEmpty => lines.isEmpty;

  /// Whether anything is on the counter.
  bool get isNotEmpty => lines.isNotEmpty;

  /// Whether the sale will post a customer receivable.
  ///
  /// True when credit was chosen on a sale that has a party at all: a transfer is
  /// stock moving between locations, so it has no debtor and no such thing as an
  /// unpaid balance.
  bool get needsCustomer =>
      saleType != SaleType.transfer && paymentMode.isOnAccount;

  /// What the sale will record as paid, for a bill of [grandTotal].
  ///
  /// Four cases, in the order the counter meets them:
  ///
  ///  * a **transfer** - nothing, whatever was typed: a stock movement takes no
  ///    payment and `checkout_sale()` refuses one that does;
  ///  * a tender was typed - record it, clamped to the bill, because the change
  ///    handed back is not revenue;
  ///  * no tender and a mode that settles at the counter (cash, card, UPI, bank,
  ///    wallet) - the counter took the money, so the sale is paid in full;
  ///  * no tender and `credit` - nothing was paid, and the balance becomes a
  ///    receivable.
  ///
  /// The screen and the write both read this, so what the cashier sees beside
  /// "Change" is what gets stored.
  double paidFor(double grandTotal) {
    if (saleType == SaleType.transfer) {
      return 0;
    }
    if (tendered > 0) {
      return SaleTotals.recordablePaid(tendered: tendered, total: grandTotal);
    }
    return paymentMode.isOnAccount
        ? 0
        : SaleTotals.recordablePaid(tendered: grandTotal, total: grandTotal);
  }

  // Every `with…` rebuilds the whole value, because that is what makes a change a
  // new cart rather than an edit Riverpod could miss - and it is also why each one
  // has to name every field it is not changing: a field left out of one of these
  // copies is a value silently reset by an unrelated action.
  // `pos_controller_test.dart` asserts that for every setter rather than trusting
  // the eye.
  //
  // None of them carries [idempotencyKey] forward. The key identifies a payload,
  // and the server answers a repeated key with the *original* sale rather than
  // comparing payloads - so an edited basket has to submit under a new one, or the
  // counter would be handed back the bill it already wrote.

  /// A copy with the lines replaced.
  PosCart withLines(List<SaleCartLine> value) => PosCart(
    lines: value,
    customerId: customerId,
    patientName: patientName,
    patientMobile: patientMobile,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
  );

  /// A copy with the patient pinned, or cleared by passing `null`.
  ///
  /// Sets the party, the printed name and the contact number together: for a
  /// counter or an IPD sale the bill's party *is* the patient, and its name and
  /// mobile are snapshots of that row. A package sale, whose debtor is the
  /// hospital's account, sets the party with [withCustomer] and those two by hand
  /// with [withPatientDetails].
  PosCart withPatient(Customer? value) => PosCart(
    lines: lines,
    customerId: value?.id,
    patientName: value?.name,
    patientMobile: value?.phone,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
  );

  /// A copy with the party replaced, or cleared by passing `null`.
  ///
  /// The party is the payload's `customer_id`: the patient on a counter or IPD
  /// sale, and the hospital's own account row on a package sale. Naming it by id
  /// alone **clears the printed name and mobile**, because a different party's
  /// identity is a different thing to print - the patient step sets all three
  /// together through [withPatient].
  PosCart withCustomer(String? value) => PosCart(
    lines: lines,
    customerId: value,
    // Stated rather than left to the constructor's defaults: clearing them is what
    // this copy *does*, and an implicit null here would read as an omission.
    // ignore: avoid_redundant_argument_values
    patientName: null,
    // ignore: avoid_redundant_argument_values
    patientMobile: null,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
  );

  /// A copy with the patient's printed name and mobile replaced, or cleared.
  PosCart withPatientDetails({String? name, String? mobile}) => PosCart(
    lines: lines,
    customerId: customerId,
    patientName: name,
    patientMobile: mobile,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
  );

  /// A copy with the episode replaced, or cleared by passing `null`.
  ///
  /// An IPD bill needs either this or the hospital's own number, and it takes the
  /// number from the episode it finds, so the reference travels with the id.
  PosCart withAdmission(Admission? value) => PosCart(
    lines: lines,
    customerId: customerId,
    patientName: patientName,
    patientMobile: patientMobile,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: value?.id,
    admissionNo: value?.admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: value?.admissionNo ?? hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
  );

  /// A copy with the hospital's OPD/IPD case reference replaced, or cleared.
  PosCart withHospitalReference(String? value) => PosCart(
    lines: lines,
    customerId: customerId,
    patientName: patientName,
    patientMobile: patientMobile,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: value,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
  );

  /// A copy with the prescriber replaced, or cleared by passing `null` for both.
  ///
  /// The id is the master row this spelling points at, and the name is what the
  /// bill prints; a name with no id is a prescriber the master has never heard of,
  /// which the server accepts and records (D-072).
  PosCart withDoctor({String? id, String? name}) => PosCart(
    lines: lines,
    customerId: customerId,
    patientName: patientName,
    patientMobile: patientMobile,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: id,
    doctorName: name,
    hospitalReference: hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
  );

  /// A copy with a transfer's three fields replaced.
  ///
  /// One method rather than three setters, so a form that edits all three can
  /// report its whole state at once instead of racing three partial writes.
  PosCart withTransfer({String? from, String? to, String? reason}) => PosCart(
    lines: lines,
    customerId: customerId,
    patientName: patientName,
    patientMobile: patientMobile,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: hospitalReference,
    fromLocation: from,
    toLocation: to,
    transferReason: reason,
  );

  /// A copy with the place of supply replaced, or cleared by passing `null`.
  PosCart withPlaceOfSupply(String? value) => PosCart(
    lines: lines,
    customerId: customerId,
    patientName: patientName,
    patientMobile: patientMobile,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: value,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
  );

  /// A copy with the payment mode replaced.
  PosCart withPaymentMode(PaymentMode value) => PosCart(
    lines: lines,
    customerId: customerId,
    patientName: patientName,
    patientMobile: patientMobile,
    paymentMode: value,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
  );

  /// A copy with the tender replaced.
  PosCart withTendered(double value) => PosCart(
    lines: lines,
    customerId: customerId,
    patientName: patientName,
    patientMobile: patientMobile,
    paymentMode: paymentMode,
    tendered: value,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
  );

  /// A copy with the bill-level discount replaced.
  ///
  /// The one copy that moves it, so every other action leaves the discount where the
  /// counter put it - which is what a counter expects of a figure it typed for *this*
  /// bill and no other. It does **not** carry [idempotencyKey] forward, like every other
  /// copy but [withIdempotencyKey]: the key identifies a payload, and a changed discount
  /// is a different payload.
  PosCart withBillDiscount(double value) => PosCart(
    lines: lines,
    customerId: customerId,
    patientName: patientName,
    patientMobile: patientMobile,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: value,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
  );

  /// A copy with the sale type replaced.
  ///
  /// Nothing is discarded: what a type cannot carry is left out of the **payload**
  /// rather than out of the cart, so a mis-tap does not lose the patient someone
  /// has just been pinned - which matters because the patient is chosen before the
  /// type (D-067's flow). Re-pricing the basket is the one thing a type change
  /// cannot do silently; `PosController.setSaleType` refuses that instead.
  PosCart withSaleType(SaleType value) => PosCart(
    lines: lines,
    customerId: customerId,
    patientName: patientName,
    patientMobile: patientMobile,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: value,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
  );

  /// A copy with the submission key replaced.
  ///
  /// The one copy that carries the key, because minting it is the whole point: it
  /// is set once a submission starts so a retry is the same sale, and every other
  /// `with…` clears it so an edit cannot reuse it.
  ///
  /// It **does** carry [discountApprovalId] forward, unlike every other copy but
  /// [withDiscountApproval]: stamping a submission is not an edit to the bill, and a
  /// retry of the same bill has to quote the approval the first attempt carried.
  PosCart withIdempotencyKey(String? value) => PosCart(
    lines: lines,
    customerId: customerId,
    patientName: patientName,
    patientMobile: patientMobile,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
    idempotencyKey: value,
    discountApprovalId: discountApprovalId,
  );

  /// A copy with the owner's approval for this bill's above-cap discount attached.
  ///
  /// The one copy that sets it, and like every other edit it does **not** carry
  /// [idempotencyKey] forward: what the bill will be has changed, so the submission that
  /// wrote the previous shape is not this one. Every *other* copy drops the approval for
  /// the same reason - the owner approves a figure on a bill, and a bill that has moved
  /// since is not the one he looked at (the server checks that too, and refuses a
  /// mismatch, but a counter that kept a stale approval would offer a bill the server
  /// would then reject).
  PosCart withDiscountApproval(String? value) => PosCart(
    lines: lines,
    customerId: customerId,
    patientName: patientName,
    patientMobile: patientMobile,
    paymentMode: paymentMode,
    tendered: tendered,
    billDiscount: billDiscount,
    placeOfSupply: placeOfSupply,
    saleType: saleType,
    admissionId: admissionId,
    admissionNo: admissionNo,
    doctorId: doctorId,
    doctorName: doctorName,
    hospitalReference: hospitalReference,
    fromLocation: fromLocation,
    toLocation: toLocation,
    transferReason: transferReason,
    discountApprovalId: value,
  );
}

/// The basket at the counter.
///
/// Kept alive on purpose: a cashier who opens a product's detail mid-sale - or
/// the invoice of the sale they just rang up - must not come back to an empty
/// counter. `clear()` is the explicit way to start over, and a successful
/// checkout clears it too.
@Riverpod(keepAlive: true)
class PosController extends _$PosController {
  @override
  PosCart build() => const PosCart();

  /// Adds [qty] of one batch to the basket.
  ///
  /// The same product out of the same batch merges into the line already there -
  /// a second scan of one barcode is another unit, not a competing line - while a
  /// different batch of the same product is a line of its own, because the two
  /// have their own expiry and their own stock.
  ///
  /// [rate] defaults to the batch's counter price, falling back to its MRP when no
  /// counter price was ever set; [gstPercent] to the product's own slab, falling
  /// back to the named 5% default when the catalogue has none recorded.
  void addLine({
    required Product product,
    required BatchStatus batch,
    required int qty,
    double? rate,
    double? gstPercent,
  }) {
    if (qty <= 0) {
      return;
    }

    final line = SaleCartLine(
      productId: product.id,
      productName: product.name,
      scheduleType: product.scheduleType,
      batchId: batch.id,
      batchNo: batch.batchNo,
      qty: qty,
      rate: rate ?? _defaultRate(batch),
      // The product's own slab wins, including a recorded zero - which is a rate,
      // not an absence, and must not be replaced by the default. `??` reads exactly
      // that way: only a null slab falls through.
      gstPercent: gstPercent ?? product.gstPercent ?? defaultSaleGstPercent,
      // Kept for the MRP ceiling a retail rate may not cross (`rateRefusal`).
      mrp: batch.mrp,
      // Absent when the batch's expiry was never recorded, which is the honest
      // answer for the 145 opening-stock rows whose source had no date.
      expiryDateIso: batch.expiryDate?.toIso8601String(),
    );

    final existing = state.lines.indexWhere(
      (candidate) => candidate.isSameLineAs(line),
    );
    if (existing < 0) {
      state = state.withLines(<SaleCartLine>[...state.lines, line]);
      return;
    }

    final merged = state.lines[existing].copyWith(
      qty: state.lines[existing].qty + qty,
    );
    state = state.withLines(<SaleCartLine>[
      for (var index = 0; index < state.lines.length; index++)
        if (index == existing) merged else state.lines[index],
    ]);
  }

  /// Sets a line's quantity.
  ///
  /// **A quantity that is not a positive number changes nothing.** It used to remove the
  /// line, and that is what made Backspace on a default `1` delete the row out from under
  /// the operator: an emptied field parses to no number, no number became zero, and zero was
  /// read as "drop this line". D-078 gives removal to exactly two controls - the line's own
  /// delete button and Delete while the caret is on the line - so a field that cannot answer
  /// yet leaves the line as it stands, and puts the line's own number back when the caret
  /// leaves it.
  void setQty(String batchId, int qty) {
    if (qty <= 0) {
      return;
    }
    _replace(batchId, (line) => line.copyWith(qty: qty));
  }

  /// Sets a line's rate.
  void setRate(String batchId, double rate) =>
      _replace(batchId, (line) => line.copyWith(rate: rate));

  /// Sets a line's discount percentage.
  void setDiscount(String batchId, double percent) =>
      _replace(batchId, (line) => line.copyWith(discountPercent: percent));

  /// Sets a line's GST slab.
  void setGst(String batchId, double percent) =>
      _replace(batchId, (line) => line.copyWith(gstPercent: percent));

  /// Removes a line.
  void removeLine(String batchId) => state = state.withLines(<SaleCartLine>[
    for (final line in state.lines)
      if (line.batchId != batchId) line,
  ]);

  /// Records who is buying by id, or clears the party with `null`.
  ///
  /// Clears the printed name and mobile with it: a party named by id alone has no
  /// snapshot here, which is what the package sale's account picker wants and what
  /// the patient step must not use - it calls [setPatient], which carries all three.
  void setCustomer(String? customerId) =>
      state = state.withCustomer(customerId);

  /// Pins the patient, or clears them with `null`.
  ///
  /// The whole identity at once - the row, the printed name and the contact
  /// number - because a counter sale's party *is* the patient and its name and
  /// mobile are snapshots of that row (D-074).
  void setPatient(Customer? patient) => state = state.withPatient(patient);

  /// Records the patient's own name and mobile on a package bill.
  ///
  /// The package sale's debtor is the hospital's account rather than the patient,
  /// and the server still requires the patient's name and number for traceability
  /// (D-067) - which is what these two carry.
  void setPatientDetails({String? name, String? mobile}) =>
      state = state.withPatientDetails(name: name, mobile: mobile);

  /// Records the episode an IPD bill posts to, or clears it with `null`.
  void setAdmission(Admission? admission) =>
      state = state.withAdmission(admission);

  /// Records the hospital's own OPD/IPD number for the sale.
  void setHospitalReference(String? value) =>
      state = state.withHospitalReference(value);

  /// Records the prescriber, or clears both halves with `null`.
  void setDoctor({String? id, String? name}) =>
      state = state.withDoctor(id: id, name: name);

  /// Records a transfer's source, destination and reason.
  void setTransfer({String? from, String? to, String? reason}) =>
      state = state.withTransfer(from: from, to: to, reason: reason);

  /// Records where the goods are going, or clears it with `null`.
  void setPlaceOfSupply(String? value) =>
      state = state.withPlaceOfSupply(value);

  /// Records how the sale is being settled.
  void setPaymentMode(PaymentMode mode) => state = state.withPaymentMode(mode);

  /// Records what kind of sale this is.
  ///
  /// Refused while the basket is not empty **when the type changes the pricing
  /// basis**: a package or transfer line is priced from the batch's cost, which the
  /// cart does not carry (the server resolves it, and the client could only
  /// re-derive it by reading every batch again), so re-pricing a rung-up basket
  /// would silently leave the preview describing retail prices the server would
  /// never store. The flow chooses the type before the items, so this is a guard
  /// against a mis-tap rather than a limit on the counter.
  void setSaleType(SaleType type) {
    if (type == state.saleType) {
      return;
    }
    final changesBasis =
        type == SaleType.package ||
        type == SaleType.transfer ||
        state.saleType == SaleType.package ||
        state.saleType == SaleType.transfer;
    if (changesBasis && state.isNotEmpty) {
      throw const ValidationException(
        message:
            'A package or transfer sale is priced from cost, so the type has to '
            'be chosen before the medicines: empty the basket to change it.',
      );
    }
    state = state.withSaleType(type);
  }

  /// Records the key this submission is identified by.
  ///
  /// Set once a write starts, so a retry is the same sale; every other change to
  /// the basket clears it, because the server answers a repeated key with the
  /// original sale rather than comparing payloads.
  void setIdempotencyKey(String? key) => state = state.withIdempotencyKey(key);

  /// Records the owner's approval for this bill's above-cap discount, or clears it.
  ///
  /// Set by the counter once he grants it, and cleared by any edit to the bill - which
  /// the cart does itself, so no caller has to remember to.
  void setDiscountApproval(String? id) =>
      state = state.withDiscountApproval(id);

  /// Records what the customer handed over.
  void setTendered(double amount) => state = state.withTendered(amount);

  /// Records the bill-level discount, in rupees.
  ///
  /// Deliberately unvalidated here. What a discount may be depends on the whole bill -
  /// its tax-inclusive total, and whether its type has a discount concept at all - so
  /// the rules live in [SaleTotals.billDiscountRefusal] and are applied before the write
  /// (through `saleRefusal`), where the counter hears them as a sentence it can act on.
  /// A field that refused mid-keystroke would refuse the "4" of "46".
  void setBillDiscount(double amount) => state = state.withBillDiscount(amount);

  /// Empties the basket and forgets everything chosen for it.
  void clear() => state = const PosCart();

  /// Replaces one line in place.
  void _replace(String batchId, SaleCartLine Function(SaleCartLine) change) =>
      state = state.withLines(<SaleCartLine>[
        for (final line in state.lines)
          if (line.batchId == batchId) change(line) else line,
      ]);

  /// The price to charge for a unit of [batch].
  static double _defaultRate(BatchStatus batch) =>
      batch.sellingRate > 0 ? batch.sellingRate : batch.mrp;
}
