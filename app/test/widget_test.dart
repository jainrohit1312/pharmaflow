/// Smoke tests for the route registry shared by the router and the shell.
///
/// The default template widget test was replaced: the app root is now
/// `PharmaFlowApp` (see `lib/app.dart`), which needs an initialised Supabase
/// client and therefore cannot be pumped without a live backend.
library;

import 'package:app/core/router/routes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every bottom-nav path is part of the shell', () {
    for (final path in Routes.bottomNavPaths) {
      expect(Routes.shellPaths, contains(path));
    }
  });

  test('the shell exposes the nine post-login destinations', () {
    expect(Routes.shellPaths, hasLength(9));
  });

  test('the bottom bar carries four primary destinations', () {
    expect(Routes.bottomNavPaths, hasLength(4));
  });
}
