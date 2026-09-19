/// Smoke tests for the route registry shared by the router and the shell.
///
/// The default template widget test was replaced: the app root is now
/// `PharmaFlowApp` (see `lib/app.dart`), which needs an initialised Supabase
/// client and therefore cannot be pumped without a live backend.
///
/// `Routes` and `DashboardShell` each declare the same destinations - the router
/// needs paths, the shell needs icons - so these tests hold the two together.
/// A silent disagreement between them is a screen that exists but that nothing
/// leads to, which is how the desktop rail once hid seven of them.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/features/dashboard/presentation/dashboard_shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the shell serves every destination the router declares', () {
    expect(DashboardShell.destinationPaths, Routes.shellPaths);
  });

  test('every bottom-nav path is part of the shell', () {
    for (final path in Routes.bottomNavPaths) {
      expect(Routes.shellPaths, contains(path));
    }
  });

  test(
    'the rail and the bottom bar agree on which destinations are primary',
    () {
      expect(DashboardShell.bottomBarPaths, Routes.bottomNavPaths);
    },
  );

  test('the shell exposes every post-login destination', () {
    expect(
      Routes.shellPaths,
      hasLength(13),
      reason:
          'dashboard, products, suppliers, customers, inventory, purchase, '
          'sales, returns, ledger, reports, notifications, chatbot, settings',
    );
  });

  test('the bottom bar carries four primary destinations', () {
    expect(Routes.bottomNavPaths, hasLength(4));
  });
}
