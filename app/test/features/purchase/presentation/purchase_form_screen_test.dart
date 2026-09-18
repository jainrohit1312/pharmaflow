/// Widget tests for the purchase form screen.
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

void main() {
  testWidgets('starts a new purchase with one empty line', (tester) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(purchases: const <Purchase>[]),
      initialLocation: Routes.purchaseForm,
    );

    expect(find.text('New purchase'), findsOneWidget);
    expect(find.text('Line 1'), findsOneWidget);
    expect(find.text('Save draft'), findsOneWidget);
    // The last remaining line may not be removed, or the form would have nothing
    // to save.
    expect(
      find.byTooltip('A purchase needs at least one line'),
      findsOneWidget,
    );
    expect(find.byTooltip('Remove this line'), findsNothing);
  });

  testWidgets('adds a line and removes it again', (tester) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(purchases: const <Purchase>[]),
      initialLocation: Routes.purchaseForm,
    );
    expect(find.text('Line 2'), findsNothing);

    await tapVisible(tester, find.widgetWithText(TextButton, 'Add line'));
    expect(find.text('Line 2'), findsOneWidget);

    await tapVisible(tester, find.byTooltip('Remove this line').last);
    expect(find.text('Line 2'), findsNothing);
  });

  testWidgets('reports a missing supplier and invoice number at the fields', (
    tester,
  ) async {
    final repository = FakePurchasesRepository(purchases: const <Purchase>[]);
    await pumpPurchaseApp(
      tester,
      repository: repository,
      initialLocation: Routes.purchaseForm,
    );

    await tapVisible(tester, find.widgetWithText(ElevatedButton, 'Save draft'));

    expect(find.text('Choose a supplier'), findsOneWidget);
    expect(find.text('Invoice number is required'), findsOneWidget);
    expect(
      repository.lastHeader,
      isNull,
      reason: 'nothing should reach the repository',
    );
  });

  testWidgets('saves a draft with the supplier, invoice and line it was given', (
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

    expect(repository.lastHeader?.supplierId, 'sup-1');
    expect(repository.lastHeader?.invoiceNo, 'INV-2026');
    expect(repository.lastLines, hasLength(1));
    expect(repository.lastLines!.first.productId, 'id-Dolo 650');
    expect(
      repository.lastLines!.first.gstPercent,
      12,
      reason: 'a new line starts on the most common slab',
    );
    // Saving opens the document that was written. `Next step` is a section only
    // the detail screen has, so it proves the navigation rather than matching
    // the form's own totals card.
    expect(find.text('Next step'), findsOneWidget);
  });

  testWidgets('seeds an existing draft for editing', (tester) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase()],
        items: <PurchaseItem>[buildItem()],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.purchaseEdit('purchase-1'),
    );

    expect(find.text('Edit purchase'), findsOneWidget);
    expect(find.text('INV-1'), findsOneWidget);
    expect(find.text('Paracetamol 500mg'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);
  });

  testWidgets('refuses to edit a document whose stock is booked in', (
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
        items: <PurchaseItem>[buildItem()],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.purchaseEdit('purchase-1'),
    );

    expect(find.text('This purchase is received already'), findsOneWidget);
    expect(
      find.text('Save changes'),
      findsNothing,
      reason: 'there is no form to save',
    );
  });
}
