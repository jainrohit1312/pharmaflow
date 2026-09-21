/// A router and pump helper for the bill screen.
///
/// Separate from `sales_test_app.dart` on purpose: that harness stubs
/// `/sales/:saleId` with a text placeholder, because the list and counter tests
/// navigate *to* a bill without being about one. This one stands the real screen
/// up, which is a different set of providers.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/pharmacy.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/repositories/pharmacy_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/balances/data/balances_repository.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/sale_detail_controller.dart';
import 'package:app/features/sales/application/sale_tax_split.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:app/features/sales/presentation/sale_detail_screen.dart';
import 'package:app/services/invoice_printer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_balances_repository.dart';
import 'fake_products_repository.dart';
import 'fake_sales_repository.dart';

/// A printer that records the bill instead of handing it to a platform.
///
/// The real `printReceipt` opens the print sheet, which a widget test cannot drive -
/// and the provider exists so that a test can replace it (the class doc says so).
/// Recording the *sheet* rather than the arguments is what makes the assertion about
/// what would have printed rather than about which method was called.
class FakeInvoicePrinter extends InvoicePrinter {
  /// Creates a fake that prints everything, or throws [error] every time.
  FakeInvoicePrinter({this.error});

  /// The bills it was handed, in order.
  final List<InvoiceSheet> sheets = <InvoiceSheet>[];

  /// The pharmacy each of those bills was headed with.
  final List<Pharmacy?> pharmacies = <Pharmacy?>[];

  /// When set, every print throws it.
  final Exception? error;

  @override
  Future<void> printReceipt({
    required SaleDetailData data,
    required Pharmacy? pharmacy,
    TaxSplit split = TaxSplit.intraState,
  }) async {
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    sheets.add(buildSheet(data: data, pharmacy: pharmacy, split: split));
    pharmacies.add(pharmacy);
  }
}

/// A pharmacy repository answering with one row, or nothing.
class FakePharmacyRepository implements PharmacyRepository {
  /// Creates a fake over [pharmacy].
  FakePharmacyRepository({this.pharmacy});

  /// The row every `byId` returns.
  final Pharmacy? pharmacy;

  @override
  Future<Pharmacy?> byId(String pharmacyId) async => pharmacy;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}

/// The bill screen, at the route a sale opens at.
GoRouter saleDetailTestRouter({String saleId = 'sale-1'}) => GoRouter(
  initialLocation: Routes.saleDetail(saleId),
  routes: <RouteBase>[
    GoRoute(
      path: Routes.saleDetailPattern,
      builder: (context, state) =>
          SaleDetailScreen(saleId: state.pathParameters['saleId']!),
    ),
  ],
);

/// Pumps the bill screen over [repository] and lets the first load settle.
///
/// [split] is what the tax-head label reads: `saleTaxSplitProvider` asks the
/// pharmacy repository for a state and the supplier's for another, neither of which
/// this screen is about, so it is answered here the way the counter's harness does.
///
/// The printer is always replaced, even by a test that never taps print: a widget
/// test that reached the real one would open a platform print sheet.
Future<GoRouter> pumpSaleDetailApp(
  WidgetTester tester, {
  required FakeSalesRepository repository,
  FakeProductsRepository? products,
  FakePharmacyRepository? pharmacy,
  FakeBalancesRepository? balances,
  FakeInvoicePrinter? printer,
  TaxSplit split = TaxSplit.intraState,
  String saleId = 'sale-1',
  Size size = const Size(1000, 3000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = saleDetailTestRouter(saleId: saleId);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      // The list is left untyped on purpose: `Override` is declared in `riverpod`,
      // which `flutter_riverpod` does not re-export (D-015 notes).
      overrides: [
        salesRepositoryProvider.overrideWithValue(repository),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
        saleTaxSplitProvider.overrideWith((ref, placeOfSupply) => split),
        invoicePrinterProvider.overrideWithValue(
          printer ?? FakeInvoicePrinter(),
        ),
        pharmacyRepositoryProvider.overrideWithValue(
          pharmacy ?? FakePharmacyRepository(),
        ),
        productsRepositoryProvider.overrideWithValue(
          products ?? FakeProductsRepository(products: const <Product>[]),
        ),
        // The bill shows what has been applied to it, which is a server aggregate. Left
        // unstubbed it would reach a real client, and the card would render its own
        // error - which is how a screen can read a live repository in a test without
        // failing, and is exactly what this override is for.
        balancesRepositoryProvider.overrideWithValue(
          balances ?? FakeBalancesRepository(),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// A pharmacy to head a bill with.
Pharmacy buildPharmacy() => Pharmacy(
  id: 'ph-1',
  name: 'Sunrise Medicals',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  city: 'Pune',
  gstin: '27AAAAA0000A1Z5',
);
