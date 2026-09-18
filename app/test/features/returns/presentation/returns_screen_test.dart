/// Widget tests for the purchase returns list.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/data/models/purchase_return.dart';
import 'package:app/data/models/purchase_return_item.dart';
import 'package:app/data/models/supplier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_purchase_returns_repository.dart';
import '../../../support/fake_purchases_repository.dart';
import '../../../support/returns_test_app.dart';

void main() {
  testWidgets('lists a return with its supplier and what it credits', (
    tester,
  ) async {
    await pumpReturnsApp(
      tester,
      repository: FakePurchaseReturnsRepository(
        returns: <PurchaseReturn>[
          buildPurchaseReturn(reason: 'Damaged in transit', grandTotal: 403.20),
        ],
      ),
      purchases: FakePurchasesRepository(purchases: const <Purchase>[]),
      suppliers: <Supplier>[buildSupplier()],
    );

    expect(find.text('Arihant Distributors'), findsOneWidget);
    expect(find.text('Damaged in transit'), findsOneWidget);
    expect(find.text('Credit ₹403.20'), findsOneWidget);
  });

  testWidgets('says there is nothing yet, and offers to raise one', (
    tester,
  ) async {
    await pumpReturnsApp(
      tester,
      repository: FakePurchaseReturnsRepository(),
      purchases: FakePurchasesRepository(purchases: const <Purchase>[]),
    );

    expect(find.text('No returns yet'), findsOneWidget);
    expect(find.text('New return'), findsWidgets);
  });

  testWidgets('opens the return a tap lands on', (tester) async {
    await pumpReturnsApp(
      tester,
      repository: FakePurchaseReturnsRepository(
        returns: <PurchaseReturn>[buildPurchaseReturn()],
        items: <PurchaseReturnItem>[buildReturnItem()],
        purchases: <Purchase>[buildPurchase(status: PurchaseStatus.received)],
      ),
      purchases: FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase(status: PurchaseStatus.received)],
        items: <PurchaseItem>[buildItem()],
      ),
      suppliers: <Supplier>[buildSupplier()],
    );

    await tester.tap(find.byType(Card).first);
    await tester.pumpAndSettle();

    expect(find.text('Purchase return'), findsOneWidget);
    expect(find.text('INV-1'), findsOneWidget);
    expect(find.text('Paracetamol 500mg'), findsOneWidget);
    expect(find.text('Open the purchase'), findsOneWidget);
  });

  testWidgets('reports a failed list without blanking the screen', (
    tester,
  ) async {
    final repository = FakePurchaseReturnsRepository()..failNextList = true;
    await pumpReturnsApp(
      tester,
      repository: repository,
      purchases: FakePurchasesRepository(purchases: const <Purchase>[]),
    );

    expect(find.textContaining('the fake was told to fail'), findsWidgets);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a return opened by url is the one the detail shows', (
    tester,
  ) async {
    await pumpReturnsApp(
      tester,
      repository: FakePurchaseReturnsRepository(
        returns: <PurchaseReturn>[
          buildPurchaseReturn(id: 'return-7', grandTotal: 144),
        ],
        purchases: <Purchase>[
          buildPurchase(status: PurchaseStatus.received, invoiceNo: 'INV-9'),
        ],
      ),
      purchases: FakePurchasesRepository(
        purchases: <Purchase>[
          buildPurchase(status: PurchaseStatus.received, invoiceNo: 'INV-9'),
        ],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.returnDetail('return-7'),
    );

    expect(find.text('Credit'), findsOneWidget);
    expect(find.text('₹144.00'), findsOneWidget);
    expect(find.text('INV-9'), findsOneWidget);
  });
}
