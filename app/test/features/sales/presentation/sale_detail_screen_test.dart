/// Widget tests for the bill screen.
///
/// The screen renders the document's *stored* columns (`sales` and `sale_items`)
/// rather than recomputing them, so what these assert is that it shows what was
/// stored - a bill that recalculated its own total could only disagree with the
/// ledger entry it posted.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_item.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_products_repository.dart';
import '../../../support/fake_sales_repository.dart';
import '../../../support/sale_detail_test_app.dart';

/// The bill's one line: two units at 100, 20% off, 12% GST, 24 of tax.
SaleItem _line() => buildSaleItem().copyWith(discountPercent: 20);

/// The sale itself, in figures that disagree with the line on purpose.
///
/// Nothing on this screen may be derived from [SaleItem], so a header that did not
/// match its own line is the fixture that catches it: 1000 taxable, 50 off, 120 tax,
/// 1120 due.
Sale _sale({
  double amountPaid = 1120,
  double balanceDue = 0,
  String? customerId,
  String? placeOfSupply,
}) => buildSale(
  invoiceNo: 'INV-7',
  saleDate: DateTime(2026, 9, 18, 14, 5),
  subTotal: 1000,
  taxTotal: 120,
  grandTotal: 1120,
  amountPaid: amountPaid,
  balanceDue: balanceDue,
  customerId: customerId,
).copyWith(discountTotal: 50, placeOfSupply: placeOfSupply);

/// A repository holding one bill with its line.
FakeSalesRepository _repository({
  Sale? sale,
  List<SaleItem>? items,
  Exception? error,
}) => FakeSalesRepository(
  sales: <Sale>[sale ?? _sale()],
  items: items ?? <SaleItem>[_line()],
)..errorToThrow = error;

/// Every plain-text line a `RichText` in the tree is carrying.
///
/// The item card's metrics are `RichText` spans rather than `Text` widgets, so
/// `find.text` cannot see them; this reads what they actually say.
List<String> _richTexts(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((rich) => rich.text.toPlainText())
    .toList(growable: false);

void main() {
  testWidgets('shows the figures the document stored', (tester) async {
    await pumpSaleDetailApp(tester, repository: _repository());

    expect(find.text('Bill INV-7'), findsOneWidget);
    expect(find.text('Invoice'), findsOneWidget);
    expect(find.text('INV-7'), findsOneWidget);

    // Every figure is the sale's own column, formatted - not a sum of the lines.
    expect(find.text('Taxable value'), findsOneWidget);
    expect(find.text(Formatters.currency(1000)), findsOneWidget);
    expect(find.text('Discount'), findsOneWidget);
    expect(find.text('-${Formatters.currency(50)}'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(find.text(Formatters.currency(1120)), findsWidgets);
  });

  testWidgets("names an intra-state bill's tax head CGST + SGST", (
    tester,
  ) async {
    await pumpSaleDetailApp(tester, repository: _repository());
    expect(
      find.text('CGST + SGST'),
      findsOneWidget,
      reason:
          'the tax is one column, so it prints as one head and a half-share '
          "is the printer's job, not this screen's",
    );
    expect(find.text('IGST'), findsNothing);
  });

  testWidgets("names an inter-state bill's tax head IGST", (tester) async {
    await pumpSaleDetailApp(
      tester,
      repository: _repository(),
      split: TaxSplit.interState,
    );
    expect(find.text('IGST'), findsOneWidget);
    expect(find.text('CGST + SGST'), findsNothing);
  });

  testWidgets('lists the line with its metrics', (tester) async {
    await pumpSaleDetailApp(
      tester,
      repository: _repository(),
      products: FakeProductsRepository(
        products: <Product>[buildProduct('Dolo 650', id: 'product-1')],
      ),
    );

    expect(find.text('Dolo 650'), findsOneWidget);
    expect(
      _richTexts(tester),
      containsAll(<String>[
        'Qty 2',
        'Rate ${Formatters.currency(100)}',
        // `discountPercent` is stored as a `numeric`, so it arrives a double and
        // the screen prints the value it was given: `20.0%`. The printer strips
        // that `.0` because a thermal roll has 32 columns; a screen does not have
        // to.
        'Discount 20.0%',
        'GST 12.0%',
        'Tax ${Formatters.currency(24)}',
      ]),
    );
  });

  testWidgets('leaves out the metrics a line does not have', (tester) async {
    await pumpSaleDetailApp(
      tester,
      repository: _repository(
        items: <SaleItem>[
          buildSaleItem().copyWith(discountPercent: 0, gstPercent: 0),
        ],
      ),
      products: FakeProductsRepository(
        products: <Product>[buildProduct('Dolo 650', id: 'product-1')],
      ),
    );

    final texts = _richTexts(tester);
    expect(texts, contains('Qty 2'));
    expect(
      texts.where((text) => text.startsWith('Discount ')),
      isEmpty,
      reason: 'a zero discount is not a 0% discount',
    );
    expect(texts.where((text) => text.startsWith('GST ')), isEmpty);
  });

  testWidgets('sends a prescription-only line to the drug register', (
    tester,
  ) async {
    await pumpSaleDetailApp(
      tester,
      repository: _repository(
        items: <SaleItem>[
          buildSaleItem().copyWith(scheduleType: ScheduleType.h1),
        ],
      ),
      products: FakeProductsRepository(
        products: <Product>[buildProduct('Dolo 650', id: 'product-1')],
      ),
    );

    expect(find.text('Register'), findsOneWidget);
    expect(
      find.textContaining('drug register'),
      findsOneWidget,
      reason: 'a Schedule H1 sale is a record the pharmacy has to keep',
    );
    expect(_richTexts(tester), contains('Schedule ${ScheduleType.h1.label}'));
  });

  testWidgets('says a bill has no lines rather than showing an empty card', (
    tester,
  ) async {
    await pumpSaleDetailApp(tester, repository: _repository(items: []));

    expect(find.text('This bill has no lines.'), findsOneWidget);
  });

  testWidgets('distinguishes a walk-in from an account sale', (tester) async {
    await pumpSaleDetailApp(tester, repository: _repository());
    expect(find.text('Walk-in'), findsOneWidget);

    await pumpSaleDetailApp(
      tester,
      repository: _repository(sale: _sale(customerId: 'customer-1')),
    );
    expect(find.text('On account'), findsOneWidget);
  });

  testWidgets('shows what is still owed on a part payment', (tester) async {
    await pumpSaleDetailApp(
      tester,
      repository: _repository(sale: _sale(amountPaid: 500, balanceDue: 620)),
    );

    expect(find.text('Balance due'), findsOneWidget);
    expect(find.text(Formatters.currency(620)), findsOneWidget);
    expect(find.text(Formatters.currency(500)), findsOneWidget);
  });

  testWidgets('leaves the balance off a settled bill', (tester) async {
    await pumpSaleDetailApp(tester, repository: _repository());

    expect(find.text('Balance due'), findsNothing);
  });

  testWidgets('prints the bill it is showing', (tester) async {
    final printer = FakeInvoicePrinter();
    await pumpSaleDetailApp(
      tester,
      repository: _repository(),
      pharmacy: FakePharmacyRepository(pharmacy: buildPharmacy()),
      printer: printer,
    );

    await tester.tap(find.byIcon(Icons.print_outlined));
    await tester.pumpAndSettle();

    expect(printer.sheets, hasLength(1));
    final sheet = printer.sheets.single;
    expect(sheet.reference, 'Bill INV-7');
    expect(sheet.heading.first, 'Sunrise Medicals');
    expect(
      printer.pharmacies.single?.name,
      'Sunrise Medicals',
      reason:
          'the seller half of a GST bill comes from the pharmacy, not the sale',
    );
  });

  testWidgets('says so when the bill could not be printed', (tester) async {
    final printer = FakeInvoicePrinter(
      error: const ServerException(message: 'the print sheet refused it'),
    );
    await pumpSaleDetailApp(
      tester,
      repository: _repository(),
      printer: printer,
    );

    await tester.tap(find.byIcon(Icons.print_outlined));
    await tester.pumpAndSettle();

    // The screen keeps the bill: a printer that would not open is not a reason to
    // take the invoice away from the counter.
    expect(find.textContaining('Could not print the bill:'), findsOneWidget);
    expect(find.textContaining('the print sheet refused it'), findsOneWidget);
    expect(find.text('Bill INV-7'), findsOneWidget);
  });

  testWidgets('offers a retry when the bill could not be read', (tester) async {
    final repository = _repository(
      error: const ServerException(message: 'Unable to load that sale.'),
    );
    await pumpSaleDetailApp(tester, repository: repository);

    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    repository.errorToThrow = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsNothing);
    expect(find.text('Bill INV-7'), findsOneWidget);
  });

  testWidgets('says a bill that is gone is gone, rather than loading for ever', (
    tester,
  ) async {
    // `saleDetailProvider` answers `null` for an id that is no longer there. Read as
    // "still loading", that spun for ever on a bill a stale link opened.
    await pumpSaleDetailApp(
      tester,
      repository: FakeSalesRepository(),
      saleId: 'sale-gone',
    );

    expect(find.text('Bill not found'), findsOneWidget);
    expect(find.text('Loading the bill…'), findsNothing);
  });
}
