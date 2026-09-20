/// Supabase-backed repository for the prescriber master.
///
/// The read the counter needs and nothing more: `doctors` is written by whatever
/// settings screen owns the master, and a sale only ever *names* a prescriber
/// (D-072) - `save_admission()` and `checkout_sale()` create a missing row
/// themselves from the typed name, so the client has no reason to write one.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/doctor.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'doctors_repository.g.dart';

/// Exposes the single [DoctorsRepository].
@riverpod
DoctorsRepository doctorsRepository(Ref ref) =>
    DoctorsRepository(ref.watch(supabaseClientProvider));

/// Data access for `doctors`.
class DoctorsRepository {
  /// Creates a repository backed by the shared Supabase client.
  DoctorsRepository(this._client);

  final sb.SupabaseClient _client;

  /// Prescribers a picker loads at once.
  ///
  /// A pharmacy's prescriber list is a directory of the doctors who write for it,
  /// not a crowd, so the whole active list is one page - and a typed name is
  /// always accepted anyway, so a doctor nobody has recorded yet is not a blocker.
  static const int pageSize = 200;

  /// The pharmacy's prescribers, ordered by name.
  ///
  /// [search] matches anywhere in the name, case-insensitively, for the picker's
  /// type-ahead. Inactive doctors are included only when a search asks for them by
  /// name - the list a counter chooses from holds the active ones.
  Future<List<Doctor>> list({
    required String pharmacyId,
    String search = '',
    bool includeInactive = false,
    int limit = pageSize,
  }) async {
    try {
      var request = _client
          .from('doctors')
          .select()
          .eq('pharmacy_id', pharmacyId);

      if (!includeInactive) {
        request = request.eq('is_active', true);
      }
      final term = search.trim();
      if (term.isNotEmpty) {
        request = request.ilike('name', '%$term%');
      }

      final rows = await request.order('name').limit(limit);
      return rows.map(Doctor.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the prescribers.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the prescribers.',
        cause: error,
      );
    }
  }
}
