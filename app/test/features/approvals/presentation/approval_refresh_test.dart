/// Widget tests for what an answer to the owner refreshes.
///
/// Phase 6.5c chunk 2 shipped `decide()` invalidating the pending list and nothing else, so a screen
/// holding the DOCUMENT the answer had just written kept showing the state before it, and a
/// document's *waiting for the owner* card stayed mounted with a question that no longer existed to
/// show. Chunk 6 fixed that through `refreshApprovalReaders()`, and these are the proof: the screens
/// below are mounted BEFORE the answer and are never re-entered, so anything they show after it can
/// only have come from the answer refreshing them.
///
/// The answer is driven through the controller - the same verb the approvals screen calls - because
/// that is the whole contract: the refresh belongs to the ANSWER, not to the screen that takes it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/approval_request.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/features/approvals/application/approvals_controller.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_status_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_approvals_repository.dart';
import '../../../support/fake_purchases_repository.dart';
import '../../../support/purchase_test_app.dart';

void main() {
  testWidgets('a detail screen mounted under the answer re-reads the document', (
    tester,
  ) async {
    final repository = FakePurchasesRepository(
      purchases: <Purchase>[
        buildPurchase(status: PurchaseStatus.pendingApproval),
      ],
      items: <PurchaseItem>[
        buildItem(batchNo: 'B-1', expiryDate: DateTime(2027)),
      ],
      isOwner: false,
    );
    final approvals = FakeApprovalsRepository(
      pending: <ApprovalRequest>[_askAboutPurchase()],
    );

    await pumpPurchaseApp(
      tester,
      repository: repository,
      approvals: approvals,
      initialLocation: Routes.purchaseDetail('purchase-1'),
    );

    expect(
      find.text('Waiting for the owner'),
      findsOneWidget,
      reason: 'the document is staged, and the screen has to say so',
    );
    expect(find.text('Waiting for approval'), findsOneWidget);

    // The owner answers on his own screen, in his own time: the server writes the document (its
    // status, its stock, its payable) and records the decision. Both are applied to the fakes here,
    // because both are what the answer MOVED.
    repository.purchases[0] = buildPurchase(
      status: PurchaseStatus.received,
      stockPostedAt: DateTime(2026, 9, 22),
    );

    await _decide(tester, id: 'approval-1');

    expect(
      approvals.decisions.single.id,
      'approval-1',
      reason: 'the answer went through the rail',
    );
    expect(
      find.text('Waiting for the owner'),
      findsNothing,
      reason:
          'the card is only mounted for a document that is still waiting - so the DOCUMENT was '
          're-read. Invalidating the ask alone would have left the card standing with no question '
          'in it, which is a screen promising an approval that no longer exists',
    );
    expect(find.text('Waiting for approval'), findsNothing);
    expect(
      find.text('Received'),
      findsOneWidget,
      reason: 'and what it re-read is the document the answer wrote',
    );
    expect(
      find.text('This is the payable the ledger holds against the supplier.'),
      findsOneWidget,
      reason: 'the payable the approval posted is now a fact on the screen',
    );
  });

  testWidgets(
    'and a list the document appears in re-reads, though it is kept alive',
    (tester) async {
      final repository = FakePurchasesRepository(
        purchases: <Purchase>[
          buildPurchase(status: PurchaseStatus.pendingApproval),
        ],
        isOwner: false,
      );
      final approvals = FakeApprovalsRepository(
        pending: <ApprovalRequest>[_askAboutPurchase()],
      );

      await pumpPurchaseApp(
        tester,
        repository: repository,
        approvals: approvals,
      );

      expect(
        tester
            .widget<PurchaseStatusBadge>(find.byType(PurchaseStatusBadge))
            .status,
        PurchaseStatus.pendingApproval,
        reason: 'a list shows the staged state it was read with',
      );

      // The list is NOT re-entered: it stays mounted, and its controller is `keepAlive`, so without
      // the answer refreshing it this screen would keep the row it read before the decision - which is
      // the same defect one screen further out.
      repository.purchases[0] = buildPurchase(status: PurchaseStatus.received);

      await _decide(tester, id: 'approval-1');

      expect(
        tester
            .widget<PurchaseStatusBadge>(find.byType(PurchaseStatusBadge))
            .status,
        PurchaseStatus.received,
        reason: 'the row the owner has answered about is no longer waiting',
      );
    },
  );
}

/// The one undecided ask about the fixture document.
ApprovalRequest _askAboutPurchase() => buildApprovalRequest(
  title: 'Purchase INV-1 from Arihant Distributors',
  summary:
      '1 line · ₹1,120.00 · books the goods into stock and raises the supplier payable',
  actionType: ApprovalActionType.purchase,
  targetTable: 'purchases',
  targetId: 'purchase-1',
);

/// Answers [id] the way the approvals screen does - through the rail's own verb.
///
/// Driven from the container rather than by tapping, because the point is the ANSWER rather than the
/// screen that gives it: a tap would mount the approvals screen over this one, and the screens under
/// test are never re-entered.
Future<void> _decide(WidgetTester tester, {required String id}) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );
  await container
      .read(approvalActionsProvider.notifier)
      .decide(id: id, approve: true);
  await tester.pumpAndSettle();
}
