/// Tests for the sale return form's controller and the lines it offers.
///
/// The money is checked against a line that stored a discounted amount, because
/// the rule worth testing is that a return slices what the line *stored*: a
/// fixture whose `qty x rate` happened to agree with it would test nothing.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/errors/error_message.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_item.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/returns/application/sale_return_form_controller.dart';
import 'package:app/features/returns/data/sale_return_totals.dart';
import 'package:app/features/returns/data/sale_returns_repository.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_products_repository.dart';
import '../../../support/fake_sale_returns_repository.dart';
import '../../../support/fake_sales_repository.dart';

/// The sold line the fixtures slice: 5 units at 100 less a 20% discount, so the
/// line stored 400 taxable, 48 tax and 448.
///
/// Taken from the stored figures rather than left to the builder's defaults,
/// because those figures are what a return slices: four units at this line's rate
/// come to 448, which is what the whole discounted line sold for.
SaleItem _soldLine({
  String batchId = 'batch-1',
  String? productId = 'product-1',
}) => buildSaleItem(
  qty: 5,
  batchId: batchId,
  productId: productId,
  taxAmount: 48,
  totalAmount: 448,
);

/// The returns fake: one bill, with one line of [_soldLine] on it.
FakeSaleReturnsRepository _returns({
  int alreadyReturned = 0,
  String batchId = 'batch-1',
  String? productId = 'product-1',
  SaleStatus status = SaleStatus.completed,
}) => FakeSaleReturnsRepository(
  sales: <Sale>[buildSale(status: status)],
  returnable: <String, List<SaleReturnableLine>>{
    'sale-1': <SaleReturnableLine>[
      SaleReturnableLine(
        item: _soldLine(batchId: batchId, productId: productId),
        alreadyReturned: alreadyReturned,
      ),
    ],
  },
);

/// A container with the three repositories the form reads stubbed out.
///
/// The override list is inferred rather than annotated: `Override` is declared in
/// the `riverpod` package, which `flutter_riverpod` does not re-export, so naming
/// it would need an extra import for no benefit.
///
/// The form controller is held open for the whole test. It is auto-dispose, and a
/// write that landed after Riverpod had disposed it would throw on `state = ...`
/// instead of reporting what the write said.
ProviderContainer _container({
  required FakeSaleReturnsRepository returns,
  FakeSalesRepository? sales,
  FakeProductsRepository? products,
}) {
  final container = ProviderContainer(
    overrides: [
      saleReturnsRepositoryProvider.overrideWithValue(returns),
      salesRepositoryProvider.overrideWithValue(sales ?? FakeSalesRepository()),
      productsRepositoryProvider.overrideWithValue(
        products ??
            FakeProductsRepository(
              products: <Product>[buildProduct('Dolo 650', id: 'product-1')],
            ),
      ),
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(
    container.listen(saleReturnFormControllerProvider, (p, n) {}).close,
  );
  return container;
}

/// The return form's controller behind [container].
SaleReturnFormController _form(ProviderContainer container) =>
    container.read(saleReturnFormControllerProvider.notifier);

void main() {
  group('SaleReturnableLine', () {
    test('offers what was billed less what has already come back', () {
      final line = SaleReturnableLine(item: _soldLine(), alreadyReturned: 2);

      expect(line.returnable, 3);
      expect(line.canReturn, isTrue);
      expect(line.blockedReason, isNull);
    });

    test('offers nothing once the whole line has come back', () {
      final line = SaleReturnableLine(item: _soldLine(), alreadyReturned: 5);

      expect(line.returnable, 0);
      expect(line.canReturn, isFalse);
      expect(
        line.blockedReason,
        'All 5 units of this line have already come back.',
      );
    });

    test('offers nothing when more came back than was billed', () {
      final line = SaleReturnableLine(item: _soldLine(), alreadyReturned: 6);

      expect(line.returnable, 0, reason: 'the cap is clamped, never negative');
      expect(line.canReturn, isFalse);
    });

    test('will not offer a line with no batch to restock', () {
      final line = SaleReturnableLine(
        item: _soldLine(batchId: ''),
        alreadyReturned: 0,
      );

      expect(line.returnable, 5, reason: 'the units are there to come back');
      expect(
        line.blockedReason,
        'This line has no batch recorded, so a restock has nowhere to go.',
      );
      expect(line.canReturn, isFalse);
    });
  });

  group('SaleReturnTotals', () {
    test('refunds the slice of the line that was stored, not qty x rate', () {
      final amounts = SaleReturnTotals.forLine(item: _soldLine(), qty: 4);

      expect(amounts.taxable, 320);
      expect(amounts.tax, 38.40);
      expect(amounts.total, 358.40);
      expect(
        amounts.total,
        isNot(448),
        reason:
            'four units at the line rate come to 448, which is what the whole '
            'discounted line sold for',
      );
    });

    test('rounds each line to two decimals', () {
      // A third of a line that stored 448 on 48 tax: 448 / 3 is 149.333...
      final amounts = SaleReturnTotals.forLine(
        item: buildSaleItem(qty: 3, taxAmount: 48, totalAmount: 448),
        qty: 1,
      );

      expect(amounts.tax, 16);
      expect(amounts.total, 149.33);
      expect(amounts.taxable, 133.33);
    });

    test('the document totals add the lines up', () {
      final totals = SaleReturnTotals.forLines(<SaleReturnLineAmounts>[
        SaleReturnTotals.forLine(item: _soldLine(), qty: 4),
        SaleReturnTotals.forLine(item: buildSaleItem(id: 'item-2'), qty: 2),
      ]);

      expect(totals.subTotal, 520); // 320 + 200
      expect(totals.taxTotal, 62.40); // 38.40 + 24
      expect(totals.grandTotal, 582.40); // 358.40 + 224
    });
  });

  group('saleReturnableProvider', () {
    test('offers the sold lines with what can still come back', () async {
      final container = _container(returns: _returns(alreadyReturned: 2));

      final data = await container.read(
        saleReturnableProvider('sale-1').future,
      );

      final line = data.lines.single;
      expect(line.item.qty, 5);
      expect(line.alreadyReturned, 2);
      expect(line.returnable, 3);
      expect(saleReturnableName(data, line), 'Dolo 650');
    });

    test('falls back to a placeholder when the product is not named', () async {
      final container = _container(
        returns: _returns(productId: 'product-9'),
        products: FakeProductsRepository(products: const <Product>[]),
      );

      final data = await container.read(
        saleReturnableProvider('sale-1').future,
      );

      expect(saleReturnableName(data, data.lines.single), 'Unnamed product');
    });

    test('a failed read reaches the caller as its own error', () async {
      final container = _container(
        returns: _returns()..failReturnableFor = true,
      );

      // The provider is kept alive while it fails: a one-shot read of an
      // auto-dispose provider can be disposed mid-build (D-015).
      final subscription = container.listen(
        saleReturnableProvider('sale-1'),
        (p, n) {},
      );
      addTearDown(subscription.close);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(saleReturnableProvider('sale-1'));
      expect(state.hasError, isTrue);
      expect(
        describeError(state.error!),
        'Unable to load what can be returned from that sale.',
      );
    });
  });

  group('returnableSalesProvider', () {
    test('offers every bill, a cancelled one included', () async {
      final container = _container(
        returns: _returns(),
        sales: FakeSalesRepository(
          sales: <Sale>[
            buildSale(
              id: 'sale-2',
              invoiceNo: 'INV-2',
              status: SaleStatus.cancelled,
            ),
            buildSale(),
          ],
        ),
      );

      final sales = await container.read(returnableSalesProvider.future);

      expect(
        sales.map((sale) => sale.id),
        <String>['sale-2', 'sale-1'],
        reason:
            'the write refuses a cancelled bill with a message that says why, '
            'which a picker that hid it could not do',
      );
    });
  });

  group('SaleReturnFormController', () {
    test(
      'writes the slice of the line, and the restock and refund choices',
      () async {
        final repository = _returns();
        final container = _container(returns: repository);

        final outcome = await _form(container).createReturn(
          saleId: 'sale-1',
          returnDate: DateTime(2026, 9, 18),
          quantities: <String, int>{'item-1': 2},
          restock: false,
          refundMode: PaymentMode.upi,
          reason: 'Damaged in transit',
        );
        final saved = outcome.document!;

        // 2 of the line's 5 units: 40% of 400 taxable, 48 tax and 448.
        expect(saved.subTotal, 160);
        expect(saved.taxTotal, 19.20);
        expect(saved.grandTotal, 179.20);
        expect(
          saved.grandTotal,
          isNot(224),
          reason: '2 x 100 plus tax is the list price, not what was charged',
        );
        expect(saved.restock, isFalse);
        expect(saved.refundMode, PaymentMode.upi);
        expect(saved.reason, 'Damaged in transit');
        expect(saved.customerId, isNull);
        expect(
          outcome.isStaged,
          isFalse,
          reason: 'the owner is not gated, and this fake is him',
        );

        // What was stored is the slice too, on the line as well as the header.
        final line = repository.items.single;
        expect(line.qty, 2);
        expect(line.rate, 100);
        expect(line.taxAmount, 19.20);
        expect(line.totalAmount, 179.20);

        expect(
          container.read(saleReturnFormControllerProvider).value,
          same(saved),
          reason: 'the controller publishes the document the write returned',
        );
      },
    );

    test('writes every chosen line as one document', () async {
      final repository = FakeSaleReturnsRepository(
        sales: <Sale>[buildSale()],
        returnable: <String, List<SaleReturnableLine>>{
          'sale-1': <SaleReturnableLine>[
            SaleReturnableLine(item: _soldLine(), alreadyReturned: 0),
            SaleReturnableLine(
              item: buildSaleItem(id: 'item-2', productId: 'product-2'),
              alreadyReturned: 0,
            ),
          ],
        },
      );
      final container = _container(returns: repository);

      final outcome = await _form(container).createReturn(
        saleId: 'sale-1',
        returnDate: DateTime(2026, 9, 18),
        quantities: <String, int>{'item-1': 4, 'item-2': 1},
        restock: true,
        refundMode: PaymentMode.cash,
      );
      final saved = outcome.document!;

      expect(saved.subTotal, 420); // 320 + 100
      expect(saved.taxTotal, 50.40); // 38.40 + 12
      expect(saved.grandTotal, 470.40); // 358.40 + 112
      expect(repository.items, hasLength(2));
    });

    test(
      'refuses more than was billed less what has already come back',
      () async {
        final repository = _returns(alreadyReturned: 2);
        final container = _container(returns: repository);

        await expectLater(
          _form(container).createReturn(
            saleId: 'sale-1',
            returnDate: DateTime(2026, 9, 18),
            quantities: <String, int>{'item-1': 4},
            restock: true,
            refundMode: PaymentMode.cash,
          ),
          throwsA(
            isA<ValidationException>().having(
              (error) => error.message,
              'message',
              'Only 3 units of that line can still come back.',
            ),
          ),
        );

        expect(
          repository.returns,
          isEmpty,
          reason: 'a refused set writes nothing',
        );
      },
    );

    test('refuses a set with nothing in it', () async {
      final repository = _returns();
      final container = _container(returns: repository);

      await expectLater(
        _form(container).createReturn(
          saleId: 'sale-1',
          returnDate: DateTime(2026, 9, 18),
          quantities: const <String, int>{},
          restock: true,
          refundMode: PaymentMode.cash,
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            'Enter how many units are coming back.',
          ),
        ),
      );

      expect(repository.returns, isEmpty);
    });

    test('refuses a set of zeroes as an empty set', () async {
      final repository = _returns();
      final container = _container(returns: repository);

      await expectLater(
        _form(container).createReturn(
          saleId: 'sale-1',
          returnDate: DateTime(2026, 9, 18),
          quantities: <String, int>{'item-1': 0},
          restock: true,
          refundMode: PaymentMode.cash,
        ),
        throwsA(isA<ValidationException>()),
      );

      expect(repository.returns, isEmpty);
    });

    test('refuses a line that has already come back in full', () async {
      final repository = _returns(alreadyReturned: 5);
      final container = _container(returns: repository);

      await expectLater(
        _form(container).createReturn(
          saleId: 'sale-1',
          returnDate: DateTime(2026, 9, 18),
          quantities: <String, int>{'item-1': 1},
          restock: true,
          refundMode: PaymentMode.cash,
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            'All 5 units of this line have already come back.',
          ),
        ),
      );
    });

    test('refuses to credit a bill that was cancelled', () async {
      final repository = _returns(status: SaleStatus.cancelled);
      final container = _container(returns: repository);

      await expectLater(
        _form(container).createReturn(
          saleId: 'sale-1',
          returnDate: DateTime(2026, 9, 18),
          quantities: <String, int>{'item-1': 2},
          restock: true,
          refundMode: PaymentMode.cash,
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            'That sale was cancelled, so nothing can come back from it.',
          ),
        ),
      );

      expect(repository.returns, isEmpty);
    });

    test('leaves a failed write in its state and rethrows it', () async {
      final repository = _returns()..failCreate = true;
      final container = _container(returns: repository);

      await expectLater(
        _form(container).createReturn(
          saleId: 'sale-1',
          returnDate: DateTime(2026, 9, 18),
          quantities: <String, int>{'item-1': 2},
          restock: true,
          refundMode: PaymentMode.cash,
        ),
        throwsA(isA<ServerException>()),
      );

      final state = container.read(saleReturnFormControllerProvider);
      expect(state.hasError, isTrue);
      expect(
        describeError(state.error!),
        'Unable to record that sale return.',
        reason: 'the screen turns this state into the message it shows',
      );
      expect(repository.returns, isEmpty);
    });
  });
}
