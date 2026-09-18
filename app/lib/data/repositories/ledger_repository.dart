/// Read access to party ledgers (`ledger_entries`).
///
/// Lives in `data/repositories` rather than inside a feature because both the
/// supplier and customer modules read it, and because the ledger belongs to
/// neither of them.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/party_balance.dart';
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
