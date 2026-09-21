/// Tests for the checkout write.
///
/// The order of the write is the whole design (D-023): availability is re-read
/// and checked first, then the sale goes to the till as one RPC. So these tests
/// assert both halves - that a short line never reaches the till, and that what
/// does reach it is exactly what the counter showed.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/repositories/pharmacy_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:app/features/sales/application/sale_checkout_controller.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_customers_repository.dart';
import '../../../support/fake_inventory_repository.dart';
import '../../../support/fake_patients_repository.dart';
import '../../../support/fake_pharmacy_repository.dart';
import '../../../support/fake_products_repository.dart';
import '../../../support/fake_sales_repository.dart';

/// A container with the till, the catalogue and the tenant scope stubbed out.
ProviderContainer _container({
  required FakeSalesRepository sales,
  FakeProductsRepository? products,
  FakePharmacyRepository? pharmacy,
}) {
  final container = ProviderContainer(
    overrides: [
      salesRepositoryProvider.overrideWithValue(sales),
      productsRepositoryProvider.overrideWithValue(
        products ?? FakeProductsRepository(products: const <Product>[]),
      ),
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      pharmacyRepositoryProvider.overrideWithValue(
        pharmacy ?? FakePharmacyRepository(),
      ),
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
  FakePharmacyRepository? pharmacy,
  int onHand = 50,
}) {
  final products = FakeProductsRepository(products: const <Product>[]);
  products.batchQuantities['batch-1'] = onHand;
  return (
    container: _container(
      sales: sales ?? FakeSalesRepository(),
      products: products,
      pharmacy: pharmacy,
    ),
    products: products,
  );
}

/// The patient a pharmacy sale has to name.
Customer _patient() =>
    buildCustomer('ZZTEST patient', id: 'patient-1', phone: '9876543210');

/// Rings one line into the basket, with the patient a pharmacy sale now needs.
///
/// The patient is pinned by default because almost every test here is about what
/// happens *after* the bill is legal; the ones about the requirement itself pass
/// `withPatient: false`, which is the omission they are testing.
void _ringUp(
  ProviderContainer container, {
  int qty = 2,
  double rate = 100,
  double gstPercent = 5,
  String batchId = 'batch-1',
  double mrp = 250,
  bool withPatient = true,
}) {
  final pos = container.read(posControllerProvider.notifier);
  if (withPatient) {
    pos.setPatient(_patient());
  }
  pos.addLine(
    product: buildProduct('Dolo 650'),
    // The MRP sits above every rate these tests charge, because it is a ceiling: a
    // fixture that broke its own rule would be testing a bill the counter refuses.
    batch: buildBatch(id: batchId, batchNo: 'B-$batchId', mrp: mrp),
    qty: qty,
    rate: rate,
    gstPercent: gstPercent,
  );
}

/// The basket's current totals.
SaleDocumentTotals _totals(ProviderContainer container) {
  final cart = container.read(posControllerProvider);
  return SaleTotals.forLines(
    cart.lines,
    split: TaxSplit.intraState,
    saleType: cart.saleType,
    billDiscount: cart.billDiscount,
  );
}

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
  test('writes the basket as one sale, and returns what the till stored', () async {
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
    // 2 x 100 is 200 charged, and at 5% that 200 contains 190.48 of value and
    // 9.52 of tax, half each. (Before D-075 the same line read taxable 200 /
    // tax 24 / total 224: the tax was added to the rate instead of extracted from
    // it, and the slab was the old blanket 12%.)
    expect(line.taxAmount, 9.52);
    expect(line.cgstAmount, 4.76);
    expect(line.sgstAmount, 4.76);
    expect(line.igstAmount, 0);
    expect(line.totalAmount, 200);
    expect(line.scheduleType, ScheduleType.otc);

    // The document totals are the till's business, not the client's: sending them
    // would let a stored grand total disagree with the lines it describes.
    final header = payload.toPayload();
    expect(header.keys, isNot(contains('grand_total')));
    expect(header.keys, isNot(contains('sub_total')));

    // And the document that came home agrees with its own lines.
    expect(saved.grandTotal, 200);
    expect(saved.subTotal, 190.48);
    expect(saved.taxTotal, 9.52);
    expect(saved.balanceDue, 0);
    expect(saved.status, SaleStatus.completed);
    expect(saved.paymentMode, PaymentMode.cash);
  });

  test(
    'writes the bill-level discount, and answers with the bill it produced',
    () async {
      final sales = FakeSalesRepository();
      final container = _withStock(sales: sales).container;
      container.read(posControllerProvider.notifier).setBillDiscount(20);
      _ringUp(container);

      final saved = await _write(container);

      // The payload carries the ONE amount and not a per-line share of it, which is what
      // the RPC shares out - and what comes home is the bill it produced: 200 less 20 is
      // 180, of which 171.43 is value and 8.57 the tax it contains.
      expect(sales.checkouts.single.billDiscount, 20);
      expect(sales.checkouts.single.toPayload()['bill_discount'], 20);
      expect(saved.grandTotal, 180);
      expect(saved.discountTotal, 20);
      expect(saved.subTotal, 171.43);
      expect(saved.taxTotal, 8.57);
    },
  );

  test(
    'a counter sale with no tender typed records the bill as paid',
    () async {
      final sales = FakeSalesRepository();
      final container = _withStock(sales: sales).container;
      _ringUp(container);

      await _write(container);

      expect(sales.checkouts.single.amountPaid, 200);
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
    // The rule this protects - a bill that is not settled at the counter needs a
    // party to carry it - is now enforced earlier and more precisely by the
    // per-type requirements: a counter sale cannot be built without a patient at
    // all. So the sentence the counter reports moved, and the assertion moved with
    // it rather than being loosened to accept either. (Before Phase 7a this read
    // "Choose the customer who is owing the balance, or take the payment in full.")
    final sales = FakeSalesRepository();
    final container = _withStock(sales: sales).container;
    _ringUp(container, withPatient: false);

    container
        .read(posControllerProvider.notifier)
        .setPaymentMode(PaymentMode.credit);

    await expectLater(
      _write(container),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          contains('needs a patient'),
        ),
      ),
    );
    expect(sales.checkouts, isEmpty);
  });

  test('writes a credit sale when a patient carries the balance', () async {
    final sales = FakeSalesRepository();
    final container = _withStock(sales: sales).container;
    _ringUp(container);

    container.read(posControllerProvider.notifier)
      ..setPaymentMode(PaymentMode.credit)
      ..setPatient(_patient());

    final saved = await _write(container);

    expect(saved.status, SaleStatus.credit);
    expect(saved.customerId, 'patient-1');
    expect(saved.amountPaid, 0);
    expect(saved.balanceDue, 200);
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
      container.read(posControllerProvider.notifier).setPatient(_patient());

      await expectLater(_write(container), throwsA(isA<ServerException>()));

      expect(container.read(posControllerProvider).isEmpty, isFalse);
      expect(container.read(saleCheckoutControllerProvider).hasError, isTrue);
    },
  );

  group('the typed payload', () {
    test('names its type and the patient the counter pinned', () async {
      final sales = FakeSalesRepository();
      final container = _withStock(sales: sales).container;
      _ringUp(container);
      container.read(posControllerProvider.notifier).setPatient(_patient());

      final saved = await _write(container);

      final payload = sales.checkouts.single;
      expect(payload.saleType, SaleType.counter);
      expect(payload.toPayload()['sale_type'], 'counter');
      expect(payload.customerId, 'patient-1');
      expect(saved.saleType, SaleType.counter);
      expect(saved.patientName, 'ZZTEST patient');
      expect(saved.patientMobile, '9876543210');
    });

    test('carries the prescriber and the episode on an IPD sale', () async {
      final sales = FakeSalesRepository();
      final container = _withStock(sales: sales).container;
      _ringUp(container);
      container.read(posControllerProvider.notifier)
        ..setSaleType(SaleType.ipdAdmission)
        ..setPatient(_patient())
        ..setAdmission(buildAdmission())
        ..setDoctor(id: 'doctor-1', name: 'Dr Rao');

      final saved = await _write(container);

      final payload = sales.checkouts.single.toPayload();
      expect(payload['admission_id'], 'admission-1');
      expect(payload['doctor_name'], 'Dr Rao');
      expect(saved.admissionId, 'admission-1');
      expect(saved.doctorName, 'Dr Rao');
    });

    test(
      'carries the patient as text and no prescriber on a package sale',
      () async {
        final sales = FakeSalesRepository();
        final container = _withStock(
          sales: sales,
          pharmacy: FakePharmacyRepository(
            pharmacy: buildPharmacy(packageMarkupPercent: 20),
          ),
        ).container;
        // The type first, on an empty basket: a package sale is priced from cost, so
        // the basis cannot change once something has been rung up.
        container.read(posControllerProvider.notifier)
          ..setSaleType(SaleType.package)
          ..setCustomer('hospital-account')
          ..setPatientDetails(name: 'ZZTEST patient', mobile: '9876543210')
          ..setHospitalReference('PKG-1');
        // And no patient is pinned: a package bill's party is the account, with the
        // patient travelling as text beside it.
        _ringUp(container, withPatient: false);

        final saved = await _write(container);

        final payload = sales.checkouts.single.toPayload();
        expect(payload['customer_id'], 'hospital-account');
        expect(payload['patient_name'], 'ZZTEST patient');
        expect(payload.keys, isNot(contains('doctor_name')));
        expect(saved.saleType, SaleType.package);
      },
    );

    test('carries the two locations and no payment on a transfer', () async {
      final sales = FakeSalesRepository();
      final container = _withStock(sales: sales).container;
      container.read(posControllerProvider.notifier)
        ..setSaleType(SaleType.transfer)
        ..setTransfer(
          from: 'Counter',
          to: 'Godown',
          reason: 'Stock consolidation',
        );
      _ringUp(container);
      container.read(posControllerProvider.notifier).setTendered(500);

      final saved = await _write(container);

      final payload = sales.checkouts.single.toPayload();
      expect(payload['from_location'], 'Counter');
      expect(payload['amount_paid'], 0);
      expect(payload.keys, isNot(contains('customer_id')));
      expect(saved.fromLocation, 'Counter');
      expect(saved.amountPaid, 0);
    });
  });

  group('what is refused before anything is written', () {
    test('a counter sale with no patient never reaches the till', () async {
      final sales = FakeSalesRepository();
      final container = _withStock(sales: sales).container;
      _ringUp(container, withPatient: false);

      await expectLater(
        _write(container),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('needs a patient'),
          ),
        ),
      );
      expect(sales.checkouts, isEmpty);
    });

    test('an IPD sale with no episode never reaches the till', () async {
      final sales = FakeSalesRepository();
      final container = _withStock(sales: sales).container;
      _ringUp(container);
      container.read(posControllerProvider.notifier)
        ..setSaleType(SaleType.ipdAdmission)
        ..setPatient(_patient());

      await expectLater(_write(container), throwsA(isA<ValidationException>()));
      expect(sales.checkouts, isEmpty);
    });

    test(
      'a Schedule H/H1/X bill with no prescriber never reaches the till',
      () async {
        final sales = FakeSalesRepository();
        final container = _withStock(sales: sales).container;
        container.read(posControllerProvider.notifier)
          ..setPatient(_patient())
          ..addLine(
            product: buildProduct('Dolo 650', scheduleType: ScheduleType.h1),
            batch: buildBatch(batchNo: 'B-batch-1'),
            qty: 1,
          );

        await expectLater(
          _write(container),
          throwsA(
            isA<ValidationException>().having(
              (error) => error.message,
              'message',
              contains('prescriber'),
            ),
          ),
        );
        expect(sales.checkouts, isEmpty);
      },
    );

    test('a package sale is refused while nobody configured a markup', () async {
      // D-070: the column has no default on purpose, so this is the refusal a
      // freshly onboarded pharmacy actually meets. Everything else about the bill
      // is in place - only the markup is missing - so the refusal cannot be about
      // anything else.
      final sales = FakeSalesRepository();
      final container = _withStock(sales: sales).container;
      container.read(posControllerProvider.notifier)
        ..setSaleType(SaleType.package)
        ..setCustomer('hospital-account')
        ..setPatientDetails(name: 'ZZTEST patient', mobile: '9876543210')
        ..setHospitalReference('PKG-1');
      _ringUp(container, withPatient: false);

      await expectLater(
        _write(container),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('package markup'),
          ),
        ),
      );
      expect(sales.checkouts, isEmpty);
    });

    test('the requirement is checked before the stock is even read', () async {
      // The order matters to what the counter is told: a bill that names no patient
      // is refused for the patient rather than for stock, and saying so here keeps
      // a later refactor from quietly reversing the two.
      final products = FakeProductsRepository(products: const <Product>[]);
      products.batchQuantities['batch-1'] = 0;
      final container = _container(
        sales: FakeSalesRepository(),
        products: products,
      );
      _ringUp(container, qty: 5, withPatient: false);

      await expectLater(
        _write(container),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('needs a patient'),
          ),
        ),
      );
    });
  });

  group('the submission key', () {
    test(
      'is minted once, sent with the write, and cleared with the basket',
      () async {
        final sales = FakeSalesRepository();
        final container = _withStock(sales: sales).container;
        _ringUp(container);
        container.read(posControllerProvider.notifier).setPatient(_patient());

        await _write(container);

        expect(sales.checkouts.single.idempotencyKey, isNotNull);
        expect(
          container.read(posControllerProvider).idempotencyKey,
          isNull,
          reason: 'the basket is emptied with the sale, and so is its key',
        );
      },
    );

    test('is reused by a retry, so a timed-out submit stays one sale', () async {
      final sales = FakeSalesRepository()
        ..errorToThrow = const ServerException(message: 'Timed out.');
      final container = _withStock(sales: sales).container;
      _ringUp(container);
      container.read(posControllerProvider.notifier).setPatient(_patient());

      await expectLater(_write(container), throwsA(isA<ServerException>()));
      final first = container.read(posControllerProvider).idempotencyKey;
      expect(first, isNotNull);

      sales.errorToThrow = null;
      await _write(container);

      expect(
        sales.checkouts.single.idempotencyKey,
        first,
        reason:
            'the server answers a repeated key with the original sale, which is '
            'exactly what a retry of an unknown outcome needs',
      );
    });

    test(
      'is dropped once the basket is edited, because the payload changed',
      () async {
        final sales = FakeSalesRepository()
          ..errorToThrow = const ServerException(message: 'Timed out.');
        final container = _withStock(sales: sales).container;
        _ringUp(container);
        container.read(posControllerProvider.notifier).setPatient(_patient());

        await expectLater(_write(container), throwsA(isA<ServerException>()));
        final first = container.read(posControllerProvider).idempotencyKey;
        expect(first, isNotNull);

        // The cashier corrects the quantity and submits again: a new payload, so a
        // new key - reusing the old one would hand back the sale already written.
        container.read(posControllerProvider.notifier).setQty('batch-1', 1);
        expect(container.read(posControllerProvider).idempotencyKey, isNull);

        sales.errorToThrow = null;
        await _write(container);

        final retried = sales.checkouts.last.idempotencyKey;
        expect(retried, isNotNull);
        expect(retried, isNot(first));
      },
    );
  });
}
