/// Tests for the registration sheet.
///
/// Two things are load-bearing here and both are decisions rather than mechanics:
/// the duplicate-mobile **question** (a shared number is two patients on purpose),
/// and the absence of a GSTIN field (the customers screen owns that column, and
/// `save_patient()` has no parameter for it).
library;

import 'package:app/data/models/customer.dart';
import 'package:app/features/customers/data/patients_repository.dart';
import 'package:app/features/customers/presentation/patients/patient_registration_sheet.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_customers_repository.dart';
import '../../../../support/fake_patients_repository.dart';

/// Pumps a button that opens the sheet, and the container behind it.
///
/// The window is made tall first: the sheet is a long form, and a tap on a control
/// below the fold would land outside the viewport and quietly do nothing.
Future<ProviderContainer> _pumpSheet(
  WidgetTester tester, {
  required FakePatientsRepository repository,
}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer(
    overrides: [patientsRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPatientRegistrationSheet(context),
              child: const Text('Register'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Register'));
  await tester.pumpAndSettle();
  return container;
}

/// Types [value] into the field labelled [label].
Future<void> _type(WidgetTester tester, String label, String value) async {
  await tester.enterText(find.widgetWithText(TextFormField, label), value);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('collects the minimum identity, and nothing more', (
    tester,
  ) async {
    await _pumpSheet(tester, repository: FakePatientsRepository());

    expect(find.text('New patient'), findsOneWidget);
    for (final label in <String>[
      'Name',
      'Mobile',
      'Date of birth',
      'Age (years)',
      'Age (months)',
      'Sex',
      'Guardian name',
      'Guardian mobile',
      'Address',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(
      find.text('GSTIN'),
      findsNothing,
      reason:
          'save_patient() has no GSTIN parameter and the customers screen owns '
          'that column, so the counter must not collect one',
    );
  });

  testWidgets('will not register without a name', (tester) async {
    final repository = FakePatientsRepository();
    await _pumpSheet(tester, repository: repository);

    await _type(tester, 'Mobile', '9876543210');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Register'));
    await tester.pumpAndSettle();

    expect(find.text('A name is required'), findsOneWidget);
    expect(repository.registrations, isEmpty);
  });

  testWidgets('will not register without a mobile or a guardian number', (
    tester,
  ) async {
    // The requirement is the pair, so it is said once - in the server's own words -
    // rather than as the same complaint under two fields.
    final repository = FakePatientsRepository();
    await _pumpSheet(tester, repository: repository);

    await _type(tester, 'Name', 'ZZTEST patient');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Register'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('or a guardian\u2019s for a child or'),
      findsOneWidget,
    );
    expect(repository.registrations, isEmpty);
  });

  testWidgets('refuses a number that is not a mobile', (tester) async {
    final repository = FakePatientsRepository();
    await _pumpSheet(tester, repository: repository);

    await _type(tester, 'Name', 'ZZTEST patient');
    await _type(tester, 'Mobile', '12345');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Register'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid 10-digit mobile number'), findsOneWidget);
    expect(repository.registrations, isEmpty);
  });

  testWidgets('registers, and pins the patient it answered with', (
    tester,
  ) async {
    final repository = FakePatientsRepository();
    final container = await _pumpSheet(tester, repository: repository);

    await _type(tester, 'Name', 'ZZTEST patient');
    await _type(tester, 'Mobile', '9876543210');
    await _type(tester, 'Age (years)', '34');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Register'));
    await tester.pumpAndSettle();

    expect(repository.registrations, hasLength(1));
    final registration = repository.registrations.single;
    expect(registration['name'], 'ZZTEST patient');
    expect(registration['mobile'], '9876543210');
    expect(registration['ageYears'], 34);
    expect(
      registration['patientId'],
      isNull,
      reason: 'a new patient has no id until the server mints the row',
    );

    final cart = container.read(posControllerProvider);
    expect(cart.customerId, isNotNull);
    expect(cart.patientName, 'ZZTEST patient');
  });

  testWidgets('a guardian number alone satisfies the contact requirement', (
    tester,
  ) async {
    // `save_patient()` stores the guardian's number as the patient's own contact
    // when there is none of theirs, so the form has to accept it.
    final repository = FakePatientsRepository();
    await _pumpSheet(tester, repository: repository);

    await _type(tester, 'Name', 'ZZTEST child');
    await _type(tester, 'Guardian mobile', '9123456780');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Register'));
    await tester.pumpAndSettle();

    expect(repository.registrations, hasLength(1));
    expect(repository.registrations.single['guardianPhone'], '9123456780');
  });

  group('a mobile that is already on file', () {
    testWidgets('is a question, and "use that patient" does not register', (
      tester,
    ) async {
      final repository = FakePatientsRepository(
        patients: <Customer>[
          buildCustomer(
            'ZZTEST existing',
            phone: '9876543210',
            patientCode: 'PT-00001',
          ),
        ],
      );
      final container = await _pumpSheet(tester, repository: repository);

      await _type(tester, 'Name', 'ZZTEST patient');
      await _type(tester, 'Mobile', '9876543210');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Register'));
      await tester.pumpAndSettle();

      expect(find.text('That number is already on file'), findsOneWidget);
      expect(
        find.textContaining('ZZTEST existing'),
        findsOneWidget,
        reason: 'the question names whose number it is',
      );

      await tester.tap(find.widgetWithText(TextButton, 'Use that patient'));
      await tester.pumpAndSettle();

      expect(repository.registrations, hasLength(1));
      expect(
        repository.registrations.single['patientId'],
        'id-ZZTEST existing',
        reason:
            'the returning-patient path hands the id back, which is what assigns '
            'a code without editing anybody',
      );
      final cart = container.read(posControllerProvider);
      expect(cart.customerId, 'id-ZZTEST existing');
      expect(cart.patientName, 'ZZTEST existing');
    });

    testWidgets('can be overruled, because a family shares a number', (
      tester,
    ) async {
      final repository = FakePatientsRepository(
        patients: <Customer>[
          buildCustomer('ZZTEST existing', phone: '9876543210'),
        ],
      );
      await _pumpSheet(tester, repository: repository);

      await _type(tester, 'Name', 'ZZTEST second patient');
      await _type(tester, 'Mobile', '9876543210');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Register'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Register anyway'));
      await tester.pumpAndSettle();

      expect(repository.registrations, hasLength(1));
      final second = repository.registrations.single;
      expect(second['name'], 'ZZTEST second patient');
      expect(second['mobile'], '9876543210');
      expect(
        second['patientId'],
        isNull,
        reason: 'it is a second patient, not an edit of the first',
      );
    });

    testWidgets('is not asked about for a number that matches nobody', (
      tester,
    ) async {
      final repository = FakePatientsRepository(
        patients: <Customer>[
          buildCustomer('ZZTEST existing', phone: '9000000000'),
        ],
      );
      await _pumpSheet(tester, repository: repository);

      await _type(tester, 'Name', 'ZZTEST patient');
      await _type(tester, 'Mobile', '9876543210');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Register'));
      await tester.pumpAndSettle();

      expect(find.text('That number is already on file'), findsNothing);
      expect(repository.registrations, hasLength(1));
      expect(repository.registrations.single['name'], 'ZZTEST patient');
    });
  });

  testWidgets('a server refusal is shown in the server\u2019s own words', (
    tester,
  ) async {
    final repository = FakePatientsRepository()
      ..errorToThrow = const _Refusal(
        'a patient needs a mobile number, or a guardian\u2019s for a child or '
        'dependant',
      );
    await _pumpSheet(tester, repository: repository);

    await _type(tester, 'Name', 'ZZTEST patient');
    await _type(tester, 'Mobile', '9876543210');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Register'));
    await tester.pumpAndSettle();

    expect(find.textContaining('a guardian'), findsOneWidget);
    expect(
      find.widgetWithText(ElevatedButton, 'Register'),
      findsOneWidget,
      reason: 'the sheet stays open so the counter can correct it',
    );
  });
}

/// A refusal a fake can be made to throw, worded like the RPC's own.
class _Refusal implements Exception {
  const _Refusal(this.message);

  final String message;

  @override
  String toString() => message;
}
