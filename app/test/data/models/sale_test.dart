/// Unit tests for the `sales` row: its `sale_type` converter and the Phase 7a
/// identity columns.
library;

import 'package:app/data/models/sale.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('saleTypeFromDb', () {
    test('maps each literal the column can hold', () {
      expect(saleTypeFromDb('counter'), SaleType.counter);
      expect(saleTypeFromDb('ipd_admission'), SaleType.ipdAdmission);
      expect(saleTypeFromDb('package'), SaleType.package);
      expect(saleTypeFromDb('transfer'), SaleType.transfer);
    });

    test('is case and whitespace insensitive', () {
      expect(saleTypeFromDb(' IPD_ADMISSION '), SaleType.ipdAdmission);
      expect(saleTypeFromDb('Transfer'), SaleType.transfer);
    });

    test('falls back to counter for null and an unknown literal', () {
      // Every pre-Phase-7a row is a counter sale, and the column defaults to one -
      // which is also why a caller that forgets to send a type gets a counter sale
      // rather than a refusal.
      expect(saleTypeFromDb(null), SaleType.counter);
      expect(saleTypeFromDb('nonsense'), SaleType.counter);
    });
  });

  group('SaleTypeX', () {
    test('round-trips through its DB literal', () {
      for (final type in SaleType.values) {
        expect(saleTypeFromDb(type.dbValue), type);
      }
    });

    test('labels every type', () {
      expect(SaleType.counter.label, 'Counter');
      expect(SaleType.ipdAdmission.label, 'IPD');
      expect(SaleType.package.label, 'Package');
      expect(SaleType.transfer.label, 'Transfer');
    });

    test('only the retail two are a pharmacy sale, and only those discount', () {
      for (final type in SaleType.values) {
        final retail =
            type == SaleType.counter || type == SaleType.ipdAdmission;
        expect(type.isPharmacySale, retail);
        expect(
          type.hasDiscount,
          retail,
          reason:
              'a package sale and a transfer have no discount concept (D-067)',
        );
      }
    });

    test('only a transfer carries no GST', () {
      for (final type in SaleType.values) {
        expect(type.chargesGst, type != SaleType.transfer);
      }
    });
  });

  group('Sale.fromJson', () {
    test('decodes the type and the identity the type requires', () {
      final sale = Sale.fromJson(<String, dynamic>{
        'id': 'sale-1',
        'pharmacy_id': 'ph-1',
        'invoice_no': 'INV-1',
        'sale_date': '2026-09-20T10:00:00.000Z',
        'created_at': '2026-09-20T10:00:00.000Z',
        'updated_at': '2026-09-20T10:00:00.000Z',
        'sale_type': 'ipd_admission',
        'customer_id': 'patient-1',
        'admission_id': 'admission-1',
        'patient_name': 'ZZTEST patient',
        'patient_mobile': '9876543210',
        'doctor_id': 'doctor-1',
        'doctor_name': 'Dr Rao',
        'hospital_reference': 'IPD-7',
        'idempotency_key': 'key-1',
        'sub_total': 100,
        'tax_total': 5,
        'grand_total': 105,
      });

      expect(sale.saleType, SaleType.ipdAdmission);
      expect(sale.admissionId, 'admission-1');
      expect(sale.patientName, 'ZZTEST patient');
      expect(sale.patientMobile, '9876543210');
      expect(sale.doctorName, 'Dr Rao');
      expect(sale.hospitalReference, 'IPD-7');
      expect(sale.idempotencyKey, 'key-1');
      expect(sale.grandTotal, 105);
    });

    test('a pre-Phase-7a row is a counter sale with nothing invented', () {
      final sale = Sale.fromJson(<String, dynamic>{
        'id': 'sale-1',
        'pharmacy_id': 'ph-1',
        'invoice_no': 'INV-1',
        'sale_date': '2026-09-18T10:00:00.000Z',
        'created_at': '2026-09-18T10:00:00.000Z',
        'updated_at': '2026-09-18T10:00:00.000Z',
      });

      expect(
        sale.saleType,
        SaleType.counter,
        reason:
            'the column defaults to counter, so an absent key reads that way',
      );
      expect(sale.patientName, isNull);
      expect(sale.admissionId, isNull);
      expect(sale.hospitalReference, isNull);
      expect(sale.idempotencyKey, isNull);
    });

    test('decodes the transfer shape', () {
      final sale = Sale.fromJson(<String, dynamic>{
        'id': 'sale-2',
        'pharmacy_id': 'ph-1',
        'invoice_no': 'TR-1',
        'sale_date': '2026-09-20T10:00:00.000Z',
        'created_at': '2026-09-20T10:00:00.000Z',
        'updated_at': '2026-09-20T10:00:00.000Z',
        'sale_type': 'transfer',
        'from_location': 'Counter',
        'to_location': 'Godown',
        'transfer_reason': 'Stock consolidation',
        'transfer_note_no': 'TR-1',
      });

      expect(sale.saleType, SaleType.transfer);
      expect(sale.fromLocation, 'Counter');
      expect(sale.toLocation, 'Godown');
      expect(sale.transferReason, 'Stock consolidation');
      expect(sale.customerId, isNull);
    });
  });
}
