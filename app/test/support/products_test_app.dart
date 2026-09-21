/// A router and pump helper for the catalogue screens.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/products/presentation/products_detail_screen.dart';
import 'package:app/features/products/presentation/products_form_screen.dart';
import 'package:app/features/products/presentation/products_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_products_repository.dart';

/// A router carrying the catalogue screens.
///
/// The real router is unreachable in a test - it reads a Supabase session while it builds - so the
/// navigation these screens perform (`context.go`) is exercised against this instead. The paths and
/// their declaration order mirror `app_router.dart`, which is what makes `/products/new` worth
/// having here: GoRouter matches in declaration order, so it has to precede the detail pattern.
GoRouter productsTestRouter({String initialLocation = Routes.products}) =>
    GoRouter(
      initialLocation: initialLocation,
      routes: <RouteBase>[
        GoRoute(
          path: Routes.products,
          builder: (context, state) => const ProductsScreen(),
        ),
        GoRoute(
          path: Routes.productForm,
          builder: (context, state) => const ProductsFormScreen(),
        ),
        GoRoute(
          path: Routes.productEditPattern,
          builder: (context, state) =>
              ProductsFormScreen(productId: state.pathParameters['productId']),
        ),
        GoRoute(
          path: Routes.productDetailPattern,
          builder: (context, state) => ProductsDetailScreen(
            productId: state.pathParameters['productId']!,
          ),
        ),
      ],
    );

/// Pumps the catalogue screens over [repository] and settles the first load.
///
/// A wide window on purpose: these screens carry tables and a form, and a phone-sized
/// surface would make `ensureVisible` the subject of the test.
Future<GoRouter> pumpProductsApp(
  WidgetTester tester, {
  required FakeProductsRepository repository,
  String initialLocation = Routes.products,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = productsTestRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      // The list is left untyped on purpose: `Override` is declared in `riverpod`, which
      // `flutter_riverpod` does not re-export, so naming the element type would need an extra
      // import for no benefit (D-015 notes).
      overrides: [
        productsRepositoryProvider.overrideWithValue(repository),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
