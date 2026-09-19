/// A router and pump helper for the OCR screen.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/purchase/application/purchase_tax_split.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:app/features/purchase/presentation/purchase_detail_screen.dart';
import 'package:app/features/purchase_ocr/application/purchase_ocr_controller.dart';
import 'package:app/features/purchase_ocr/data/bill_picker.dart';
import 'package:app/features/purchase_ocr/data/purchase_ocr_repository.dart';
import 'package:app/features/purchase_ocr/presentation/purchase_ocr_screen.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_bill_picker.dart';
import 'fake_products_repository.dart';
import 'fake_purchase_ocr_repository.dart';
import 'fake_purchases_repository.dart';

/// A router carrying the OCR screen and the screen its save hands off to.
///
/// The detail route is here because the save ends at
/// `Routes.purchaseDetail(saved.id)`: without it, a test of the save would be
/// asserting that navigation failed.
GoRouter purchaseOcrTestRouter({String initialLocation = Routes.purchaseOcr}) =>
    GoRouter(
      initialLocation: initialLocation,
      routes: <RouteBase>[
        GoRoute(
          path: Routes.purchaseOcr,
          builder: (context, state) => const PurchaseOcrScreen(),
        ),
        GoRoute(
          path: Routes.purchaseDetailPattern,
          builder: (context, state) => PurchaseDetailScreen(
            purchaseId: state.pathParameters['purchaseId']!,
          ),
        ),
      ],
    );

/// Pumps the OCR screen over [scanner] and lets the first frame settle.
///
/// [retryDelay] is what the controller waits before its one automatic retry; the
/// default here is zero so a test that only cares about the outcome is not kept
/// waiting, and a test that wants to *see* the retry passes something it can pump
/// through.
Future<GoRouter> pumpPurchaseOcrApp(
  WidgetTester tester, {
  required FakePurchaseOcrRepository scanner,
  BillPicker? picker,
  FakePurchasesRepository? purchases,
  List<Supplier> suppliers = const <Supplier>[],
  FakeProductsRepository? products,
  Duration retryDelay = Duration.zero,
  String initialLocation = Routes.purchaseOcr,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = purchaseOcrTestRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchaseOcrRepositoryProvider.overrideWithValue(scanner),
        billPickerProvider.overrideWithValue(picker ?? FakeBillPicker()),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
        ocrRetryDelayProvider.overrideWith((ref) => retryDelay),
        supplierOptionsProvider.overrideWith((ref) async => suppliers),
        purchaseTaxSplitProvider.overrideWith(
          (ref, supplierId) => TaxSplit.intraState,
        ),
        if (purchases != null)
          purchasesRepositoryProvider.overrideWithValue(purchases),
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
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
