/// An in-memory [ApprovalsRepository] for the approvals screen's tests.
///
/// Implements only what the screen drives - the pending read and the decision - and
/// leaves the rest to `noSuchMethod`, which is the shape the other fakes in this
/// directory use: a fake that quietly returned something for a member no test exercises
/// would hide the fact that nothing drove it.
library;

import 'package:app/data/models/approval_request.dart';
import 'package:app/features/approvals/data/approvals_repository.dart';

/// A discount request fixture, with the owner's own example figures.
ApprovalRequest buildApprovalRequest({
  String id = 'approval-1',
  String title = 'Discount 100 on a bill of 546',
  String? summary = 'Over the 10% cap',
  ApprovalActionType actionType = ApprovalActionType.discountAboveLimit,
  ApprovalStatus status = ApprovalStatus.pending,
  Map<String, dynamic> payload = const <String, dynamic>{
    'discount_amount': 100,
    'bill_gross': 546,
  },
  String? targetTable,
  String? targetId,
  DateTime? requestedAt,
}) => ApprovalRequest(
  id: id,
  pharmacyId: 'ph-1',
  title: title,
  requestedAt: requestedAt ?? DateTime(2026, 9, 21, 14, 30),
  actionType: actionType,
  status: status,
  summary: summary,
  payload: payload,
  targetTable: targetTable,
  targetId: targetId,
);

/// One decision a test saw the screen make.
typedef RecordedDecision = ({String id, bool approve, String? note});

/// A fake approvals repository holding the requests a test gave it.
class FakeApprovalsRepository implements ApprovalsRepository {
  /// Creates a fake with [pending] already waiting.
  FakeApprovalsRepository({
    List<ApprovalRequest> pending = const <ApprovalRequest>[],
  }) : _pending = <ApprovalRequest>[...pending];

  final List<ApprovalRequest> _pending;

  /// Every decision the screen made, in order.
  final List<RecordedDecision> decisions = <RecordedDecision>[];

  /// Every request the counter raised, in order.
  final List<ApprovalRequest> requests = <ApprovalRequest>[];

  /// How many times the pending list was read.
  int reads = 0;

  /// Answers the request with [id] as the owner would, so a test can drive
  /// "asked -> answered" without a second identity.
  void approve(String id) => _answer(id, ApprovalStatus.approved);

  /// Refuses the request with [id], on the same terms.
  void refuse(String id) => _answer(id, ApprovalStatus.rejected);

  void _answer(String id, ApprovalStatus status) {
    for (var index = 0; index < _pending.length; index++) {
      if (_pending[index].id == id) {
        _pending[index] = _pending[index].copyWith(status: status);
      }
    }
  }

  /// Thrown by the next call, when a test wants a failure.
  ///
  /// Typed as an [Exception] rather than an `Object` so the fake can rethrow it: a
  /// thrown non-`Exception` is a lint here, and every failure this app produces is one.
  Exception? errorToThrow;

  @override
  Future<List<ApprovalRequest>> pending({
    required String pharmacyId,
    int limit = 100,
  }) async {
    reads++;
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    return List<ApprovalRequest>.of(_pending);
  }

  @override
  Future<ApprovalRequest?> byId(String id) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    for (final request in _pending) {
      if (request.id == id) {
        return request;
      }
    }
    return null;
  }

  @override
  Future<ApprovalRequest?> pendingForTarget({
    required String targetTable,
    required String targetId,
  }) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    for (final request in _pending) {
      if (request.targetTable == targetTable && request.targetId == targetId) {
        return request;
      }
    }
    return null;
  }

  @override
  Future<ApprovalRequest> request({
    required ApprovalActionType actionType,
    required String title,
    String? summary,
    Map<String, dynamic> payload = const <String, dynamic>{},
    String? targetTable,
    String? targetId,
    String? idempotencyKey,
  }) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    final raised = ApprovalRequest(
      id: 'approval-${requests.length + 1}',
      pharmacyId: 'ph-1',
      title: title,
      requestedAt: DateTime(2026, 9, 21, 15),
      actionType: actionType,
      summary: summary,
      payload: payload,
    );
    requests.add(raised);
    _pending.add(raised);
    return raised;
  }

  @override
  Future<ApprovalRequest> decide({
    required String id,
    required bool approve,
    String? note,
  }) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    decisions.add((id: id, approve: approve, note: note));
    final decided = _pending.firstWhere((request) => request.id == id);
    _pending.removeWhere((request) => request.id == id);
    return decided.copyWith(
      status: approve ? ApprovalStatus.approved : ApprovalStatus.rejected,
      decisionNote: note,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
