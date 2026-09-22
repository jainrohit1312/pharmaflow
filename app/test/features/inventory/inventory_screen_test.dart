/// Widget tests for the inventory screen.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_stock.dart';
import 'package:app/data/models/stock_adjustment.dart';
import 'package:app/features/inventory/presentation/widgets/low_stock_card.dart';
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
    expect(find.text('2 units · reorder at 10'), findsOneWidget);
    expect(
      find.text('Order 8 units'),
      findsOneWidget,
      reason: 'the shortfall is the figure the RPC adds: how much to order',
    );
    expect(
      find.text('Dolo 650'),
      findsNothing,
      reason: 'it is above its level',
    );
  });

  testWidgets('a reorder list that is only the worst of them says so', (
    tester,
  ) async {
    // `low_stock_products` states how many there are in total (migration 00050). The tab asks
    // for 200 (the server's own ceiling), so this is the case where the pharmacy has more than
    // one page of low stock - and a list that stops at 200 without saying so reads as the whole
    // list.
    await pumpInventoryApp(
      tester,
      repository: FakeInventoryRepository(
        stock: <ProductStock>[
          buildStock(name: 'Paracetamol', totalQty: 2, minStockLevel: 10),
        ],
      )..lowStockTotal = 315,
    );

    await _openTab(tester, 'Low stock');

    expect(find.text('Showing the 1 worst of 315'), findsOneWidget);
  });

  testWidgets('a complete reorder list carries no "showing" caption', (
    tester,
  ) async {
    await pumpInventoryApp(
      tester,
      repository: FakeInventoryRepository(
        stock: <ProductStock>[
          buildStock(name: 'Paracetamol', totalQty: 2, minStockLevel: 10),
        ],
      ),
    );

    await _openTab(tester, 'Low stock');

    expect(find.text('Paracetamol'), findsOneWidget);
    expect(find.textContaining('Showing the'), findsNothing);
  });

  testWidgets('leads with the worst shortfall and cannot show a stock value', (
    tester,
  ) async {
    await pumpInventoryApp(
      tester,
      repository: FakeInventoryRepository(
        stock: <ProductStock>[
          buildStock(name: 'Paracetamol', totalQty: 9, minStockLevel: 10),
          buildStock(name: 'Amoxicillin', totalQty: 0, minStockLevel: 30),
        ],
      ),
    );

    await _openTab(tester, 'Low stock');

    // The order is the server's (shortfall desc), and the tab renders it as
    // given: 30 units short leads the 1-unit gap.
    final cards = tester.widgetList<LowStockCard>(find.byType(LowStockCard));
    expect(cards.map((card) => card.product.name), <String>[
      'Amoxicillin',
      'Paracetamol',
    ]);

    // `low_stock_products()` answers in quantities, not money, so this list
    // says nothing about value - the rollup's `at cost` figure belongs to the
    // stock tab, and a default here would print a wrong rupee amount.
    expect(find.textContaining('at cost'), findsNothing);
    expect(find.text('Out of stock'), findsOneWidget);
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

  testWidgets('a staff correction says it went to the owner, and moves nothing', (
    tester,
  ) async {
    // Phase 6.5c: a correction is a REQUEST for anybody but the owner, and a request moves
    // no stock - so "Stock adjusted." would be a claim about a balance that has not changed.
    final repository = FakeInventoryRepository(
      batches: <BatchStatus>[buildBatch()],
      isOwner: false,
    );
    await pumpInventoryApp(tester, repository: repository);
    await _openTab(tester, 'Expiry');

    await tester.tap(find.byTooltip('Adjust this batch'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '2');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Record adjustment'));
    await tester.pumpAndSettle();

    expect(
      repository.stagedSubmissions,
      1,
      reason: 'the correction was asked for rather than written',
    );
    expect(
      find.text(
        'Sent to the owner. Nothing has been recorded until he approves it.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Stock adjusted.'),
      findsNothing,
      reason: 'nothing was adjusted, so nothing may say it was',
    );
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
