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

/// The basket's totals, split intra-state, on the cart's own sale type.
SaleDocumentTotals _totals(ProviderContainer container) {
  final cart = _cart(container);
  return SaleTotals.forLines(
    cart.lines,
    split: TaxSplit.intraState,
    saleType: cart.saleType,
  );
}

void main() {
  group('adding a line', () {
    test('takes the batch counter price and the named slab as defaults', () {
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
      expect(
        line.gstPercent,
        defaultSaleGstPercent,
        reason:
            'the fixture product has no slab recorded, so the 5% POS default - '
            "the server's pos_default_gst_percent() - is what a line starts on",
      );
      expect(
        line.scheduleType,
        ScheduleType.h,
        reason: 'the schedule is a snapshot for the drug register, not a join',
      );
      expect(line.expiryDateIso, batch.expiryDate?.toIso8601String());
    });

    test("takes the product's own slab, and a recorded zero is a slab", () {
      final container = _container();

      _pos(container)
        ..addLine(
          product: buildProduct('Dolo 650', gstPercent: 12),
          batch: buildBatch(),
          qty: 1,
        )
        ..addLine(
          product: buildProduct('Amoxicillin', gstPercent: 0),
          batch: buildBatch(id: 'batch-2', batchNo: 'B-2'),
          qty: 1,
        );

      final lines = _cart(container).lines;
      expect(lines[0].gstPercent, 12);
      expect(
        lines[1].gstPercent,
        0,
        reason:
            'a recorded zero is a rate, not an absence - the default must not '
            'replace it, or a genuinely untaxed medicine would be taxed at 5%',
      );
    });

    test('carries a batch whose expiry nobody recorded', () {
      // Migration 00031 made `product_batches.expiry_date` nullable, and 145 of the
      // owner's opening-stock rows have none. The line says so rather than
      // inventing a date, and nothing here may throw on the way.
      final container = _container();

      _pos(container).addLine(
        product: buildProduct('Dolo 650'),
        batch: buildBatch(unknownExpiry: true, isUnknownBatch: true),
        qty: 1,
      );

      final line = _cart(container).lines.single;
      expect(line.expiryDateIso, isNull);
      expect(line.batchNo, 'B-1');
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
      // 2 x 12.50 is 25.00 charged, and the 5% tax is contained in that figure.
      // (Before D-075 this read 26.25: the tax was added to the rate.)
      expect(_totals(container).grandTotal, 25);
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
      // Four units at 100 is 400 charged, and at 12% that 400 contains 357.14 of
      // value and 42.86 of tax. (Before D-075 this read subTotal 400 / taxTotal 48 /
      // grandTotal 448.)
      expect(totals.subTotal, 357.14);
      expect(totals.taxTotal, 42.86);
      expect(totals.grandTotal, 400);
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

    test('a discount moves the price and the tax contained in it', () {
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

      // 1000 shelf price, 100 off, 900 charged - and at 12% that 900 contains
      // 803.57 of value and 96.43 of tax. (Before D-075 the same line read
      // subTotal 900 / taxTotal 108 / grandTotal 1008, with the tax charged on top.)
      final totals = _totals(container);
      expect(totals.discountTotal, 100);
      expect(totals.subTotal, 803.57);
      expect(totals.taxTotal, 96.43);
      expect(totals.grandTotal, 900);
    });

    test('a slab change moves the tax, not the price the customer pays', () {
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

      // One unit at 100 is 100 whichever slab applies, because the rate is the price
      // on the shelf. What the slab decides is how much of that 100 is tax: 10.71 at
      // 12%, 15.25 at 18%. (Before D-075 this read subTotal 100 / taxTotal 18 /
      // grandTotal 118 - the tax was added to the rate.)
      final totals = _totals(container);
      expect(totals.grandTotal, 100);
      expect(totals.subTotal, 84.75);
      expect(totals.taxTotal, 15.25);
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

    test('carries the sale type, and no other choice displaces it', () {
      // One type per document, and every `with…` on the cart rebuilds the whole
      // value - so a field left out of one of them would silently reset the type
      // that prices the basket.
      final container = _container();

      _pos(container)
        ..setSaleType(SaleType.package)
        ..setCustomer('customer-1')
        ..setTendered(500)
        ..addLine(
          product: buildProduct('Dolo 650'),
          batch: buildBatch(),
          qty: 1,
        );

      expect(_cart(container).saleType, SaleType.package);
      expect(_cart(container).lines, hasLength(1));
    });

    test('starts on a counter sale, the commonest one there is', () {
      expect(_cart(_container()).saleType, SaleType.counter);
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
