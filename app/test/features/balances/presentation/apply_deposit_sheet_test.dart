/// Widget tests for the sheet that applies held money to the bills it settles.
///
/// Two rules decide what this sheet may do, and both are the project's: **the client proposes and
/// the server disposes** - so the caps are figures it shows rather than arithmetic it enforces - and
/// **applying a deposit is not a second receipt** - so it writes allocation rows and nothing else,
/// which is why nothing here has an amount or a mode to fill in.
///
/// Two of the cases Phase 7a's brief listed are pinned elsewhere rather than here, and deliberately:
/// a receipt that is **already fully applied** never reaches the sheet because the reader drops it
/// (`DepositReceipt.hasHeld`, asserted in `party_deposits_test.dart`), and applying money to an
/// **admission episode** is not reachable from this sheet at all - `open_bills()` lists a customer's
/// sales, because a supplier's open documents are purchases and an episode is a different reader's
/// (D-074).
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/data/models/party_deposits.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/balances/data/balances_repository.dart';
import 'package:app/features/balances/presentation/widgets/apply_deposit_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_balances_repository.dart';

void main() {
  testWidgets(
    'a receipt that still holds money is offered with the bills it settles',
    (tester) async {
      await _pump(tester, _ready());

      expect(find.text('Apply held money'), findsOneWidget);
      expect(
        find.textContaining('Holding ₹500.00'),
        findsOneWidget,
        reason: 'what is held, from the receipt the operator is applying',
      );
      expect(find.text('INV-1'), findsOneWidget);
      expect(
        find.textContaining('owes ₹105.00'),
        findsOneWidget,
        reason:
            "the bill's own outstanding, which is the figure a refusal would name",
      );

      // Nothing entered: the button cannot apply a zero.
      await tester.tap(find.widgetWithText(AppButton, 'Apply money'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<AppButton>(find.widgetWithText(AppButton, 'Apply money'))
            .onPressed,
        isNull,
        reason: 'there is nothing to apply yet',
      );
    },
  );

  testWidgets(
    'applying part of a deposit settles the bill and leaves the rest held',
    (tester) async {
      final repository = _ready();
      await _pump(tester, repository);

      await tester.enterText(
        find.widgetWithText(AppTextField, 'Amount'),
        '105',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AppButton, 'Apply money'));
      await tester.pumpAndSettle();

      expect(repository.appliedPaymentIds, <String>['payment-1']);
      expect(
        repository.appliedTargets.single.saleId,
        'sale-1',
        reason: 'an allocation names the bill it settles',
      );
      expect(repository.appliedTargets.single.amount, 105);
      expect(
        find.text('Apply held money'),
        findsNothing,
        reason: 'the sheet closes once the server has taken the application',
      );

      // Re-opened: the server (the fake, on the application) settled that bill and the receipt holds
      // the difference, which is what "applying a deposit is not a second receipt" looks like.
      await _open(tester);
      expect(
        find.text('INV-1'),
        findsNothing,
        reason: 'a bill that owes nothing is not offered again',
      );
      expect(find.textContaining('Holding ₹395.00'), findsOneWidget);
      expect(
        find.textContaining('There is nothing to apply it to'),
        findsOneWidget,
        reason: 'and with nothing left to settle, the money simply stays held',
      );
    },
  );

  testWidgets('an application the server refuses is reported in its own words', (
    tester,
  ) async {
    final repository = _ready()
      ..writeErrorToThrow = const ValidationException(
        message:
            'that bill is owed less than you are applying: correct it and try again',
      );
    await _pump(tester, repository);

    await tester.enterText(find.widgetWithText(AppTextField, 'Amount'), '500');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Apply money'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('that bill is owed less than you are applying'),
      findsOneWidget,
      reason:
          "the refusal is the server's sentence, not a bug the sheet invented",
    );
    expect(
      find.text('Apply held money'),
      findsOneWidget,
      reason: 'the sheet stays open: the operator is one edit away',
    );
    expect(
      repository.appliedTargets,
      isEmpty,
      reason:
          'a refusal writes nothing, because the write and the decision are one transaction',
    );
  });

  testWidgets('nothing held: the sheet says so rather than offering a form', (
    tester,
  ) async {
    await _pump(tester, FakeBalancesRepository());

    expect(
      find.textContaining('Nothing is held for this patient'),
      findsOneWidget,
    );
    expect(find.widgetWithText(AppButton, 'Apply money'), findsNothing);
  });

  testWidgets('money held with nothing to apply it to stays held', (
    tester,
  ) async {
    await _pump(
      tester,
      FakeBalancesRepository()
        ..receipts = <DepositReceipt>[buildDepositReceipt()],
    );

    expect(find.textContaining('Holding ₹500.00'), findsOneWidget);
    expect(
      find.textContaining('There is nothing to apply it to'),
      findsOneWidget,
      reason: 'the money is not lost - it waits for a bill to settle',
    );
    expect(find.widgetWithText(AppButton, 'Apply money'), findsNothing);
  });
}

/// A repository holding one bill of ₹105 and one receipt of ₹500 with nothing applied.
FakeBalancesRepository _ready() => FakeBalancesRepository()
  ..receipts = <DepositReceipt>[buildDepositReceipt()]
  ..bills = <OpenBill>[buildOpenBill()];

/// Pumps the sheet's own screen, and opens it.
///
/// The window is made tall before anything is pumped, because the sheet is a scrollable bottom
/// sheet and the assertion about each bill would otherwise be about what fits rather than about
/// what is there.
Future<void> _pump(
  WidgetTester tester,
  FakeBalancesRepository repository,
) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        balancesRepositoryProvider.overrideWithValue(repository),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => AppButton.primary(
              label: 'Open the sheet',
              onPressed: () => showApplyDepositSheet(
                context,
                customerId: 'customer-1',
                patientName: 'ZZTEST patient',
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _open(tester);
}

/// Taps the button that opens the sheet, and lets it settle.
Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Open the sheet'));
  await tester.pumpAndSettle();
}
