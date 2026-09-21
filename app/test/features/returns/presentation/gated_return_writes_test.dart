/// Widget tests for what a gated return write looks like on screen.
///
/// Phase 6.5c made a purchase return and a sale return a **request** for anybody but the
/// owner: the whole document travels to the owner and nothing is written, so there is no
/// return to open. These tests drive that path, because the failing behaviour it prevents is
/// the quiet one - a form that navigated to a return it had not written would show a document
/// that does not exist.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/returns/data/purchase_returns_repository.dart';
import 'package:app/features/returns/presentation/widgets/purchase_picker_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_purchase_returns_repository.dart';
import '../../../support/fake_purchases_repository.dart';
import '../../../support/returns_test_app.dart';

/// The invoice the form is raised against: 10 units at 100 with 12% GST, received
/// into batch `B-1`.
///
/// The id and the quantity are the builder's own defaults - what matters to a return is the
/// batch it comes out of and the money on the line, and a fixture that restated the defaults
/// would be asserting them twice.
PurchaseItem _receivedLine() => buildItem(
  batchNo: 'B-1',
  expiryDate: DateTime(2027),
).copyWith(batchId: 'batch-1', taxAmount: 120, totalAmount: 1120);

/// A repository holding one received purchase with one returnable line.
FakePurchaseReturnsRepository _repository({required bool isOwner}) =>
    FakePurchaseReturnsRepository(
      isOwner: isOwner,
      purchases: <Purchase>[buildPurchase(status: PurchaseStatus.received)],
      returnable: <String, List<ReturnableLine>>{
        'purchase-1': <ReturnableLine>[
          ReturnableLine(item: _receivedLine(), alreadyReturned: 0, onHand: 10),
        ],
      },
    );

/// Picks the one received purchase the form offers.
Future<void> _choosePurchase(WidgetTester tester) async {
  await tester.tap(find.byType(PurchasePickerField));
  await tester.pumpAndSettle();
  await tester.tap(find.text('INV-1 · 01 Jan 2026'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a staff return says it went to the owner, and opens nothing', (
    tester,
  ) async {
    final repository = _repository(isOwner: false);
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
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Record return'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Sent to the owner. Nothing has been recorded until he approves it.',
      ),
      findsOneWidget,
      reason: 'nothing was written, so a silence would read as a return',
    );
    expect(
      repository.stagedSubmissions,
      1,
      reason: 'the return was asked for rather than written',
    );
    expect(
      repository.returns,
      isEmpty,
      reason: 'a request writes no document, which is the whole point',
    );
    expect(
      find.text('Purchase return'),
      findsNothing,
      reason: 'and there is no return screen to be on',
    );
  });

  testWidgets('the owner covers for a staff request by writing it himself', (
    tester,
  ) async {
    // The same form, the same request, with the owner signed in: the write lands and the
    // return opens. This is the pair the outcome exists to tell apart - no role checking
    // on a screen, just what the server answered.
    final repository = _repository(isOwner: true);
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
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Record return'));
    await tester.pumpAndSettle();

    expect(
      repository.returns,
      hasLength(1),
      reason: 'the owner is not gated, so the return exists',
    );
    expect(
      find.text(
        'Sent to the owner. Nothing has been recorded until he approves it.',
      ),
      findsNothing,
    );
    expect(find.text('Purchase return'), findsOneWidget);
  });
}
