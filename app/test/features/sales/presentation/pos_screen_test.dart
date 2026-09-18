/// Tests for the counter screen.
///
/// The assertions read the *bill* rather than the basket line, and only figures
/// that appear in one place: the line's own total and the bill's total are the same
/// number by design, so asserting on it would only prove that two widgets show it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_inventory_repository.dart';
import '../../../support/fake_products_repository.dart';
import '../../../support/fake_sales_repository.dart';
import '../../../support/sales_test_app.dart';

/// A batch with a counter price, so the line the screen shows has a known rate.
BatchStatus _batch({String id = 'batch-1', String batchNo = 'B-1'}) =>
    buildBatch(id: id, batchNo: batchNo).copyWith(sellingRate: 200);

/// Adds the only product the fake search offers to the basket.
///
/// The screen shows its results whenever the basket is empty, so no term has to be
/// typed - which keeps the search field's debounce out of these tests.
Future<void> _addLine(WidgetTester tester, {String batchNo = 'B-1'}) async {
  await tester.tap(find.text('Dolo 650'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Batch $batchNo'));
  await tester.pumpAndSettle();
}

/// Types [value] into the field labelled [label].
Future<void> _type(WidgetTester tester, String label, String value) async {
  await tester.enterText(find.widgetWithText(TextFormField, label), value);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('starts with an empty basket and no way to take payment', (
    tester,
  ) async {
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );

    expect(find.text('New sale'), findsOneWidget);
    expect(
      find.text('Nothing rung up yet. Search for a product above.'),
      findsOneWidget,
    );
    expect(find.text('Bill'), findsNothing);
    expect(
      find.text('Take payment'),
      findsNothing,
      reason: 'an empty basket has nothing to pay for',
    );
  });

  testWidgets('adds a product through the batch chooser and renders the line', (
    tester,
  ) async {
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );

    // The chooser is a choice, not an automatic FEFO pick: a customer asking for a
    // longer expiry is a real request, and the first row is only marked as the one
    // to dispense.
    await tester.tap(find.text('Dolo 650'));
    await tester.pumpAndSettle();
    expect(
      find.text('First expiry, first out — dispense from the top.'),
      findsOneWidget,
    );
    expect(find.textContaining('dispense this one first'), findsOneWidget);

    await tester.tap(find.text('Batch B-1'));
    await tester.pumpAndSettle();

    expect(find.text('Dolo 650'), findsOneWidget);
    expect(find.text('Batch B-1'), findsOneWidget);
    expect(find.text('Bill'), findsOneWidget);
    // One unit at the batch's counter price: value 200, tax 24 at the common slab.
    expect(find.text(Formatters.currency(200)), findsOneWidget);
    expect(find.text(Formatters.currency(24)), findsOneWidget);
    // And the till is now on offer.
    expect(find.widgetWithText(ElevatedButton, 'Take payment'), findsOneWidget);
  });

  testWidgets('a quantity edit moves the bill', (tester) async {
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );
    await _addLine(tester);

    await _type(tester, 'Qty', '3');

    // The field reports every keystroke through a listener rather than on submit,
    // so the bill follows without a submit key - a browser and a desktop have none.
    expect(find.text(Formatters.currency(600)), findsOneWidget);
    expect(find.text(Formatters.currency(72)), findsOneWidget);
  });

  testWidgets('a rate and a slab edit move the line and the tax head', (
    tester,
  ) async {
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );
    await _addLine(tester);

    await _type(tester, 'Rate', '217.6');
    await _type(tester, 'GST %', '18');

    expect(find.text(Formatters.currency(217.6)), findsOneWidget);
    // 217.60 at 18% is 39.168, which rounds to what Postgres would store.
    expect(find.text(Formatters.currency(39.17)), findsOneWidget);
  });

  testWidgets('an over-tender shows the change, and leaves no balance due', (
    tester,
  ) async {
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );
    await _addLine(tester);
    await _type(tester, 'Qty', '2');

    await _type(tester, 'Received', '500');

    // 448 billed, 500 handed over, 52 back - and the sale records the 448.
    expect(find.text('Change'), findsOneWidget);
    expect(find.text(Formatters.currency(52)), findsOneWidget);
    expect(
      find.text('Balance due'),
      findsNothing,
      reason: 'the change handed back is not a debt',
    );
  });

  testWidgets('offers the till once something is rung up', (tester) async {
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );

    expect(find.widgetWithText(ElevatedButton, 'Take payment'), findsNothing);

    await _addLine(tester);

    expect(find.widgetWithText(ElevatedButton, 'Take payment'), findsOneWidget);
  });

  testWidgets('writes the sale and opens its bill', (tester) async {
    final sales = FakeSalesRepository();
    final products = FakeProductsRepository(products: const <Product>[])
      ..batchQuantities['batch-1'] = 10;
    await pumpSalesApp(
      tester,
      repository: sales,
      products: products,
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );
    await _addLine(tester);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Take payment'));
    await tester.pumpAndSettle();

    expect(sales.checkouts, hasLength(1));
    expect(sales.checkouts.single.lines.single.batchId, 'batch-1');
    expect(sales.checkouts.single.lines.single.qty, 1);
    // The bill the counter opened is the sale it wrote, and the basket is gone
    // with it.
    expect(find.textContaining('bill sale-1'), findsOneWidget);
    expect(find.text('Dolo 650'), findsNothing);
  });
}
