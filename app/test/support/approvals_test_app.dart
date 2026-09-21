/// A router and pump helper for the approvals screen.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/features/approvals/data/approvals_repository.dart';
import 'package:app/features/approvals/presentation/approvals_screen.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/settings/presentation/settings_placeholder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_approvals_repository.dart';

/// A router carrying the screen and the settings it is nested under.
///
/// The real router is unreachable in a test - it reads a Supabase session while it
/// builds - so the screen's own `context.go` targets are declared here instead. Both
/// paths are declared because `/settings/approvals` is a child of `/settings`, which is
/// the relationship the real router reproduces.
GoRouter approvalsTestRouter() => GoRouter(
  initialLocation: Routes.approvals,
  routes: <RouteBase>[
    GoRoute(
      path: Routes.settings,
      builder: (context, state) => const SettingsPlaceholder(),
    ),
    GoRoute(
      path: Routes.approvals,
      builder: (context, state) => const ApprovalsScreen(),
    ),
  ],
);

/// Pumps the approvals screen over [approvals] and lets the first read settle.
Future<GoRouter> pumpApprovalsApp(
  WidgetTester tester, {
  required FakeApprovalsRepository approvals,
  Size size = const Size(1200, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = approvalsTestRouter();
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      // The override list is left untyped on purpose: `Override` is declared in
      // `riverpod`, which `flutter_riverpod` does not re-export (D-015 notes).
      overrides: [
        approvalsRepositoryProvider.overrideWithValue(approvals),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
