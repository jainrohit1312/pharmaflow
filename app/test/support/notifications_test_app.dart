/// A router and pump helper for the notifications screen and the dashboard card.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/features/notifications/data/notifications_repository.dart';
import 'package:app/features/notifications/presentation/notifications_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_notifications_repository.dart';

/// A router carrying the notifications screen.
///
/// The real router is unreachable in a test - it reads a Supabase session while it
/// builds - so the navigation this screen performs is exercised against this
/// instead. `/notifications` is a top-level path (D-048), so it is declared that
/// way here too.
GoRouter notificationsTestRouter({
  String initialLocation = Routes.notifications,
  Widget? atDashboard,
}) => GoRouter(
  initialLocation: initialLocation,
  routes: <RouteBase>[
    GoRoute(
      path: Routes.notifications,
      builder: (context, state) => const NotificationsScreen(),
    ),
    if (atDashboard != null)
      GoRoute(path: Routes.dashboard, builder: (context, state) => atDashboard),
  ],
);

/// Pumps the notifications screen and lets its three reads settle.
///
/// The window is made tall before anything is pumped: the screen is three cards and
/// a card below the fold would otherwise be missing rather than merely off-screen.
///
/// Pass `settle: false` to look at the screen *before* the fakes answer - which is
/// what a test of the loading state needs, and what a plain `pumpAndSettle` would
/// skip past.
Future<GoRouter> pumpNotificationsApp(
  WidgetTester tester, {
  required FakeNotificationsRepository notifications,
  String initialLocation = Routes.notifications,
  Size size = const Size(1200, 2400),
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = notificationsTestRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      // The override list is left untyped on purpose: `Override` is declared in
      // `riverpod`, which `flutter_riverpod` does not re-export (D-015 notes).
      overrides: [
        notificationsRepositoryProvider.overrideWithValue(notifications),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  }
  return router;
}
