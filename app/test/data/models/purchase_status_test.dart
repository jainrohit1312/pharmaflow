/// Unit tests for `purchase_status`: the literal Phase 6.5c added, and what it
/// changes about what a document allows.
library;

import 'package:app/data/models/purchase.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('purchaseStatusFromDb', () {
    test('maps each literal the column can hold', () {
      expect(purchaseStatusFromDb('draft'), PurchaseStatus.draft);
      expect(purchaseStatusFromDb('ordered'), PurchaseStatus.ordered);
      expect(purchaseStatusFromDb('received'), PurchaseStatus.received);
      expect(purchaseStatusFromDb('cancelled'), PurchaseStatus.cancelled);
      expect(
        purchaseStatusFromDb('pending_approval'),
        PurchaseStatus.pendingApproval,
      );
    });

    test('is case and whitespace insensitive', () {
      expect(
        purchaseStatusFromDb(' PENDING_APPROVAL '),
        PurchaseStatus.pendingApproval,
      );
      expect(purchaseStatusFromDb('Received'), PurchaseStatus.received);
    });

    test('falls back to draft for null and an unknown literal', () {
      expect(purchaseStatusFromDb(null), PurchaseStatus.draft);
      expect(purchaseStatusFromDb('nonsense'), PurchaseStatus.draft);
    });

    test('a waiting document is never read as a draft', () {
      // The one fallback that would matter: `pending_approval` arriving as a draft
      // would hide the single thing its owner needs to see about it.
      expect(
        purchaseStatusFromDb('pending_approval'),
        isNot(PurchaseStatus.draft),
      );
    });
  });

  group('PurchaseStatusX', () {
    test('round-trips through its DB literal', () {
      for (final status in PurchaseStatus.values) {
        expect(purchaseStatusFromDb(status.dbValue), status);
      }
    });

    test('labels every status', () {
      expect(PurchaseStatus.draft.label, 'Draft');
      expect(PurchaseStatus.ordered.label, 'Ordered');
      expect(PurchaseStatus.received.label, 'Received');
      expect(PurchaseStatus.cancelled.label, 'Cancelled');
      expect(PurchaseStatus.pendingApproval.label, 'Waiting for approval');
    });

    test('only received has posted anything', () {
      for (final status in PurchaseStatus.values) {
        expect(
          status.isPosted,
          status == PurchaseStatus.received,
          reason: 'a staged document has written its lines and moved no stock',
        );
      }
    });

    test('only a waiting document is waiting', () {
      for (final status in PurchaseStatus.values) {
        expect(
          status.isPendingApproval,
          status == PurchaseStatus.pendingApproval,
        );
      }
    });

    test('a waiting document is still editable, and a posted one is not', () {
      expect(PurchaseStatus.draft.isEditable, isTrue);
      expect(PurchaseStatus.ordered.isEditable, isTrue);
      expect(
        PurchaseStatus.pendingApproval.isEditable,
        isTrue,
        reason:
            'it is the document being proposed - an incomplete pending GRN has '
            'to be finishable, and saving it again refines the one ask',
      );
      expect(PurchaseStatus.received.isEditable, isFalse);
      expect(PurchaseStatus.cancelled.isEditable, isFalse);
    });
  });
}
