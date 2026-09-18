/// Widget tests for the purchase detail screen.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/data/models/supplier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_purchases_repository.dart';
import '../../../support/purchase_test_app.dart';

void main() {
  testWidgets('shows the invoice, its supplier, its lines and its totals', (
    tester,
  ) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase()],
        items: <PurchaseItem>[buildItem()],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.purchaseDetail('purchase-1'),
    );

    expect(find.text('Arihant Distributors'), findsOneWidget);
    expect(find.text('Invoice number'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Paracetamol 500mg'), findsOneWidget);
    // The totals come off the stored columns, so the tax head is the one the
    // write recorded rather than a fresh split.
    expect(find.text('Taxable value'), findsOneWidget);
    expect(find.text('CGST'), findsOneWidget);
    expect(find.text('SGST'), findsOneWidget);
    expect(find.text('Grand total'), findsOneWidget);
  });

  testWidgets('offers the goods receipt while nothing has been posted', (
    tester,
  ) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase()],
        items: <PurchaseItem>[buildItem()],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.purchaseDetail('purchase-1'),
    );

    expect(find.text('Next step'), findsOneWidget);
    expect(
      find.widgetWithText(ElevatedButton, 'Receive goods'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(OutlinedButton, 'Mark as ordered'),
      findsOneWidget,
    );
    expect(find.byTooltip('Edit purchase'), findsOneWidget);
  });

  testWidgets('marks a draft as ordered', (tester) async {
    final repository = FakePurchasesRepository(
      purchases: <Purchase>[buildPurchase()],
      items: <PurchaseItem>[buildItem()],
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

    expect(repository.lastStatus, PurchaseStatus.ordered);
    expect(
      find.text('Ordered'),
      findsOneWidget,
      reason: 'the badge follows the write',
    );
  });

  testWidgets('a received document shows what it posted and cannot be edited', (
    tester,
  ) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(
        purchases: <Purchase>[
          buildPurchase(
            status: PurchaseStatus.received,
            stockPostedAt: DateTime(2026),
          ),
        ],
        items: <PurchaseItem>[
          buildItem(batchNo: 'B-1', expiryDate: DateTime(2027)),
        ],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.purchaseDetail('purchase-1'),
    );

    expect(find.text('Stock & ledger'), findsOneWidget);
    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Batch B-1'), findsOneWidget);
    expect(
      find.widgetWithText(ElevatedButton, 'Receive goods'),
      findsNothing,
      reason: 'receiving happens once (D-013)',
    );
    expect(find.byTooltip('Edit purchase'), findsNothing);
  });
}
