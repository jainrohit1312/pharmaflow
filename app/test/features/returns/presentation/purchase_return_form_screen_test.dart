/// Widget tests for the purchase return form.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/returns/data/purchase_returns_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_purchase_returns_repository.dart';
import '../../../support/fake_purchases_repository.dart';
import '../../../support/returns_test_app.dart';

/// The invoice the form is raised against: 10 units at 100 with 12% GST, so
/// 1000 taxable, 120 tax and 1120 on the line, received into batch `B-1`.
///
/// `batch_id` matters as much as `batch_no` here: it is the column a return line
/// needs for the trigger to move stock at all, so a fixture without one is a line
/// the form refuses to return.
PurchaseItem _receivedLine({
  String id = 'item-1',
  int qty = 10,
  double totalAmount = 1120,
  double taxAmount = 120,
}) => buildItem(
  id: id,
  qty: qty,
  batchNo: 'B-1',
  expiryDate: DateTime(2027),
).copyWith(batchId: 'batch-1', taxAmount: taxAmount, totalAmount: totalAmount);

/// A repository holding one received purchase with one returnable line.
FakePurchaseReturnsRepository _repository({
  int alreadyReturned = 0,
  int onHand = 10,
  int purchaseQty = 10,
}) {
  final line = _receivedLine(qty: purchaseQty);
  return FakePurchaseReturnsRepository(
    purchases: <Purchase>[buildPurchase(status: PurchaseStatus.received)],
    returnable: <String, List<ReturnableLine>>{
      'purchase-1': <ReturnableLine>[
        ReturnableLine(
          item: line,
          alreadyReturned: alreadyReturned,
          onHand: onHand,
        ),
      ],
    },
  );
}

/// Picks the one received purchase the form offers.
Future<void> _choosePurchase(WidgetTester tester) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  // `.last`, because the closed button keeps every item in its own tree and the
  // open menu's copy is what a tap has to land on.
  await tester.tap(find.text('INV-1 · 01 Jan 2026').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows what the invoice billed and what is left to return', (
    tester,
  ) async {
    await pumpReturnsApp(
      tester,
      repository: _repository(alreadyReturned: 2, onHand: 8),
      purchases: FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase(status: PurchaseStatus.received)],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.returnsForm,
    );

    await _choosePurchase(tester);

    expect(find.text('Paracetamol 500mg'), findsOneWidget);
    expect(
      find.text(
        'Billed 10 units · already returned 2 units · in the batch 8 units · '
        'batch B-1',
      ),
      findsOneWidget,
    );
  });

  testWidgets('previews the credit from the invoice line it will credit', (
    tester,
  ) async {
    await pumpReturnsApp(
      tester,
      repository: _repository(),
      purchases: FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase(status: PurchaseStatus.received)],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.returnsForm,
    );
    await _choosePurchase(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Returning'),
      '4',
    );
    await tester.pumpAndSettle();

    // 40% of 1120 is 448, and 40% of its 120 tax is 48.
    expect(find.text('₹448.00'), findsOneWidget);
    expect(find.text('₹48.00'), findsOneWidget);
  });

  testWidgets('records the return and opens it', (tester) async {
    final repository = _repository();
    await pumpReturnsApp(
      tester,
      repository: repository,
      purchases: FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase(status: PurchaseStatus.received)],
        items: <PurchaseItem>[_receivedLine()],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.returnsForm,
    );
    await _choosePurchase(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Returning'),
      '4',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Reason'),
      'Damaged in transit',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Record return'));
    await tester.pumpAndSettle();

    expect(repository.lastQuantities, <String, int>{'item-1': 4});
    expect(repository.lastReason, 'Damaged in transit');
    expect(repository.lastReturnDate, isNotNull);
    // The detail screen it landed on, showing what was written.
    expect(find.text('Purchase return'), findsOneWidget);
    expect(find.text('₹448.00'), findsWidgets);
    expect(find.text('Completed'), findsOneWidget);
  });

  testWidgets('refuses more units than can go back, at the field', (
    tester,
  ) async {
    final repository = _repository(onHand: 6);
    await pumpReturnsApp(
      tester,
      repository: repository,
      purchases: FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase(status: PurchaseStatus.received)],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.returnsForm,
    );
    await _choosePurchase(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Returning'),
      '7',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Record return'));
    await tester.pumpAndSettle();

    expect(find.text('At most 6'), findsOneWidget);
    expect(
      repository.lastQuantities,
      isNull,
      reason: 'nothing should reach the repository',
    );
  });

  testWidgets('says so when nothing is chosen to go back', (tester) async {
    final repository = _repository();
    await pumpReturnsApp(
      tester,
      repository: repository,
      purchases: FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase(status: PurchaseStatus.received)],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.returnsForm,
    );
    await _choosePurchase(tester);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Record return'));
    await tester.pumpAndSettle();

    expect(find.text('Enter how many units are going back.'), findsOneWidget);
    expect(repository.lastQuantities, isNull);
  });

  testWidgets('will not offer a line whose batch is empty', (tester) async {
    await pumpReturnsApp(
      tester,
      repository: _repository(onHand: 0),
      purchases: FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase(status: PurchaseStatus.received)],
      ),
      suppliers: <Supplier>[buildSupplier()],
      initialLocation: Routes.returnsForm,
    );
    await _choosePurchase(tester);

    expect(find.text('The batch for this line is empty.'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Returning'), findsNothing);
  });
}
