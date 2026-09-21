/// Shared test double for the account aggregates.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/account_balance.dart';
import 'package:app/data/models/party_deposits.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/balances/data/balances_repository.dart';

/// Builds a patient account with only the fields a test cares about.
///
/// Every figure defaults to zero rather than to a plausible account: a fixture that came
/// with figures of its own would have to be overridden by every test that asserts one,
/// and a test that forgot to would pass for the wrong reason.
PatientAccount buildPatientAccount({
  String customerId = 'customer-1',
  String patientName = 'ZZTEST patient',
  String? patientCode,
  String? phone,
  double charges = 0,
  double returnsCredits = 0,
  double allocated = 0,
  double outstanding = 0,
  double unallocatedDeposits = 0,
}) => PatientAccount(
  customerId: customerId,
  patientName: patientName,
  patientCode: patientCode,
  phone: phone,
  charges: charges,
  returnsCredits: returnsCredits,
  allocated: allocated,
  outstanding: outstanding,
  unallocatedDeposits: unallocatedDeposits,
);

/// Builds an admission account with only the fields a test cares about.
AdmissionAccount buildAdmissionAccount({
  String admissionId = 'admission-1',
  String customerId = 'customer-1',
  String admissionNo = 'IPD-1',
  String patientName = 'ZZTEST patient',
  String? patientCode,
  String status = 'active',
  DateTime? admittedOn,
  DateTime? dischargedOn,
  double charges = 0,
  double returnsCredits = 0,
  double allocated = 0,
  double outstanding = 0,
}) => AdmissionAccount(
  admissionId: admissionId,
  customerId: customerId,
  admissionNo: admissionNo,
  patientName: patientName,
  patientCode: patientCode,
  status: status,
  admittedOn: admittedOn ?? DateTime(2026, 9, 18),
  dischargedOn: dischargedOn,
  charges: charges,
  returnsCredits: returnsCredits,
  allocated: allocated,
  outstanding: outstanding,
);

/// Builds one `payment_allocations` row.
SaleAllocation buildSaleAllocation({
  String id = 'allocation-1',
  String paymentId = '11111111-1111-1111-1111-111111111111',
  double amount = 100,
  String? saleId = 'sale-1',
  String? admissionId,
  DateTime? createdAt,
}) => SaleAllocation(
  id: id,
  paymentId: paymentId,
  amount: amount,
  saleId: saleId,
  admissionId: admissionId,
  createdAt: createdAt ?? DateTime(2026, 9, 18, 14, 5),
);

/// Builds one bill `open_bills()` would return.
///
/// [outstanding] defaults to what the three figures produce, which is what the server computes -
/// so a fixture only has to say what a test cares about, and a test that means to say something
/// impossible has to say it.
OpenBill buildOpenBill({
  String saleId = 'sale-1',
  String invoiceNo = 'INV-1',
  DateTime? saleDate,
  SaleType saleType = SaleType.counter,
  double grandTotal = 105,
  double returnedTotal = 0,
  double allocatedTotal = 0,
  double? outstanding,
}) => OpenBill(
  saleId: saleId,
  invoiceNo: invoiceNo,
  saleDate: saleDate ?? DateTime(2026, 9, 18),
  saleType: saleType,
  grandTotal: grandTotal,
  returnedTotal: returnedTotal,
  allocatedTotal: allocatedTotal,
  outstanding: outstanding ?? grandTotal - returnedTotal - allocatedTotal,
);

/// Builds one receipt, with `held` as `amount − applied`.
DepositReceipt buildDepositReceipt({
  String id = 'payment-1',
  DateTime? paymentDate,
  PaymentMode mode = PaymentMode.cash,
  String? referenceNo,
  double amount = 500,
  double applied = 0,
}) => DepositReceipt(
  id: id,
  paymentDate: paymentDate ?? DateTime(2026, 9, 18),
  mode: mode,
  referenceNo: referenceNo,
  amount: amount,
  applied: applied,
);

/// An in-memory [BalancesRepository].
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing, so the
/// fake never needs a Supabase client - which is the whole point, because a real
/// `SupabaseClient` cannot be constructed without an initialised backend.
class FakeBalancesRepository implements BalancesRepository {
  /// The patient every `patientAccount` call answers, or `null` for "no such patient".
  PatientAccount? patient;

  /// The episode every `admissionAccount` call answers, or `null` for "no such episode".
  AdmissionAccount? admission;

  /// What every `saleAllocations` call answers.
  List<SaleAllocation> allocations = const <SaleAllocation>[];

  /// The bills every `openBills` call answers, in the order the sheet shows them.
  List<OpenBill> bills = const <OpenBill>[];

  /// The receipts every `depositReceipts` call answers. The real reader returns only the ones
  /// that still hold money, so a fixture that means to be offered must have `applied < amount`.
  List<DepositReceipt> receipts = const <DepositReceipt>[];

  /// When set, every read and write throws it.
  Exception? errorToThrow;

  /// When set, ONLY `applyDeposit` throws it.
  ///
  /// A refused application is a different thing from a read that failed: the sheet has already read
  /// the bills and the receipts it is offering, and the server refuses the figure it was handed. One
  /// flag for both could not express that, because arming it would empty the sheet first.
  Exception? writeErrorToThrow;

  /// The receipts `applyDeposit` was asked to apply, in order.
  final List<String> appliedPaymentIds = <String>[];

  /// The targets `applyDeposit` was handed, in order.
  final List<PaymentAllocationTarget> appliedTargets =
      <PaymentAllocationTarget>[];

  @override
  Future<PatientAccount?> patientAccount({required String customerId}) async {
    _throwIfAsked();
    return patient;
  }

  @override
  Future<AdmissionAccount?> admissionAccount({
    required String admissionId,
  }) async {
    _throwIfAsked();
    return admission;
  }

  @override
  Future<List<SaleAllocation>> saleAllocations({
    required String pharmacyId,
    required String saleId,
  }) async {
    _throwIfAsked();
    return allocations;
  }

  @override
  Future<List<OpenBill>> openBills({required String customerId}) async {
    _throwIfAsked();
    return bills;
  }

  @override
  Future<List<DepositReceipt>> depositReceipts({
    required String pharmacyId,
    required String customerId,
  }) async {
    _throwIfAsked();
    return receipts;
  }

  @override
  Future<void> applyDeposit({
    required String paymentId,
    required List<PaymentAllocationTarget> targets,
  }) async {
    _throwIfAsked();

    // The server's refusal of the application itself, before anything is recorded - which is what a
    // refusal is: nothing written, because the write and the decision are one transaction.
    final refusal = writeErrorToThrow;
    if (refusal != null) {
      throw refusal;
    }

    if (targets.isEmpty) {
      throw ArgumentError('the real repository refuses an empty allocation');
    }
    appliedPaymentIds.add(paymentId);
    appliedTargets.addAll(targets);

    // The money moves: the receipt holds less and the bills it settled owe less, and a bill that
    // owes nothing leaves the list - which is what the server's reader does. The real CAP is the
    // server's (under a row lock); this fake applies what it is handed, so a test that wants a
    // refusal configures `errorToThrow` rather than relying on arithmetic here.
    for (final target in targets) {
      final saleId = target.saleId;
      if (saleId == null) {
        continue;
      }
      bills = <OpenBill>[
        for (final bill in bills)
          if (bill.saleId != saleId)
            bill
          else if (bill.outstanding > target.amount)
            buildOpenBill(
              saleId: bill.saleId,
              invoiceNo: bill.invoiceNo,
              saleDate: bill.saleDate,
              saleType: bill.saleType,
              grandTotal: bill.grandTotal,
              returnedTotal: bill.returnedTotal,
              allocatedTotal: bill.allocatedTotal + target.amount,
            ),
      ];
    }

    receipts = <DepositReceipt>[
      for (final receipt in receipts)
        if (receipt.id != paymentId)
          receipt
        else
          buildDepositReceipt(
            id: receipt.id,
            paymentDate: receipt.paymentDate,
            mode: receipt.mode,
            referenceNo: receipt.referenceNo,
            amount: receipt.amount,
            applied:
                receipt.applied +
                targets.fold<double>(0, (sum, target) => sum + target.amount),
          ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );

  /// Throws the configured failure, leaving it set.
  ///
  /// Persistent rather than one-shot on purpose: a route can be built more than once
  /// before the first frame settles, so a failure that cleared itself would be retried
  /// into a success before a test could look at the error state.
  void _throwIfAsked() {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
  }
}
