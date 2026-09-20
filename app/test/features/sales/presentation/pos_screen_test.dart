/// Tests for the counter screen.
///
/// The assertions read the *bill* rather than the basket line, and only figures
/// that appear in one place: the line's own total and the bill's total are the same
/// number by design, so asserting on it would only prove that two widgets show it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/expiry_badge.dart';
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
    // One unit at the batch's counter price: 200 charged, of which 190.48 is value
    // and 9.52 the tax it contains at the 5% slab the fixture product has no
    // recorded override for.
    expect(find.text(Formatters.currency(190.48)), findsOneWidget);
    expect(find.text(Formatters.currency(9.52)), findsOneWidget);
    // The 200 is deliberately not "one place": the line's own total, the bill's total
    // and what was paid are all the same number, which is what makes a cash sale
    // legible at a glance.
    expect(find.text(Formatters.currency(200)), findsNWidgets(3));
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
    // 600 charged at 5% is 571.43 of value and 28.57 of tax.
    expect(find.text(Formatters.currency(571.43)), findsOneWidget);
    expect(find.text(Formatters.currency(28.57)), findsOneWidget);
  });

  testWidgets('a rate and a slab edit move the value and the tax head', (
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

    // 217.60 at 18% contains 184.41 of value and 33.19 of tax - the tax is taken out
    // of the price on the shelf rather than added to it (D-075).
    expect(find.text(Formatters.currency(184.41)), findsOneWidget);
    expect(find.text(Formatters.currency(33.19)), findsOneWidget);
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

    // 400 billed, 500 handed over, 100 back - and the sale records the 400.
    expect(find.text('Change'), findsOneWidget);
    expect(find.text(Formatters.currency(100)), findsOneWidget);
    expect(
      find.text('Balance due'),
      findsNothing,
      reason: 'the change handed back is not a debt',
    );
  });

  testWidgets('offers a batch whose expiry nobody recorded, without a fake date', (
    tester,
  ) async {
    // The regression this exists for: `product_batches.expiry_date` became nullable
    // in migration 00031 and 145 of the owner's opening-stock batches have no date,
    // so reading one used to throw on the way in - the chooser could not be opened
    // for any such product at all.
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[
        buildBatch(
          unknownExpiry: true,
          isUnknownBatch: true,
          // What the view reports for a null date: the 'unknown' bucket, which
          // `expiryStatusFromDb` folds to safe. That fold is exactly why the screen
          // has to ask the date and not the bucket.
          expiryStatus: ExpiryStatus.safe,
        ),
      ],
      initialLocation: Routes.pos,
    );

    await tester.tap(find.text('Dolo 650'));
    await tester.pumpAndSettle();

    expect(find.textContaining('expiry unknown'), findsOneWidget);
    expect(
      find.byType(ExpiryBadge),
      findsNothing,
      reason:
          'the bucket for a null date would read "Safe", which is a claim about a '
          'date that does not exist',
    );

    await tester.tap(find.text('Batch B-1'));
    await tester.pumpAndSettle();

    expect(find.text('Batch B-1'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Take payment'), findsOneWidget);
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
