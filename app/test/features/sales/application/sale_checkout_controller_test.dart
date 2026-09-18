/// Tests for the checkout write.
///
/// The order of the write is the whole design (D-023): availability is re-read
/// and checked first, then the sale goes to the till as one RPC. So these tests
/// assert both halves - that a short line never reaches the till, and that what
/// does reach it is exactly what the counter showed.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:app/features/sales/application/sale_checkout_controller.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_inventory_repository.dart';
import '../../../support/fake_products_repository.dart';
import '../../../support/fake_sales_repository.dart';

/// A container with the till, the catalogue and the tenant scope stubbed out.
ProviderContainer _container({
  required FakeSalesRepository sales,
  FakeProductsRepository? products,
}) {
  final container = ProviderContainer(
    overrides: [
      salesRepositoryProvider.overrideWithValue(sales),
      productsRepositoryProvider.overrideWithValue(
        products ?? FakeProductsRepository(products: const <Product>[]),
      ),
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A container whose batch holds [onHand] units, with its catalogue fake.
///
/// The same fake answers both questions the write asks - what the catalogue knows
/// and what the batch holds - which is why it is returned rather than rebuilt.
({ProviderContainer container, FakeProductsRepository products}) _withStock({
  FakeSalesRepository? sales,
  int onHand = 50,
}) {
  final products = FakeProductsRepository(products: const <Product>[]);
  products.batchQuantities['batch-1'] = onHand;
  return (
    container: _container(
      sales: sales ?? FakeSalesRepository(),
      products: products,
    ),
    products: products,
  );
}

/// Rings one line into the basket.
void _ringUp(
  ProviderContainer container, {
  int qty = 2,
  double rate = 100,
  double gstPercent = 12,
  String batchId = 'batch-1',
}) {
  container
      .read(posControllerProvider.notifier)
      .addLine(
        product: buildProduct('Dolo 650'),
        batch: buildBatch(id: batchId, batchNo: 'B-$batchId'),
        qty: qty,
        rate: rate,
        gstPercent: gstPercent,
      );
}

/// The basket's current totals.
SaleDocumentTotals _totals(ProviderContainer container) => SaleTotals.forLines(
  container.read(posControllerProvider).lines,
  split: TaxSplit.intraState,
);

/// The checkout controller.
SaleCheckoutController _checkout(ProviderContainer container) =>
    container.read(saleCheckoutControllerProvider.notifier);

/// Writes the basket.
Future<Sale> _write(ProviderContainer container) =>
    _checkout(container).checkout(
      cart: container.read(posControllerProvider),
      split: TaxSplit.intraState,
    );

void main() {
  test(
    'writes the basket as one sale, and returns what the till stored',
    () async {
      final sales = FakeSalesRepository();
      final container = _withStock(sales: sales).container;
      _ringUp(container);

      final saved = await _write(container);

      // One call, carrying what the counter showed.
      final payload = sales.checkouts.single;
      expect(payload.lines, hasLength(1));
      final line = payload.lines.single;
      expect(line.productId, 'id-Dolo 650');
      expect(line.batchId, 'batch-1');
      expect(line.qty, 2);
      expect(line.rate, 100);
      expect(line.discountAmount, 0);
      expect(line.taxAmount, 24);
      expect(line.cgstAmount, 12);
      expect(line.sgstAmount, 12);
      expect(line.igstAmount, 0);
      expect(line.totalAmount, 224);
      expect(line.scheduleType, ScheduleType.otc);

      // The document totals are the till's business, not the client's: sending them
      // would let a stored grand total disagree with the lines it describes.
      final header = payload.toPayload();
      expect(header.keys, isNot(contains('grand_total')));
      expect(header.keys, isNot(contains('sub_total')));

      // And the document that came home agrees with its own lines.
      expect(saved.grandTotal, 224);
      expect(saved.subTotal, 200);
      expect(saved.taxTotal, 24);
      expect(saved.balanceDue, 0);
      expect(saved.status, SaleStatus.completed);
      expect(saved.paymentMode, PaymentMode.cash);
    },
  );

  test(
    'a counter sale with no tender typed records the bill as paid',
    () async {
      final sales = FakeSalesRepository();
      final container = _withStock(sales: sales).container;
      _ringUp(container);

      await _write(container);

      expect(sales.checkouts.single.amountPaid, 224);
    },
  );

  test('empties the basket once the sale is written', () async {
    final container = _withStock().container;
    _ringUp(container);

    await _write(container);

    expect(container.read(posControllerProvider).isEmpty, isTrue);
  });

  test('refuses an empty basket before it reaches the till', () async {
    final sales = FakeSalesRepository();
    final container = _withStock(sales: sales).container;

    await expectLater(
      _write(container),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          'Ring something up before taking payment.',
        ),
      ),
    );
    expect(sales.checkouts, isEmpty);
  });

  test('refuses a line that asks for more than its batch holds', () async {
    final sales = FakeSalesRepository();
    final container = _withStock(sales: sales, onHand: 1).container;
    _ringUp(container);

    await expectLater(
      _write(container),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          contains('Only 1 unit of Dolo 650 (batch B-batch-1) are left'),
        ),
      ),
    );
    expect(
      sales.checkouts,
      isEmpty,
      reason:
          'the database would refuse it anyway, but with a message naming a '
          'batch id, which is no use to a cashier',
    );
    expect(
      container.read(posControllerProvider).isEmpty,
      isFalse,
      reason: 'a refused checkout must leave the basket to correct',
    );
  });

  test(
    'counts the units it refuses in the plural when there are none',
    () async {
      final container = _withStock(onHand: 0).container;
      _ringUp(container, qty: 1);

      await expectLater(
        _write(container),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('Only 0 units of Dolo 650'),
          ),
        ),
      );
    },
  );

  test('refuses a balance that nobody will owe', () async {
    // The only payment rule a sale has, alongside the overpayment guard: a bill
    // that is not settled at the counter needs a customer to carry it. There is no
    // "invalid payment mode" to refuse - `PaymentMode` is a closed enum, so the
    // credit-without-a-customer case is where a bad settlement actually shows up.
    final sales = FakeSalesRepository();
    final container = _withStock(sales: sales).container;
    _ringUp(container);

    container
        .read(posControllerProvider.notifier)
        .setPaymentMode(PaymentMode.credit);

    await expectLater(
      _write(container),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          'Choose the customer who is owing the balance, or take the payment in '
              'full.',
        ),
      ),
    );
    expect(sales.checkouts, isEmpty);
  });

  test('writes a credit sale when a customer carries the balance', () async {
    final sales = FakeSalesRepository();
    final container = _withStock(sales: sales).container;
    _ringUp(container);

    container.read(posControllerProvider.notifier)
      ..setPaymentMode(PaymentMode.credit)
      ..setCustomer('customer-1');

    final saved = await _write(container);

    expect(saved.status, SaleStatus.credit);
    expect(saved.customerId, 'customer-1');
    expect(saved.amountPaid, 0);
    expect(saved.balanceDue, 224);
  });

  test('clamps an over-tender so no negative balance is stored', () async {
    // `sales_payment_check` refuses a sale paid beyond its total, and returns a
    // negative balance due would be a change the cashier handed back recorded as
    // revenue.
    final sales = FakeSalesRepository();
    final container = _withStock(sales: sales).container;
    _ringUp(container, qty: 1, rate: 217.6, gstPercent: 0);
    expect(_totals(container).grandTotal, 217.6);

    container.read(posControllerProvider.notifier).setTendered(500);
    final saved = await _write(container);

    expect(sales.checkouts.single.amountPaid, 217.6);
    expect(saved.amountPaid, 217.6);
    expect(saved.balanceDue, 0);
    expect(
      PurchaseTotals.round2(saved.grandTotal - saved.amountPaid),
      0,
      reason: 'the till must never store a negative balance',
    );
    expect(SaleTotals.changeFor(tendered: 500, total: saved.grandTotal), 282.4);
  });

  test(
    'a refused write leaves the basket, and reports itself in the state',
    () async {
      final sales = FakeSalesRepository()
        ..errorToThrow = const ServerException(
          message: 'Unable to record that sale.',
        );
      final container = _withStock(sales: sales).container;
      // Kept alive on purpose: an auto-dispose provider read once can be disposed
      // between two reads, and a rebuilt one would report no error at all.
      final subscription = container.listen(
        saleCheckoutControllerProvider,
        (previous, next) {},
      );
      addTearDown(subscription.close);
      _ringUp(container);

      await expectLater(_write(container), throwsA(isA<ServerException>()));

      expect(container.read(posControllerProvider).isEmpty, isFalse);
      expect(container.read(saleCheckoutControllerProvider).hasError, isTrue);
    },
  );
}
