/// Widget tests for the sale return form.
library;

import 'dart:async';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_item.dart';
import 'package:app/features/returns/data/sale_returns_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_products_repository.dart';
import '../../../support/fake_sale_returns_repository.dart';
import '../../../support/fake_sales_repository.dart';
import '../../../support/sale_returns_test_app.dart';

/// The sold line the fixtures slice: 5 units at 100 less a 20% discount, so the
/// line stored 400 taxable, 48 tax and 448.
///
/// Taken from the stored figures rather than left to the builder's defaults,
/// because those figures are what a refund slices: four units at this line's rate
/// come to 448, which is what the whole discounted line sold for.
SaleItem _soldLine({String id = 'item-1', String batchId = 'batch-1'}) =>
    buildSaleItem(
      id: id,
      qty: 5,
      batchId: batchId,
      taxAmount: 48,
      totalAmount: 448,
    );

/// The returns fake the form writes through: [sale] with its sold lines on it.
FakeSaleReturnsRepository _returns(
  Sale sale, {
  int alreadyReturned = 2,
  List<SaleItem>? lines,
}) => FakeSaleReturnsRepository(
  sales: <Sale>[sale],
  returnable: <String, List<SaleReturnableLine>>{
    sale.id: <SaleReturnableLine>[
      for (final line in lines ?? <SaleItem>[_soldLine()])
        SaleReturnableLine(item: line, alreadyReturned: alreadyReturned),
    ],
  },
);

/// Pumps the form over one bill, and hands back the fake behind its write.
Future<FakeSaleReturnsRepository> _pumpForm(
  WidgetTester tester, {
  int alreadyReturned = 2,
  SaleStatus status = SaleStatus.completed,
  List<SaleItem>? lines,
  bool failReturnable = false,
  bool failCreate = false,
  Completer<void>? createGate,
}) async {
  final sale = buildSale(status: status);
  final repository =
      _returns(sale, alreadyReturned: alreadyReturned, lines: lines)
        ..failReturnableFor = failReturnable
        ..failCreate = failCreate
        ..createGate = createGate;

  await pumpSaleReturnApp(
    tester,
    repository: repository,
    sales: FakeSalesRepository(sales: <Sale>[sale]),
    products: FakeProductsRepository(
      products: <Product>[buildProduct('Dolo 650', id: 'product-1')],
    ),
  );
  return repository;
}

/// The label the bill picker shows for [sale], as the screen builds it.
String _billLabel(Sale sale) =>
    '${sale.invoiceNo} · ${Formatters.dateDdMmmYyyy(sale.saleDate)} · '
    '${Formatters.currency(sale.grandTotal)}';

/// Picks [sale], or the one bill the default fixtures offer, from the picker.
Future<void> _chooseBill(WidgetTester tester, {Sale? sale}) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  // `.last`, because the closed button keeps every item in its own tree and the
  // open menu's copy is what a tap has to land on.
  await tester.tap(find.text(_billLabel(sale ?? buildSale())).last);
  await tester.pumpAndSettle();
}

/// Scrolls [finder] into view, then taps it.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The form's submit button.
Finder _record() => find.widgetWithText(ElevatedButton, 'Record return');

/// The quantity field of a line that can come back.
Finder _qtyField() => find.widgetWithText(TextFormField, 'Returning');

void main() {
  testWidgets('shows the sold lines with what can still come back', (
    tester,
  ) async {
    await _pumpForm(tester);

    await _chooseBill(tester);

    expect(find.text('Dolo 650'), findsOneWidget);
    expect(
      find.text(
        'Sold 5 units · already returned 2 units · '
        '${Formatters.currency(100)} each',
      ),
      findsOneWidget,
    );
    expect(find.text('Up to 3'), findsOneWidget);
  });

  testWidgets('will not offer a line whose batch is empty', (tester) async {
    await _pumpForm(tester, lines: <SaleItem>[_soldLine(batchId: '')]);

    await _chooseBill(tester);

    expect(
      find.text(
        'This line has no batch recorded, so a restock has nowhere to go.',
      ),
      findsOneWidget,
    );
    expect(_qtyField(), findsNothing);
  });

  testWidgets('previews the refund as a slice of the line that was sold', (
    tester,
  ) async {
    await _pumpForm(tester);
    await _chooseBill(tester);

    await tester.enterText(_qtyField(), '2');
    await tester.pumpAndSettle();

    // 2 of the line's 5 units: 40% of 400 taxable, 48 tax and 448.
    expect(find.text('Refund'), findsOneWidget);
    expect(find.text(Formatters.currency(160)), findsOneWidget);
    expect(find.text(Formatters.currency(19.20)), findsOneWidget);
    expect(find.text(Formatters.currency(179.20)), findsOneWidget);
    expect(
      find.text(Formatters.currency(200)),
      findsNothing,
      reason: '2 x the line rate is the list price, not what was charged',
    );
  });

  testWidgets('drops the credit when a line is emptied again', (tester) async {
    await _pumpForm(tester);
    await _chooseBill(tester);
    await tester.enterText(_qtyField(), '2');
    await tester.pumpAndSettle();
    expect(find.text(Formatters.currency(179.20)), findsOneWidget);

    await tester.enterText(_qtyField(), '');
    await tester.pumpAndSettle();

    expect(
      find.text('Refund'),
      findsNothing,
      reason: 'a line with nothing coming back is not part of the credit',
    );
    expect(find.text(Formatters.currency(179.20)), findsNothing);
  });

  testWidgets('drops the line choices when another bill is chosen', (
    tester,
  ) async {
    final first = buildSale();
    final second = buildSale(id: 'sale-2', invoiceNo: 'INV-2');
    await pumpSaleReturnApp(
      tester,
      repository: FakeSaleReturnsRepository(
        sales: <Sale>[first, second],
        returnable: <String, List<SaleReturnableLine>>{
          first.id: <SaleReturnableLine>[
            SaleReturnableLine(item: _soldLine(), alreadyReturned: 2),
          ],
          second.id: <SaleReturnableLine>[
            SaleReturnableLine(
              item: _soldLine(id: 'item-3'),
              alreadyReturned: 0,
            ),
          ],
        },
      ),
      sales: FakeSalesRepository(sales: <Sale>[first, second]),
      products: FakeProductsRepository(
        products: <Product>[buildProduct('Dolo 650', id: 'product-1')],
      ),
    );
    await _chooseBill(tester);
    await tester.enterText(_qtyField(), '2');
    await tester.pumpAndSettle();
    expect(find.text(Formatters.currency(179.20)), findsOneWidget);

    await _chooseBill(tester, sale: second);

    expect(
      find.text('Refund'),
      findsNothing,
      reason:
          'a quantity left over from the first bill belongs to a line of that '
          'bill',
    );
    expect(find.text('Up to 5'), findsOneWidget);
  });

  testWidgets('records the return and opens the bill it credits', (
    tester,
  ) async {
    final repository = await _pumpForm(tester);
    await _chooseBill(tester);

    await tester.enterText(_qtyField(), '2');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Reason'),
      'Damaged in transit',
    );
    await tester.pumpAndSettle();

    await _tap(tester, _record());

    expect(repository.lastQuantities, <String, int>{'item-1': 2});
    expect(repository.lastReason, 'Damaged in transit');
    expect(repository.lastRestock, isTrue, reason: 'the switch starts on');
    expect(repository.lastRefundMode, PaymentMode.cash);
    expect(repository.returns.single.grandTotal, 179.20);
    expect(find.text('Bill sale-1'), findsOneWidget);
  });

  testWidgets('puts the units back only when the switch is on', (tester) async {
    final repository = await _pumpForm(tester);
    await _chooseBill(tester);

    await _tap(tester, find.text('Put the units back in stock'));

    expect(
      find.textContaining('Damaged or unsellable'),
      findsOneWidget,
      reason: 'the subtitle says what a write-off does',
    );

    await tester.enterText(_qtyField(), '2');
    await tester.pumpAndSettle();
    await _tap(tester, _record());

    expect(repository.lastRestock, isFalse);
    expect(repository.returns.single.restock, isFalse);
  });

  testWidgets('records how the money went back', (tester) async {
    final repository = await _pumpForm(tester);
    await _chooseBill(tester);

    await tester.tap(find.byType(DropdownButtonFormField<PaymentMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('UPI').last);
    await tester.pumpAndSettle();

    await tester.enterText(_qtyField(), '2');
    await tester.pumpAndSettle();
    await _tap(tester, _record());

    expect(repository.lastRefundMode, PaymentMode.upi);
    expect(repository.returns.single.refundMode, PaymentMode.upi);
  });

  testWidgets('refuses more units than the line has left, at the field', (
    tester,
  ) async {
    final repository = await _pumpForm(tester);
    await _chooseBill(tester);

    await tester.enterText(_qtyField(), '4');
    await tester.pumpAndSettle();
    await _tap(tester, _record());

    expect(find.text('At most 3'), findsOneWidget);
    expect(repository.returns, isEmpty, reason: 'nothing reaches the write');
  });

  testWidgets('refuses a quantity that is not a whole number', (tester) async {
    final repository = await _pumpForm(tester);
    await _chooseBill(tester);

    await tester.enterText(_qtyField(), 'two');
    await tester.pumpAndSettle();
    await _tap(tester, _record());

    expect(find.text('Enter a whole number'), findsOneWidget);
    expect(repository.returns, isEmpty);
  });

  testWidgets('will not submit until a bill is chosen', (tester) async {
    await _pumpForm(tester);

    // The button's disabled state is the *only* place this rule lives. The picker
    // used to carry a "Choose a bill" validator and `_save` used to report the same
    // thing, and neither could ever run: nothing reaches either while the button is
    // dead (T-4).
    expect(tester.widget<ElevatedButton>(_record()).onPressed, isNull);

    await _chooseBill(tester);

    expect(tester.widget<ElevatedButton>(_record()).onPressed, isNotNull);
  });

  testWidgets('says the bills are loading rather than that there are none', (
    tester,
  ) async {
    final gate = Completer<void>();
    final sale = buildSale();

    await pumpSaleReturnApp(
      tester,
      repository: _returns(sale),
      sales: FakeSalesRepository(sales: <Sale>[sale])..listGate = gate,
      products: FakeProductsRepository(
        products: <Product>[buildProduct('Dolo 650', id: 'product-1')],
      ),
    );

    // The read is held open. "No sales yet" would be a claim about a question this
    // form has not been answered yet, and an empty disabled picker saying it is
    // exactly what T-5 recorded.
    expect(find.text('Loading the bills…'), findsOneWidget);
    expect(find.text('No sales yet'), findsNothing);
    expect(tester.widget<ElevatedButton>(_record()).onPressed, isNull);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('Loading the bills…'), findsNothing);
    expect(
      find.text('Which bill'),
      findsOneWidget,
      reason:
          'the hint answers the question it was asking instead of denying it',
    );
  });

  testWidgets('will not submit twice while the write is in flight', (
    tester,
  ) async {
    final gate = Completer<void>();
    final repository = await _pumpForm(tester, createGate: gate);
    await _chooseBill(tester);
    await tester.enterText(_qtyField(), '2');
    await tester.pumpAndSettle();

    await tester.ensureVisible(_record());
    await tester.pumpAndSettle();
    await tester.tap(_record());
    // A single pump, not a settle: the spinner never stops turning, so a settle
    // would time out rather than show the state the write is in.
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final saving = find.byType(ElevatedButton);
    expect(saving, findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(saving).onPressed,
      isNull,
      reason:
          'a second tap while the first write is in flight would credit the '
          'customer twice',
    );

    gate.complete();
    await tester.pumpAndSettle();

    expect(repository.returns, hasLength(1));
    expect(find.text('Bill sale-1'), findsOneWidget);
  });

  testWidgets('reports a refused write and stays on the form', (tester) async {
    final repository = await _pumpForm(tester, failCreate: true);
    await _chooseBill(tester);
    await tester.enterText(_qtyField(), '2');
    await tester.pumpAndSettle();

    await _tap(tester, _record());

    expect(find.text('Unable to record that sale return.'), findsOneWidget);
    expect(repository.returns, isEmpty);
    expect(
      find.text('New sale return'),
      findsOneWidget,
      reason: 'the form stays put so the counter can try again',
    );

    repository.failCreate = false;
    await _tap(tester, _record());

    expect(repository.returns, hasLength(1));
    expect(find.text('Bill sale-1'), findsOneWidget);
  });

  testWidgets('reports a failed line read and reads again when retried', (
    tester,
  ) async {
    final repository = await _pumpForm(tester, failReturnable: true);
    await _chooseBill(tester);

    expect(
      find.text('Unable to load what can be returned from that sale.'),
      findsOneWidget,
    );

    // Reads again, this time successfully. The tap is not preceded by a settle:
    // Riverpod 3 retries a failed provider build on its own backoff, so a pump
    // between clearing the failure and pressing the button would race the retry
    // and the error view would already be gone.
    repository.failReturnableFor = false;
    await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Dolo 650'), findsOneWidget);
  });

  testWidgets('offers a cancelled bill, and refuses it when it is used', (
    tester,
  ) async {
    final repository = await _pumpForm(tester, status: SaleStatus.cancelled);
    await _chooseBill(tester);

    await tester.enterText(_qtyField(), '2');
    await tester.pumpAndSettle();
    await _tap(tester, _record());

    expect(
      find.text('That sale was cancelled, so nothing can come back from it.'),
      findsOneWidget,
    );
    expect(repository.returns, isEmpty);
  });

  testWidgets('says so when nothing was chosen to come back', (tester) async {
    final repository = await _pumpForm(tester);
    await _chooseBill(tester);

    await _tap(tester, _record());

    expect(find.text('Enter how many units are coming back.'), findsOneWidget);
    expect(repository.returns, isEmpty);
  });

  testWidgets('reports a bill list that could not be read', (tester) async {
    final sale = buildSale();
    await pumpSaleReturnApp(
      tester,
      repository: _returns(sale),
      sales: FakeSalesRepository(sales: <Sale>[sale])
        ..errorToThrow = const ServerException(
          message: 'Unable to load the sales.',
        ),
    );

    expect(find.text('Unable to load the sales.'), findsOneWidget);
  });
}
