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

  /// How many times the pending list was read.
  int reads = 0;

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
