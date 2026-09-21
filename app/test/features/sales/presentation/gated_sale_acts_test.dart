/// Widget tests for what a gated sale act looks like on screen.
///
/// Phase 6.5c chunk 5d built the two acts a posted bill allows, and gated both for anybody but the
/// owner: the server writes nothing and answers `staged`, so the screen says where the work went.
/// These tests drive that path from the bill itself, because the failing behaviour it prevents is
/// the quiet one - a bill screen that refreshed after a cancellation that had not happened would
/// show a status the books do not agree with yet.
library;

import 'package:app/data/models/sale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_sales_repository.dart';
import '../../../support/sale_detail_test_app.dart';

/// What every gated write says, verbatim.
const String _sentForApproval =
    'Sent to the owner. Nothing has been recorded until he approves it.';

/// The bill the screen is stood up on: paid in full, no customer link, nothing against it.
FakeSalesRepository _repository({required bool isOwner}) => FakeSalesRepository(
  sales: <Sale>[
    buildSale(
      invoiceNo: 'SL-1',
      grandTotal: 105,
      amountPaid: 105,
      patientName: 'Asha',
      patientMobile: '9876500061',
      doctorName: 'Dr Rao',
    ),
  ],
  isOwner: isOwner,
);

void main() {
  testWidgets(
    'a staff cancellation says it went to the owner, and moves nothing',
    (tester) async {
      final repository = _repository(isOwner: false);
      await pumpSaleDetailApp(tester, repository: repository);

      await tester.tap(find.byTooltip('Cancel this bill'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel the bill'));
      await tester.pumpAndSettle();

      expect(
        find.text(_sentForApproval),
        findsOneWidget,
        reason: 'nothing moved, so a silence would read as a cancelled bill',
      );
      expect(repository.stagedSubmissions, 1);
      expect(
        repository.sales.single.status,
        SaleStatus.completed,
        reason: 'the bill is exactly as it was - which is what a request means',
      );
    },
  );

  testWidgets('the owner cancels the same bill directly', (tester) async {
    // The same act, the same screen, with the owner signed in: the write lands. This is the pair
    // the outcome exists to tell apart - no role check on the screen, just what the server said.
    final repository = _repository(isOwner: true);
    await pumpSaleDetailApp(tester, repository: repository);

    await tester.tap(find.byTooltip('Cancel this bill'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel the bill'));
    await tester.pumpAndSettle();

    expect(repository.stagedSubmissions, 0);
    expect(repository.sales.single.status, SaleStatus.cancelled);
    expect(find.text('The bill is cancelled.'), findsOneWidget);
    expect(
      find.byTooltip('Cancel this bill'),
      findsNothing,
      reason:
          'a cancelled bill offers neither act: the server refuses both questions',
    );
  });

  testWidgets('a staff identity edit says it went to the owner', (
    tester,
  ) async {
    final repository = _repository(isOwner: false);
    await pumpSaleDetailApp(tester, repository: repository);

    await tester.tap(find.byTooltip('Correct the printed details'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Prescribed by'),
      'Dr Kulkarni',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save these details'));
    await tester.pumpAndSettle();

    expect(
      find.text(_sentForApproval),
      findsOneWidget,
      reason:
          'nothing was rewritten, so the bill still prints the old prescriber',
    );
    expect(repository.stagedSubmissions, 1);
    expect(repository.sales.single.doctorName, 'Dr Rao');
    expect(
      repository.identityEdits.single['doctor_name'],
      'Dr Kulkarni',
      reason: 'the sheet built the document it asked about',
    );
  });

  testWidgets('the owner corrects the printed details directly', (
    tester,
  ) async {
    final repository = _repository(isOwner: true);
    await pumpSaleDetailApp(tester, repository: repository);

    await tester.tap(find.byTooltip('Correct the printed details'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Prescribed by'),
      'Dr Kulkarni',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save these details'));
    await tester.pumpAndSettle();

    expect(repository.stagedSubmissions, 0);
    expect(repository.sales.single.doctorName, 'Dr Kulkarni');
    expect(find.text('The bill now prints those details.'), findsOneWidget);
  });

  testWidgets('the sheet sends the patient pair together, always', (
    tester,
  ) async {
    // Migration 00035's constraint carries the name and the number together. A sheet that sent only
    // the field the operator touched would be offering them a refusal they did not ask for, so it
    // sends both - and this pins that.
    final repository = _repository(isOwner: true);
    await pumpSaleDetailApp(tester, repository: repository);

    await tester.tap(find.byTooltip('Correct the printed details'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Patient address'),
      '12 Test Road',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save these details'));
    await tester.pumpAndSettle();

    final sent = repository.identityEdits.single;
    expect(sent['patient_address'], '12 Test Road');
    expect(sent['patient_name'], 'Asha');
    expect(sent['patient_mobile'], '9876500061');
  });
}
