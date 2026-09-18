/// Widget tests for the inventory screen.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_stock.dart';
import 'package:app/data/models/stock_adjustment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_inventory_repository.dart';
import '../../support/fake_products_repository.dart';
import '../../support/inventory_test_app.dart';

/// Taps a tab by its label, inside the tab bar.
///
/// Scoped to the bar deliberately: a card can carry the same words - "Low stock"
/// is both a tab and a badge - and an unscoped finder would match two widgets and
/// fail rather than tap.
Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(TabBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists the stock rollup with its quantity and value', (
    tester,
  ) async {
    await pumpInventoryApp(
      tester,
      repository: FakeInventoryRepository(
        stock: <ProductStock>[buildStock(name: 'Dolo 650')],
      ),
    );

    expect(find.text('Dolo 650'), findsOneWidget);
    expect(find.text('10 units · ₹1,000.00 at cost'), findsOneWidget);
  });

  testWidgets('narrows the stock list to what is out of stock', (tester) async {
    await pumpInventoryApp(
      tester,
      repository: FakeInventoryRepository(
        stock: <ProductStock>[
          buildStock(name: 'Dolo 650'),
          buildStock(name: 'Amoxicillin', totalQty: 0),
        ],
      ),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'Out of stock'));
    await tester.pumpAndSettle();

    expect(find.text('Amoxicillin'), findsOneWidget);
    expect(find.text('Dolo 650'), findsNothing);
  });

  testWidgets('lists the products below their reorder level', (tester) async {
    await pumpInventoryApp(
      tester,
      repository: FakeInventoryRepository(
        stock: <ProductStock>[
          buildStock(name: 'Dolo 650', minStockLevel: 5),
          buildStock(name: 'Paracetamol', totalQty: 2, minStockLevel: 10),
        ],
      ),
    );

    await _openTab(tester, 'Low stock');

    expect(find.text('Paracetamol'), findsOneWidget);
    expect(find.text('Reorder at 10'), findsOneWidget);
    expect(
      find.text('Dolo 650'),
      findsNothing,
      reason: 'it is above its level',
    );
  });

  testWidgets('says so when the stock read fails, and retries', (tester) async {
    final repository = FakeInventoryRepository()..failNextStockList = true;
    await pumpInventoryApp(tester, repository: repository);

    // Two surfaces, as on the other list screens: the ErrorView takes the body
    // when there is nothing to show, and the `ref.listen` SnackBar reports a
    // failure that arrives while stale rows are still on screen. On a first-load
    // failure both fire, so this asserts the message rather than its count.
    expect(find.textContaining('the fake was told to fail'), findsWidgets);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('shows each expiry bucket with how many batches are in it', (
    tester,
  ) async {
    await pumpInventoryApp(
      tester,
      repository: FakeInventoryRepository(
        batches: <BatchStatus>[
          buildBatch(),
          buildBatch(
            id: 'batch-2',
            batchNo: 'B-2',
            productId: 'product-2',
            expiryStatus: ExpiryStatus.expired,
            expiryDate: DateTime(2026),
          ),
        ],
      ),
      // The expiry rows are named by the products repository, so the names a test
      // expects come from the products fake.
      products: FakeProductsRepository(
        products: <Product>[
          buildProduct('Dolo 650', id: 'product-1'),
          buildProduct('Amoxicillin', id: 'product-2'),
        ],
      ),
    );

    await _openTab(tester, 'Expiry');

    expect(find.text('Critical (1)'), findsOneWidget);
    expect(find.text('Expired (1)'), findsOneWidget);
    // The critical bucket opens first, so only its row is listed.
    expect(find.text('Dolo 650'), findsOneWidget);
    expect(find.text('Amoxicillin'), findsNothing);
    expect(find.text('Expiring within 30 days'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Expired (1)'));
    await tester.pumpAndSettle();

    expect(find.text('Amoxicillin'), findsOneWidget);
    expect(find.text('Expiring within 30 days'), findsNothing);
    expect(find.text('Already past the expiry date'), findsOneWidget);
  });

  testWidgets('records a stock correction against a batch', (tester) async {
    final repository = FakeInventoryRepository(
      batches: <BatchStatus>[buildBatch()],
    );
    await pumpInventoryApp(tester, repository: repository);
    await _openTab(tester, 'Expiry');

    await tester.tap(find.byTooltip('Adjust this batch'));
    await tester.pumpAndSettle();

    // The sheet opens on a decrease, which is what an expired batch needs.
    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '2');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Reason'),
      'Breakage',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Record adjustment'));
    await tester.pumpAndSettle();

    expect(repository.lastAdjustedProductId, 'product-1');
    expect(repository.lastAdjustedBatchId, 'batch-1');
    expect(repository.lastAdjustmentType, AdjustmentType.decrease);
    expect(repository.lastAdjustedQty, 2);
    expect(repository.lastAdjustmentReason, 'Breakage');
    expect(find.text('Stock adjusted.'), findsOneWidget);
  });

  testWidgets('will not let a decrease exceed what the batch holds', (
    tester,
  ) async {
    final repository = FakeInventoryRepository(
      batches: <BatchStatus>[buildBatch()],
    );
    await pumpInventoryApp(tester, repository: repository);
    await _openTab(tester, 'Expiry');

    await tester.tap(find.byTooltip('Adjust this batch'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantity'),
      '11',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Record adjustment'));
    await tester.pumpAndSettle();

    // Reported at the field, so nothing reaches the database to be refused.
    expect(find.text('Only 10 units on hand'), findsOneWidget);
    expect(repository.lastAdjustedQty, isNull);
  });

  testWidgets('reports a refused correction and stays open to fix it', (
    tester,
  ) async {
    final repository =
        FakeInventoryRepository(batches: <BatchStatus>[buildBatch()])
          ..errorToThrow = const ValidationException(
            message: 'stock adjustment abc would take batch batch-1 below zero',
          );
    await pumpInventoryApp(tester, repository: repository);
    await _openTab(tester, 'Expiry');

    await tester.tap(find.byTooltip('Adjust this batch'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '2');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Record adjustment'));
    await tester.pumpAndSettle();

    expect(
      find.text('stock adjustment abc would take batch batch-1 below zero'),
      findsOneWidget,
      reason: 'the database names the batch; a generic message would not',
    );
    expect(
      find.widgetWithText(ElevatedButton, 'Record adjustment'),
      findsOneWidget,
      reason: 'the sheet stays open, because the user is one edit away',
    );
  });
}
