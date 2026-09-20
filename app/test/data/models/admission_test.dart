/// Unit tests for [Admission] — the episode an IPD bill posts its credit to
/// (D-074).
library;

import 'package:app/data/models/admission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Admission.fromJson', () {
    test('decodes the row save_admission() returns', () {
      final admission = Admission.fromJson(<String, dynamic>{
        'id': 'a-1',
        'pharmacy_id': 'ph-1',
        'customer_id': 'c-1',
        'hospital_id': 'h-1',
        'admission_no': 'IPD-7',
        'admitted_on': '2026-09-19',
        'ward': 'B',
        'bed': '12',
        'treating_doctor_id': 'd-1',
        'treating_doctor_name': 'Dr Rao',
        'status': 'active',
        'notes': null,
        'created_at': '2026-09-19T00:00:00.000Z',
        'updated_at': '2026-09-19T00:00:00.000Z',
      });

      expect(admission.admissionNo, 'IPD-7');
      expect(admission.admittedOn, DateTime(2026, 9, 19));
      expect(admission.treatingDoctorName, 'Dr Rao');
      expect(admission.isActive, isTrue);
      expect(admission.isDischarged, isFalse);
    });

    test('decodes the projection patient_admissions() returns', () {
      // The lookup names the hospital rather than the tenant, and carries neither
      // the patient id nor the doctor's master id - which is why those are
      // nullable on the model.
      final admission = Admission.fromJson(<String, dynamic>{
        'id': 'a-1',
        'admission_no': 'IPD-7',
        'hospital_id': 'h-1',
        'hospital_name': 'Rohit Kidney & Stone Hospital',
        'admitted_on': '2026-09-19',
        'discharged_on': null,
        'ward': null,
        'bed': null,
        'treating_doctor_name': null,
        'status': 'active',
        'created_at': '2026-09-19T00:00:00.000Z',
      });

      expect(admission.hospitalName, 'Rohit Kidney & Stone Hospital');
      expect(admission.pharmacyId, isNull);
      expect(admission.customerId, isNull);
    });

    test('a discharged episode says so', () {
      final admission = Admission.fromJson(<String, dynamic>{
        'id': 'a-1',
        'admission_no': 'IPD-7',
        'admitted_on': '2026-09-19',
        'discharged_on': '2026-09-20',
        'status': 'discharged',
        'created_at': '2026-09-19T00:00:00.000Z',
      });

      expect(admission.isActive, isFalse);
      expect(admission.isDischarged, isTrue);
    });
  });

  group('AdmissionX.label', () {
    test('names the episode, the hospital, the doctor and the bed', () {
      final admission = Admission.fromJson(<String, dynamic>{
        'id': 'a-1',
        'admission_no': 'IPD-7',
        'hospital_name': 'Rohit Kidney & Stone Hospital',
        'admitted_on': '2026-09-19',
        'ward': 'B',
        'bed': '12',
        'treating_doctor_name': 'Dr Rao',
        'created_at': '2026-09-19T00:00:00.000Z',
      });

      expect(
        admission.label,
        'IPD-7 · Rohit Kidney & Stone Hospital · Dr Rao · Ward B, Bed 12',
      );
    });

    test('leaves out what the episode does not have', () {
      final admission = Admission.fromJson(<String, dynamic>{
        'id': 'a-1',
        'admission_no': 'IPD-8',
        'admitted_on': '2026-09-19',
        'ward': '  ',
        'created_at': '2026-09-19T00:00:00.000Z',
      });

      expect(
        admission.label,
        'IPD-8',
        reason:
            'a blank ward is not a ward, and an empty segment is not a label',
      );
    });
  });
}
