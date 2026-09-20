/// Tests for the `jsonb` payload `checkout_sale()` is handed.
///
/// The payload is the one place where the RPC's field names have to be spelled
/// exactly, and the one place a field can be *stored* that nobody meant to send:
/// the function copies several of them straight into the row. So what these assert
/// is mostly what is **absent** for a given sale type.
library;

import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_cart_line.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/data/sale_checkout.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:flutter_test/flutter_test.dart';

/// One line as the counter holds it.
SaleCartLine _cartLine({
  int qty = 1,
  double rate = 105,
  double discountPercent = 0,
}) => SaleCartLine(
  productId: 'product-1',
  productName: 'Dolo 650',
  scheduleType: ScheduleType.otc,
  batchId: 'batch-1',
  batchNo: 'B-1',
  qty: qty,
  rate: rate,
  discountPercent: discountPercent,
  gstPercent: 5,
  mrp: rate,
);

/// That line as the payload carries it, priced on [saleType]'s basis.
SaleCheckoutLine _line({
  int qty = 1,
  double rate = 105,
  double discountPercent = 0,
  SaleType saleType = SaleType.counter,
}) {
  final line = _cartLine(
    qty: qty,
    rate: rate,
    discountPercent: discountPercent,
  );
  return SaleCheckoutLine.from(
    line: line,
    totals: SaleTotals.forLine(
      line,
      split: TaxSplit.intraState,
      saleType: saleType,
    ),
    saleType: saleType,
  );
}

/// A sale of one 105 line, of whichever type, carrying every field the cart could
/// possibly hold - which is what makes the "and nothing else" assertions mean
/// something.
SaleCheckout _sale(SaleType saleType) => SaleCheckout(
  lines: <SaleCheckoutLine>[_line(saleType: saleType)],
  saleType: saleType,
  customerId: 'patient-1',
  patientName: 'ZZTEST patient',
  patientMobile: '9876543210',
  admissionId: 'admission-1',
  doctorId: 'doctor-1',
  doctorName: 'Dr Rao',
  hospitalReference: 'IPD-7',
  amountPaid: 105,
  fromLocation: 'Counter',
  toLocation: 'Godown',
  transferReason: 'Stock consolidation',
  idempotencyKey: 'key-1',
);

void main() {
  group('the payload names its type', () {
    test('and the four of them round-trip through their literals', () {
      for (final type in SaleType.values) {
        expect(_sale(type).toPayload()['sale_type'], type.dbValue);
      }
    });

    test('the document totals are never sent', () {
      // The function sums the lines itself, so a stored grand total cannot disagree
      // with the lines it describes.
      final payload = _sale(SaleType.counter).toPayload();
      expect(payload.keys, isNot(contains('grand_total')));
      expect(payload.keys, isNot(contains('sub_total')));
      expect(payload.keys, isNot(contains('tax_total')));
    });

    test('the items and the settlement always travel', () {
      final payload = _sale(SaleType.counter).toPayload();
      expect(payload['items'], hasLength(1));
      expect(payload['payment_mode'], 'cash');
      expect(payload['amount_paid'], 105);
    });
  });

  group('a counter sale carries the patient and the prescriber', () {
    test('and nothing that belongs to another type', () {
      final payload = _sale(SaleType.counter).toPayload();

      expect(payload['customer_id'], 'patient-1');
      expect(payload['doctor_id'], 'doctor-1');
      expect(payload['doctor_name'], 'Dr Rao');
      expect(
        payload.keys,
        isNot(contains('admission_id')),
        reason: 'a counter sale has no episode',
      );
      expect(payload.keys, isNot(contains('hospital_reference')));
      expect(payload.keys, isNot(contains('from_location')));
      expect(payload.keys, isNot(contains('patient_name')));
    });
  });

  group('an IPD sale carries the episode', () {
    test('by id and by the hospital’s own number, with the prescriber', () {
      final payload = _sale(SaleType.ipdAdmission).toPayload();

      expect(payload['admission_id'], 'admission-1');
      expect(payload['hospital_reference'], 'IPD-7');
      expect(payload['doctor_name'], 'Dr Rao');
      expect(payload.keys, isNot(contains('from_location')));
    });
  });

  group('a package sale carries the patient as text', () {
    test(
      'because the account is the debtor and the patient is traceability',
      () {
        final payload = _sale(SaleType.package).toPayload();

        expect(payload['customer_id'], 'patient-1');
        expect(payload['patient_name'], 'ZZTEST patient');
        expect(payload['patient_mobile'], '9876543210');
        expect(payload['hospital_reference'], 'IPD-7');
        expect(
          payload.keys,
          isNot(contains('doctor_name')),
          reason: 'the hospital is buying, so there is no prescriber to name',
        );
        expect(payload.keys, isNot(contains('admission_id')));
      },
    );
  });

  group('a transfer carries its two locations and its reason', () {
    test('and no party, no payment and no episode', () {
      final payload = _sale(SaleType.transfer).toPayload();

      expect(payload['from_location'], 'Counter');
      expect(payload['to_location'], 'Godown');
      expect(payload['transfer_reason'], 'Stock consolidation');
      expect(
        payload.keys,
        isNot(contains('customer_id')),
        reason: 'the function refuses a transfer with a party, not ignores it',
      );
      expect(payload['amount_paid'], 0);
      expect(payload.keys, isNot(contains('admission_id')));
      expect(payload.keys, isNot(contains('patient_mobile')));
    });

    test('whatever the cart was holding, because the type decides', () {
      // The cart keeps everything (a mis-tap must not lose a pinned patient), so
      // the payload is what shapes the document - and the function copies several
      // of these straight into the row, so sending one would store it.
      final transfer = _sale(SaleType.transfer).toPayload();
      for (final key in <String>[
        'customer_id',
        'patient_name',
        'patient_mobile',
        'doctor_id',
        'doctor_name',
        'hospital_reference',
      ]) {
        expect(transfer.keys, isNot(contains(key)), reason: key);
      }
    });
  });

  group('a line', () {
    test('carries no discount on a type that has none', () {
      final line = _line(discountPercent: 10, saleType: SaleType.package);

      expect(line.discountPercent, 0);
      expect(line.toPayload()['discount_percent'], 0);
      expect(
        line.discountAmount,
        0,
        reason: 'the money follows the percentage, not the other way round',
      );
    });

    test('keeps the counter’s discount on a pharmacy sale', () {
      final line = _line(rate: 100, discountPercent: 10);

      expect(line.discountPercent, 10);
      expect(line.discountAmount, 10);
      expect(line.totalAmount, 90);
    });

    test('names the batch, the quantity, the rate and the schedule', () {
      final payload = _line(qty: 3, rate: 40).toPayload();

      expect(payload['batch_id'], 'batch-1');
      expect(payload['qty'], 3);
      expect(payload['rate'], 40);
      expect(payload['total_amount'], 120);
      expect(payload['schedule_type'], 'OTC');
    });

    test('carries the tax the counter previewed', () {
      // 105 at 5% contains 100 of value and 5 of tax, half to each head.
      final payload = _line().toPayload();

      expect(payload['gst_percent'], 5);
      expect(payload['tax_amount'], 5);
      expect(payload['cgst_amount'], 2.5);
      expect(payload['sgst_amount'], 2.5);
      expect(payload['igst_amount'], 0);
    });
  });

  group('the submission key', () {
    test('travels when there is one, and is left out when there is not', () {
      expect(_sale(SaleType.counter).toPayload()['idempotency_key'], 'key-1');

      final withoutKey = SaleCheckout(
        lines: <SaleCheckoutLine>[_line()],
        customerId: 'patient-1',
        amountPaid: 105,
      );
      expect(
        withoutKey.toPayload().keys,
        isNot(contains('idempotency_key')),
        reason: 'an absent key is the function’s own default of "no key"',
      );
    });
  });
}
