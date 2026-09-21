/// Reads the server's account aggregates, and applies money that was already taken.
///
/// Every figure here is the **server's**: `patient_account()` and `admission_account()`
/// aggregate over the whole patient or the whole episode, and no caller sums rows
/// (D-025). The two RPCs take their tenant from `get_my_pharmacy_id()` and refuse a
/// party from another pharmacy, which is why - like `PatientsRepository` - the reads
/// take no `pharmacyId`: a tenant the server ignores would be worse than none.
///
/// One read is a plain table read rather than an RPC, and that is deliberate:
/// `payment_allocations` is a tenant-scoped table with a select policy, so the rows that
/// settled one bill are a `select` - not a second aggregate that could disagree with the
/// account.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/account_balance.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'balances_repository.g.dart';

/// Exposes the single [BalancesRepository].
@riverpod
BalancesRepository balancesRepository(Ref ref) =>
    BalancesRepository(ref.watch(supabaseClientProvider));

/// One document a collection is applied to, and how much of it.
///
/// An allocation names **exactly one** target - a sale or an admission - because that
/// is what the server requires (`payment_allocations_target_check`): both or neither is
/// refused. The two named constructors are what makes "exactly one" true by
/// construction rather than by convention.
class PaymentAllocationTarget {
  /// Applies money to one bill.
  const PaymentAllocationTarget.sale({
    required this.saleId,
    required this.amount,
  }) : admissionId = null;

  /// Applies money to one admission episode.
  const PaymentAllocationTarget.admission({
    required this.admissionId,
    required this.amount,
  }) : saleId = null;

  /// The bill, when this slice was aimed at one.
  final String? saleId;

  /// The episode, when this slice was aimed at one.
  final String? admissionId;

  /// How much of the receipt this slice applies.
  final double amount;

  /// The shape `collect_payment()` / `allocate_payment()` read.
  Map<String, dynamic> toJson() => <String, dynamic>{
    if (saleId != null) 'sale_id': saleId,
    if (admissionId != null) 'admission_id': admissionId,
    'amount': amount,
  };
}

/// Data access for the account aggregates and the money applied to a document.
class BalancesRepository {
  /// Creates a repository backed by the shared Supabase client.
  BalancesRepository(this._client);

  final sb.SupabaseClient _client;

  /// One patient's account, or `null` when they are not in this pharmacy.
  ///
  /// `patient_account()` returns a table, so an absent patient answers with no rows
  /// rather than an error - the same answer a sale outside the caller's pharmacy gets.
  Future<PatientAccount?> patientAccount({required String customerId}) async {
    final row = await _oneRow(
      'patient_account',
      <String, dynamic>{'p_customer_id': customerId},
      fallbackMessage: 'Unable to load that patient\u2019s account.',
    );
    return row == null ? null : PatientAccount.fromJson(row);
  }

  /// One admission's account, or `null` when it is not in this pharmacy.
  Future<AdmissionAccount?> admissionAccount({
    required String admissionId,
  }) async {
    final row = await _oneRow(
      'admission_account',
      <String, dynamic>{'p_admission_id': admissionId},
      fallbackMessage: 'Unable to load that admission\u2019s account.',
    );
    return row == null ? null : AdmissionAccount.fromJson(row);
  }

  /// The receipts applied to one bill, oldest first.
  ///
  /// A bill with no rows has had no money applied: it may still have been paid, and
  /// that money is an unallocated deposit on the party's account rather than a
  /// settlement of this document. The two are different answers and this read only
  /// gives the second.
  Future<List<SaleAllocation>> saleAllocations({
    required String pharmacyId,
    required String saleId,
  }) async {
    try {
      final rows = await _client
          .from('payment_allocations')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('sale_id', saleId)
          .order('created_at');
      return rows.map(SaleAllocation.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load what settled that bill.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load what settled that bill.',
        cause: error,
      );
    }
  }

  /// Applies a receipt's unallocated remainder to the documents it settles.
  ///
  /// `allocate_payment()` (migration `20260920000037`) writes **only** allocation rows:
  /// no `payments` row and no `ledger_entries` row, because the money arrived when the
  /// receipt was taken and applying it must not look like a second receipt (D-075).
  ///
  /// **The limit is the server's, not this caller's.** Each target is checked against
  /// what is still owed on it **under a `for update` lock**, and the total against what
  /// the receipt still holds - so a client that believed a bill was settled cannot
  /// over-apply it, and two collections cannot both settle the same bill.
  Future<void> applyDeposit({
    required String paymentId,
    required List<PaymentAllocationTarget> targets,
  }) async {
    if (targets.isEmpty) {
      throw const ValidationException(
        message: 'Choose the bill this money settles.',
      );
    }

    try {
      await _client.rpc<dynamic>(
        'allocate_payment',
        params: <String, dynamic>{
          'p_payment_id': paymentId,
          'p_allocations': <Map<String, dynamic>>[
            for (final target in targets) target.toJson(),
          ],
        },
      );
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to apply that money.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to apply that money.',
        cause: error,
      );
    }
  }

  /// The first row an account RPC returns, or `null` when it returns none.
  ///
  /// Both readers are `returns table`, so PostgREST answers with an array - and an
  /// empty one is a real answer ("no such patient in this pharmacy") rather than a
  /// failure. A single object is tolerated for the same reason the checkout read
  /// tolerates one: a shape difference, not a case the function can produce.
  Future<Map<String, dynamic>?> _oneRow(
    String function,
    Map<String, dynamic> params, {
    required String fallbackMessage,
  }) async {
    try {
      final response = await _client.rpc<dynamic>(function, params: params);
      return switch (response) {
        final List<dynamic> rows when rows.isNotEmpty =>
          (rows.first as Map).cast<String, dynamic>(),
        final Map<dynamic, dynamic> map => map.cast<String, dynamic>(),
        _ => null,
      };
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(error, fallbackMessage: fallbackMessage);
    } on Object catch (error) {
      throw ServerException(message: fallbackMessage, cause: error);
    }
  }
}
