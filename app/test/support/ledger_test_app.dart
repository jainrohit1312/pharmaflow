/// A router and pump helper for the ledger screen.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/data/repositories/ledger_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/customers/data/customers_repository.dart';
import 'package:app/features/ledger/presentation/ledger_screen.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_customers_repository.dart';
import 'fake_ledger_repository.dart';
import 'fake_suppliers_repository.dart';

/// A router carrying the ledger screen.
///
/// The real router is unreachable in a test - it reads a Supabase session while it
/// builds - so the screen is mounted behind a miniature one instead.
GoRouter ledgerTestRouter({String initialLocation = Routes.ledger}) => GoRouter(
  initialLocation: initialLocation,
  routes: <RouteBase>[
    GoRoute(
      path: Routes.ledger,
      builder: (context, state) => const LedgerScreen(),
    ),
  ],
);

/// Pumps the ledger screen over [ledger] and lets the first load settle.
///
/// The party picker is fed by the suppliers and customers repositories, so those
/// are stubbed even though the ledger rows themselves come from the ledger fake.
/// The test window is made tall before anything is pumped, for the same reason as
/// the inventory helper: the picker, the balance card and the list would
/// otherwise run off the bottom, and a widget below the fold is missing rather
/// than merely off-screen.
///
/// [configure] runs against the container before the first frame. That is the only
/// way to drive state a provider reads as it builds: the entries provider answers
/// with an empty page while no party is selected, so a *first* read that fails -
/// the one that renders the retry - can only be produced by selecting a party up
/// front.
Future<GoRouter> pumpLedgerApp(
  WidgetTester tester, {
  required FakeLedgerRepository ledger,
  List<Supplier>? suppliers,
  List<Customer>? customers,
  void Function(ProviderContainer container)? configure,
  Size size = const Size(1200, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // The override list is left untyped on purpose: `Override` is declared in
  // `riverpod`, which `flutter_riverpod` does not re-export, so naming the
  // element type would need an extra import for no benefit (D-015 notes).
  final container = ProviderContainer(
    overrides: [
      ledgerRepositoryProvider.overrideWithValue(ledger),
      suppliersRepositoryProvider.overrideWithValue(
        FakeSuppliersRepository(suppliers: suppliers ?? const <Supplier>[]),
      ),
      customersRepositoryProvider.overrideWithValue(
        FakeCustomersRepository(customers: customers ?? const <Customer>[]),
      ),
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
    ],
  );
  addTearDown(container.dispose);
  configure?.call(container);

  final router = ledgerTestRouter();
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
