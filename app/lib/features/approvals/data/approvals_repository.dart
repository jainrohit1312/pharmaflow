/// Reads and writes the owner-approval rail (migration 00043).
///
/// Three things only, because the server holds every rule: the pending list the owner
/// looks at, the ask a member of staff raises, and the answer only the owner may give.
/// Who may call which is RLS and `decide_approval()`'s own role check - a client that
/// offered the wrong control would be refused server-side, which is the direction this
/// repository is designed in.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/approval_request.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'approvals_repository.g.dart';

/// Exposes the single [ApprovalsRepository].
@riverpod
ApprovalsRepository approvalsRepository(Ref ref) =>
    ApprovalsRepository(ref.watch(supabaseClientProvider));

/// Reads, raises and decides approval requests.
class ApprovalsRepository {
  /// Creates a repository backed by the shared Supabase client.
  ApprovalsRepository(this._client);

  final sb.SupabaseClient _client;

  /// The requests waiting for an answer, oldest first.
  ///
  /// Reads what the caller is allowed to see and no more: the table's RLS policy gives
  /// the owner every pending request in his pharmacy and a member of staff his own.
  /// So the same call serves the owner's queue and a cashier's "did he answer yet?".
  Future<List<ApprovalRequest>> pending({
    required String pharmacyId,
    int limit = 100,
  }) async {
    try {
      final rows = await _client
          .from('approval_requests')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('status', ApprovalStatus.pending.dbValue)
          .order('requested_at')
          .limit(limit);

      return <ApprovalRequest>[
        for (final row in rows) ApprovalRequest.fromJson(row),
      ];
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to read the approvals waiting for you.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to read the approvals waiting for you.',
        cause: error,
      );
    }
  }

  /// One request by id, or `null` when this caller may not read it.
  ///
  /// `null` rather than a throw, for the same reason the table's read policy is a SELECT
  /// one: another pharmacy's row, somebody else's request and an id that names nothing
  /// all answer "nothing". That is exactly what the counter's waiting state needs - it is
  /// asking "has the owner answered this yet", not "does this row exist".
  Future<ApprovalRequest?> byId(String id) async {
    try {
      final row = await _client
          .from('approval_requests')
          .select()
          .eq('id', id)
          .maybeSingle();

      return row == null ? null : ApprovalRequest.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to check that approval.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to check that approval.',
        cause: error,
      );
    }
  }

  /// Raises a request, and answers with the row the server stored.
  ///
  /// The server refuses an action type whose chunk has not landed, and refuses a
  /// discount that is within the cap the counter may give anyway - both in its own
  /// words, which is why nothing here pre-checks them.
  Future<ApprovalRequest> request({
    required ApprovalActionType actionType,
    required String title,
    String? summary,
    Map<String, dynamic> payload = const <String, dynamic>{},
    String? targetTable,
    String? targetId,
    String? idempotencyKey,
  }) async {
    try {
      final row = await _client.rpc<dynamic>(
        'request_approval',
        params: <String, dynamic>{
          'p_action_type': actionType.dbValue,
          'p_title': title,
          'p_summary': summary,
          'p_payload': payload,
          'p_target_table': targetTable,
          'p_target_id': targetId,
          'p_idempotency_key': idempotencyKey,
        },
      );
      return ApprovalRequest.fromJson(row as Map<String, dynamic>);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to send that for approval.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to send that for approval.',
        cause: error,
      );
    }
  }

  /// The owner's answer to [id].
  ///
  /// Owner-only server-side, and a request can be decided once - so a stale list and a
  /// second tap are both refused rather than re-stamped.
  Future<ApprovalRequest> decide({
    required String id,
    required bool approve,
    String? note,
  }) async {
    try {
      final row = await _client.rpc<dynamic>(
        'decide_approval',
        params: <String, dynamic>{
          'p_id': id,
          'p_approve': approve,
          'p_note': note,
        },
      );
      return ApprovalRequest.fromJson(row as Map<String, dynamic>);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to record that decision.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to record that decision.',
        cause: error,
      );
    }
  }
}
