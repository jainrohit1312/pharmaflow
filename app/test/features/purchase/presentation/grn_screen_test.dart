/// Widget tests for the goods receipt screen.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/data/models/supplier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_products_repository.dart';
import '../../../support/fake_purchases_repository.dart';
import '../../../support/purchase_test_app.dart';

/// Picks [name] in the receipt's supplier dropdown.
Future<void> _selectSupplier(WidgetTester tester, String name) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

/// Picks [name] through the line's product picker.
Future<void> _pickProduct(WidgetTester tester, String name) async {
  await tapVisible(tester, find.text('Search the catalogue'));
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

/// Accepts the picker's own starting date, which is what a hurried user does.
Future<void> _acceptDate(WidgetTester tester, Finder field) async {
  await tapVisible(tester, field);
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a standalone receipt asks for the batch on every line', (
    tester,
  ) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(purchases: const <Purchase>[]),
      initialLocation: Routes.purchaseGrnForm,
    );

    expect(find.text('Standalone receipt'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Batch number'), findsOneWidget);
    // Two date fields on the line: manufactured, then expiry.
    expect(find.text('Choose a date'), findsNWidgets(2));
    expect(find.text('Manufactured on'), findsOneWidget);
    expect(find.text('Expiry date'), findsOneWidget);
  });

  testWidgets('reports a missing batch number at the field', (tester) async {
    final repository = FakePurchasesRepository(purchases: const <Purchase>[]);
    await pumpPurchaseApp(
      tester,
      repository: repository,
      initialLocation: Routes.purchaseGrnForm,
    );

    await tapVisible(
      tester,
      find.widgetWithText(ElevatedButton, 'Receive goods'),
    );

    expect(find.text('Batch number is required'), findsOneWidget);
    expect(find.text('Expiry date is required'), findsOneWidget);
    expect(
      repository.lastReceivedId,
      isNull,
      reason: 'nothing should reach the repository',
    );
  });

  testWidgets('seeds an existing document with the batch it was given', (
    tester,
  ) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase()],
        items: <PurchaseItem>[
          buildItem(batchNo: 'B-1', expiryDate: DateTime(2027)),
        ],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.purchaseGrn('purchase-1'),
    );

    expect(find.text('Receiving INV-1'), findsOneWidget);
    expect(find.text('B-1'), findsOneWidget);
    // The seeded expiry shows as a date, not as an empty prompt.
    expect(find.text('Choose a date'), findsOneWidget);
  });

  testWidgets('receives an existing document and opens what it posted', (
    tester,
  ) async {
    final repository = FakePurchasesRepository(
      purchases: <Purchase>[buildPurchase()],
      items: <PurchaseItem>[
        buildItem(batchNo: 'B-1', expiryDate: DateTime(2027)),
      ],
    );
    await pumpPurchaseApp(
      tester,
      repository: repository,
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.purchaseGrn('purchase-1'),
    );

    await tapVisible(
      tester,
      find.widgetWithText(ElevatedButton, 'Receive goods'),
    );

    expect(repository.lastReceivedId, 'purchase-1');
    expect(repository.lastSplit, isNotNull);
    expect(find.text('Stock & ledger'), findsOneWidget);
  });

  testWidgets('a standalone receipt creates and receives in one action', (
    tester,
  ) async {
    final repository = FakePurchasesRepository(purchases: const <Purchase>[]);
    await pumpPurchaseApp(
      tester,
      repository: repository,
      suppliers: <Supplier>[buildSupplier()],
      products: FakeProductsRepository(
        products: <Product>[buildProduct('Dolo 650')],
      ),
      initialLocation: Routes.purchaseGrnForm,
    );

    await _selectSupplier(tester, 'Arihant Distributors');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Invoice number'),
      'INV-9',
    );
    await tester.pump();
    await _pickProduct(tester, 'Dolo 650');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Batch number'),
      'B-9',
    );
    await tester.pump();
    // The second date field on the line is the expiry; the first is
    // manufactured, which the receipt does not need.
    await _acceptDate(tester, find.text('Choose a date').last);

    await tapVisible(
      tester,
      find.widgetWithText(ElevatedButton, 'Receive goods'),
    );

    expect(
      repository.lastReceivedId,
      isNotNull,
      reason: 'the draft is created and then received, in that order',
    );
    expect(repository.lastLines, hasLength(1));
    expect(repository.lastLines!.first.batchNo, 'B-9');
    expect(repository.lastLines!.first.expiryDate, isNotNull);
    expect(find.text('Stock & ledger'), findsOneWidget);
  });

  testWidgets('a received document cannot be received twice', (tester) async {
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
      initialLocation: Routes.purchaseGrn('purchase-1'),
    );

    expect(find.text('This purchase is received already'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Receive goods'), findsNothing);
  });
}
