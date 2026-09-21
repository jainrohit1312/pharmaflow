/// Tests for the counter screen.
///
/// The assertions read the *bill* rather than the basket line, and only figures
/// that appear in one place: the line's own total and the bill's total are the same
/// number by design, so asserting on it would only prove that two widgets show it.
///
/// C2 changed how a product reaches the basket: the search dropdown's row shows the
/// batch FEFO would take, so tapping it (or pressing Enter on it) adds that batch
/// **without a chooser**. The chooser is still here - the row's own affordance asks
/// for it - and both paths are tested, because "no chooser in the common case" only
/// means anything if the deliberate case still works.
library;

import 'dart:async';

import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_search_field.dart';
import 'package:app/core/widgets/expiry_badge.dart';
import 'package:app/data/models/admission.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/doctor.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/sales/presentation/widgets/pos_cart_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_customers_repository.dart';
import '../../../support/fake_doctors_repository.dart';
import '../../../support/fake_inventory_repository.dart';
import '../../../support/fake_patients_repository.dart';
import '../../../support/fake_products_repository.dart';
import '../../../support/fake_sales_repository.dart';
import '../../../support/sales_test_app.dart';

/// A batch with a counter price, so the line the screen shows has a known rate.
///
/// The MRP sits above the counter price because it is a **ceiling**: a rate above
/// it is refused at checkout, and a fixture that broke its own rule would be
/// testing a bill the counter cannot actually write.
BatchStatus _batch({String id = 'batch-1', String batchNo = 'B-1'}) =>
    buildBatch(id: id, batchNo: batchNo).copyWith(sellingRate: 200, mrp: 250);

/// A second batch of the same product at a different price.
///
/// So a test can tell two basket lines apart by what each comes to: a Tab that
/// landed on the wrong line would move a different figure.
BatchStatus _secondBatch() => buildBatch(
  id: 'batch-2',
  batchNo: 'B-2',
).copyWith(sellingRate: 100, mrp: 250);

/// Adds the only product the fake search offers, by tapping its row.
///
/// No chooser and no term: the screen shows its results while the basket is empty,
/// and tapping a row takes the batch FEFO would - which is the default case. The
/// deliberate path (the row's affordance) has its own test.
Future<void> _addLine(WidgetTester tester) async {
  await tester.tap(find.text('Dolo 650'));
  await tester.pumpAndSettle();
}

/// Types [value] into the field labelled [label].
Future<void> _type(WidgetTester tester, String label, String value) async {
  await tester.enterText(find.widgetWithText(TextFormField, label), value);
  await tester.pumpAndSettle();
}

/// Types [value] into the counter's own product search field.
///
/// The patient step has a search field of its own above this one, so the counter's
/// is the last in the tree.
Future<void> _searchFor(WidgetTester tester, String value) async {
  await tester.enterText(find.byType(AppSearchField).last, value);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// Presses [key] as a keyboard would, and lets the screen settle.
Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

/// The patient a pharmacy sale has to name.
Customer _patient() => buildCustomer(
  'ZZTEST patient',
  id: 'id-ZZTEST patient',
  phone: '9876543210',
);

/// Chooses [_patient] from the counter's patient step.
///
/// The step opens on the recent patients, so the patient is one tap away - which is
/// the point of showing them rather than an empty box.
Future<void> _choosePatient(WidgetTester tester) async {
  await tester.tap(find.text('ZZTEST patient').last);
  await tester.pumpAndSettle();
}

/// Confirms the bill in the dialog the counter raises before it writes.
///
/// The write is two steps now: the counter shows what it is about to write, and nothing
/// reaches the till until the operator says so. A test that wants a sale written takes
/// both steps - which is the change, not an inconvenience of the harness.
Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ElevatedButton, 'Confirm & Submit'));
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

  testWidgets('a search row shows the batch Enter would take, and adds it', (
    tester,
  ) async {
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );

    // The row itself is the preview: the batch FEFO would take, when it expires,
    // what is left in it, and what it costs - so Enter is an informed choice.
    expect(find.textContaining('Batch B-1'), findsOneWidget);
    expect(find.textContaining('exp 10/26'), findsOneWidget);
    expect(find.textContaining('10 in stock'), findsOneWidget);
    expect(find.textContaining('MRP'), findsOneWidget);

    await _addLine(tester);

    // No chooser interrupted the common case.
    expect(
      find.text('First expiry, first out — dispense from the top.'),
      findsNothing,
    );
    expect(find.text('Dolo 650'), findsOneWidget);
    expect(find.textContaining('Batch B-1 · exp 10/26'), findsOneWidget);
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

  testWidgets('the choose-batch affordance still opens the chooser', (
    tester,
  ) async {
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );

    // The deliberate path: a customer asking for a longer expiry is a real request,
    // and it is one tap away rather than gone.
    await tester.tap(find.byTooltip('Choose batch'));
    await tester.pumpAndSettle();

    expect(
      find.text('First expiry, first out — dispense from the top.'),
      findsOneWidget,
    );
    expect(find.textContaining('dispense this one first'), findsOneWidget);

    await tester.tap(find.text('Batch B-1'));
    await tester.pumpAndSettle();

    expect(find.text('Dolo 650'), findsOneWidget);
    expect(find.textContaining('Batch B-1 · exp 10/26'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Take payment'), findsOneWidget);
  });

  testWidgets('Enter adds the highlighted row and never checks out', (
    tester,
  ) async {
    final sales = FakeSalesRepository();
    await pumpSalesApp(
      tester,
      repository: sales,
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );

    // The field takes the caret on load, so Enter reaches the search rather than
    // anything below it.
    await _key(tester, LogicalKeyboardKey.enter);

    expect(find.text('Dolo 650'), findsOneWidget);
    expect(
      find.textContaining('Batch B-1 · exp 10/26'),
      findsOneWidget,
      reason: 'Enter took the batch the row showed',
    );
    expect(
      sales.checkouts,
      isEmpty,
      reason: 'the only way to write a sale is the button, never a keystroke',
    );
  });

  testWidgets('the arrow keys move which row Enter adds', (tester) async {
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[
        buildProduct('Dolo 650'),
        buildProduct('Crocin'),
      ],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );

    // The first row is highlighted to begin with, so one arrow down moves to the
    // second - which is the one Enter then takes.
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.enter);

    expect(find.text('Crocin'), findsOneWidget);
    expect(
      find.text('Dolo 650'),
      findsNothing,
      reason: 'only the highlighted row was added',
    );
  });

  testWidgets('Escape closes the list and leaves the basket alone', (
    tester,
  ) async {
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[
        buildProduct('Dolo 650'),
        buildProduct('Crocin'),
      ],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );
    await _addLine(tester);

    await _searchFor(tester, 'croc');
    expect(find.text('Crocin'), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.escape);

    expect(
      find.text('Crocin'),
      findsNothing,
      reason: 'Escape dismissed the list',
    );
    expect(
      find.text('Dolo 650'),
      findsOneWidget,
      reason: 'and stepped back out of the search without touching the basket',
    );
  });

  testWidgets('a rapid double Enter adds one line, not two', (tester) async {
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );

    // Two presses with no frame between them: the first adds and closes the list,
    // and the second finds nothing to add - the "cannot double-add" half of the
    // keyboard contract.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      find.text(Formatters.currency(200)),
      findsNWidgets(3),
      reason: 'one unit, not two - a doubled line would bill 400',
    );
    expect(find.text(Formatters.currency(400)), findsNothing);
  });

  testWidgets('offers a product with nothing in stock, but does not add it', (
    tester,
  ) async {
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[buildBatch(qty: 0)],
      initialLocation: Routes.pos,
    );

    expect(find.textContaining('Nothing in stock'), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.enter);

    expect(
      find.text('Nothing in stock for Dolo 650.'),
      findsOneWidget,
      reason: 'the refusal names the product instead of silently doing nothing',
    );
    expect(find.text('Bill'), findsNothing);
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

    // Rate, discount and slab are the counter's exceptions rather than its
    // routine, so they are one tap away rather than always on screen.
    expect(find.text('Rate'), findsNothing);
    await tester.tap(find.byTooltip('Rate, discount and GST'));
    await tester.pumpAndSettle();
    expect(find.text('Rate'), findsOneWidget);

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
    // so reading one used to throw on the way in - the counter could not add such a
    // product at all.
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

    expect(find.textContaining('expiry unknown'), findsOneWidget);
    expect(
      find.byType(ExpiryBadge),
      findsNothing,
      reason:
          'the bucket for a null date would read "Safe", which is a claim about a '
          'date that does not exist',
    );

    await _addLine(tester);

    expect(find.textContaining('Batch B-1 · exp unknown'), findsOneWidget);
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
      customers: <Customer>[_patient()],
      initialLocation: Routes.pos,
    );
    await _addLine(tester);
    // A pharmacy sale needs a patient before the medicines, and the server refuses
    // one without: the counter has to name them before it can take payment.
    await _choosePatient(tester);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Take payment'));
    await tester.pumpAndSettle();
    // The bill is confirmed before it is written: nothing reaches the till until the
    // operator has said so.
    await _confirm(tester);

    expect(sales.checkouts, hasLength(1));
    expect(sales.checkouts.single.lines.single.batchId, 'batch-1');
    expect(sales.checkouts.single.lines.single.qty, 1);
    expect(sales.checkouts.single.saleType, SaleType.counter);
    expect(sales.checkouts.single.customerId, 'id-ZZTEST patient');
    // The bill the counter opened is the sale it wrote, and the basket is gone
    // with it.
    expect(find.textContaining('bill sale-1'), findsOneWidget);
    expect(find.text('Dolo 650'), findsNothing);
  });

  testWidgets('a rapid second tap cannot raise a second confirmation', (
    tester,
  ) async {
    // The confirmation is the **new** window a double tap lands in, and the newer of the
    // two: no write has started while it is up, so the live-state guard that stops one
    // arriving during a write cannot see it. Two taps with no frame between them would
    // otherwise raise two dialogs over each other and let one bill be confirmed twice.
    final sales = FakeSalesRepository();
    final products = FakeProductsRepository(products: const <Product>[])
      ..batchQuantities['batch-1'] = 10;
    await pumpSalesApp(
      tester,
      repository: sales,
      products: products,
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      customers: <Customer>[_patient()],
      initialLocation: Routes.pos,
    );
    await _addLine(tester);
    await _choosePatient(tester);

    final button = find.widgetWithText(ElevatedButton, 'Take payment');
    await tester.tap(button);
    await tester.tap(button, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(ElevatedButton, 'Confirm & Submit'),
      findsOneWidget,
      reason: 'a second tap asks the same question once, not twice',
    );
    expect(
      sales.checkouts,
      isEmpty,
      reason: 'and nothing is written until the confirmation is answered',
    );

    // Answering it once writes one sale, which is the whole of the contract: a second
    // submission is the first one.
    await _confirm(tester);

    expect(sales.checkouts, hasLength(1));
  });

  testWidgets('refuses to take payment for a bill with no patient', (
    tester,
  ) async {
    // The refusal is the server's own rule, said before the write rather than after
    // it: nothing reaches the till, and the message says what is missing.
    final sales = FakeSalesRepository();
    await pumpSalesApp(
      tester,
      repository: sales,
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      initialLocation: Routes.pos,
    );
    await _addLine(tester);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Take payment'));
    await tester.pumpAndSettle();

    expect(sales.checkouts, isEmpty);
    expect(
      find.text(
        'A pharmacy sale needs a patient: select or register one before the '
        'medicines.',
      ),
      findsOneWidget,
      reason:
          'the sentence names what is missing rather than only that something is',
    );
  });

  testWidgets('pins the patient that was tapped, however slow the server is', (
    tester,
  ) async {
    // The registration controller is **read** by the step and **watched by nothing**, and
    // every one of its methods does its work *after* an `await`. A real write takes time;
    // an instant fake does not - so this window only opens against a real backend, which
    // is why a green suite here proves nothing about the device. The gate holds the write
    // open long enough for the test to look at it.
    final patients = FakePatientsRepository(patients: <Customer>[_patient()])
      ..registerGate = Completer<void>();
    await pumpSalesApp(
      tester,
      repository: FakeSalesRepository(),
      searchResults: <Product>[buildProduct('Dolo 650')],
      batches: <BatchStatus>[_batch()],
      patients: patients,
      initialLocation: Routes.pos,
    );

    await tester.tap(find.text('ZZTEST patient').last);
    await tester.pump();

    patients.registerGate!.complete();
    await tester.pumpAndSettle();

    expect(
      find.text('Change'),
      findsOneWidget,
      reason:
          'the bill is pinned to the patient the operator tapped, and stays pinned',
    );
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: 'a selection that happened is not also reported as a failure',
    );
  });

  group('the quantity field', () {
    /// The [index]-th line's quantity field, and what is inside it.
    Finder qtyEditable({int index = 0}) => find.descendant(
      of: find.widgetWithText(TextFormField, 'Qty').at(index),
      matching: find.byType(EditableText),
    );

    /// The controller behind the [index]-th line's quantity field.
    TextEditingController qtyAt(WidgetTester tester, {int index = 0}) =>
        tester.widget<EditableText>(qtyEditable(index: index)).controller;

    /// Pumps the counter with one product and one batch to ring up.
    Future<void> pumpCounter(WidgetTester tester, FakeSalesRepository sales) =>
        pumpSalesApp(
          tester,
          repository: sales,
          searchResults: <Product>[buildProduct('Dolo 650')],
          batches: <BatchStatus>[_batch()],
          initialLocation: Routes.pos,
        );

    testWidgets('takes the caret when a row is tapped, with the 1 selected', (
      tester,
    ) async {
      await pumpCounter(tester, FakeSalesRepository());
      await _addLine(tester);

      // The caret follows the line that was just rung up - a counter rings a line up and
      // then very often says "make it two".
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'pos cart quantity',
      );
      final qty = qtyAt(tester);
      expect(qty.text, '1');
      expect(
        qty.selection,
        const TextSelection(baseOffset: 0, extentOffset: 1),
        reason:
            'selected, so the next digit replaces the default rather than following it',
      );
    });

    testWidgets('takes the caret on the Enter path as well as the tap', (
      tester,
    ) async {
      await pumpCounter(tester, FakeSalesRepository());
      await _searchFor(tester, 'Dolo');
      await _key(tester, LogicalKeyboardKey.enter);

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'pos cart quantity',
      );
      expect(qtyAt(tester).text, '1');
    });

    testWidgets('a typed quantity replaces the default in one keystroke', (
      tester,
    ) async {
      await pumpCounter(tester, FakeSalesRepository());
      await _addLine(tester);

      // `enterText` writes the whole value, which is the *outcome* of typing over a
      // selection - and the selection above is what makes it one keystroke.
      await _type(tester, 'Qty', '7');
      expect(qtyAt(tester).text, '7');

      await _type(tester, 'Qty', '10');
      expect(qtyAt(tester).text, '10');

      await _type(tester, 'Qty', '100');
      expect(qtyAt(tester).text, '100');
    });

    testWidgets('the typed quantity is the one the bill is written with', (
      tester,
    ) async {
      final sales = FakeSalesRepository();
      // The basket is checked against stock before the write, so a line with no available
      // units is refused rather than ticked off - the fake has to say there are some.
      final products = FakeProductsRepository(products: const <Product>[])
        ..batchQuantities['batch-1'] = 10;
      await pumpSalesApp(
        tester,
        repository: sales,
        products: products,
        searchResults: <Product>[buildProduct('Dolo 650')],
        batches: <BatchStatus>[_batch()],
        customers: <Customer>[_patient()],
        initialLocation: Routes.pos,
      );
      await _addLine(tester);

      await _type(tester, 'Qty', '7');
      await _choosePatient(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Take payment'));
      await tester.pumpAndSettle();
      await _confirm(tester);

      expect(
        sales.checkouts.single.lines.single.qty,
        7,
        reason: 'the field is not a decoration: its number is the payload',
      );
    });

    testWidgets('an emptied quantity keeps the line, and blur puts it back', (
      tester,
    ) async {
      await pumpCounter(tester, FakeSalesRepository());
      await _addLine(tester);

      await _type(tester, 'Qty', '');

      // The bug this replaces: the field reported zero, and zero removed the line.
      expect(find.text('Dolo 650'), findsOneWidget);
      expect(qtyAt(tester).text, isEmpty);

      // Leaving the field settles it, silently, on the line's own number.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(find.text('Dolo 650'), findsOneWidget);
      expect(qtyAt(tester).text, '1');
    });

    testWidgets('Escape returns to the search without touching the basket', (
      tester,
    ) async {
      await pumpCounter(tester, FakeSalesRepository());
      await _addLine(tester);

      await _key(tester, LogicalKeyboardKey.escape);

      expect(FocusManager.instance.primaryFocus?.debugLabel, 'pos search');
      expect(
        find.text('Dolo 650'),
        findsOneWidget,
        reason: 'Escape steps out of the field; it is not an undo for the line',
      );
      expect(qtyAt(tester).text, '1');
    });

    testWidgets('Enter returns to the search, so the next product can be typed', (
      tester,
    ) async {
      await pumpCounter(tester, FakeSalesRepository());
      await _addLine(tester);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'pos cart quantity',
      );

      await _key(tester, LogicalKeyboardKey.enter);

      // The counter's loop: search, Enter to ring the line up, type the quantity, Enter to
      // search again - a whole bill without the mouse. This is the opposite of Tab, which
      // moves on, and the two keys mean two different things on purpose.
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'pos search',
        reason: 'the caret goes back to the search, not forward',
      );
      expect(
        find.text('Dolo 650'),
        findsOneWidget,
        reason: 'stepping back to the search is not a removal',
      );
    });

    testWidgets('Tab from the last quantity leaves the basket for payment', (
      tester,
    ) async {
      await pumpCounter(tester, FakeSalesRepository());
      await _addLine(tester);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'pos cart quantity',
      );

      await _key(tester, LogicalKeyboardKey.tab);

      expect(
        tester.widget<EditableText>(qtyEditable()).focusNode.hasFocus,
        isFalse,
        reason: 'there is no next quantity, so the basket is done with',
      );
      // The payment card's mode chips are its first controls, so this says the caret left
      // the basket and landed in the money - rather than on the line's own details toggle,
      // which is where it used to go.
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<Wrap>()
            ?.children
            .length,
        PaymentMode.values.length,
        reason: 'the next stop past the last quantity is the payment card',
      );
    });
  });

  group('the confirmation', () {
    testWidgets('shows the bill before it is written, and can be cancelled', (
      tester,
    ) async {
      final sales = FakeSalesRepository();
      final products = FakeProductsRepository(products: const <Product>[])
        ..batchQuantities['batch-1'] = 10;
      await pumpSalesApp(
        tester,
        repository: sales,
        products: products,
        searchResults: <Product>[buildProduct('Dolo 650')],
        batches: <BatchStatus>[_batch()],
        customers: <Customer>[_patient()],
        initialLocation: Routes.pos,
      );
      await _addLine(tester);
      await _choosePatient(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Take payment'));
      await tester.pumpAndSettle();

      // What is about to be written, and the plain statement that these figures are not
      // the last word: the server recomputes them from its own reading.
      expect(find.text('Server will verify totals.'), findsOneWidget);
      expect(
        find.widgetWithText(ElevatedButton, 'Confirm & Submit'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      expect(
        find.text('Total'),
        findsWidgets,
        reason: 'the bill is on the dialog as well as behind it',
      );
      expect(
        find.text('Verified'),
        findsNothing,
        reason: 'the notice is only for a server that disagreed',
      );
      expect(
        sales.checkouts,
        isEmpty,
        reason: 'nothing is written before the operator confirms the bill',
      );

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(sales.checkouts, isEmpty);
      expect(find.text('Server will verify totals.'), findsNothing);
      expect(
        find.text('Dolo 650'),
        findsOneWidget,
        reason: 'a cancelled confirmation leaves the basket where it was',
      );
    });

    testWidgets('refuses a settling mode that is short of the bill', (
      tester,
    ) async {
      // The rule the server does not have. `sales_payment_check()` refuses only a sale
      // paid MORE than its bill, so a "cash" sale carrying a balance is storable there -
      // and it is not a sale this counter should write.
      final sales = FakeSalesRepository();
      final products = FakeProductsRepository(products: const <Product>[])
        ..batchQuantities['batch-1'] = 10;
      await pumpSalesApp(
        tester,
        repository: sales,
        products: products,
        searchResults: <Product>[buildProduct('Dolo 650')],
        batches: <BatchStatus>[_batch()],
        customers: <Customer>[_patient()],
        initialLocation: Routes.pos,
      );
      await _addLine(tester);
      await _choosePatient(tester);

      await _type(tester, 'Received', '10');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Take payment'));
      await tester.pumpAndSettle();

      expect(
        find.text('Server will verify totals.'),
        findsNothing,
        reason: 'a sale the counter is about to refuse is not worth confirming',
      );
      expect(sales.checkouts, isEmpty);
      expect(find.textContaining('requires the full'), findsOneWidget);
      expect(find.textContaining('short.'), findsOneWidget);
    });

    testWidgets("names the server's figures when they differ from the counter's", (
      tester,
    ) async {
      // The client computes on the server's basis, so agreement is the ordinary case and
      // this is the rare one. It is not silent, because the bill the customer is handed
      // is the server's version - so the divergence is the fake's whole purpose.
      final sales = FakeSalesRepository()
        // The stored total differs from the counter's in every figure, not only the tax
        // split: the notice names the total that moved, so a fixture that agreed on the
        // total would not exercise it.
        ..storedTotalsOverride = const SaleDocumentTotalSum(
          subTotal: 200,
          discountTotal: 0,
          taxTotal: 10,
          grandTotal: 210,
        );
      final products = FakeProductsRepository(products: const <Product>[])
        ..batchQuantities['batch-1'] = 10;
      await pumpSalesApp(
        tester,
        repository: sales,
        products: products,
        searchResults: <Product>[buildProduct('Dolo 650')],
        batches: <BatchStatus>[_batch()],
        customers: <Customer>[_patient()],
        initialLocation: Routes.pos,
      );
      await _addLine(tester);
      await _choosePatient(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Take payment'));
      await tester.pumpAndSettle();
      await _confirm(tester);

      expect(find.text('Verified'), findsOneWidget);
      expect(find.text(Formatters.currency(210)), findsWidgets);
      expect(
        find.textContaining('The counter showed'),
        findsOneWidget,
        reason:
            'a disagreement names both figures rather than only the new one',
      );

      // The sale is written either way, and the bill it opens is the server's.
      expect(sales.checkouts, hasLength(1));
      await tester.tap(find.widgetWithText(ElevatedButton, 'OK'));
      await tester.pumpAndSettle();
      expect(find.textContaining('bill sale-1'), findsOneWidget);
    });
  });

  group('the basket lines', () {
    testWidgets('show the quantity and the total, and the details on demand', (
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

      // What the counter reads off every line: what it is, which batch and expiry,
      // how many, and what it comes to.
      expect(find.text('Dolo 650'), findsOneWidget);
      expect(find.textContaining('Batch B-1 · exp 10/26'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Qty'), findsOneWidget);
      expect(find.text(Formatters.currency(200)), findsNWidgets(3));

      // And what it does not, until it asks: pricing detail is the exception, not
      // the routine.
      for (final label in <String>['Rate', 'Disc %', 'GST %']) {
        expect(find.text(label), findsNothing, reason: label);
      }

      await tester.tap(find.byTooltip('Rate, discount and GST'));
      await tester.pumpAndSettle();

      for (final label in <String>['Rate', 'Disc %', 'GST %']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.byTooltip('Hide rate, discount and GST'), findsOneWidget);

      // And away again, which is what keeps a phone's line compact.
      await tester.tap(find.byTooltip('Hide rate, discount and GST'));
      await tester.pumpAndSettle();
      expect(find.text('Rate'), findsNothing);
    });

    testWidgets('Tab from a quantity moves to the next line, not its details', (
      tester,
    ) async {
      await pumpSalesApp(
        tester,
        repository: FakeSalesRepository(),
        searchResults: <Product>[buildProduct('Dolo 650')],
        // Two batches, so the same product can be rung up twice - the one case a
        // basket really does hold the same medicine out of two batches.
        batches: <BatchStatus>[_batch(), _secondBatch()],
        initialLocation: Routes.pos,
      );
      await _addLine(tester);
      // A term, so the dropdown is open again and the row's affordance is there -
      // the same way a counter reaches a second batch after the first add closed
      // the list.
      await _searchFor(tester, 'dolo');
      await tester.tap(find.byTooltip('Choose batch'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Batch B-2'));
      await tester.pumpAndSettle();

      // The first line's details are open on purpose: in the widget tree's own
      // order a Tab would land in them, and the contract says it must not.
      await tester.tap(find.byTooltip('Rate, discount and GST').first);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextFormField, 'Qty').first);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      final focused = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PosCartLine>();
      expect(
        focused?.order,
        1,
        reason: 'Tab walks the quantities in basket order, not the tree\u2019s',
      );
    });

    testWidgets('Delete removes the line the caret is on', (tester) async {
      await pumpSalesApp(
        tester,
        repository: FakeSalesRepository(),
        searchResults: <Product>[buildProduct('Dolo 650')],
        batches: <BatchStatus>[_batch()],
        initialLocation: Routes.pos,
      );
      await _addLine(tester);
      expect(find.text('Bill'), findsOneWidget);

      // The caret goes on the line itself - its own space, not a field inside it -
      // which is what makes Delete mean "this line".
      await tester.tap(find.text('Dolo 650'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      expect(find.text('Bill'), findsNothing);
      expect(
        find.text('Nothing rung up yet. Search for a product above.'),
        findsOneWidget,
      );
    });

    testWidgets('lay out on a 360x800 phone with targets a thumb can hit', (
      tester,
    ) async {
      await pumpSalesApp(
        tester,
        repository: FakeSalesRepository(),
        searchResults: <Product>[buildProduct('Dolo 650')],
        batches: <BatchStatus>[_batch()],
        initialLocation: Routes.pos,
        size: const Size(360, 800),
      );

      // A Row that cannot fit throws in debug, so reaching the assertions is
      // already the layout passing at the narrow end.
      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Dolo 650'),
        200,
        scrollable: scrollable,
      );
      expect(find.textContaining('10 in stock'), findsOneWidget);

      await tester.tap(find.text('Dolo 650'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('Batch B-1 · exp 10/26'),
        200,
        scrollable: scrollable,
      );

      expect(tester.takeException(), isNull);
      // Every control a thumb reaches is at least a fingertip high.
      for (final (label, target) in <(String, Finder)>[
        ('the remove control', find.byTooltip('Remove this line')),
        ('the details control', find.byTooltip('Rate, discount and GST')),
      ]) {
        expect(
          tester.getSize(target).height,
          greaterThanOrEqualTo(44),
          reason: '$label is a tap target',
        );
      }
    });
  });

  group('the strip', () {
    testWidgets('opens on Recent, and a tab brings the list back', (
      tester,
    ) async {
      await pumpSalesApp(
        tester,
        repository: FakeSalesRepository(),
        searchResults: <Product>[buildProduct('Dolo 650')],
        batches: <BatchStatus>[_batch()],
        initialLocation: Routes.pos,
      );

      // Recent first, All last, and nothing between them while the catalogue
      // records no category.
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Recent'))
            .selected,
        isTrue,
      );
      expect(find.widgetWithText(ChoiceChip, 'All'), findsOneWidget);

      await _addLine(tester);
      // An add closes the list - which is what stops a second Enter doubling the
      // line - so the product appears once, as the basket line.
      expect(find.text('Dolo 650'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'All'))
            .selected,
        isTrue,
      );
      expect(
        find.text('Dolo 650'),
        findsNWidgets(2),
        reason: 'the line, and the list the tab just reopened',
      );
    });

    testWidgets('a category the catalogue records becomes a tab', (
      tester,
    ) async {
      await pumpSalesApp(
        tester,
        repository: FakeSalesRepository(),
        searchResults: <Product>[buildProduct('Dolo 650')],
        batches: <BatchStatus>[_batch()],
        // The strip is built from data rather than from a list written into the
        // app, so these two chips exist only because the catalogue says so.
        categories: <String>['Antibiotics', 'Fever'],
        initialLocation: Routes.pos,
      );

      expect(find.widgetWithText(ChoiceChip, 'Antibiotics'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Fever'), findsOneWidget);
    });

    testWidgets('a failed categories read costs the middle tabs, not the sale', (
      tester,
    ) async {
      // The read is lenient on purpose: a pharmacy whose catalogue read fails still
      // has to sell something, and Recent and All are what it has.
      await pumpSalesApp(
        tester,
        repository: FakeSalesRepository(),
        searchResults: <Product>[buildProduct('Dolo 650')],
        batches: <BatchStatus>[_batch()],
        failCategories: true,
        initialLocation: Routes.pos,
      );

      expect(find.widgetWithText(ChoiceChip, 'Recent'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'All'), findsOneWidget);
      // And the list it drives still answers, which is the half that matters.
      expect(find.text('Dolo 650'), findsOneWidget);
    });
  });

  group('the sale type', () {
    testWidgets('offers all four, and says what each one means', (
      tester,
    ) async {
      await pumpSalesApp(
        tester,
        repository: FakeSalesRepository(),
        initialLocation: Routes.pos,
      );

      for (final label in <String>['Counter', 'IPD', 'Package', 'Transfer']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.textContaining('the patient is required'), findsOneWidget);
    });

    testWidgets('an IPD sale asks for the admission and the treating doctor', (
      tester,
    ) async {
      final patients = FakePatientsRepository(
        patients: <Customer>[_patient()],
        admissions: <Admission>[buildAdmission(treatingDoctorName: 'Dr Rao')],
      );
      await pumpSalesApp(
        tester,
        repository: FakeSalesRepository(),
        patients: patients,
        initialLocation: Routes.pos,
      );

      await tester.tap(find.text('IPD'));
      await tester.pumpAndSettle();
      await _choosePatient(tester);

      expect(find.text('Hospital admission number'), findsOneWidget);
      expect(
        find.textContaining('IPD-7'),
        findsWidgets,
        reason:
            "the patient's own episodes are offered, not just an empty field",
      );

      // Choosing the episode is what fills the hospital's reference in.
      await tester.tap(find.textContaining('IPD-7').first);
      await tester.pumpAndSettle();
      expect(find.text('Billing admission IPD-7'), findsOneWidget);
    });

    testWidgets('a transfer asks where the stock is going, and why', (
      tester,
    ) async {
      await pumpSalesApp(
        tester,
        repository: FakeSalesRepository(),
        initialLocation: Routes.pos,
      );

      await tester.tap(find.text('Transfer'));
      await tester.pumpAndSettle();

      for (final label in <String>['From', 'To', 'Reason']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(
        find.text('Patient'),
        findsNothing,
        reason:
            'a transfer names no patient, so the step goes away with the type',
      );
      expect(find.textContaining('no payment and no GST'), findsOneWidget);
    });

    testWidgets('a package sale asks for the account and the patient', (
      tester,
    ) async {
      await pumpSalesApp(
        tester,
        repository: FakeSalesRepository(),
        customers: <Customer>[
          buildCustomer(
            'Rohit Kidney & Stone Hospital (Account)',
            id: 'account-1',
          ),
        ],
        initialLocation: Routes.pos,
      );

      await tester.tap(find.text('Package'));
      await tester.pumpAndSettle();

      expect(find.text('Hospital account'), findsOneWidget);
      expect(find.text('Package / case reference'), findsOneWidget);
      expect(
        find.text('Prescriber'),
        findsNothing,
        reason: 'the hospital is the buyer, so there is no prescriber to name',
      );
    });
  });

  group('the prescriber', () {
    testWidgets('records a name the master does not have', (tester) async {
      final sales = FakeSalesRepository();
      final products = FakeProductsRepository(products: const <Product>[])
        ..batchQuantities['batch-1'] = 10;
      await pumpSalesApp(
        tester,
        repository: sales,
        products: products,
        searchResults: <Product>[buildProduct('Dolo 650')],
        batches: <BatchStatus>[_batch()],
        patients: FakePatientsRepository(patients: <Customer>[_patient()]),
        initialLocation: Routes.pos,
      );
      await _addLine(tester);
      await _choosePatient(tester);

      await _type(tester, 'Prescriber', 'Dr Nobody');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Take payment'));
      await tester.pumpAndSettle();
      await _confirm(tester);

      expect(sales.checkouts.single.doctorName, 'Dr Nobody');
      expect(
        sales.checkouts.single.doctorId,
        isNull,
        reason: 'a name the master has never heard of is still the bill\u2019s',
      );
    });

    testWidgets('records the master row when one is tapped', (tester) async {
      final sales = FakeSalesRepository();
      final products = FakeProductsRepository(products: const <Product>[])
        ..batchQuantities['batch-1'] = 10;
      await pumpSalesApp(
        tester,
        repository: sales,
        products: products,
        searchResults: <Product>[buildProduct('Dolo 650')],
        batches: <BatchStatus>[_batch()],
        patients: FakePatientsRepository(patients: <Customer>[_patient()]),
        doctors: FakeDoctorsRepository(
          doctors: <Doctor>[
            buildDoctor('Dr Rao', specialization: 'Nephrology'),
          ],
        ),
        initialLocation: Routes.pos,
      );
      await _addLine(tester);
      await _choosePatient(tester);

      await tester.tap(find.text('Dr Rao · Nephrology'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Take payment'));
      await tester.pumpAndSettle();
      await _confirm(tester);

      expect(sales.checkouts.single.doctorId, 'id-Dr Rao');
      expect(sales.checkouts.single.doctorName, 'Dr Rao');
    });
  });
}
