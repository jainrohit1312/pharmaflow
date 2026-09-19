/// Widget tests for the purchase picker: the search, the pages and the states.
///
/// The two things this file exists for are the ones a controller test cannot
/// show: what a *failed* search looks like next to an empty one (T-5), and that a
/// row the user taps becomes the field's own label rather than a lookup into
/// whatever list happened to be loaded (I-3).
library;

import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:app/features/returns/presentation/widgets/purchase_picker_field.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:app/features/suppliers/data/suppliers_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_purchases_repository.dart';
import '../../../../support/fake_suppliers_repository.dart'
    show FakeSuppliersRepository;

/// A host that keeps the chosen purchase, the way a form does.
class _PickerHost extends StatefulWidget {
  const _PickerHost();

  @override
  State<_PickerHost> createState() => _PickerHostState();
}

class _PickerHostState extends State<_PickerHost> {
  Purchase? _chosen;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: PurchasePickerField(
        selected: _chosen,
        // What the return form resolves from the supplier options for the
        // invoice it is holding.
        selectedSupplierName: _chosen == null ? null : 'Arihant Distributors',
        onSelected: (purchase) => setState(() => _chosen = purchase),
      ),
    ),
  );
}

/// [count] received invoices, `INV-1` … `INV-<count>`, newest first.
List<Purchase> _received(int count) => <Purchase>[
  for (var index = 1; index <= count; index++)
    buildPurchase(
      id: 'purchase-$index',
      invoiceNo: 'INV-$index',
      status: PurchaseStatus.received,
    ).copyWith(
      invoiceDate: DateTime(2026, 6, 30).subtract(Duration(days: index)),
    ),
];

/// Pumps the picker over [purchases] and [suppliers].
Future<void> pumpPicker(
  WidgetTester tester, {
  required FakePurchasesRepository purchases,
  List<Supplier> suppliers = const <Supplier>[],
}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchasesRepositoryProvider.overrideWithValue(purchases),
        suppliersRepositoryProvider.overrideWithValue(
          FakeSuppliersRepository(suppliers: List<Supplier>.of(suppliers)),
        ),
        supplierOptionsProvider.overrideWith((ref) async => suppliers),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      ],
      child: const MaterialApp(home: _PickerHost()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the search sheet.
Future<void> openSheet(WidgetTester tester) async {
  await tester.tap(find.byType(PurchasePickerField));
  await tester.pumpAndSettle();
}

/// Types [term] into the search box and lets the debounce fire.
Future<void> searchFor(WidgetTester tester, String term) async {
  await tester.enterText(find.byType(TextField), term);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('prompts for an invoice before one is chosen', (tester) async {
    await pumpPicker(
      tester,
      purchases: FakePurchasesRepository(purchases: _received(3)),
    );

    expect(find.text('Search received invoices'), findsOneWidget);
    expect(find.text('Choose a purchase'), findsOneWidget);
  });

  testWidgets('names the chosen invoice and the supplier it came from', (
    tester,
  ) async {
    await pumpPicker(
      tester,
      purchases: FakePurchasesRepository(purchases: _received(3)),
      suppliers: <Supplier>[buildSupplier()],
    );

    await openSheet(tester);

    expect(find.text('Find a received invoice'), findsOneWidget);
    expect(
      find.text('Arihant Distributors'),
      findsNWidgets(3),
      reason:
          'every row names who the invoice came from - a list of invoice numbers '
          'with no distributor on it is a list nobody can scan',
    );

    await tester.tap(find.text('INV-1 · 29 Jun 2026'));
    await tester.pumpAndSettle();

    expect(
      find.text('INV-1 · 29 Jun 2026 · Arihant Distributors'),
      findsOneWidget,
      reason:
          'the field carries the choice rather than looking it up in a list it '
          'happens to hold - the old dropdown called a chosen invoice "Another '
          'purchase" whenever the list had moved on',
    );
    expect(find.text('Choose a purchase'), findsNothing);
  });

  testWidgets('says nothing matched, which is not the same as nothing there', (
    tester,
  ) async {
    await pumpPicker(
      tester,
      purchases: FakePurchasesRepository(purchases: _received(3)),
      suppliers: <Supplier>[buildSupplier()],
    );

    await openSheet(tester);
    await searchFor(tester, 'nothing-like-this');

    expect(find.text('No invoice matches this search.'), findsOneWidget);
    expect(
      find.textContaining('No received purchases yet'),
      findsNothing,
      reason: 'the pharmacy has three invoices; the search simply missed them',
    );
  });

  testWidgets('says there is nothing to return against, when there is not', (
    tester,
  ) async {
    await pumpPicker(
      tester,
      purchases: FakePurchasesRepository(purchases: <Purchase>[]),
    );

    await openSheet(tester);

    expect(
      find.textContaining('No received purchases yet'),
      findsOneWidget,
      reason:
          'a blank list has to say whether it is empty or the search missed - '
          'the two need different words (T-5)',
    );
  });

  testWidgets('finds an invoice by its number', (tester) async {
    await pumpPicker(
      tester,
      purchases: FakePurchasesRepository(purchases: _received(45)),
    );

    await openSheet(tester);

    // The first page holds INV-1 … INV-20. This one is on page three.
    await searchFor(tester, 'INV-31');

    expect(find.text('INV-31 · 30 May 2026'), findsOneWidget);
    expect(find.text('INV-20 · 10 Jun 2026'), findsNothing);
  });

  testWidgets("finds invoices by the distributor's name", (tester) async {
    await pumpPicker(
      tester,
      purchases: FakePurchasesRepository(purchases: _received(3)),
      suppliers: <Supplier>[buildSupplier()],
    );

    await openSheet(tester);
    await searchFor(tester, 'arihant');

    expect(
      find.text('INV-1 · 29 Jun 2026'),
      findsOneWidget,
      reason:
          'no invoice number contains "arihant" - one box covers the number, the '
          'notes and who the bill came from',
    );
  });

  testWidgets('offers the next page, and appends it', (tester) async {
    await pumpPicker(
      tester,
      purchases: FakePurchasesRepository(purchases: _received(25)),
    );

    await openSheet(tester);

    expect(find.text('INV-21 · 09 Jun 2026'), findsNothing);

    // The tile is under the twentieth row, which is under the fold - as it is for
    // a user, who scrolls to the end of a page to ask for the next one.
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();

    expect(find.text('INV-21 · 09 Jun 2026'), findsOneWidget);
    expect(
      find.text('Load more'),
      findsNothing,
      reason: 'a short page is the end of the list',
    );
  });

  testWidgets('a failed search is its own state, with its own retry', (
    tester,
  ) async {
    final purchases = FakePurchasesRepository(purchases: _received(3));
    await pumpPicker(tester, purchases: purchases);

    await openSheet(tester);
    expect(find.text('INV-1 · 29 Jun 2026'), findsOneWidget);

    purchases.failNextList = true;
    await tester.enterText(find.byType(TextField), 'INV-1');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('Could not search the invoices.'), findsOneWidget);
    expect(
      find.text('No invoice matches this search.'),
      findsNothing,
      reason: 'a failure that reads as an empty result is a lie about the data',
    );

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('INV-1 · 29 Jun 2026'), findsOneWidget);
  });

  testWidgets('narrows the list to a date range', (tester) async {
    final purchases = FakePurchasesRepository(purchases: _received(3));
    await pumpPicker(tester, purchases: purchases);

    await openSheet(tester);
    expect(find.text('All dates'), findsOneWidget);

    await tester.tap(find.text('All dates'));
    await tester.pumpAndSettle();
    // The picker opens on the month of the fixture dates' year, with both ends
    // tapped in it - which is all this test needs from Material's own calendar.
    await tester.tap(find.text('10').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('20').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('All dates'), findsNothing);
    expect(
      purchases.lastQuery?.from,
      isNotNull,
      reason: 'the window reaches the query, not only the button',
    );
    expect(purchases.lastQuery?.to, isNotNull);
  });
}
