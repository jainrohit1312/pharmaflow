/// A router and pump helper for the sales screens.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/customers/application/customer_options.dart';
import 'package:app/features/customers/application/patient_lookup.dart';
import 'package:app/features/customers/data/patients_repository.dart';
import 'package:app/features/products/application/product_categories.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/doctor_options.dart';
import 'package:app/features/sales/application/pos_search.dart';
import 'package:app/features/sales/application/sale_tax_split.dart';
import 'package:app/features/sales/application/sellable_batches_controller.dart';
import 'package:app/features/sales/data/doctors_repository.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:app/features/sales/presentation/pos_screen.dart';
import 'package:app/features/sales/presentation/sales_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_doctors_repository.dart';
import 'fake_patients_repository.dart';
import 'fake_products_repository.dart';
import 'fake_sales_repository.dart';

/// A router carrying the sales list and the counter.
///
/// The real router is unreachable in a test - it reads a Supabase session while it
/// builds - so the navigation these screens perform (`context.go`) is exercised
/// against this instead. The declaration order mirrors `app_router.dart`, where
/// `/sales/new` has to come before `/sales/:saleId`.
///
/// The bill the counter opens after a write is a stub on purpose: `sale_detail_
/// screen.dart` has its own reads and is not what these tests are about, and a
/// test that had to stand up its providers to check where the counter navigated
/// would be testing the wrong screen.
GoRouter salesTestRouter({String initialLocation = Routes.sales}) => GoRouter(
  initialLocation: initialLocation,
  routes: <RouteBase>[
    GoRoute(
      path: Routes.sales,
      builder: (context, state) => const SalesScreen(),
    ),
    GoRoute(path: Routes.pos, builder: (context, state) => const PosScreen()),
    GoRoute(
      path: Routes.saleDetailPattern,
      builder: (context, state) =>
          Scaffold(body: Text('bill ${state.pathParameters['saleId']}')),
    ),
  ],
);

/// Pumps a sales screen over [repository] and lets the first load settle.
///
/// The test window is made tall before anything is pumped, for the same reason as
/// the purchase helper: these screens are long, and a `SliverList` only mounts the
/// children inside its viewport, so an assertion about something below the fold
/// would find nothing at all rather than something merely off-screen.
///
/// The counter reads things that belong to other features - the product search, the
/// sellable batches of a product, the patients and the accounts a bill may be put on,
/// the prescribers, and the tax split - so all of them are stubbed here rather than
/// left to reach a real repository. The patient and prescriber stubs answer through
/// their fakes, so a test drives the same filtering a real read would.
Future<GoRouter> pumpSalesApp(
  WidgetTester tester, {
  required FakeSalesRepository repository,
  FakeProductsRepository? products,
  FakePatientsRepository? patients,
  FakeDoctorsRepository? doctors,
  List<Product> searchResults = const <Product>[],
  List<BatchStatus> batches = const <BatchStatus>[],
  List<String> categories = const <String>[],
  bool failCategories = false,
  List<Customer> customers = const <Customer>[],
  String initialLocation = Routes.sales,
  Size size = const Size(1200, 4000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = salesTestRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);

  final patientRepository =
      patients ?? FakePatientsRepository(patients: customers);
  final doctorRepository = doctors ?? FakeDoctorsRepository();

  await tester.pumpWidget(
    ProviderScope(
      // The list is left untyped on purpose: `Override` is declared in
      // `riverpod`, which `flutter_riverpod` does not re-export, so naming the
      // element type would need an extra import for no benefit (D-015 notes).
      overrides: [
        salesRepositoryProvider.overrideWithValue(repository),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
        posListProvider.overrideWith(
          // Every key answers the same fixtures: these tests use one product and one
          // batch, and a hit's product id need not match the batch's - the flat
          // override is the point, the same way the batch chooser's
          // `sellableBatchesProvider` override works. A test that needs a tab to
          // answer differently drives the repository instead.
          (ref, key) async => <PosSearchHit>[
            for (final product in searchResults)
              PosSearchHit(product: product, batches: batches),
          ],
        ),
        productCategoriesProvider.overrideWith((ref) async {
          if (failCategories) {
            throw StateError('the fake was told to fail');
          }
          return categories;
        }),
        sellableBatchesProvider.overrideWith((ref, productId) async => batches),
        customerOptionsProvider.overrideWith((ref) async => customers),
        patientsRepositoryProvider.overrideWithValue(patientRepository),
        doctorsRepositoryProvider.overrideWithValue(doctorRepository),
        patientSearchProvider.overrideWith(
          (ref, term) => patientRepository.search(term: term),
        ),
        recentPatientsProvider.overrideWith(
          (ref) => patientRepository.recent(pharmacyId: 'ph-1'),
        ),
        patientAdmissionsProvider.overrideWith(
          (ref, patientId) =>
              patientRepository.admissionsFor(patientId: patientId),
        ),
        doctorOptionsProvider.overrideWith(
          (ref) => doctorRepository.list(pharmacyId: 'ph-1'),
        ),
        saleTaxSplitProvider.overrideWith(
          (ref, placeOfSupply) => TaxSplit.intraState,
        ),
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
