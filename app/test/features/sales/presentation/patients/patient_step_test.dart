/// Tests for the patient step: the lookup, the recent list, and pinning.
///
/// The step reads a real cart through the container, so these assert what the
/// counter ends up with - the party, the printed name and the number - rather than
/// only what the screen drew.
library;

import 'package:app/data/models/admission.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/customers/application/customer_options.dart';
import 'package:app/features/customers/application/patient_lookup.dart';
import 'package:app/features/customers/data/patients_repository.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:app/features/sales/presentation/patients/patient_step.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_customers_repository.dart';
import '../../../../support/fake_patients_repository.dart';

/// The patient the counter knows.
Customer _patient({
  String name = 'ZZTEST patient',
  String code = 'PT-00042',
  String? phone = '9876543210',
}) => buildCustomer(name, phone: phone, patientCode: code);

/// Pumps the step over [repository], with the cart read from a container the test
/// keeps, so it can assert what pinning did.
Future<ProviderContainer> _pumpStep(
  WidgetTester tester, {
  required FakePatientsRepository repository,
  List<Customer> accounts = const <Customer>[],
  SaleType saleType = SaleType.counter,
}) async {
  final container = ProviderContainer(
    overrides: [
      patientsRepositoryProvider.overrideWithValue(repository),
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      patientSearchProvider.overrideWith(
        (ref, term) => repository.search(term: term),
      ),
      recentPatientsProvider.overrideWith(
        (ref) => repository.recent(pharmacyId: 'ph-1'),
      ),
      patientAdmissionsProvider.overrideWith(
        (ref, patientId) => repository.admissionsFor(patientId: patientId),
      ),
      // The package variant's account list, read leniently by the step.
      customerOptionsProvider.overrideWith((ref) async => accounts),
    ],
  );
  addTearDown(container.dispose);
  container.read(posControllerProvider.notifier).setSaleType(saleType);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, child) =>
                PatientStep(cart: ref.watch(posControllerProvider)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Types [term] into the lookup and lets the debounce fire.
///
/// `pumpAndSettle` alone is not enough: the debounce is a bare `Timer`, and a timer
/// does not schedule frames, so settling returns before the query is applied.
Future<void> _search(WidgetTester tester, String term) async {
  await tester.enterText(find.byType(TextField), term);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

void main() {
  group('with nothing pinned', () {
    testWidgets('offers the recent patients, and the way to register one', (
      tester,
    ) async {
      await _pumpStep(
        tester,
        repository: FakePatientsRepository(patients: <Customer>[_patient()]),
      );

      expect(find.text('Recent patients'), findsOneWidget);
      expect(find.text('ZZTEST patient'), findsOneWidget);
      expect(
        find.text('PT-00042 · 9876543210'),
        findsOneWidget,
        reason:
            'the code and the number are what tell two patients with the same '
            'name apart',
      );
      expect(find.text('New patient'), findsOneWidget);
    });

    testWidgets('says so when the pharmacy has registered nobody yet', (
      tester,
    ) async {
      await _pumpStep(tester, repository: FakePatientsRepository());

      expect(find.text('No patients yet'), findsOneWidget);
      expect(
        find.textContaining('needs a name and a number'),
        findsOneWidget,
        reason: 'the empty state says why it cannot be skipped',
      );
    });

    testWidgets('a failed read costs the list, not the screen', (tester) async {
      final repository = FakePatientsRepository()..errorToThrow = const _Boom();
      await _pumpStep(tester, repository: repository);

      expect(find.textContaining('boom'), findsOneWidget);
      expect(
        find.text('New patient'),
        findsOneWidget,
        reason: 'registering somebody is still the way through',
      );
    });
  });

  group('searching', () {
    testWidgets('narrows the list by what was typed', (tester) async {
      final repository = FakePatientsRepository(
        patients: <Customer>[
          _patient(name: 'ZZTEST Asha', code: 'PT-00001'),
          _patient(name: 'ZZTEST Bhim', code: 'PT-00002'),
        ],
      );
      await _pumpStep(tester, repository: repository);

      await _search(tester, 'Bhim');

      expect(find.text('ZZTEST Bhim'), findsOneWidget);
      expect(find.text('ZZTEST Asha'), findsNothing);
      expect(repository.searchedTerms, contains('Bhim'));
    });

    testWidgets('says when nothing matched, rather than showing nothing', (
      tester,
    ) async {
      await _pumpStep(
        tester,
        repository: FakePatientsRepository(patients: <Customer>[_patient()]),
      );

      await _search(tester, 'Nobody');

      expect(find.text('No patient matches "Nobody".'), findsOneWidget);
    });

    testWidgets('finds a patient by the code on their card', (tester) async {
      await _pumpStep(
        tester,
        repository: FakePatientsRepository(
          patients: <Customer>[
            _patient(name: 'ZZTEST Asha', code: 'PT-00001'),
            _patient(name: 'ZZTEST Bhim', code: 'PT-00002'),
          ],
        ),
      );

      await _search(tester, 'PT-00002');

      expect(find.text('ZZTEST Bhim'), findsOneWidget);
      expect(find.text('ZZTEST Asha'), findsNothing);
    });

    testWidgets('marks a patient who is currently admitted', (tester) async {
      // The count is what tells the details step whether to ask which episode is
      // being billed, so it travels with a match - and a match is what the search
      // returns.
      await _pumpStep(
        tester,
        repository: FakePatientsRepository(
          patients: <Customer>[_patient()],
          admissions: <Admission>[buildAdmission()],
        ),
      );

      await _search(tester, 'ZZTEST');

      expect(find.textContaining('admitted'), findsOneWidget);
    });
  });

  group('pinning a patient', () {
    testWidgets('puts the row, the printed name and the number on the bill', (
      tester,
    ) async {
      final container = await _pumpStep(
        tester,
        repository: FakePatientsRepository(patients: <Customer>[_patient()]),
      );

      await tester.tap(find.text('ZZTEST patient'));
      await tester.pumpAndSettle();

      final cart = container.read(posControllerProvider);
      expect(cart.customerId, 'id-ZZTEST patient');
      expect(cart.patientName, 'ZZTEST patient');
      expect(cart.patientMobile, '9876543210');
      // And the step says who it is for now, with the way to change it.
      expect(find.text('Change'), findsOneWidget);
      expect(find.text('New patient'), findsNothing);
    });

    testWidgets('a patient with no number on file is pinned anyway, and said', (
      tester,
    ) async {
      // The server refuses the bill later, in its own words; showing the gap here
      // is what lets the counter fix it before the medicines are rung up.
      final container = await _pumpStep(
        tester,
        repository: FakePatientsRepository(
          patients: <Customer>[_patient(phone: null)],
        ),
      );

      await tester.tap(find.text('ZZTEST patient'));
      await tester.pumpAndSettle();

      expect(container.read(posControllerProvider).customerId, isNotNull);
      expect(find.text('No number on file'), findsOneWidget);
    });

    testWidgets('Change forgets the patient and brings the lookup back', (
      tester,
    ) async {
      final container = await _pumpStep(
        tester,
        repository: FakePatientsRepository(patients: <Customer>[_patient()]),
      );
      await tester.tap(find.text('ZZTEST patient'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();

      expect(container.read(posControllerProvider).customerId, isNull);
      expect(container.read(posControllerProvider).patientName, isNull);
      expect(find.text('Recent patients'), findsOneWidget);
    });

    testWidgets('an admitted patient is marked as such in the lookup', (
      tester,
    ) async {
      await _pumpStep(
        tester,
        repository: FakePatientsRepository(
          patients: <Customer>[_patient()],
          admissions: <Admission>[buildAdmission()],
        ),
      );

      await _search(tester, 'ZZTEST');

      expect(find.textContaining('admitted'), findsOneWidget);
    });
  });

  group('a package sale', () {
    testWidgets('asks for the account, and for the patient in words', (
      tester,
    ) async {
      final container = await _pumpStep(
        tester,
        repository: FakePatientsRepository(),
        accounts: <Customer>[
          buildCustomer('Rohit Kidney & Stone Hospital (Account)'),
        ],
        saleType: SaleType.package,
      );

      expect(find.text('Hospital account'), findsOneWidget);
      expect(find.text('Patient'), findsOneWidget);
      expect(find.text('Patient mobile'), findsOneWidget);
      expect(
        find.textContaining('The hospital is the debtor'),
        findsOneWidget,
        reason: 'the step explains why the party is not the patient here',
      );

      // Both typed fields travel together, so the cart never holds half of them.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Patient'),
        'ZZTEST package patient',
      );
      await tester.pumpAndSettle();
      final cart = container.read(posControllerProvider);
      expect(cart.patientName, 'ZZTEST package patient');
      expect(cart.customerId, isNull);
    });
  });
}

/// A failure a fake can be made to throw, so a read can be seen to fail.
class _Boom implements Exception {
  const _Boom();

  @override
  String toString() => 'boom';
}
