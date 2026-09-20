/// Registering a patient at the counter, and finding the one a mobile already
/// belongs to.
///
/// The write goes through `save_patient()`, which mints the patient code
/// server-side and has its own ten-minute double-submit guard - so a double-tapped
/// Save is one patient rather than two. What this adds is the half the server
/// deliberately does not do: **asking** whether the number belongs to someone
/// already on file, rather than deduplicating behind the counter's back (families
/// share a mobile number, so a match is a question, not a conflict).
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/features/customers/application/patient_lookup.dart';
import 'package:app/features/customers/data/patients_repository.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'patient_registration_controller.g.dart';

/// A patient the counter just registered, or agreed to reuse.
class PatientRegistration {
  /// Creates a registration result.
  const PatientRegistration({required this.patient, required this.reused});

  /// The patient the bill will be put on.
  final Customer patient;

  /// Whether this was a returning patient rather than a new registration, which is
  /// what the screen says out loud so the operator knows what happened.
  final bool reused;
}

/// Registers a patient, or pins the one a mobile number already belongs to.
@riverpod
class PatientRegistrationController extends _$PatientRegistrationController {
  @override
  Future<PatientRegistration?> build() async => null;

  /// The patients a [mobile] already belongs to, exactly matched.
  ///
  /// A read rather than a write: the sheet shows them and lets the operator decide.
  /// The list is usually empty or one row, and a match is not a refusal - two
  /// people in a family legitimately share a number.
  Future<List<Customer>> matchesForMobile(String mobile) async {
    final term = mobile.trim();
    if (term.isEmpty) {
      return const <Customer>[];
    }
    final digits = term.replaceAll(RegExp('[^0-9]'), '');
    if (digits.length < 10) {
      return const <Customer>[];
    }
    final matches = await ref
        .read(patientsRepositoryProvider)
        .search(term: term);
    return matches
        .where((match) => _sameNumber(match.patient.phone, digits))
        .map((match) => match.patient)
        .toList(growable: false);
  }

  /// Registers a new patient from what the sheet collected, and pins them.
  ///
  /// The code is the server's to mint and is read off the row it answers with;
  /// nothing here invents one.
  Future<PatientRegistration> register({
    required String name,
    required String mobile,
    DateTime? dateOfBirth,
    int? ageYears,
    int? ageMonths,
    String? sex,
    String? guardianName,
    String? guardianPhone,
    String? address,
  }) async {
    if (name.trim().isEmpty) {
      throw const ValidationException(message: 'A patient needs a name.');
    }

    state = const AsyncLoading<PatientRegistration?>();
    try {
      final patient = await ref
          .read(patientsRepositoryProvider)
          .register(
            name: name,
            mobile: mobile,
            dateOfBirth: dateOfBirth,
            ageYears: ageYears,
            ageMonths: ageMonths,
            sex: sex,
            guardianName: guardianName,
            guardianPhone: guardianPhone,
            address: address,
          );
      ref.read(posControllerProvider.notifier).setPatient(patient);
      // A patient who was not on file a moment ago is on the list now, and the
      // recent list is what the next counter opens with.
      ref.invalidate(recentPatientsProvider);
      final result = PatientRegistration(patient: patient, reused: false);
      state = AsyncData<PatientRegistration?>(result);
      return result;
    } on Object catch (error, stackTrace) {
      state = AsyncError<PatientRegistration?>(error, stackTrace);
      rethrow;
    }
  }

  /// Pins a patient who was already on file, without touching their record.
  ///
  /// This is the returning-patient path (and the answer to the duplicate question):
  /// `save_patient` is handed the id and returns the row **unchanged**, which is
  /// also what assigns a code to a customer registered before Phase 7a. Invoice
  /// details never silently edit the patient master.
  Future<PatientRegistration> reuse(Customer patient) async {
    state = const AsyncLoading<PatientRegistration?>();
    try {
      final saved = await ref
          .read(patientsRepositoryProvider)
          .register(name: patient.name, patientId: patient.id);
      ref.read(posControllerProvider.notifier).setPatient(saved);
      final result = PatientRegistration(patient: saved, reused: true);
      state = AsyncData<PatientRegistration?>(result);
      return result;
    } on Object catch (error, stackTrace) {
      state = AsyncError<PatientRegistration?>(error, stackTrace);
      rethrow;
    }
  }

  /// Whether a stored number is the same mobile as the digits just typed.
  ///
  /// The server stores canonical ten-digit form, so this only has to tolerate a row
  /// written before Phase 7a as `+91 98…`: the last ten digits are the number.
  static bool _sameNumber(String? stored, String digits) {
    final other = (stored ?? '').replaceAll(RegExp('[^0-9]'), '');
    if (other.length < 10 || digits.length < 10) {
      return false;
    }
    return other.substring(other.length - 10) ==
        digits.substring(digits.length - 10);
  }
}
