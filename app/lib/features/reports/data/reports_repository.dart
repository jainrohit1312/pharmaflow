/// Supabase-backed repository for the reporting aggregates.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/report_summary.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'reports_repository.g.dart';

/// Exposes the single [ReportsRepository].
@riverpod
ReportsRepository reportsRepository(Ref ref) =>
    ReportsRepository(ref.watch(supabaseClientProvider));

/// Reads the reporting aggregates.
class ReportsRepository {
  /// Creates a repository backed by the shared Supabase client.
  ReportsRepository(this._client);

  final sb.SupabaseClient _client;

  /// Every total for [from]..[to], in one round trip.
  ///
  /// One call rather than six queries, because a report whose parts were read at
  /// different moments can disagree with itself - a sale rung up between two reads
  /// lands in one figure and not the other - and a report nobody trusts is worse
  /// than no report.
  ///
  /// The pharmacy is not passed: the function takes it from the caller's identity
  /// (`get_my_pharmacy_id()`), so a crafted argument cannot read another tenant's
  /// numbers.
  Future<ReportSummary> summary({
    required DateTime from,
    required DateTime to,
  }) async {
    try {
      final response = await _client.rpc<dynamic>(
        'report_summary',
        params: <String, dynamic>{
          'p_from': Formatters.dateIso(from),
          'p_to': Formatters.dateIso(to),
        },
      );
      // PostgREST returns a `jsonb`-returning function as one object; the list
      // branch is tolerance for a shape difference rather than a case this
      // function can produce.
      final row = switch (response) {
        final Map<dynamic, dynamic> map => map.cast<String, dynamic>(),
        final List<dynamic> rows when rows.isNotEmpty =>
          (rows.first as Map).cast<String, dynamic>(),
        _ => throw const ServerException(message: 'The report came back empty.'),
      };
      return ReportSummary.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to read the report.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(message: 'Unable to read the report.', cause: error);
    }
  }
}
