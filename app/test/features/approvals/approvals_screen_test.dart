/// Tests for the owner's approvals screen.
///
/// The assertions are about what the owner is shown and what his tap sends, because
/// those are the two halves of the control: the figures on the card are the ones
/// `checkout_sale()` will match a bill against, and the decision the tap records is the
/// permission. Who may decide is the server's rule and is asserted there.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/data/models/approval_request.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/approvals_test_app.dart';
import '../../support/fake_approvals_repository.dart';

/// Confirms the dialog with [label], after typing [note] when one is given.
///
/// The dialog's buttons are `TextButton`s and the card's are the app's own
/// `ElevatedButton`/`OutlinedButton`, so the label alone would be ambiguous once the
/// dialog is up.
Future<void> _answer(WidgetTester tester, String label, {String? note}) async {
  if (note != null) {
    await tester.enterText(find.byType(TextField), note);
  }
  await tester.tap(find.widgetWithText(TextButton, label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows what is waiting, with the figures being agreed to', (
    tester,
  ) async {
    final approvals = FakeApprovalsRepository(
      pending: <ApprovalRequest>[buildApprovalRequest()],
    );
    await pumpApprovalsApp(tester, approvals: approvals);

    expect(find.text('Approvals'), findsOneWidget);
    expect(find.text('Discount 100 on a bill of 546'), findsOneWidget);
    expect(
      find.text(ApprovalActionType.discountAboveLimit.label),
      findsOneWidget,
      reason: 'the owner reads which kind of control he is being asked to lift',
    );
    // The two figures are the control itself: `checkout_sale()` refuses a bill whose
    // discount and total are not these.
    expect(
      find.text(
        '${Formatters.currency(100)} off a bill of ${Formatters.currency(546)}',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Asked '), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Approve'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Refuse'), findsOneWidget);
  });

  testWidgets('an approval reaches the decision, with its reason', (
    tester,
  ) async {
    final approvals = FakeApprovalsRepository(
      pending: <ApprovalRequest>[buildApprovalRequest()],
    );
    await pumpApprovalsApp(tester, approvals: approvals);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Approve'));
    await tester.pumpAndSettle();
    expect(find.text('Approve this?'), findsOneWidget);

    await _answer(tester, 'Approve', note: 'OK for this customer');

    expect(approvals.decisions, hasLength(1));
    expect(approvals.decisions.single.id, 'approval-1');
    expect(approvals.decisions.single.approve, isTrue);
    expect(approvals.decisions.single.note, 'OK for this customer');
  });

  testWidgets('a refusal is recorded as a refusal', (tester) async {
    final approvals = FakeApprovalsRepository(
      pending: <ApprovalRequest>[buildApprovalRequest()],
    );
    await pumpApprovalsApp(tester, approvals: approvals);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Refuse'));
    await tester.pumpAndSettle();
    expect(find.text('Refuse this?'), findsOneWidget);

    await _answer(tester, 'Refuse', note: 'Bill it at 10%');

    expect(approvals.decisions.single.approve, isFalse);
    expect(approvals.decisions.single.note, 'Bill it at 10%');
  });

  testWidgets('dismissing the dialog answers nothing at all', (tester) async {
    // A cancelled confirmation is not a refusal: recording one would tell the cashier
    // "no" when the owner never said anything.
    final approvals = FakeApprovalsRepository(
      pending: <ApprovalRequest>[buildApprovalRequest()],
    );
    await pumpApprovalsApp(tester, approvals: approvals);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Approve'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(approvals.decisions, isEmpty);
    expect(find.text('Discount 100 on a bill of 546'), findsOneWidget);
  });

  testWidgets('an empty reason is sent as no reason', (tester) async {
    final approvals = FakeApprovalsRepository(
      pending: <ApprovalRequest>[buildApprovalRequest()],
    );
    await pumpApprovalsApp(tester, approvals: approvals);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Approve'));
    await tester.pumpAndSettle();
    await _answer(tester, 'Approve', note: '   ');

    expect(approvals.decisions.single.note, isNull);
  });

  testWidgets('nothing waiting says so rather than showing an empty list', (
    tester,
  ) async {
    await pumpApprovalsApp(tester, approvals: FakeApprovalsRepository());

    expect(find.text('Nothing is waiting for an answer.'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('a request this build cannot classify is still shown', (
    tester,
  ) async {
    // An unrecognised action literal must not be silently mistaken for a discount: the
    // owner sees that something is waiting, under a neutral label.
    final approvals = FakeApprovalsRepository(
      pending: <ApprovalRequest>[
        buildApprovalRequest(
          actionType: ApprovalActionType.unknown,
          payload: const <String, dynamic>{},
          summary: null,
        ),
      ],
    );
    await pumpApprovalsApp(tester, approvals: approvals);

    expect(find.text(ApprovalActionType.unknown.label), findsOneWidget);
    expect(find.textContaining(' off a bill of '), findsNothing);
  });

  testWidgets('a failed read costs the screen, not the app', (tester) async {
    final approvals = FakeApprovalsRepository()
      ..errorToThrow = const ServerException(
        message: 'Unable to read the approvals waiting for you.',
      );
    await pumpApprovalsApp(tester, approvals: approvals);

    expect(find.textContaining('Unable to read the approvals'), findsOneWidget);
  });
}
