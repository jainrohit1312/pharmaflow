/// Tests for the counter's basket.
///
/// The basket is the one place where a wrong total is money rather than a display
/// glitch, so every operation that can change a figure is asserted through
/// `SaleTotals` - the same helper the screen and the write use - rather than
/// against a number worked out by hand in the test.
library;

import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_inventory_repository.dart';
import '../../../support/fake_products_repository.dart';

/// A container holding only the basket (which depends on nothing).
ProviderContainer _container() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

/// The basket's controller.
PosController _pos(ProviderContainer container) =>
    container.read(posControllerProvider.notifier);

/// The basket.
PosCart _cart(ProviderContainer container) =>
    container.read(posControllerProvider);

/// The basket's totals, split intra-state.
SaleDocumentTotals _totals(ProviderContainer container) =>
    SaleTotals.forLines(_cart(container).lines, split: TaxSplit.intraState);

void main() {
  group('adding a line', () {
    test('takes the batch counter price and the common slab as defaults', () {
      final container = _container();
      final product = buildProduct('Dolo 650', scheduleType: ScheduleType.h);
      final batch = buildBatch(batchNo: 'B-7').copyWith(sellingRate: 200);

      _pos(container).addLine(product: product, batch: batch, qty: 1);

      final line = _cart(container).lines.single;
      expect(line.productId, 'id-Dolo 650');
      expect(line.productName, 'Dolo 650');
      expect(line.batchId, batch.id);
      expect(line.batchNo, 'B-7');
      expect(line.qty, 1);
      expect(line.rate, 200);
      expect(line.gstPercent, defaultSaleGstPercent);
      expect(
        line.scheduleType,
        ScheduleType.h,
        reason: 'the schedule is a snapshot for the drug register, not a join',
      );
      expect(line.expiryDateIso, batch.expiryDate.toIso8601String());
    });

    test('falls back to the batch MRP when no counter price was ever set', () {
      final container = _container();
      final batch = buildBatch(qty: 4);

      _pos(
        container,
      ).addLine(product: buildProduct('Dolo 650'), batch: batch, qty: 1);

      expect(batch.sellingRate, 0, reason: 'the fixture sets no counter price');
      expect(_cart(container).lines.single.rate, batch.mrp);
    });

    test('honours a rate and a slab the counter typed', () {
      final container = _container();

      _pos(container).addLine(
        product: buildProduct('Dolo 650'),
        batch: buildBatch(),
        qty: 2,
        rate: 12.5,
        gstPercent: 5,
      );

      final line = _cart(container).lines.single;
      expect(line.rate, 12.5);
      expect(line.gstPercent, 5);
      expect(_totals(container).grandTotal, 26.25);
    });

    test('a second scan of the same batch adds a unit to the line already '
        'there', () {
      final container = _container();
      final product = buildProduct('Dolo 650');
      final batch = buildBatch();

      _pos(container)
        ..addLine(product: product, batch: batch, qty: 1)
        ..addLine(product: product, batch: batch, qty: 2);

      expect(_cart(container).lines, hasLength(1));
      expect(_cart(container).lines.single.qty, 3);
    });

    test('a different batch of the same product is a line of its own', () {
      // The two batches have their own expiry and their own stock, so they cannot
      // be one line - and `sale_items.batch_id` is not null, so each line has to
      // name exactly one.
      final container = _container();
      final product = buildProduct('Dolo 650');

      _pos(container)
        ..addLine(product: product, batch: buildBatch(), qty: 1)
        ..addLine(
          product: product,
          batch: buildBatch(id: 'batch-2', batchNo: 'B-2'),
          qty: 1,
        );

      expect(_cart(container).lines, hasLength(2));
      expect(_cart(container).lines.map((line) => line.batchNo), <String>[
        'B-1',
        'B-2',
      ]);
    });

    test('a quantity of nothing is refused rather than added', () {
      final container = _container();

      _pos(
        container,
      ).addLine(product: buildProduct('Dolo 650'), batch: buildBatch(), qty: 0);

      expect(_cart(container).isEmpty, isTrue);
      expect(_cart(container).lines, isEmpty);
    });
  });

  group('changing a line', () {
    test('sets a quantity, and removes the line at zero', () {
      final container = _container();
      final batch = buildBatch();

      _pos(container)
        ..addLine(product: buildProduct('Dolo 650'), batch: batch, qty: 1)
        ..setQty(batch.id, 5);
      expect(_cart(container).lines.single.qty, 5);

      _pos(container).setQty(batch.id, 0);

      expect(
        _cart(container).isEmpty,
        isTrue,
        reason: 'a quantity of zero is how the counter drops a line',
      );
    });

    test('a quantity change moves the line and document totals', () {
      final container = _container();
      final batch = buildBatch();

      _pos(container)
        ..addLine(
          product: buildProduct('Dolo 650'),
          batch: batch,
          qty: 1,
          rate: 100,
          gstPercent: 12,
        )
        ..setQty(batch.id, 4);

      final totals = _totals(container);
      expect(totals.subTotal, 400);
      expect(totals.taxTotal, 48);
      expect(totals.grandTotal, 448);
    });

    test('a rate change moves the totals', () {
      final container = _container();
      final batch = buildBatch();

      _pos(container)
        ..addLine(
          product: buildProduct('Dolo 650'),
          batch: batch,
          qty: 2,
          rate: 100,
          gstPercent: 0,
        )
        ..setRate(batch.id, 150);

      expect(_totals(container).grandTotal, 300);
    });

    test('a discount moves the taxable value and the tax with it', () {
      final container = _container();
      final batch = buildBatch();

      _pos(container)
        ..addLine(
          product: buildProduct('Dolo 650'),
          batch: batch,
          qty: 10,
          rate: 100,
          gstPercent: 12,
        )
        ..setDiscount(batch.id, 10);

      final totals = _totals(container);
      expect(totals.discountTotal, 100);
      expect(totals.subTotal, 900);
      expect(totals.taxTotal, 108);
      expect(totals.grandTotal, 1008);
    });

    test('a slab change moves only the tax', () {
      final container = _container();
      final batch = buildBatch();

      _pos(container)
        ..addLine(
          product: buildProduct('Dolo 650'),
          batch: batch,
          qty: 1,
          rate: 100,
          gstPercent: 12,
        )
        ..setGst(batch.id, 18);

      final totals = _totals(container);
      expect(totals.subTotal, 100);
      expect(totals.taxTotal, 18);
      expect(totals.grandTotal, 118);
    });

    test('removing a line leaves the others alone', () {
      final container = _container();

      _pos(container)
        ..addLine(
          product: buildProduct('Dolo 650'),
          batch: buildBatch(),
          qty: 1,
          rate: 100,
          gstPercent: 0,
        )
        ..addLine(
          product: buildProduct('Amoxicillin'),
          batch: buildBatch(id: 'batch-2', batchNo: 'B-2'),
          qty: 1,
          rate: 250,
          gstPercent: 0,
        )
        ..removeLine('batch-1');

      final lines = _cart(container).lines;
      expect(lines, hasLength(1));
      expect(lines.single.productName, 'Amoxicillin');
      expect(_totals(container).grandTotal, 250);
    });
  });

  group('how the sale will be settled', () {
    test(
      'records the customer, the mode, the tender and the place of supply',
      () {
        final container = _container();

        _pos(container)
          ..setCustomer('customer-1')
          ..setPaymentMode(PaymentMode.upi)
          ..setTendered(250)
          ..setPlaceOfSupply('Maharashtra');

        final cart = _cart(container);
        expect(cart.customerId, 'customer-1');
        expect(cart.paymentMode, PaymentMode.upi);
        expect(cart.tendered, 250);
        expect(cart.placeOfSupply, 'Maharashtra');
      },
    );

    test('clears the customer when null is passed', () {
      // `copyWith(customerId: null)` could not be told from "leave it alone",
      // which is why the cart carries its own `withCustomer`.
      final container = _container();

      _pos(container)
        ..setCustomer('customer-1')
        ..setCustomer(null);

      expect(_cart(container).customerId, isNull);
      expect(_cart(container).placeOfSupply, isNull);
    });

    test('a counter sale with no tender typed is paid in full', () {
      final container = _container();

      _pos(container).addLine(
        product: buildProduct('Dolo 650'),
        batch: buildBatch(),
        qty: 1,
        rate: 217.6,
        gstPercent: 0,
      );

      expect(_cart(container).paidFor(_totals(container).grandTotal), 217.6);
      expect(_cart(container).needsCustomer, isFalse);
    });

    test('a sale on account records nothing paid and needs a customer', () {
      final container = _container();

      _pos(container)
        ..addLine(
          product: buildProduct('Dolo 650'),
          batch: buildBatch(),
          qty: 1,
          rate: 217.6,
          gstPercent: 0,
        )
        ..setPaymentMode(PaymentMode.credit);

      expect(_cart(container).paidFor(_totals(container).grandTotal), 0);
      expect(_cart(container).needsCustomer, isTrue);
    });

    test('a tender above the bill is clamped to the bill', () {
      final container = _container();

      _pos(container)
        ..addLine(
          product: buildProduct('Dolo 650'),
          batch: buildBatch(),
          qty: 1,
          rate: 217.6,
          gstPercent: 0,
        )
        ..setTendered(500);

      expect(
        _cart(container).paidFor(_totals(container).grandTotal),
        217.6,
        reason: 'the change handed back is not a payment',
      );
      expect(
        SaleTotals.changeFor(
          tendered: _cart(container).tendered,
          total: _totals(container).grandTotal,
        ),
        282.4,
      );
    });

    test('clear empties the basket and forgets everything chosen for it', () {
      final container = _container();

      _pos(container)
        ..addLine(
          product: buildProduct('Dolo 650'),
          batch: buildBatch(),
          qty: 1,
        )
        ..setCustomer('customer-1')
        ..setPaymentMode(PaymentMode.upi)
        ..setTendered(500)
        ..setPlaceOfSupply('Maharashtra')
        ..clear();

      final cart = _cart(container);
      expect(cart.isEmpty, isTrue);
      expect(cart.customerId, isNull);
      expect(cart.paymentMode, PaymentMode.cash);
      expect(cart.tendered, 0);
      expect(cart.placeOfSupply, isNull);
    });
  });

  test('the basket starts empty, which is what disables the till', () {
    final container = _container();

    expect(_cart(container).isEmpty, isTrue);
    expect(_cart(container).isNotEmpty, isFalse);
    expect(_totals(container).grandTotal, 0);
  });
}
