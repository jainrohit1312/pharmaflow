/// Read access to the pharmacy tenant row.
///
/// Lives in `data/repositories` rather than inside a feature because more than
/// one does need it: the GRN needs the pharmacy's state to decide the GST split,
/// and Settings (Phase 4) will edit the rest of the row.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/pharmacy.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'pharmacy_repository.g.dart';

/// Exposes the single [PharmacyRepository].
@riverpod
PharmacyRepository pharmacyRepository(Ref ref) =>
    PharmacyRepository(ref.watch(supabaseClientProvider));

/// Reads the pharmacy tenant row.
class PharmacyRepository {
  /// Creates a repository backed by the shared Supabase client.
  PharmacyRepository(this._client);

  final sb.SupabaseClient _client;

  /// The pharmacy row, or `null` when it cannot be read.
  ///
  /// For the screens that have to *print* the tenant rather than merely branch on
  /// a field of it: a GST bill carries the seller's name, address and GSTIN, and
  /// none of those are in `stateFor`.
  Future<Pharmacy?> byId(String pharmacyId) async {
    try {
      final row = await _client
          .from('pharmacies')
          .select()
          .eq('id', pharmacyId)
          .maybeSingle();
      return row == null ? null : Pharmacy.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to read your pharmacy details.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to read your pharmacy details.',
        cause: error,
      );
    }
  }

  /// The state this pharmacy is registered in, or `null` when it is unset.
  ///
  /// Used to decide whether a purchase is intra-state (CGST + SGST) or
  /// inter-state (IGST). `null` is a legitimate answer - a pharmacy may not have
  /// filled its address in yet - and the caller treats it as unknown rather than
  /// guessing here.
  Future<String?> stateFor(String pharmacyId) async {
    try {
      final row = await _client
          .from('pharmacies')
          .select('state')
          .eq('id', pharmacyId)
          .maybeSingle();
      final state = row?['state'] as String?;
      return state?.trim().isEmpty ?? true ? null : state!.trim();
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to read your pharmacy details.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to read your pharmacy details.',
        cause: error,
      );
    }
  }
}
