/// The approval rail's readers and the two commands over it.
library;

import 'package:app/data/models/approval_request.dart';
import 'package:app/features/approvals/data/approvals_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'approvals_controller.g.dart';

/// The requests waiting for an answer, oldest first.
///
/// The same provider serves both sides of the rail, because the RLS policy already
/// decides what each caller may see: for the owner it is his queue, and for a member of
/// staff it is his own asks - which is exactly what "did he answer yet?" needs.
@riverpod
Future<List<ApprovalRequest>> pendingApprovals(Ref ref) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref.watch(approvalsRepositoryProvider).pending(pharmacyId: pharmacyId);
}

/// Raises a request and decides one.
///
/// A command holder rather than a state machine: what the UI needs from it is whether a
/// call is in flight, and the two verbs the rail has. Both refresh [pendingApprovals]
/// on success, so the list a screen is showing cannot be a stale one.
@riverpod
class ApprovalActions extends _$ApprovalActions {
  @override
  Future<ApprovalRequest?> build() async => null;

  /// Asks the owner to allow [actionType], and returns the request that was stored.
  Future<ApprovalRequest> request({
    required ApprovalActionType actionType,
    required String title,
    String? summary,
    Map<String, dynamic> payload = const <String, dynamic>{},
    String? targetTable,
    String? targetId,
    String? idempotencyKey,
  }) async {
    state = const AsyncLoading<ApprovalRequest?>();
    try {
      final stored = await ref
          .read(approvalsRepositoryProvider)
          .request(
            actionType: actionType,
            title: title,
            summary: summary,
            payload: payload,
            targetTable: targetTable,
            targetId: targetId,
            idempotencyKey: idempotencyKey,
          );
      ref.invalidate(pendingApprovalsProvider);
      state = AsyncData<ApprovalRequest?>(stored);
      return stored;
    } on Object catch (error, stackTrace) {
      state = AsyncError<ApprovalRequest?>(error, stackTrace);
      rethrow;
    }
  }

  /// Records the owner's answer, and returns the decided request.
  Future<ApprovalRequest> decide({
    required String id,
    required bool approve,
    String? note,
  }) async {
    state = const AsyncLoading<ApprovalRequest?>();
    try {
      final decided = await ref
          .read(approvalsRepositoryProvider)
          .decide(id: id, approve: approve, note: note);
      ref.invalidate(pendingApprovalsProvider);
      state = AsyncData<ApprovalRequest?>(decided);
      return decided;
    } on Object catch (error, stackTrace) {
      state = AsyncError<ApprovalRequest?>(error, stackTrace);
      rethrow;
    }
  }
}
