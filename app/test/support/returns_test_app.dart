/// A router and pump helper for the purchase returns screens.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:app/features/purchase/presentation/purchase_detail_screen.dart';
import 'package:app/features/returns/data/purchase_returns_repository.dart';
import 'package:app/features/returns/presentation/purchase_return_detail_screen.dart';
import 'package:app/features/returns/presentation/purchase_return_form_screen.dart';
import 'package:app/features/returns/presentation/returns_screen.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_purchase_returns_repository.dart';
import 'fake_purchases_repository.dart';
// Narrowed on purpose: both fakes declare a `buildSupplier`, and the purchase
// one is the builder this harness's fixtures come from.
import 'fake_suppliers_repository.dart' show FakeSuppliersRepository;

/// A router carrying the returns screens and the purchase detail they link to.
///
/// The real router is unreachable in a test - it reads a Supabase session while
/// it builds - so the navigation these screens perform (`context.go`) is
/// exercised against this instead. The paths and their declaration order mirror
/// `app_router.dart`, which is what makes `/returns/new` worth having here.
GoRouter returnsTestRouter({String initialLocation = Routes.returns}) =>
    GoRouter(
      initialLocation: initialLocation,
      routes: <RouteBase>[
        GoRoute(
          path: Routes.returns,
          builder: (context, state) => const ReturnsScreen(),
        ),
        GoRoute(
          path: Routes.returnsForm,
          builder: (context, state) => const PurchaseReturnFormScreen(),
        ),
        GoRoute(
          path: Routes.returnsDetailPattern,
          builder: (context, state) => PurchaseReturnDetailScreen(
            returnId: state.pathParameters['returnId']!,
          ),
        ),
        GoRoute(
          path: Routes.purchaseDetailPattern,
          builder: (context, state) => PurchaseDetailScreen(
            purchaseId: state.pathParameters['purchaseId']!,
          ),
        ),
      ],
    );

/// Pumps the returns screens over the two repositories and settles the first load.
///
/// [purchases] is the purchase repository the form reads its invoice list from and
/// the detail screen reads its source invoice from; it is a separate fake because
/// it is a separate repository.
Future<GoRouter> pumpReturnsApp(
  WidgetTester tester, {
  required FakePurchaseReturnsRepository repository,
  required FakePurchasesRepository purchases,
  List<Supplier> suppliers = const <Supplier>[],
  String initialLocation = Routes.returns,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = returnsTestRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      // The list is left untyped on purpose: `Override` is declared in
      // `riverpod`, which `flutter_riverpod` does not re-export, so naming the
      // element type would need an extra import for no benefit (D-015 notes).
      overrides: [
        purchaseReturnsRepositoryProvider.overrideWithValue(repository),
        purchasesRepositoryProvider.overrideWithValue(purchases),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
        supplierOptionsProvider.overrideWith((ref) async => suppliers),
        // The picker resolves a typed term against supplier *names* (I-3), which
        // is a second call to the same repository the options above come from - so
        // it is the same list behind both, and a term that matches a supplier here
        // matches it there.
        suppliersRepositoryProvider.overrideWithValue(
          FakeSuppliersRepository(suppliers: List<Supplier>.of(suppliers)),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
