/// Unit tests for [Customer] as the patient master (D-074).
library;

import 'package:app/data/models/customer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Customer.fromJson', () {
    test('decodes the patient identity and the demographics', () {
      final customer = Customer.fromJson(<String, dynamic>{
        'id': 'c-1',
        'pharmacy_id': 'ph-1',
        'name': 'ZZTEST patient',
        'phone': '9876543210',
        'patient_code': 'PT-00042',
        'date_of_birth': '1990-05-04',
        'sex': 'female',
        'guardian_name': 'ZZTEST guardian',
        'guardian_phone': '9123456780',
        'notes': 'allergic to penicillin',
        'created_at': '2026-09-20T00:00:00.000Z',
        'updated_at': '2026-09-20T00:00:00.000Z',
      });

      expect(customer.patientCode, 'PT-00042');
      expect(customer.dateOfBirth, DateTime(1990, 5, 4));
      expect(customer.sex, 'female');
      expect(customer.guardianName, 'ZZTEST guardian');
      expect(customer.guardianPhone, '9123456780');
      expect(customer.ageYears, isNull);
    });

    test('a child registered by age carries years and months', () {
      final customer = Customer.fromJson(<String, dynamic>{
        'id': 'c-2',
        'pharmacy_id': 'ph-1',
        'name': 'ZZTEST child',
        'phone': '9123456780',
        'guardian_phone': '9123456780',
        'patient_code': 'PT-00043',
        'age_years': 1,
        'age_months': 6,
        'created_at': '2026-09-20T00:00:00.000Z',
        'updated_at': '2026-09-20T00:00:00.000Z',
      });

      expect(customer.ageYears, 1);
      expect(customer.ageMonths, 6);
      expect(customer.dateOfBirth, isNull);
      expect(
        customer.phone,
        '9123456780',
        reason:
            "save_patient() stores a guardian's number as the patient's own "
            'contact when there is none of theirs, which is what makes the family '
            'findable by the number they gave',
      );
      expect(customer.guardianPhone, '9123456780');
    });

    test('a pre-Phase-7a row has no patient identity, and is not patient zero', () {
      // A NULL patient_code means "registered before Phase 7a and not yet used as a
      // patient" - the seed assigns one on first use, and nothing here may invent
      // one.
      final customer = Customer.fromJson(<String, dynamic>{
        'id': 'c-3',
        'pharmacy_id': 'ph-1',
        'name': 'A supplier account',
        'created_at': '2026-09-18T00:00:00.000Z',
        'updated_at': '2026-09-18T00:00:00.000Z',
      });

      expect(customer.patientCode, isNull);
      expect(customer.dateOfBirth, isNull);
      expect(customer.ageYears, isNull);
      expect(customer.ageMonths, isNull);
      expect(customer.sex, isNull);
      expect(customer.guardianName, isNull);
      expect(customer.guardianPhone, isNull);
      expect(customer.notes, isNull);
    });
  });
}
