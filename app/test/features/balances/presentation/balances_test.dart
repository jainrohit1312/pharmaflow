/// Tests for the account views: a patient's balance, an episode's, and what settled a
/// bill.
///
/// The point of every assertion here is that the figures are the **server's**. The
/// fixtures are deliberately *inconsistent* - `charges − returns − allocated` does not
/// equal the `outstanding` they carry - so a screen that recomputed the balance in Dart
/// would print a different number and fail. That is the only way to tell "prints the
/// aggregate" from "prints a sum that happens to agree".
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/data/models/account_balance.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/balances/data/balances_repository.dart';
import 'package:app/features/balances/presentation/admission_account_screen.dart';
import 'package:app/features/balances/presentation/widgets/patient_balance_card.dart';
import 'package:app/features/balances/presentation/widgets/sale_allocations_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/fake_balances_repository.dart';

/// Pumps a card over [repository].
Future<void> _pumpCard(
  WidgetTester tester,
  Widget card,
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
        home: Scaffold(body: SingleChildScrollView(child: card)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pumps the admission screen at the route it opens at.
Future<void> _pumpAdmission(
  WidgetTester tester,
  FakeBalancesRepository repository, {
  String admissionId = 'admission-1',
}) async {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    initialLocation: Routes.admission(admissionId),
    routes: <RouteBase>[
      GoRoute(
        path: Routes.admissionPattern,
        builder: (context, state) => AdmissionAccountScreen(
          admissionId: state.pathParameters['admissionId']!,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        balancesRepositoryProvider.overrideWithValue(repository),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group("a patient's account", () {
    testWidgets("prints the server's outstanding, not a sum of its own", (
      tester,
    ) async {
      // 1000 − 100 − 400 is 500. The server says 300, and 300 is what must print: the
      // account is an aggregate over the whole patient, including sales this card never
      // sees, so a Dart sum would be a *different and wrong* figure.
      final repository = FakeBalancesRepository()
        ..patient = buildPatientAccount(
          patientCode: 'PT-00001',
          charges: 1000,
          returnsCredits: 100,
          allocated: 400,
          outstanding: 300,
        );

      await _pumpCard(
        tester,
        const PatientBalanceCard(customerId: 'customer-1'),
        repository,
      );

      expect(find.text(PatientBalanceCard.title), findsOneWidget);
      expect(find.text(Formatters.currency(300)), findsOneWidget);
      expect(
        find.text(Formatters.currency(500)),
        findsNothing,
        reason: 'the card must not work the balance out for itself',
      );
      expect(find.text(Formatters.currency(1000)), findsOneWidget);
      expect(find.text('-${Formatters.currency(100)}'), findsOneWidget);
      expect(find.text(Formatters.currency(400)), findsOneWidget);
    });

    testWidgets('separates money held unapplied from money applied', (
      tester,
    ) async {
      final repository = FakeBalancesRepository()
        ..patient = buildPatientAccount(
          charges: 800,
          allocated: 400,
          outstanding: 400,
          unallocatedDeposits: 250,
        );

      await _pumpCard(
        tester,
        const PatientBalanceCard(customerId: 'customer-1'),
        repository,
      );

      expect(find.text('Held unapplied'), findsOneWidget);
      expect(
        find.text(Formatters.currency(250)),
        findsOneWidget,
        reason:
            'a receipt nobody applied is money the pharmacy holds, not a bill it '
            'settled',
      );
    });

    testWidgets('says nothing about a deposit when there is none', (
      tester,
    ) async {
      final repository = FakeBalancesRepository()
        ..patient = buildPatientAccount(charges: 200, allocated: 200);

      await _pumpCard(
        tester,
        const PatientBalanceCard(customerId: 'customer-1'),
        repository,
      );

      expect(find.text('Held unapplied'), findsNothing);
      expect(find.text('Settled'), findsOneWidget);
    });

    testWidgets('reads an account the pharmacy has never billed as one', (
      tester,
    ) async {
      // `patient_account()` answers no rows for a customer who is not in this pharmacy -
      // a real answer, not a failure.
      await _pumpCard(
        tester,
        const PatientBalanceCard(customerId: 'customer-1'),
        FakeBalancesRepository(),
      );

      expect(find.text('No account yet'), findsOneWidget);
      expect(find.text(PatientBalanceCard.title), findsOneWidget);
    });

    testWidgets('offers a retry when the account could not be read', (
      tester,
    ) async {
      final repository = FakeBalancesRepository()
        ..errorToThrow = const ServerException(
          message: 'Unable to load that patient\u2019s account.',
        );

      await _pumpCard(
        tester,
        const PatientBalanceCard(customerId: 'customer-1'),
        repository,
      );

      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      repository
        ..errorToThrow = null
        // The three figures differ, so a match on one of them cannot be a match on
        // another: a fixture whose charges equalled its outstanding would pass this
        // assertion twice over.
        ..patient = buildPatientAccount(
          charges: 500,
          allocated: 400,
          outstanding: 100,
        );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.byType(ErrorView), findsNothing);
      expect(find.text(Formatters.currency(100)), findsOneWidget);
    });
  });

  group("an episode's account", () {
    testWidgets('shows the episode, and keeps it apart from the patient', (
      tester,
    ) async {
      // The episode's figures and the patient's are deliberately different, and neither
      // is a sum of the other: one patient has many episodes and their balances never
      // mix (D-074).
      final repository = FakeBalancesRepository()
        ..admission = buildAdmissionAccount(
          admissionNo: 'IPD-7',
          patientCode: 'PT-00001',
          charges: 500,
          allocated: 200,
          outstanding: 300,
        )
        ..patient = buildPatientAccount(
          charges: 9000,
          allocated: 5000,
          outstanding: 4000,
        );

      await _pumpAdmission(tester, repository);

      expect(find.text('IPD-7'), findsWidgets);
      expect(find.text('Active'), findsOneWidget);
      expect(
        find.text(Formatters.currency(300)),
        findsOneWidget,
        reason: "the episode's own outstanding",
      );
      expect(
        find.text(Formatters.currency(9000)),
        findsOneWidget,
        reason: "and the patient's, shown separately and not added to it",
      );
    });

    testWidgets('shows a discharged episode as discharged', (tester) async {
      final repository = FakeBalancesRepository()
        ..admission = buildAdmissionAccount(
          status: 'discharged',
          dischargedOn: DateTime(2026, 9, 20),
          charges: 400,
        );

      await _pumpAdmission(tester, repository);

      expect(
        find.text('Discharged'),
        findsWidgets,
        reason:
            "the episode's status badge, and the field that labels its date",
      );
      expect(
        find.text(Formatters.dateDdMmYyyy(DateTime(2026, 9, 20))),
        findsOneWidget,
      );
      expect(find.text('Settled'), findsOneWidget);
    });

    testWidgets(
      'says when the episode is not there, rather than loading for ever',
      (tester) async {
        await _pumpAdmission(tester, FakeBalancesRepository());

        expect(find.text('Admission not found'), findsOneWidget);
        expect(find.text('Loading the admission…'), findsNothing);
      },
    );
  });

  group('what settled a bill', () {
    testWidgets('lists the receipts applied to it', (tester) async {
      final repository = FakeBalancesRepository()
        ..allocations = <SaleAllocation>[
          // The default fixture: one receipt, `11111111-…`, 100.
          buildSaleAllocation(amount: 150),
          buildSaleAllocation(
            id: 'allocation-2',
            paymentId: '22222222-2222-2222-2222-222222222222',
            amount: 50,
          ),
        ];

      await _pumpCard(
        tester,
        const SaleAllocationsCard(saleId: 'sale-1'),
        repository,
      );

      expect(find.text(SaleAllocationsCard.title), findsOneWidget);
      expect(find.text('2 receipts'), findsOneWidget);
      expect(find.text('Receipt 11111111'), findsOneWidget);
      expect(find.text('Receipt 22222222'), findsOneWidget);
      expect(find.text(Formatters.currency(150)), findsOneWidget);
      expect(find.text(Formatters.currency(50)), findsOneWidget);
      expect(
        find.text(Formatters.currency(200)),
        findsNothing,
        reason:
            'no total is added up here: a sum of rows is a figure no server computed',
      );
    });

    testWidgets('says when nothing has been applied to it', (tester) async {
      await _pumpCard(
        tester,
        const SaleAllocationsCard(saleId: 'sale-1'),
        FakeBalancesRepository(),
      );

      expect(find.text('Nothing applied'), findsOneWidget);
      expect(
        find.textContaining('unapplied deposit'),
        findsOneWidget,
        reason:
            'money handed over that was never aimed at a bill is not a settlement',
      );
    });

    testWidgets('offers a retry when the allocations could not be read', (
      tester,
    ) async {
      final repository = FakeBalancesRepository()
        ..errorToThrow = const ServerException(
          message: 'Unable to load what settled that bill.',
        );

      await _pumpCard(
        tester,
        const SaleAllocationsCard(saleId: 'sale-1'),
        repository,
      );

      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
