/// A router and pump helper for the reports and expenses screens.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/expenses/data/expenses_repository.dart';
import 'package:app/features/expenses/presentation/expenses_screen.dart';
import 'package:app/features/reports/data/reports_repository.dart';
import 'package:app/features/reports/presentation/reports_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_expenses_repository.dart';
import 'fake_reports_repository.dart';

/// A router carrying both screens, because reports navigates to expenses.
///
/// The real router is unreachable in a test - it reads a Supabase session while it
/// builds - so the navigation these screens perform (`context.go`) is exercised
/// against this instead.
GoRouter reportsTestRouter({
  String initialLocation = Routes.reports,
}) => GoRouter(
  initialLocation: initialLocation,
  routes: <RouteBase>[
    GoRoute(
      path: Routes.reports,
      builder: (context, state) => const ReportsScreen(),
    ),
    // A child of `/reports`, as the real router declares it: the path shares
    // the prefix, so the same nesting is what a test has to reproduce.
    GoRoute(
      path: Routes.expenses,
      builder: (context, state) => const ExpensesScreen(),
    ),
  ],
);

/// Pumps the reports or expenses screen and lets the first load settle.
///
/// The window is made tall before anything is pumped: the summary is a column of
/// seven cards, and a card below the fold would otherwise be missing rather than
/// merely off-screen. A test that pages a long list passes a taller [size] for
/// the same reason.
Future<GoRouter> pumpReportsApp(
  WidgetTester tester, {
  required FakeReportsRepository reports,
  FakeExpensesRepository? expenses,
  String initialLocation = Routes.reports,
  Size size = const Size(1200, 4000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = reportsTestRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      // The override list is left untyped on purpose: `Override` is declared in
      // `riverpod`, which `flutter_riverpod` does not re-export (D-015 notes).
      overrides: [
        reportsRepositoryProvider.overrideWithValue(reports),
        expensesRepositoryProvider.overrideWithValue(
          expenses ?? FakeExpensesRepository(),
        ),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
