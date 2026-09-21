/// The approval rail's readers and the two commands over it.
library;

import 'package:app/data/models/approval_request.dart';
import 'package:app/features/approvals/application/approval_readers.dart';
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

/// One request's current state, for whoever is waiting on the answer.
///
/// A family over the id rather than a watch on the pending list, because once the owner
/// has answered, the row leaves that list - and "no longer pending" cannot say whether he
/// allowed it or refused it, which is the whole question the counter is asking.
@riverpod
Future<ApprovalRequest?> approvalRequest(Ref ref, String id) =>
    ref.watch(approvalsRepositoryProvider).byId(id);

/// The undecided request about one document, if there is one.
///
/// Keyed by the target rather than by the request's id, for the screens that hold a
/// document and have to say what is waiting: a purchase detail that shows
/// "waiting for the owner" can say what he is being asked, and can say nothing at all
/// when the document is not actually waiting - which is the shape that keeps a screen
/// from promising an approval that does not exist.
@riverpod
Future<ApprovalRequest?> approvalForTarget(
  Ref ref, {
  required String targetTable,
  required String targetId,
}) => ref
    .watch(approvalsRepositoryProvider)
    .pendingForTarget(targetTable: targetTable, targetId: targetId);

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
  ///
  /// **One answer moves more than the queue**, which is what this used to get wrong: it invalidated
  /// the pending list and nothing else, so a screen holding the document the answer had just written
  /// kept showing the state before it - and the counter's own label on a bill it had asked about kept
  /// reading *waiting for the owner*. Both are refreshed here, through the one place that knows which
  /// reads an answer feeds.
  ///
  /// [request] deliberately keeps its narrower refresh. An ask writes nothing for the gated families -
  /// the document is untouched until the owner answers - and the one write it can make, a document
  /// staged as `pending_approval`, is refreshed by the screen that made it, which re-reads its own
  /// document and list as part of reporting where the work went.
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
      refreshApprovalReaders(ref);
      state = AsyncData<ApprovalRequest?>(decided);
      return decided;
    } on Object catch (error, stackTrace) {
      state = AsyncError<ApprovalRequest?>(error, stackTrace);
      rethrow;
    }
  }
}
