/// Shared test doubles for the patient identity and its admissions.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/admission.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/features/customers/data/patients_repository.dart';

/// Builds an admission with only the fields a test cares about.
///
/// [hospitalName] is the projection `patient_admissions()` returns; a test that
/// wants the bare table row `save_admission()` answers with passes `null`.
Admission buildAdmission({
  String id = 'admission-1',
  String admissionNo = 'IPD-7',
  String status = 'active',
  DateTime? admittedOn,
  DateTime? dischargedOn,
  String? hospitalName = 'Rohit Kidney & Stone Hospital',
  String? ward,
  String? bed,
  String? treatingDoctorName,
}) => Admission(
  id: id,
  admissionNo: admissionNo,
  status: status,
  admittedOn: admittedOn ?? DateTime(2026, 9, 19),
  createdAt: DateTime(2026, 9, 19),
  dischargedOn: dischargedOn,
  hospitalName: hospitalName,
  ward: ward,
  bed: bed,
  treatingDoctorName: treatingDoctorName,
);

/// Wraps [patient] as a lookup hit with [activeAdmissionCount] open episodes.
PatientMatch buildPatientMatch(
  Customer patient, {
  int activeAdmissionCount = 0,
}) =>
    PatientMatch(patient: patient, activeAdmissionCount: activeAdmissionCount);

/// An in-memory [PatientsRepository].
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing, so
/// the fake never needs a Supabase client - which is the whole point, because a real
/// `SupabaseClient` cannot be constructed without an initialised backend.
///
/// It applies the two behaviours the real calls promise and a screen depends on:
/// `search` filters its rows by the term (so a test can type and see the list
/// narrow), and `saveAdmission` returns an episode for the number it was given
/// rather than inventing a second one for a repeat.
class FakePatientsRepository implements PatientsRepository {
  /// Creates a fake holding [patients], as the lookup would return them.
  FakePatientsRepository({
    List<Customer> patients = const <Customer>[],
    List<Admission> admissions = const <Admission>[],
  }) : patients = List<Customer>.of(patients),
       admissions = List<Admission>.of(admissions);

  /// The patients a lookup searches.
  List<Customer> patients;

  /// The episodes `admissionsFor` answers with, for every patient.
  List<Admission> admissions;

  /// The terms `search` was asked for, in order.
  final List<String> searchedTerms = <String>[];

  /// The registrations `register` was handed, in order.
  final List<Map<String, Object?>> registrations = <Map<String, Object?>>[];

  /// The admissions `saveAdmission` was handed, in order.
  final List<Map<String, Object?>> savedAdmissions = <Map<String, Object?>>[];

  /// When set, the next call throws it.
  Exception? errorToThrow;

  /// The patient `register` answers with, so a test can assert on the code the
  /// server would have minted. Defaults to a fresh row built from the arguments.
  Customer? patientToReturn;

  @override
  Future<List<PatientMatch>> search({
    String term = '',
    int limit = PatientsRepository.searchLimit,
    int offset = 0,
  }) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    searchedTerms.add(term);
    return _matches(term).take(limit).toList(growable: false);
  }

  @override
  Future<List<Customer>> recent({
    required String pharmacyId,
    int limit = PatientsRepository.recentLimit,
  }) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    return patients.take(limit).toList(growable: false);
  }

  @override
  Future<Customer> register({
    required String name,
    String? patientId,
    String? mobile,
    String? address,
    DateTime? dateOfBirth,
    int? ageYears,
    int? ageMonths,
    String? sex,
    String? guardianName,
    String? guardianPhone,
    String? notes,
  }) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    registrations.add(<String, Object?>{
      'name': name,
      'patientId': patientId,
      'mobile': mobile,
      'address': address,
      'dateOfBirth': dateOfBirth,
      'ageYears': ageYears,
      'ageMonths': ageMonths,
      'sex': sex,
      'guardianName': guardianName,
      'guardianPhone': guardianPhone,
      'notes': notes,
    });

    final returning = patientId == null ? null : _byId(patientId);
    if (returning != null) {
      return returning;
    }

    final created =
        patientToReturn ??
        Customer(
          id: 'patient-${patients.length + 1}',
          pharmacyId: 'ph-1',
          name: name,
          phone: mobile ?? guardianPhone,
          address: address,
          patientCode: 'PT-0000${patients.length + 1}',
          dateOfBirth: dateOfBirth,
          ageYears: ageYears,
          ageMonths: ageMonths,
          sex: sex,
          guardianName: guardianName,
          guardianPhone: guardianPhone,
          notes: notes,
          createdAt: DateTime(2026, 9, 20),
          updatedAt: DateTime(2026, 9, 20),
        );
    patients.insert(0, created);
    return created;
  }

  @override
  Future<List<Admission>> admissionsFor({required String patientId}) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    return admissions;
  }

  @override
  Future<Admission> saveAdmission({
    required String patientId,
    required String admissionNo,
    DateTime? admittedOn,
    String? ward,
    String? bed,
    String? doctorId,
    String? doctorName,
    String? hospitalId,
    String? notes,
  }) async {
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    savedAdmissions.add(<String, Object?>{
      'patientId': patientId,
      'admissionNo': admissionNo,
      'admittedOn': admittedOn,
      'ward': ward,
      'bed': bed,
      'doctorId': doctorId,
      'doctorName': doctorName,
    });

    for (final admission in admissions) {
      if (admission.admissionNo == admissionNo) {
        return admission;
      }
    }
    final created = buildAdmission(
      id: 'admission-${admissions.length + 1}',
      admissionNo: admissionNo,
      admittedOn: admittedOn,
      ward: ward,
      bed: bed,
      treatingDoctorName: doctorName,
    );
    admissions.insert(0, created);
    return created;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );

  /// The matches [term] would find, the way `search_patients()` decides them.
  List<PatientMatch> _matches(String term) {
    final needle = term.trim().toLowerCase();
    final digits = needle.replaceAll(RegExp('[^0-9]'), '');
    return patients
        .where((patient) {
          if (needle.isEmpty) {
            return true;
          }
          final code = (patient.patientCode ?? '').toLowerCase();
          final name = patient.name.toLowerCase();
          final phone = (patient.phone ?? '').replaceAll(RegExp('[^0-9]'), '');
          return name.contains(needle) ||
              code.startsWith(needle) ||
              (digits.isNotEmpty && phone.endsWith(digits));
        })
        .map(
          (patient) => buildPatientMatch(
            patient,
            activeAdmissionCount: admissions
                .where((admission) => admission.isActive)
                .length,
          ),
        )
        .toList(growable: false);
  }

  /// The patient with [id], or `null`.
  Customer? _byId(String id) {
    for (final patient in patients) {
      if (patient.id == id) {
        return patient;
      }
    }
    return null;
  }
}
