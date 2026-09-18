/// Tests for the sales list.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/sales/presentation/widgets/sale_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_customers_repository.dart';
import '../../../support/fake_sales_repository.dart';
import '../../../support/sales_test_app.dart';

/// Two sales: one settled for a named customer, one on credit for a walk-in.
List<Sale> _sales() => <Sale>[
  buildSale(
    invoiceNo: 'INV-7',
    customerId: 'id-Ravi Kumar',
    subTotal: 1000,
    taxTotal: 120,
    grandTotal: 1120,
    amountPaid: 1120,
  ),
  buildSale(
    id: 'sale-2',
    invoiceNo: 'INV-8',
    status: SaleStatus.credit,
    grandTotal: 800,
    amountPaid: 300,
    balanceDue: 500,
    saleDate: DateTime(2026, 9, 17, 14, 5),
  ),
];

/// A status badge inside a sale's card.
///
/// Scoped to the card because the filter chips carry the same labels.
Finder _badgeIn(String invoiceNo, String label) => find.descendant(
  of: find.widgetWithText(SaleCard, invoiceNo),
  matching: find.text(label),
);

void main() {
  testWidgets('says so when nothing has been sold', (tester) async {
    await pumpSalesApp(tester, repository: FakeSalesRepository());

    expect(find.text('Sales'), findsOneWidget);
    expect(find.text('No sales found'), findsOneWidget);
    expect(find.text('Ring up the first sale at the counter.'), findsOneWidget);
    expect(
      find.widgetWithText(FloatingActionButton, 'New sale'),
      findsOneWidget,
      reason: 'the counter is the only way out of an empty list',
    );
  });

  testWidgets('lists what was sold, newest first', (tester) async {
    final repository = FakeSalesRepository(sales: _sales());
    await pumpSalesApp(
      tester,
      repository: repository,
      customers: <Customer>[buildCustomer('Ravi Kumar')],
    );

    expect(find.byType(SaleCard), findsNWidgets(2));
    expect(find.text('INV-7'), findsOneWidget);
    expect(find.text('INV-8'), findsOneWidget);
    // The customer is stored by id and resolved for the card; a sale with nobody
    // on it is a walk-in.
    expect(find.textContaining('Ravi Kumar'), findsOneWidget);
    expect(find.textContaining('Walk-in'), findsOneWidget);
    // What each bill came to.
    expect(find.text(Formatters.currency(1120)), findsOneWidget);
    expect(find.text(Formatters.currency(800)), findsOneWidget);
    // And what is still owed on the credit sale, which the settled one has none of.
    expect(find.text('${Formatters.currency(500)} due'), findsOneWidget);
    expect(_badgeIn('INV-7', SaleStatus.completed.label), findsOneWidget);
    expect(_badgeIn('INV-8', SaleStatus.credit.label), findsOneWidget);
    expect(repository.requestedOffsets, <int>[0]);
  });

  testWidgets('narrows to a matching invoice number', (tester) async {
    final repository = FakeSalesRepository(sales: _sales());
    await pumpSalesApp(tester, repository: repository);

    expect(find.byType(SaleCard), findsNWidgets(2));

    await tester.enterText(find.byType(TextField), 'INV-8');
    // The search is applied once the user stops typing, not on every keystroke.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(repository.lastQuery?.search, 'INV-8');
    // Scoped to the cards: `find.text` also matches the term the search field is
    // holding.
    expect(find.widgetWithText(SaleCard, 'INV-8'), findsOneWidget);
    expect(find.widgetWithText(SaleCard, 'INV-7'), findsNothing);
  });

  testWidgets('restricts the list to one status', (tester) async {
    final repository = FakeSalesRepository(sales: _sales());
    await pumpSalesApp(tester, repository: repository);

    await tester.tap(find.widgetWithText(ChoiceChip, SaleStatus.credit.label));
    await tester.pumpAndSettle();

    expect(repository.lastQuery?.status, SaleStatus.credit);
    expect(find.text('INV-8'), findsOneWidget);
    expect(find.text('INV-7'), findsNothing);
  });

  testWidgets('says nothing matches when a filter excludes everything', (
    tester,
  ) async {
    final repository = FakeSalesRepository(sales: _sales());
    await pumpSalesApp(tester, repository: repository);

    await tester.tap(
      find.widgetWithText(ChoiceChip, SaleStatus.cancelled.label),
    );
    await tester.pumpAndSettle();

    expect(find.text('No sales found'), findsOneWidget);
    expect(
      find.text('Nothing matches the current search and filters.'),
      findsOneWidget,
    );

    // And clearing brings them back, with the query dropped rather than narrowed.
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(repository.lastQuery?.isFiltered, isFalse);
    expect(find.byType(SaleCard), findsNWidgets(2));
  });

  testWidgets('reports a failed list and offers a retry', (tester) async {
    // Persistent, not one-shot: GoRouter builds a route more than once before the
    // first frame settles, so a failure that cleared itself would be retried into a
    // success before the assertion ran.
    final repository = FakeSalesRepository(sales: _sales())
      ..errorToThrow = const ServerException(
        message: 'Unable to load the sales list.',
      );
    await pumpSalesApp(tester, repository: repository);

    expect(find.byType(ErrorView), findsOneWidget);
    expect(
      find.textContaining('Unable to load the sales list.'),
      findsWidgets,
      reason: 'the body reports it, and the listener announces it too',
    );

    repository.errorToThrow = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsNothing);
    expect(find.byType(SaleCard), findsNWidgets(2));
  });
}
