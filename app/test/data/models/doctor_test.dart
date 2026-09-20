/// Unit tests for [Doctor] — the prescriber a bill may name (D-072).
library;

import 'package:app/data/models/doctor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Doctor.fromJson', () {
    test('decodes a prescriber', () {
      final doctor = Doctor.fromJson(<String, dynamic>{
        'id': 'd-1',
        'pharmacy_id': 'ph-1',
        'name': 'Dr Rao',
        'specialization': 'Nephrology',
        'contact': '9876543210',
        'is_active': true,
        'created_at': '2026-09-20T00:00:00.000Z',
        'updated_at': '2026-09-20T00:00:00.000Z',
      });

      expect(doctor.name, 'Dr Rao');
      expect(doctor.specialization, 'Nephrology');
      expect(doctor.isActive, isTrue);
    });

    test('decodes a prescriber the master only has a name for', () {
      final doctor = Doctor.fromJson(<String, dynamic>{
        'id': 'd-1',
        'pharmacy_id': 'ph-1',
        'name': 'Dr Rao',
        'created_at': '2026-09-20T00:00:00.000Z',
        'updated_at': '2026-09-20T00:00:00.000Z',
      });

      expect(doctor.name, 'Dr Rao');
      expect(doctor.specialization, isNull);
      expect(doctor.contact, isNull);
      expect(
        doctor.isActive,
        isTrue,
        reason: 'a master row with no is_active key is an active prescriber',
      );
    });
  });

  group('DoctorX.label', () {
    test('is the name alone without a speciality', () {
      final doctor = Doctor.fromJson(<String, dynamic>{
        'id': 'd-1',
        'pharmacy_id': 'ph-1',
        'name': 'Dr Rao',
        'created_at': '2026-09-20T00:00:00.000Z',
        'updated_at': '2026-09-20T00:00:00.000Z',
      });

      expect(doctor.label, 'Dr Rao');
    });

    test(
      'names the speciality after the name, which is what a bill prints',
      () {
        final doctor = Doctor.fromJson(<String, dynamic>{
          'id': 'd-1',
          'pharmacy_id': 'ph-1',
          'name': 'Dr Rao',
          'specialization': '  Nephrology  ',
          'created_at': '2026-09-20T00:00:00.000Z',
          'updated_at': '2026-09-20T00:00:00.000Z',
        });

        expect(doctor.label, 'Dr Rao · Nephrology');
      },
    );
  });
}
