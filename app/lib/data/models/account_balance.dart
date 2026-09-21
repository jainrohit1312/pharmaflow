/// The server's account aggregates: what a party owes, and what has been applied to a
/// document.
///
/// Read from `patient_account()` and `admission_account()` (migration
/// `20260920000036`), which aggregate **server-side** over the whole patient or the
/// whole episode. **Nothing in this file, or in anything that reads it, sums rows**:
/// `outstanding` is the server's own figure - `charges − valid returns − allocated` -
/// and a client that recomputed it could only disagree with the account the ledger
/// describes (D-025, D-075).
///
/// Plain classes rather than Freezed, like the other RPC envelopes this app reads once
/// (`SaleDocument`, `PatientMatch`): nothing here is a table row with a converter, and
/// none of them is a provider family argument that would need real `==`.
library;

/// What one patient owes, and what the pharmacy is holding for them.
class PatientAccount {
  /// Creates an account.
  const PatientAccount({
    required this.customerId,
    required this.patientName,
    this.patientCode,
    this.phone,
    this.charges = 0,
    this.returnsCredits = 0,
    this.allocated = 0,
    this.outstanding = 0,
    this.unallocatedDeposits = 0,
  });

  /// Decodes one row of `patient_account()`.
  factory PatientAccount.fromJson(Map<String, dynamic> json) => PatientAccount(
    customerId: json['customer_id'] as String,
    patientName: json['patient_name'] as String? ?? 'Patient',
    patientCode: json['patient_code'] as String?,
    phone: json['phone'] as String?,
    charges: _money(json['charges']),
    returnsCredits: _money(json['returns_credits']),
    allocated: _money(json['allocated']),
    outstanding: _money(json['outstanding']),
    unallocatedDeposits: _money(json['unallocated_deposits']),
  );

  /// The patient (`customers.id`).
  final String customerId;

  /// Their name as the master holds it.
  final String patientName;

  /// Their generated code, or `null` for a customer registered before Phase 7a who has
  /// not been billed since (D-074).
  final String? patientCode;

  /// Their contact number.
  final String? phone;

  /// What has been billed to them: the sum of the valid sales that name them.
  final double charges;

  /// What valid returns have credited back against those bills.
  final double returnsCredits;

  /// How much of the money taken from them has been **applied** to those documents.
  final double allocated;

  /// `charges − returnsCredits − allocated`, computed by the server.
  final double outstanding;

  /// Receipts taken from them that have **not** been applied to anything yet.
  ///
  /// The remainder of a receipt whose allocations totalled less than its amount. It is
  /// not "paid" against a bill and must not read as one: it is money the pharmacy is
  /// holding, and applying it is a separate act (`allocate_payment()`) that writes no
  /// second receipt.
  final double unallocatedDeposits;

  /// Whether anything has been billed to this patient at all.
  bool get hasCharges => charges != 0 || returnsCredits != 0;

  /// Whether the pharmacy is holding money that no bill has been applied to.
  bool get hasDeposit => unallocatedDeposits != 0;

  /// Whether their account balances to nothing.
  bool get isSettled => outstanding == 0;
}

/// What one admission episode owes.
///
/// Its own account, separate from the patient's: **one patient has many admissions and
/// their balances never mix** (D-074), so a bill posted to episode A leaves episode B
/// untouched and both leave the patient's personal balance alone.
class AdmissionAccount {
  /// Creates an account.
  const AdmissionAccount({
    required this.admissionId,
    required this.customerId,
    required this.admissionNo,
    required this.patientName,
    this.patientCode,
    this.hospitalId,
    this.admittedOn,
    this.dischargedOn,
    this.status = 'active',
    this.charges = 0,
    this.returnsCredits = 0,
    this.allocated = 0,
    this.outstanding = 0,
  });

  /// Decodes one row of `admission_account()`.
  factory AdmissionAccount.fromJson(Map<String, dynamic> json) =>
      AdmissionAccount(
        admissionId: json['admission_id'] as String,
        customerId: json['customer_id'] as String,
        admissionNo: json['admission_no'] as String? ?? '—',
        patientName: json['patient_name'] as String? ?? 'Patient',
        patientCode: json['patient_code'] as String?,
        hospitalId: json['hospital_id'] as String?,
        admittedOn: _date(json['admitted_on']),
        dischargedOn: _date(json['discharged_on']),
        status: json['status'] as String? ?? 'active',
        charges: _money(json['charges']),
        returnsCredits: _money(json['returns_credits']),
        allocated: _money(json['allocated']),
        outstanding: _money(json['outstanding']),
      );

  /// The episode.
  final String admissionId;

  /// The patient it belongs to.
  final String customerId;

  /// The hospital's own IPD/OPD number for the episode.
  final String admissionNo;

  /// The patient's name.
  final String patientName;

  /// Their generated code, when the master has one.
  final String? patientCode;

  /// The hospital the episode is at.
  final String? hospitalId;

  /// When they were admitted.
  final DateTime? admittedOn;

  /// When they were discharged, or `null` while the episode is open.
  final DateTime? dischargedOn;

  /// `active` or `discharged`.
  final String status;

  /// What has been billed to this episode.
  final double charges;

  /// What valid returns have credited back against it.
  final double returnsCredits;

  /// How much money taken has been applied to it - whether aimed at the episode itself
  /// or at an individual bill inside it, because each allocation row is a slice of
  /// money and the sum of the slices is what was applied.
  final double allocated;

  /// `charges − returnsCredits − allocated`, computed by the server.
  final double outstanding;

  /// Whether the episode is still open.
  ///
  /// A discharged episode refuses new charges (D-074), so this is what decides whether a
  /// counter may still bill against it.
  bool get isActive => status == 'active';

  /// Whether anything has been billed to this episode at all.
  bool get hasCharges => charges != 0 || returnsCredits != 0;

  /// Whether the episode balances to nothing.
  bool get isSettled => outstanding == 0;
}

/// One receipt applied to one document - a row of `payment_allocations`.
///
/// What a bill shows as "money that settled this": the receipt it came from, and how
/// much of that receipt was aimed here. A receipt that appears more than once was split
/// across several documents, and one that does not appear at all settled nothing - its
/// amount is still an unallocated deposit.
class SaleAllocation {
  /// Creates an allocation.
  const SaleAllocation({
    required this.id,
    required this.paymentId,
    required this.amount,
    this.saleId,
    this.admissionId,
    this.createdAt,
  });

  /// Decodes one `payment_allocations` row.
  factory SaleAllocation.fromJson(Map<String, dynamic> json) => SaleAllocation(
    id: json['id'] as String,
    paymentId: json['payment_id'] as String,
    amount: _money(json['amount']),
    saleId: json['sale_id'] as String?,
    admissionId: json['admission_id'] as String?,
    createdAt: _date(json['created_at']),
  );

  /// The allocation row.
  final String id;

  /// The receipt this slice of money came from.
  final String paymentId;

  /// How much of that receipt was applied here.
  final double amount;

  /// The bill it settled, when it was aimed at one.
  final String? saleId;

  /// The episode it settled, when it was aimed at one.
  ///
  /// An allocation names **exactly one** target - a sale or an admission, and the server
  /// refuses both or neither.
  final String? admissionId;

  /// When the money was applied.
  final DateTime? createdAt;
}

/// A `numeric` column as a double, whatever shape the JSON arrived in.
double _money(Object? value) => switch (value) {
  final num n => n.toDouble(),
  final String s => double.tryParse(s) ?? 0,
  _ => 0,
};

/// A `date` or `timestamp` column as a [DateTime], or `null`.
DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
