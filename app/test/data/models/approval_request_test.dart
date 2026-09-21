/// Tests for the approval request model.
///
/// The row is what the server wrote, so the parsing is asserted against the column names
/// migration 00043 created rather than against a hand-made map: a model that read
/// `actionType` instead of `action_type` would compile, pass a camelCase fixture and fail
/// against every real row.
library;

import 'package:app/data/models/approval_request.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_approvals_repository.dart';

void main() {
  group('parsing a row', () {
    test('reads the snake_case columns the migration created', () {
      final request = ApprovalRequest.fromJson(<String, dynamic>{
        'id': 'approval-1',
        'pharmacy_id': 'ph-1',
        'action_type': 'discount_above_limit',
        'status': 'pending',
        'title': 'Discount 100 on a bill of 546',
        'summary': 'Over the 10% cap',
        'payload': <String, dynamic>{'discount_amount': 100, 'bill_gross': 546},
        'requested_by': 'user-1',
        'requested_at': '2026-09-21T14:30:00.000Z',
      });

      expect(request.actionType, ApprovalActionType.discountAboveLimit);
      expect(request.status, ApprovalStatus.pending);
      expect(request.pharmacyId, 'ph-1');
      expect(request.requestedBy, 'user-1');
      expect(request.decidedBy, isNull);
      expect(request.decidedAt, isNull);
      expect(request.requestedAt.toUtc(), DateTime.utc(2026, 9, 21, 14, 30));
    });

    test('reads the decision a decided row carries', () {
      final request = ApprovalRequest.fromJson(<String, dynamic>{
        'id': 'approval-1',
        'pharmacy_id': 'ph-1',
        'action_type': 'discount_above_limit',
        'status': 'approved',
        'title': 'Discount 100 on a bill of 546',
        'requested_at': '2026-09-21T14:30:00.000Z',
        'decided_by': 'owner-1',
        'decided_at': '2026-09-21T14:35:00.000Z',
        'decision_note': 'OK',
      });

      expect(request.status, ApprovalStatus.approved);
      expect(request.decidedBy, 'owner-1');
      expect(request.decisionNote, 'OK');
    });
  });

  group('an unrecognised literal', () {
    test('is an unknown action type rather than a guess', () {
      // Treating a new action type as a discount would offer the owner a card whose
      // figures are read off a payload that means something else entirely.
      expect(
        approvalActionTypeFromDb('something_a_later_chunk_added'),
        ApprovalActionType.unknown,
      );
      expect(approvalActionTypeFromDb(null), ApprovalActionType.unknown);
      expect(ApprovalActionType.unknown.label, 'Approval');
    });

    test('is a PENDING status, never an approved one', () {
      // The safe direction: an unreadable status shows as something still to answer,
      // not as a permission nobody gave.
      expect(approvalStatusFromDb('weird'), ApprovalStatus.pending);
      expect(approvalStatusFromDb(null), ApprovalStatus.pending);
    });
  });

  test('every literal round-trips through its own parser', () {
    for (final type in ApprovalActionType.values) {
      expect(
        approvalActionTypeFromDb(type.dbValue),
        type,
        reason: '${type.name} -> ${type.dbValue}',
      );
      expect(type.label, isNotEmpty, reason: type.name);
    }
    for (final status in ApprovalStatus.values) {
      expect(
        approvalStatusFromDb(status.dbValue),
        status,
        reason: '${status.name} -> ${status.dbValue}',
      );
    }
  });

  group('the figures a request carries', () {
    test('are read off the payload, which is what the owner agrees to', () {
      final request = buildApprovalRequest();

      expect(request.discountAmount, 100);
      expect(request.billGross, 546);
    });

    test('are null when the payload does not carry them', () {
      // A request for anything else has no discount to show, and the card must not
      // invent one.
      final request = buildApprovalRequest(payload: const <String, dynamic>{});

      expect(request.discountAmount, isNull);
      expect(request.billGross, isNull);
    });
  });
}
