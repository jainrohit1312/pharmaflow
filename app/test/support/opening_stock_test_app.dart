/// A router and pump helper for the opening stock import screen.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it. The real
/// router is unreachable in a test - it reads a Supabase session while it builds -
/// so the navigation this screen performs (`context.go`) is exercised against
/// this one, and the two destinations it links to are stubs whose only job is to
/// prove the link resolved.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/profile.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_audit_csv.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_file_picker.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_repository.dart';
import 'package:app/features/import/opening_stock/presentation/opening_stock_import_screen.dart';
import 'package:app/features/settings/presentation/settings_placeholder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_opening_stock_file_picker.dart';
import 'fake_opening_stock_repository.dart';

/// The stub a navigation test lands on.
const String inventoryStubText = 'STUB: inventory';

/// A router carrying the import screen, the settings screen above it, and the
/// inventory it links to.
GoRouter openingStockTestRouter({
  String initialLocation = Routes.openingStockImport,
}) => GoRouter(
  initialLocation: initialLocation,
  routes: <RouteBase>[
    GoRoute(
      path: Routes.settings,
      builder: (context, state) => const SettingsPlaceholder(),
    ),
    // A child of `/settings`, as the real router declares it.
    GoRoute(
      path: Routes.openingStockImport,
      builder: (context, state) => const OpeningStockImportScreen(),
    ),
    GoRoute(
      path: Routes.inventory,
      builder: (context, state) =>
          const Scaffold(body: Center(child: Text(inventoryStubText))),
    ),
  ],
);

/// A profile for the signed-in user, with [role] and a pharmacy.
Profile buildProfile({AppRole role = AppRole.owner}) => Profile(
  id: 'profile-1',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  pharmacyId: 'ph-1',
  fullName: 'Rohit',
  role: role,
);

/// Pumps the import screen (or the settings screen above it) and settles.
///
/// The window is made tall before anything is pumped: the screen is a column of
/// a summary card, a refusal list and a table, and a widget below the fold would
/// otherwise be missing rather than merely off-screen.
Future<GoRouter> pumpOpeningStockApp(
  WidgetTester tester, {
  required FakeOpeningStockRepository repository,
  FakeOpeningStockFilePicker? picker,
  FakeOpeningStockCsvSaver? saver,
  Profile? profile,
  String initialLocation = Routes.openingStockImport,
  Size size = const Size(1200, 2000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = openingStockTestRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      // Left untyped on purpose: `Override` is declared in `riverpod`, which
      // `flutter_riverpod` does not re-export (D-015 notes).
      overrides: [
        openingStockRepositoryProvider.overrideWithValue(repository),
        openingStockFilePickerProvider.overrideWithValue(
          picker ?? FakeOpeningStockFilePicker(),
        ),
        openingStockCsvSaverProvider.overrideWithValue(
          saver ?? FakeOpeningStockCsvSaver(),
        ),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
        profileStateProvider.overrideWith(
          (ref) => AsyncValue<Profile?>.data(profile ?? buildProfile()),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
