/// Supabase-backed repository for the opening-stock import.
///
/// Every call is an RPC, and the two that decide anything are server-side:
/// `preview_opening_stock` classifies a payload and writes nothing, and
/// `commit_opening_stock_import` re-classifies it and writes everything in one
/// transaction. This class sends rows and reads envelopes; it holds no rule about
/// what an opening-stock row may contain, because the one place those rules live
/// is `opening_stock_classify()` (migration 20260920000031) - a second copy here
/// is how a preview comes to differ from a commit.
///
/// The tenant is never sent: the functions take it from `get_my_pharmacy_id()`.
library;

import 'dart:async';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_csv.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_models.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'opening_stock_repository.g.dart';

/// Exposes the single [OpeningStockRepository].
@riverpod
OpeningStockRepository openingStockRepository(Ref ref) =>
    OpeningStockRepository(ref.watch(supabaseClientProvider));

/// Reads and writes opening stock through the Phase 6.5a RPCs.
class OpeningStockRepository {
  /// Creates a repository over the Supabase client.
  OpeningStockRepository(this._client);

  /// The RPC that classifies a payload without writing anything.
  static const String previewRpc = 'preview_opening_stock';

  /// The RPC that commits one.
  static const String commitRpc = 'commit_opening_stock_import';

  /// The RPC that reads a committed job back for the audit trail.
  static const String jobRpc = 'get_import_job';

  final sb.SupabaseClient _client;

  /// Classifies [rows] and answers with every counter the preview screen shows.
  Future<OpeningStockPreview> preview(List<OpeningStockCsvRow> rows) async {
    try {
      final response = await _client.rpc<dynamic>(
        previewRpc,
        params: <String, dynamic>{'p_rows': _payload(rows)},
      );
      return OpeningStockPreview.fromJson(_envelope(response, previewRpc));
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'That file could not be checked.',
      );
    } on Object catch (error) {
      throw _unexpected(error, 'That file could not be checked.');
    }
  }

  /// Commits [rows] as one import, or answers with the job that already holds
  /// this exact content.
  ///
  /// [fileName] is recorded for the audit trail and takes no part in the
  /// idempotency key: the same rows under another name are the same import.
  Future<OpeningStockCommitResult> commit({
    required List<OpeningStockCsvRow> rows,
    required String fileName,
  }) async {
    try {
      final response = await _client.rpc<dynamic>(
        commitRpc,
        params: <String, dynamic>{
          'p_rows': _payload(rows),
          'p_filename': fileName,
        },
      );
      return OpeningStockCommitResult.fromJson(_envelope(response, commitRpc));
    } on sb.PostgrestException catch (error) {
      // A refusal is a sentence the server wrote for the owner, and it names the
      // rows at fault, so it is shown as it stands. That includes the one
      // refusal the function raises as a unique violation rather than a check
      // violation - a batch number the pharmacy's stock already holds - which
      // would otherwise be replaced by a generic "already exists" line.
      throw mapPostgrestException(
        error,
        fallbackMessage: 'That import could not be written.',
        uniqueViolationMessage: error.message.isEmpty ? null : error.message,
      );
    } on Object catch (error) {
      throw _unexpected(error, 'That import could not be written.');
    }
  }

  /// Reads a committed import back, with the names it wrote.
  Future<ImportJob> job(String jobId) async {
    try {
      final response = await _client.rpc<dynamic>(
        jobRpc,
        params: <String, dynamic>{'p_job_id': jobId},
      );
      return ImportJob.fromJson(_envelope(response, jobRpc));
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'That import could not be read.',
      );
    } on Object catch (error) {
      throw _unexpected(error, 'That import could not be read.');
    }
  }

  /// The rows as the RPC's `p_rows`: raw text, coerced server-side.
  List<Map<String, dynamic>> _payload(List<OpeningStockCsvRow> rows) =>
      rows.map((row) => row.toJson()).toList(growable: false);

  /// The response as an object, or a failure naming the shape that arrived.
  Map<String, dynamic> _envelope(Object? response, String rpc) {
    final raw = switch (response) {
      final List<dynamic> rows when rows.isNotEmpty => rows.first,
      final Map<dynamic, dynamic> map => map,
      _ => null,
    };
    if (raw is Map) {
      return raw.cast<String, dynamic>();
    }
    throw ServerException(
      message: 'The import service answered in a shape this app cannot read.',
      code: rpc,
    );
  }

  /// An unexpected throw, re-thrown as-is when the app already classified it.
  ///
  /// A request that timed out is named as a network failure rather than as a
  /// server one: nothing came back, so the server never said anything about the
  /// file, and the screen reads the two differently - "the file could not be
  /// sent" is advice about the connection, "the server could not check the file"
  /// is advice about the file.
  AppException _unexpected(Object error, String message) => switch (error) {
    final AppException classified => classified,
    final TimeoutException timedOut => NetworkException(
      message:
          'The server did not answer in time, so the file has not been checked. '
          'Check the connection and try again.',
      cause: timedOut,
    ),
    _ => ServerException(message: message, cause: error),
  };
}
