/// A router and pump helper for the inventory screens.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/inventory/data/inventory_repository.dart';
import 'package:app/features/inventory/presentation/expiry_calendar_screen.dart';
import 'package:app/features/inventory/presentation/inventory_screen.dart';
import 'package:app/features/products/presentation/products_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_inventory_repository.dart';

/// A router carrying the inventory screens and the one product screen they can
/// navigate to.
///
/// The real router is unreachable in a test - it reads a Supabase session while
/// it builds - so the navigation these screens perform (`context.go`) is
/// exercised against this instead.
GoRouter inventoryTestRouter({String initialLocation = Routes.inventory}) =>
    GoRouter(
      initialLocation: initialLocation,
      routes: <RouteBase>[
        GoRoute(
          path: Routes.inventory,
          builder: (context, state) => const InventoryScreen(),
        ),
        GoRoute(
          path: Routes.inventoryCalendar,
          builder: (context, state) => const ExpiryCalendarScreen(),
        ),
        GoRoute(
          path: Routes.productDetailPattern,
          builder: (context, state) => ProductsDetailScreen(
            productId: state.pathParameters['productId']!,
          ),
        ),
      ],
    );

/// Pumps the inventory screens over [repository] and lets the first load settle.
///
/// The test window is made tall before anything is pumped, for the same reason as
/// the purchase helper: these screens are long, and a cell below the fold would
/// otherwise be missing rather than merely off-screen.
Future<GoRouter> pumpInventoryApp(
  WidgetTester tester, {
  required FakeInventoryRepository repository,
  String initialLocation = Routes.inventory,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = inventoryTestRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      // The list is left untyped on purpose: `Override` is declared in
      // `riverpod`, which `flutter_riverpod` does not re-export, so naming the
      // element type would need an extra import for no benefit (D-015 notes).
      overrides: [
        inventoryRepositoryProvider.overrideWithValue(repository),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
