/// The two lists applying a deposit needs: the bills it can settle, and the receipts that
/// still hold money.
///
/// A deposit is a receipt whose allocations totalled **less** than its amount, and applying it
/// means `allocate_payment()` - which writes allocation rows and nothing else, so applying money
/// already taken is never a second receipt (D-075, D-081).
///
/// The two lists come from opposite sides of the wire, and the difference is deliberate:
///
///   * **the bills are the server's** (`open_bills()`, migration `20260921000040`), computed with
///     the same expressions `allocate_payment()` re-checks under its lock - so a bill's figure here
///     is the limit a refusal will name, rather than a number this client invented.
///   * **a receipt's remainder is not**, and there is no reader for it: the party's TOTAL is the
///     server's (`patient_account().unallocated_deposits`) and this file never recomputes that, but
///     the sheet has to show *which* receipt holds the money, and one subtraction per receipt is the
///     smallest thing that can answer that. [DepositReceipt.held] is that subtraction and nothing
///     else.
///
/// Plain classes rather than Freezed, like the other RPC envelopes this app reads once
/// (`SaleDocument`, `PatientAccount`): neither is a table row with a converter, and neither is a
/// provider family argument that would need real `==`.
library;

import 'package:app/data/models/sale.dart';

/// One bill with something still owed on it, as `open_bills()` returns it.
class OpenBill {
  /// Creates a bill.
  const OpenBill({
    required this.saleId,
    required this.invoiceNo,
    required this.saleDate,
    required this.saleType,
    required this.grandTotal,
    required this.returnedTotal,
    required this.allocatedTotal,
    required this.outstanding,
  });

  /// Decodes one entry of `open_bills()`'s `bills` array.
  factory OpenBill.fromJson(Map<String, dynamic> json) => OpenBill(
    saleId: json['sale_id'] as String,
    invoiceNo: json['invoice_no'] as String? ?? '—',
    saleDate: DateTime.tryParse(json['sale_date'] as String? ?? ''),
    saleType: saleTypeFromDb(json['sale_type'] as String?),
    grandTotal: _money(json['grand_total']),
    returnedTotal: _money(json['returned_total']),
    allocatedTotal: _money(json['allocated_total']),
    outstanding: _money(json['outstanding']),
  );

  /// The bill (`sales.id`), which is what an allocation names.
  final String saleId;

  /// The bill's number, as it was printed.
  final String invoiceNo;

  /// The day it was raised, or `null` if the row carried none - the server orders by it.
  final DateTime? saleDate;

  /// Which of the four sale types it is.
  final SaleType saleType;

  /// What it billed.
  final double grandTotal;

  /// What valid returns have credited back against it.
  final double returnedTotal;

  /// What receipts have already been applied to it.
  final double allocatedTotal;

  /// `grandTotal − returnedTotal − allocatedTotal`, computed by the server: the most that can be
  /// applied to this bill, and the figure a refusal names.
  final double outstanding;
}

/// One receipt with money still unapplied.
///
/// Read as a plain PostgREST row - `payments` with its `payment_allocations` embedded - because
/// there is no RPC that answers "which of this party's receipts still holds money", and the party's
/// total is already on their account. See this file's own header for why the remainder is computed
/// here and the total is not.
class DepositReceipt {
  /// Creates a receipt.
  const DepositReceipt({
    required this.id,
    required this.paymentDate,
    required this.mode,
    required this.amount,
    required this.applied,
    this.referenceNo,
  });

  /// Decodes one `payments` row with its allocations embedded.
  factory DepositReceipt.fromJson(Map<String, dynamic> json) => DepositReceipt(
    id: json['id'] as String,
    paymentDate: DateTime.tryParse(json['payment_date'] as String? ?? ''),
    mode: paymentModeFromDb(json['mode'] as String?),
    referenceNo: json['reference_no'] as String?,
    amount: _money(json['amount']),
    applied: switch (json['payment_allocations']) {
      final List<dynamic> allocations => allocations.fold<double>(
        0,
        (sum, row) => sum + _money((row as Map<String, dynamic>)['amount']),
      ),
      _ => 0,
    },
  );

  /// The receipt (`payments.id`), which is what `allocate_payment()` is handed.
  final String id;

  /// The day the money was taken, or `null` if the row carried none.
  final DateTime? paymentDate;

  /// How it was taken.
  final PaymentMode mode;

  /// Its own reference, when it has one.
  final String? referenceNo;

  /// What was taken.
  final double amount;

  /// What has been applied to documents so far.
  final double applied;

  /// What is still held - the one subtraction this file performs, per receipt.
  double get held => amount - applied;

  /// Whether there is anything left to apply. A fully applied receipt is not offered.
  bool get hasHeld => held > 0;
}

/// A `numeric` column as a double, whatever shape the JSON arrived in.
double _money(Object? value) => switch (value) {
  final num n => n.toDouble(),
  final String s => double.tryParse(s) ?? 0,
  _ => 0,
};
