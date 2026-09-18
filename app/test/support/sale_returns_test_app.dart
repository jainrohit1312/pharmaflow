/// A router and pump helper for the sale returns screens.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/returns/data/sale_returns_repository.dart';
import 'package:app/features/returns/presentation/sale_return_form_screen.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_products_repository.dart';
import 'fake_sale_returns_repository.dart';
import 'fake_sales_repository.dart';

/// A router carrying the sale return form and the bill it opens afterwards.
///
/// The real router is unreachable in a test - it reads a Supabase session while it
/// builds - so the navigation the form performs (`context.go`) is exercised
/// against this instead. The paths and their declaration order mirror
/// `app_router.dart`, where `/returns/sale/new` sits after `/returns/new` and
/// before the parameterised `/returns/:returnId`.
///
/// The bill the form opens after a write is a stub on purpose: `sale_detail_
/// screen.dart` has its own reads and is not what these tests are about, and a
/// test that had to stand up its providers to check where the form navigated
/// would be testing the wrong screen.
GoRouter saleReturnsTestRouter({
  String initialLocation = Routes.saleReturnForm,
}) => GoRouter(
  initialLocation: initialLocation,
  routes: <RouteBase>[
    GoRoute(
      path: Routes.saleReturnForm,
      builder: (context, state) => const SaleReturnFormScreen(),
    ),
    GoRoute(
      path: Routes.saleDetailPattern,
      builder: (context, state) =>
          Scaffold(body: Text('Bill ${state.pathParameters['saleId']}')),
    ),
  ],
);

/// Pumps the sale return form over [repository] and settles the first load.
///
/// The test window is made tall before anything is pumped. The form is a
/// `ListView`, which only mounts the children that fall inside the viewport, so an
/// assertion about a field below the fold would otherwise find nothing at all
/// rather than something merely off-screen. A window this tall keeps the
/// assertions about content, not about scroll position.
///
/// [sales] is a separate fake because it is a separate repository: the form's bill
/// picker reads the sales list through `salesRepositoryProvider`, while the returns
/// repository reads the bill it is crediting itself.
Future<GoRouter> pumpSaleReturnApp(
  WidgetTester tester, {
  required FakeSaleReturnsRepository repository,
  required FakeSalesRepository sales,
  FakeProductsRepository? products,
  String initialLocation = Routes.saleReturnForm,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = saleReturnsTestRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      // The list is left untyped on purpose: `Override` is declared in
      // `riverpod`, which `flutter_riverpod` does not re-export, so naming the
      // element type would need an extra import for no benefit (D-015 notes).
      overrides: [
        saleReturnsRepositoryProvider.overrideWithValue(repository),
        salesRepositoryProvider.overrideWithValue(sales),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
        productsRepositoryProvider.overrideWithValue(
          products ?? FakeProductsRepository(products: const <Product>[]),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
