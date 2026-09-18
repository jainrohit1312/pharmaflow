/// Read access to party ledgers (`ledger_entries`).
///
/// Lives in `data/repositories` rather than inside a feature because both the
/// supplier and customer modules read it, and because the ledger belongs to
/// neither of them.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/ledger_entry.dart';
import 'package:app/data/models/party_balance.dart';
import 'package:app/data/models/sale.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'ledger_repository.g.dart';

/// Exposes the single [LedgerRepository].
@riverpod
LedgerRepository ledgerRepository(Ref ref) =>
    LedgerRepository(ref.watch(supabaseClientProvider));

/// Reads a party's ledger totals.
class LedgerRepository {
  /// Creates a repository backed by the shared Supabase client.
  LedgerRepository(this._client);

  final sb.SupabaseClient _client;

  /// Rows fetched per request while totalling a ledger.
  ///
  /// Tied to PostgREST's `max_rows` ceiling (`supabase/config.toml:27`), which
  /// caps a single response at 1000 rows regardless of what the client asks
  /// for. Asking for exactly one page at a time is what makes the loop below
  /// able to detect that there is more to read.
  static const int pageSize = 1000;

  /// Rows fetched per page by the ledger screen.
  ///
  /// Much smaller than [pageSize]: a person reads this list, and a thousand rows is
  /// a wall rather than a page.
  static const int ledgerPageSize = 50;

  /// One page of a party's ledger entries, newest first.
  ///
  /// Ordered by entry date and then by insertion, because several entries are often
  /// posted on one date (a purchase and its payment, say) and the order they were
  /// written in is the order they happened in.
  Future<List<LedgerEntry>> entriesFor({
    required String pharmacyId,
    required PartyType partyType,
    required String partyId,
    int limit = ledgerPageSize,
    int offset = 0,
  }) async {
    try {
      final rows = await _client
          .from('ledger_entries')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('party_type', partyType.dbValue)
          .eq(
            partyType == PartyType.supplier ? 'supplier_id' : 'customer_id',
            partyId,
          )
          .order('entry_date', ascending: false)
          .order('created_at', ascending: false)
          .range(offset, offset + limit - 1);
      return rows.map(LedgerEntry.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load that ledger.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load that ledger.',
        cause: error,
      );
    }
  }

  /// Records a payment and its ledger entry, in one transaction.
  ///
  /// An RPC rather than two inserts, because the two rows have to agree: a payment
  /// that recorded the cash and failed to post the ledger would leave a party
  /// looking in debt after they had paid. `record_payment()` (migration
  /// 20260918000020) takes the pharmacy from the caller's identity and refuses a
  /// party from another tenant.
  ///
  /// The direction is the function's business, not this one's: a supplier payment
  /// debits and a customer payment credits.
  Future<void> recordPayment({
    required PartyType partyType,
    required String partyId,
    required double amount,
    required PaymentMode mode,
    String? referenceNo,
    DateTime? paymentDate,
    String? notes,
  }) async {
    if (amount <= 0) {
      throw const ValidationException(
        message: 'Enter an amount greater than zero.',
      );
    }

    try {
      await _client.rpc<dynamic>(
        'record_payment',
        params: <String, dynamic>{
          'p_party_type': partyType.dbValue,
          'p_party_id': partyId,
          'p_amount': amount,
          'p_mode': mode.dbValue,
          'p_reference_no': referenceNo?.trim().isEmpty ?? true
              ? null
              : referenceNo!.trim(),
          'p_payment_date': paymentDate == null
              ? null
              : Formatters.dateIso(paymentDate),
          'p_notes': notes?.trim().isEmpty ?? true ? null : notes!.trim(),
        },
      );
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to record that payment.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to record that payment.',
        cause: error,
      );
    }
  }

  /// Totals the ledger entries of one party.
  ///
  /// Pages explicitly instead of issuing one unbounded `select`: a capped
  /// response would silently omit the tail of the ledger and return a balance
  /// that is merely wrong, with nothing to indicate it. This is a financial
  /// figure, so "wrong but plausible" is the one outcome worth engineering
  /// against.
  ///
  /// Phase 4 owns ledger reporting and should replace this with a server-side
  /// aggregate (a `party_balances` view), which removes the round trips
  /// entirely; until then this is the smallest correct implementation.
  Future<PartyBalance> balanceFor({
    required String pharmacyId,
    required PartyType partyType,
    required String partyId,
  }) async {
    var offset = 0;
    var totalDebit = 0.0;
    var totalCredit = 0.0;
    var entryCount = 0;

    while (true) {
      final rows = await _page(
        pharmacyId: pharmacyId,
        partyType: partyType,
        partyId: partyId,
        offset: offset,
      );

      for (final row in rows) {
        totalDebit += (row['debit'] as num?)?.toDouble() ?? 0;
        totalCredit += (row['credit'] as num?)?.toDouble() ?? 0;
      }
      entryCount += rows.length;

      if (rows.length < pageSize) {
        break;
      }
      offset += pageSize;
    }

    return PartyBalance(
      totalDebit: totalDebit,
      totalCredit: totalCredit,
      entryCount: entryCount,
    );
  }

  /// Reads one page of a party's debit/credit columns.
  ///
  /// Only the two columns being summed are selected: the ledger can run to
  /// thousands of rows for a busy supplier, and pulling descriptions and
  /// timestamps along with them would be pure waste.
  Future<List<Map<String, dynamic>>> _page({
    required String pharmacyId,
    required PartyType partyType,
    required String partyId,
    required int offset,
  }) async {
    try {
      return await _client
          .from('ledger_entries')
          .select('debit, credit')
          .eq('pharmacy_id', pharmacyId)
          .eq('party_type', partyType.dbValue)
          .eq(
            partyType == PartyType.supplier ? 'supplier_id' : 'customer_id',
            partyId,
          )
          .range(offset, offset + pageSize - 1);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to read that ledger balance.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to read that ledger balance.',
        cause: error,
      );
    }
  }
}
