/// A router and pump helper for the purchase screens.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/approvals/data/approvals_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/purchase/application/purchase_tax_split.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:app/features/purchase/presentation/grn_screen.dart';
import 'package:app/features/purchase/presentation/purchase_detail_screen.dart';
import 'package:app/features/purchase/presentation/purchase_form_screen.dart';
import 'package:app/features/purchase/presentation/purchases_screen.dart';
import 'package:app/features/purchase_ocr/data/bill_picker.dart';
import 'package:app/features/purchase_ocr/data/purchase_ocr_repository.dart';
import 'package:app/features/purchase_ocr/presentation/purchase_ocr_screen.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_approvals_repository.dart';
import 'fake_bill_picker.dart';
import 'fake_products_repository.dart';
import 'fake_purchase_ocr_repository.dart';
import 'fake_purchases_repository.dart';

/// A router carrying only the purchase screens.
///
/// The real router is unreachable in a test - it reads a Supabase session while
/// it builds - so the navigation each screen performs (`context.go`) is exercised
/// against this instead. The paths and their declaration order mirror
/// `app_router.dart`, which is what makes the two literal-before-parameterised
/// routes (`/purchase/grn`, `/purchase/new`) worth having here at all.
GoRouter purchaseTestRouter({
  String initialLocation = Routes.purchase,
}) => GoRouter(
  initialLocation: initialLocation,
  routes: <RouteBase>[
    GoRoute(
      path: Routes.purchase,
      builder: (context, state) => const PurchasesScreen(),
    ),
    GoRoute(
      path: Routes.purchaseOcr,
      builder: (context, state) => const PurchaseOcrScreen(),
    ),
    GoRoute(
      path: Routes.purchaseGrnForm,
      builder: (context, state) => const GrnScreen(),
    ),
    GoRoute(
      path: Routes.purchaseForm,
      builder: (context, state) => const PurchaseFormScreen(),
    ),
    GoRoute(
      path: Routes.purchaseEditPattern,
      builder: (context, state) =>
          PurchaseFormScreen(purchaseId: state.pathParameters['purchaseId']),
    ),
    GoRoute(
      path: Routes.purchaseGrnPattern,
      builder: (context, state) =>
          GrnScreen(purchaseId: state.pathParameters['purchaseId']),
    ),
    GoRoute(
      path: Routes.purchaseDetailPattern,
      builder: (context, state) =>
          PurchaseDetailScreen(purchaseId: state.pathParameters['purchaseId']!),
    ),
  ],
);

/// Pumps the purchase screens over [repository] and lets the first load settle.
///
/// The test window is made tall before anything is pumped. The purchase screens
/// are long, and a `SliverList` only mounts the children that fall inside the
/// viewport, so an assertion about a field below the fold would otherwise find
/// nothing at all rather than something merely off-screen. A window this tall
/// keeps the assertions about content, not about scroll position.
///
/// [products] is only needed by a test that drives the product picker, which
/// reads the catalogue through the products repository rather than through
/// anything the purchase feature owns.
///
/// [approvals] is what a document that is **waiting** for the owner reads to say what
/// is waiting: the detail screen's card shows the ask itself. It defaults to an empty
/// fake rather than the real repository, so a test that never stages a document does not
/// reach a Supabase client when it happens to render one.
Future<GoRouter> pumpPurchaseApp(
  WidgetTester tester, {
  required FakePurchasesRepository repository,
  List<Supplier> suppliers = const <Supplier>[],
  FakeProductsRepository? products,
  FakeApprovalsRepository? approvals,
  String initialLocation = Routes.purchase,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = purchaseTestRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      // The list is left untyped on purpose: `Override` is declared in
      // `riverpod`, which `flutter_riverpod` does not re-export, so naming the
      // element type would need an extra import for no benefit (D-015 notes).
      overrides: [
        purchasesRepositoryProvider.overrideWithValue(repository),
        approvalsRepositoryProvider.overrideWithValue(
          approvals ?? FakeApprovalsRepository(),
        ),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
        supplierOptionsProvider.overrideWith((ref) async => suppliers),
        purchaseTaxSplitProvider.overrideWith(
          (ref, supplierId) => TaxSplit.intraState,
        ),
        // The purchase screen now offers the bill reader, so a test that taps
        // that action builds the OCR screen: both of its seams are faked here
        // rather than left to reach `Supabase.instance` and a real file dialog.
        purchaseOcrRepositoryProvider.overrideWithValue(
          FakePurchaseOcrRepository(),
        ),
        billPickerProvider.overrideWithValue(FakeBillPicker()),
        if (products != null)
          productsRepositoryProvider.overrideWithValue(products),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// Scrolls [finder] into view, then taps it.
///
/// The purchase screens are long scrolling forms, and the buttons that submit
/// them sit below the fold on a test-sized window; an un-scrolled `tap` would
/// either miss or hit whatever is at that offset.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
