/// Unit tests for the two documents the sale acts are handed.
///
/// The payloads are a contract with server-side functions, not an implementation detail of one
/// repository method, so they are asserted here rather than through a widget: these are the keys the
/// SQL whitelist reads, and the one thing a caller must NOT be able to do - name a money column or a
/// line - is exactly what the builder never emits.
library;

import 'package:app/features/sales/data/sale_act_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cancel', () {
    test('is the bill and nothing else, because the status is the whole act', () {
      final payload = SaleActPayload.cancel(saleId: 's-1');

      expect(payload['sale_id'], 's-1');
      expect(
        payload.containsKey('reason'),
        isFalse,
        reason:
            'an empty reason is not a reason, and the server has no column for one',
      );
      expect(payload['idempotency_key'], isNull);
    });

    test('carries a reason when there is one, trimmed', () {
      expect(
        SaleActPayload.cancel(
          saleId: 's-1',
          reason: '  rung up twice  ',
        )['reason'],
        'rung up twice',
      );
    });

    test('never names a money column or a line', () {
      final payload = SaleActPayload.cancel(saleId: 's-1', reason: 'x');

      for (final forbidden in <String>[
        'grand_total',
        'sub_total',
        'amount_paid',
        'balance_due',
        'items',
        'status',
      ]) {
        expect(
          payload.containsKey(forbidden),
          isFalse,
          reason:
              'the status is moved by the server, and the money is not this act',
        );
      }
    });
  });

  group('editIdentity', () {
    test(
      'sends only the keys it was given, so an unnamed field is left alone',
      () {
        final payload = SaleActPayload.editIdentity(
          saleId: 's-1',
          doctorName: 'Dr Rao',
        );

        expect(payload, <String, dynamic>{
          'sale_id': 's-1',
          'doctor_name': 'Dr Rao',
        });
        expect(
          payload.containsKey('patient_name'),
          isFalse,
          reason:
              'an absent key means "leave it", which is why it is not sent as null',
        );
      },
    );

    test('sends the patient pair together when both are supplied', () {
      final payload = SaleActPayload.editIdentity(
        saleId: 's-1',
        patientName: 'Asha',
        patientMobile: '9876500061',
      );

      expect(payload['patient_name'], 'Asha');
      expect(
        payload['patient_mobile'],
        '9876500061',
        reason:
            'a pharmacy bill carries the name and the number together, so the sheet always '
            'sends both and the server never has to refuse the half pair',
      );
    });

    test('trims every value, because the server stores what it is given', () {
      final payload = SaleActPayload.editIdentity(
        saleId: 's-1',
        patientName: '  Asha  ',
        patientAddress: '  12 Test Road ',
        hospitalReference: ' OPD-1 ',
      );

      expect(payload['patient_name'], 'Asha');
      expect(payload['patient_address'], '12 Test Road');
      expect(payload['hospital_reference'], 'OPD-1');
    });

    test('never names a money column, a line or the party link', () {
      final payload = SaleActPayload.editIdentity(
        saleId: 's-1',
        doctorName: 'Dr Rao',
      );

      for (final forbidden in <String>[
        'grand_total',
        'sub_total',
        'discount_total',
        'amount_paid',
        'balance_due',
        'customer_id',
        'items',
        'status',
        'sale_type',
      ]) {
        expect(
          payload.containsKey(forbidden),
          isFalse,
          reason:
              'the server refuses these by name, naming the sale return that can change them',
        );
      }
    });
  });
}
