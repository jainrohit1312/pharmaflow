/// Tests for what each sale type needs before it can be sent.
///
/// Every rule here is also enforced by `checkout_sale()`, so these assertions are
/// about *when* the counter hears about it: before the write, next to the field
/// that is missing, rather than as a server error a round trip later. The wording
/// is deliberately the server's, so the two cannot drift into describing the same
/// requirement differently.
library;

import 'package:app/data/models/customer.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:app/features/sales/application/sale_requirements.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_customers_repository.dart';
import '../../../support/fake_inventory_repository.dart';
import '../../../support/fake_patients_repository.dart';
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

/// A patient with a name and a number on file.
Customer _patient({String? phone = '9876543210'}) =>
    buildCustomer('ZZTEST patient', id: 'patient-1', phone: phone);

/// Rings one line of an over-the-counter medicine into the basket.
void _ringUp(
  ProviderContainer container, {
  ScheduleType scheduleType = ScheduleType.otc,
}) {
  _pos(container).addLine(
    product: buildProduct('Dolo 650', scheduleType: scheduleType),
    batch: buildBatch(),
    qty: 1,
  );
}

/// The refusal this basket meets, if any.
String? _refusal(ProviderContainer container, {double? packageMarkupPercent}) =>
    saleRefusal(
      cart: _cart(container),
      packageMarkupPercent: packageMarkupPercent,
    );

/// The payment refusal this basket meets for a bill of [grandTotal], if any.
String? _paymentRefusal(
  ProviderContainer container, {
  required double grandTotal,
}) => paymentModeRefusal(cart: _cart(container), grandTotal: grandTotal);

void main() {
  group('a counter sale', () {
    test('needs a patient before the medicines', () {
      final container = _container();
      _ringUp(container);

      expect(_refusal(container), contains('needs a patient'));
    });

    test('is refused when the patient has no number on file', () {
      // The server takes the name and the mobile from the patient row and refuses
      // a sale whose patient has neither, so the counter asks here instead.
      final container = _container();
      _pos(container)
        ..setPatient(_patient(phone: null))
        ..addLine(
          product: buildProduct('Dolo 650'),
          batch: buildBatch(),
          qty: 1,
        );

      expect(_refusal(container), contains('no mobile number on file'));
    });

    test('passes with a patient who has a name and a number', () {
      final container = _container();
      _pos(container).setPatient(_patient());
      _ringUp(container);

      expect(_refusal(container), isNull);
    });

    test('needs the prescriber when a line is a Schedule H/H1/X one', () {
      final container = _container();
      _pos(container).setPatient(_patient());
      _ringUp(container, scheduleType: ScheduleType.h1);

      expect(_refusal(container), contains('prescriber'));
    });

    test('accepts a prescriber who is not in the master', () {
      final container = _container();
      _pos(container)
        ..setPatient(_patient())
        ..setDoctor(name: 'Dr Nobody');
      _ringUp(container, scheduleType: ScheduleType.h1);

      expect(
        _refusal(container),
        isNull,
        reason:
            'a name with no id is a prescriber the master has yet to record',
      );
    });
  });

  group('an IPD sale', () {
    test('needs the episode, by id or by the hospital’s own number', () {
      final container = _container();
      _pos(container)
        ..setSaleType(SaleType.ipdAdmission)
        ..setPatient(_patient());
      _ringUp(container);

      expect(_refusal(container), contains('admission number'));

      _pos(container).setHospitalReference('IPD-7');
      expect(_refusal(container), contains('treating doctor'));
    });

    test('passes with a chosen admission and a treating doctor', () {
      final container = _container();
      _pos(container)
        ..setSaleType(SaleType.ipdAdmission)
        ..setPatient(_patient())
        ..setAdmission(buildAdmission())
        ..setDoctor(name: 'Dr Rao');
      _ringUp(container);

      expect(_cart(container).admissionId, 'admission-1');
      expect(_cart(container).hospitalReference, 'IPD-7');
      expect(_refusal(container), isNull);
    });

    test('does not care whether the episode is discharged', () {
      // The counter is allowed to *find* a discharged episode and be told so by the
      // server's own refusal - "open a new episode or bill this as a counter sale" -
      // which names the episode. Refusing it here would replace that sentence with a
      // vaguer one.
      final container = _container();
      _pos(container)
        ..setSaleType(SaleType.ipdAdmission)
        ..setPatient(_patient())
        ..setAdmission(buildAdmission(status: 'discharged'))
        ..setDoctor(name: 'Dr Rao');
      _ringUp(container);

      expect(_refusal(container), isNull);
    });
  });

  group('a package sale', () {
    test('is refused while nobody has configured the markup', () {
      final container = _container();
      _pos(container)
        ..setSaleType(SaleType.package)
        ..setCustomer('hospital-account')
        ..setPatientDetails(name: 'ZZTEST patient', mobile: '9876543210')
        ..setHospitalReference('PKG-1');
      _ringUp(container);

      expect(_refusal(container), contains('markup'));
    });

    test('needs the account, the patient and the case reference', () {
      final container = _container();
      _pos(container).setSaleType(SaleType.package);
      _ringUp(container);

      expect(
        _refusal(container, packageMarkupPercent: 20),
        contains('account'),
      );

      _pos(container).setCustomer('hospital-account');
      expect(
        _refusal(container, packageMarkupPercent: 20),
        contains('patient’s name'),
      );

      _pos(
        container,
      ).setPatientDetails(name: 'ZZTEST patient', mobile: '9876543210');
      expect(
        _refusal(container, packageMarkupPercent: 20),
        contains('case reference'),
      );

      _pos(container).setHospitalReference('PKG-1');
      expect(_refusal(container, packageMarkupPercent: 20), isNull);
    });

    test('takes a configured zero markup as a configured value', () {
      final container = _container();
      _pos(container)
        ..setSaleType(SaleType.package)
        ..setCustomer('hospital-account')
        ..setPatientDetails(name: 'ZZTEST patient', mobile: '9876543210')
        ..setHospitalReference('PKG-1');
      _ringUp(container);

      expect(_refusal(container, packageMarkupPercent: 0), isNull);
    });

    test('does not need a prescriber, because the hospital is the buyer', () {
      final container = _container();
      _pos(container)
        ..setSaleType(SaleType.package)
        ..setCustomer('hospital-account')
        ..setPatientDetails(name: 'ZZTEST patient', mobile: '9876543210')
        ..setHospitalReference('PKG-1');
      _ringUp(container, scheduleType: ScheduleType.h1);

      expect(_refusal(container, packageMarkupPercent: 20), isNull);
    });
  });

  group('a transfer', () {
    test('needs a source, a destination and a reason', () {
      final container = _container();
      _pos(container).setSaleType(SaleType.transfer);
      _ringUp(container);

      expect(_refusal(container), contains('source and a destination'));

      _pos(container).setTransfer(from: 'Counter', to: 'Godown');
      expect(_refusal(container), contains('reason'));

      _pos(container).setTransfer(
        from: 'Counter',
        to: 'Godown',
        reason: 'Stock consolidation',
      );
      expect(_refusal(container), isNull);
    });

    test('refuses a transfer that goes nowhere', () {
      final container = _container();
      _pos(container)
        ..setSaleType(SaleType.transfer)
        ..setTransfer(
          from: 'Counter',
          to: 'Counter',
          reason: 'Stock consolidation',
        );
      _ringUp(container);

      expect(_refusal(container), contains('cannot be the same'));
    });

    test('does not need a patient, and carries no tax', () {
      final container = _container();
      _pos(container)
        ..setSaleType(SaleType.transfer)
        ..setTransfer(
          from: 'Counter',
          to: 'Godown',
          reason: 'Stock consolidation',
        );
      _ringUp(container);

      expect(_refusal(container), isNull);
      expect(_cart(container).paidFor(100), 0);
    });
  });

  group('the pricing rules the type brings with it', () {
    test('a discount above the cap is refused on a counter sale', () {
      final container = _container();
      _pos(container)
        ..setPatient(_patient())
        ..addLine(
          product: buildProduct('Dolo 650'),
          batch: buildBatch(),
          qty: 1,
        )
        ..setDiscount('batch-1', 15);

      expect(_refusal(container), contains('above 10%'));
    });

    test('a discount is refused outright on a package sale', () {
      final container = _container();
      _pos(container)
        ..setSaleType(SaleType.package)
        ..setCustomer('hospital-account')
        ..setPatientDetails(name: 'ZZTEST patient', mobile: '9876543210')
        ..setHospitalReference('PKG-1')
        ..addLine(
          product: buildProduct('Dolo 650'),
          batch: buildBatch(),
          qty: 1,
        )
        ..setDiscount('batch-1', 5);

      expect(
        _refusal(container, packageMarkupPercent: 20),
        contains('no discount'),
      );
    });

    test('a retail rate above the batch MRP is refused, naming the product', () {
      // And it is refused *before* the missing patient is reported: a bill with
      // both wrong names the line, because the line is what a counter can act on
      // without walking back a step.
      final container = _container();
      _pos(container).addLine(
        product: buildProduct('Dolo 650'),
        batch: buildBatch(),
        qty: 1,
        rate: 500,
      );

      expect(_refusal(container), contains('above its MRP'));
      expect(_refusal(container), contains('Dolo 650'));
    });
  });

  group('the refusal shape', () {
    test('is a sentence rather than a thrown error, so a screen can show it', () {
      final container = _container();
      _ringUp(container);

      expect(
        _refusal(container),
        isA<String>(),
        reason:
            'the controller turns it into a ValidationException; the rule itself '
            'has to be answerable without one',
      );
    });
  });

  group('the payment', () {
    test('needs nothing when the counter took the exact amount', () {
      final container = _container();
      _ringUp(container);

      // No tender and a mode that settles means the exact amount was handed over.
      expect(_paymentRefusal(container, grandTotal: 105), isNull);
    });

    test('needs nothing when the customer handed over more, which is change', () {
      final container = _container();
      _ringUp(container);
      _pos(container).setTendered(500);

      // The figure that gets stored is clamped to the bill: the change a cashier hands
      // back is not revenue, and `sales_payment_check()` refuses a sale paid beyond it.
      expect(_paymentRefusal(container, grandTotal: 105), isNull);
    });

    test('is refused when a settling mode is short of the bill', () {
      final container = _container();
      _ringUp(container);
      _pos(container).setTendered(10);

      // The rule the server does not have: `sales_payment_check()` (00020) refuses a sale
      // paid *more* than its bill and turns a shortfall into a balance whatever the mode
      // says, so this is the counter's own completeness check.
      expect(
        _paymentRefusal(container, grandTotal: 105),
        'Cash requires the full ₹105.00. ₹95.00 short.',
      );
    });

    test('names the mode the customer actually chose', () {
      final container = _container();
      _ringUp(container);
      _pos(container).setPaymentMode(PaymentMode.card);
      _pos(container).setTendered(50);

      expect(
        _paymentRefusal(container, grandTotal: 105),
        'Card requires the full ₹105.00. ₹55.00 short.',
      );
    });

    test('lets credit leave a balance when a customer owes it', () {
      final container = _container();
      _ringUp(container);
      _pos(container)
        ..setPaymentMode(PaymentMode.credit)
        ..setPatient(_patient());

      expect(_paymentRefusal(container, grandTotal: 105), isNull);
    });

    test('refuses a balance nobody owes, in the server\u2019s own words', () {
      final container = _container();
      _ringUp(container);
      _pos(container).setPaymentMode(PaymentMode.credit);

      // The server's sentence (migration 00019): "a sale with an unpaid balance needs a
      // customer to owe it". Unreachable through the counter's own screen today, because
      // every sale type that bills somebody already requires its party first - kept and
      // asserted because it is the server's rule, and a future type that allowed an
      // unowed balance would otherwise reach the till.
      expect(
        _paymentRefusal(container, grandTotal: 105),
        'A sale with an unpaid balance needs a customer to owe it.',
      );
    });

    test('says nothing about a transfer, which takes no payment at all', () {
      final container = _container();
      _pos(container).setSaleType(SaleType.transfer);
      _ringUp(container);

      // Stock moving between the owner's own locations: `paidFor` is zero for a transfer,
      // and `checkout_sale()` refuses one that carries any money.
      expect(_paymentRefusal(container, grandTotal: 105), isNull);
    });
  });
}
