/// The account aggregates a screen watches.
///
/// Thin on purpose: the figures are the server's (`BalancesRepository`), and a screen
/// needs only to read them per customer, per admission or per bill.
library;

import 'package:app/data/models/account_balance.dart';
import 'package:app/data/models/party_deposits.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/balances/data/balances_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'balances.g.dart';

/// The patient named by [customerId], or `null` when they are not in this pharmacy.
@riverpod
Future<PatientAccount?> patientAccount(Ref ref, String customerId) => ref
    .watch(balancesRepositoryProvider)
    .patientAccount(customerId: customerId);

/// The episode named by [admissionId], or `null` when it is not in this pharmacy.
@riverpod
Future<AdmissionAccount?> admissionAccount(Ref ref, String admissionId) => ref
    .watch(balancesRepositoryProvider)
    .admissionAccount(admissionId: admissionId);

/// The receipts that have been applied to the bill named by [saleId].
///
/// An empty list is a real answer: nothing has been applied to that bill, whatever was
/// handed over at the counter.
@riverpod
Future<List<SaleAllocation>> saleAllocations(Ref ref, String saleId) => ref
    .watch(balancesRepositoryProvider)
    .saleAllocations(
      pharmacyId: ref.watch(requirePharmacyIdProvider),
      saleId: saleId,
    );

/// The bills the patient named by [customerId] still owes something on, oldest first.
///
/// The sheet that applies a deposit needs them before it can apply anything: an
/// allocation names a bill, and the server caps each slice at what that bill still owes.
@riverpod
Future<List<OpenBill>> openBills(Ref ref, String customerId) =>
    ref.watch(balancesRepositoryProvider).openBills(customerId: customerId);

/// The patient's receipts that still hold money, oldest first.
///
/// Their **total** is not this list's sum: it is `patientAccount().unallocatedDeposits`, the
/// server's own figure (D-025). This is the per-receipt answer to "which of them holds it".
@riverpod
Future<List<DepositReceipt>> depositReceipts(Ref ref, String customerId) => ref
    .watch(balancesRepositoryProvider)
    .depositReceipts(
      pharmacyId: ref.watch(requirePharmacyIdProvider),
      customerId: customerId,
    );
