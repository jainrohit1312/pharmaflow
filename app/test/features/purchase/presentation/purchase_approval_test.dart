/// Widget tests for what a purchase write looks like when it is gated.
///
/// Phase 6.5c put every purchase write behind the owner's approval for anybody but him, so
/// the screens have two jobs the tests before it did not cover: say **where** the write
/// went (nothing has posted), and say **what is waiting** on the document itself. The fake
/// repository stands in for the server's two behaviours through `isOwner`, and every test
/// here signs in as staff.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/approval_request.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/data/models/supplier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_approvals_repository.dart';
import '../../../support/fake_products_repository.dart';
import '../../../support/fake_purchases_repository.dart';
import '../../../support/purchase_test_app.dart';

void main() {
  testWidgets(
    'a waiting document says what is waiting and that nothing posted',
    (tester) async {
      await pumpPurchaseApp(
        tester,
        repository: FakePurchasesRepository(
          purchases: <Purchase>[
            buildPurchase(status: PurchaseStatus.pendingApproval),
          ],
          items: <PurchaseItem>[
            buildItem(batchNo: 'B-1', expiryDate: DateTime(2027)),
          ],
          isOwner: false,
        ),
        suppliers: <Supplier>[buildSupplier()],
        approvals: FakeApprovalsRepository(
          pending: <ApprovalRequest>[
            buildApprovalRequest(
              title: 'Purchase INV-1 from Arihant Distributors',
              summary:
                  '1 line · ₹1,120.00 · books the goods into stock and raises '
                  'the supplier payable',
              actionType: ApprovalActionType.purchase,
              targetTable: 'purchases',
              targetId: 'purchase-1',
            ),
          ],
        ),
        initialLocation: Routes.purchaseDetail('purchase-1'),
      );

      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.text('Waiting for the owner'), findsOneWidget);
      expect(
        find.text('Purchase INV-1 from Arihant Distributors'),
        findsOneWidget,
        reason: 'the card shows the question the owner is being asked',
      );
      expect(find.textContaining('books the goods into stock'), findsOneWidget);
      expect(
        find.textContaining('the goods are not in stock'),
        findsOneWidget,
        reason: 'the operational cost of a pending GRN, said plainly',
      );
      expect(
        find.textContaining('cannot be sold'),
        findsOneWidget,
        reason: 'a pending GRN is not sellable, and the counter has to know',
      );
    },
  );

  testWidgets('and does not claim a payable that does not exist yet', (
    tester,
  ) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(
        purchases: <Purchase>[
          buildPurchase(status: PurchaseStatus.pendingApproval),
        ],
        items: <PurchaseItem>[buildItem()],
        isOwner: false,
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.purchaseDetail('purchase-1'),
    );

    expect(
      find.text('This is the payable the ledger holds against the supplier.'),
      findsNothing,
      reason: 'nothing owes the supplier until the owner approves the document',
    );
    expect(find.textContaining('Nothing owes this yet'), findsOneWidget);
  });

  testWidgets('a staff save says it went to the owner rather than landing', (
    tester,
  ) async {
    final repository = FakePurchasesRepository(
      purchases: const <Purchase>[],
      isOwner: false,
    );
    await pumpPurchaseApp(
      tester,
      repository: repository,
      suppliers: <Supplier>[buildSupplier()],
      products: FakeProductsRepository(
        products: <Product>[buildProduct('Dolo 650')],
      ),
      initialLocation: Routes.purchaseForm,
    );

    await _selectSupplier(tester, 'Arihant Distributors');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Invoice number'),
      'INV-2026',
    );
    await tester.pump();
    await _pickProduct(tester, 'Dolo 650');

    await tapVisible(tester, find.widgetWithText(ElevatedButton, 'Save draft'));

    expect(
      repository.asks.single.resumeStatus,
      PurchaseStatus.draft,
      reason: 'a draft is what the form asked for, and what approving it gives',
    );
    expect(repository.asks.single.actionType, ApprovalActionType.purchase);
    expect(
      find.text('Sent to the owner. Nothing posts until he approves it.'),
      findsOneWidget,
      reason: 'a silence after Save would read as a draft that exists',
    );
  });

  testWidgets('the same document saved twice asks once', (tester) async {
    final repository = FakePurchasesRepository(
      purchases: <Purchase>[buildPurchase()],
      items: <PurchaseItem>[buildItem()],
      isOwner: false,
    );
    await pumpPurchaseApp(
      tester,
      repository: repository,
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.purchaseDetail('purchase-1'),
    );

    await tapVisible(
      tester,
      find.widgetWithText(OutlinedButton, 'Mark as ordered'),
    );

    expect(
      repository.asks,
      hasLength(1),
      reason:
          'the question is refined, not stacked (request_approval convergence)',
    );
    expect(repository.asks.single.resumeStatus, PurchaseStatus.ordered);
    expect(find.text('Waiting for approval'), findsOneWidget);
  });

  testWidgets(
    'a staff cancellation asks, and leaves the document where it is',
    (tester) async {
      final repository = FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase()],
        items: <PurchaseItem>[buildItem()],
        isOwner: false,
      );
      await pumpPurchaseApp(
        tester,
        repository: repository,
        suppliers: <Supplier>[buildSupplier()],
        initialLocation: Routes.purchaseDetail('purchase-1'),
      );

      await tapVisible(
        tester,
        find.widgetWithText(OutlinedButton, 'Cancel purchase'),
      );
      await tapVisible(
        tester,
        find.widgetWithText(TextButton, 'Cancel purchase'),
      );

      expect(repository.lastStatus, PurchaseStatus.cancelled);
      expect(
        repository.asks.single.actionType,
        ApprovalActionType.purchaseDelete,
      );
      expect(
        find.text('Draft'),
        findsOneWidget,
        reason: 'nothing moves until the owner answers a cancellation',
      );
      expect(
        find.text(
          'Sent to the owner. The document stays as it is until he answers.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('the list can be filtered to what is waiting', (tester) async {
    final repository = FakePurchasesRepository(
      purchases: <Purchase>[
        buildPurchase(status: PurchaseStatus.pendingApproval),
      ],
      isOwner: false,
    );
    await pumpPurchaseApp(
      tester,
      repository: repository,
      suppliers: <Supplier>[buildSupplier()],
    );

    // Asserted by widget rather than by text alone: the chip and the card's badge say
    // the same words, and only one of them filters.
    final chip = find.widgetWithText(ChoiceChip, 'Waiting for approval');
    expect(
      chip,
      findsOneWidget,
      reason: 'a member of staff has to be able to find the GRN he sent',
    );

    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(
      repository.lastQuery?.status,
      PurchaseStatus.pendingApproval,
      reason: 'the chip filters on the status the server actually stores',
    );
  });
}

/// Picks [name] in the form's supplier dropdown.
Future<void> _selectSupplier(WidgetTester tester, String name) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  // `.last`, because the closed button keeps every item in its own tree and the
  // open menu's copy is what a tap has to land on.
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

/// Picks [name] through the line's product picker.
Future<void> _pickProduct(WidgetTester tester, String name) async {
  await tapVisible(tester, find.text('Search the catalogue'));
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}
