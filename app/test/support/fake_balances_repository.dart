/// Shared test double for the account aggregates.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/account_balance.dart';
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

  /// When set, every read and write throws it.
  Exception? errorToThrow;

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
  Future<void> applyDeposit({
    required String paymentId,
    required List<PaymentAllocationTarget> targets,
  }) async {
    _throwIfAsked();
    if (targets.isEmpty) {
      throw ArgumentError('the real repository refuses an empty allocation');
    }
    appliedPaymentIds.add(paymentId);
    appliedTargets.addAll(targets);
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
