/// The returning-patient lookup, and the episodes a patient already has.
///
/// Separate from `customer_options.dart` because it answers a different question:
/// that one loads the accounts a bill may be put on, while this one is the
/// counter's "who is this?" - a search over the identity a pharmacy sale has to
/// name (D-074).
library;

import 'package:app/data/models/admission.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/customers/data/patients_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'patient_lookup.g.dart';

/// Patients matching [term] by name, canonical mobile or patient-code prefix.
///
/// An empty term lists the pharmacy's own patients, so the picker opens with
/// something to tap rather than an empty box - the same shape as the product
/// search. The query is debounced by the screen rather than here, because the
/// delay is a policy of that field.
@riverpod
Future<List<PatientMatch>> patientSearch(Ref ref, String term) async {
  return ref.watch(patientsRepositoryProvider).search(term: term);
}

/// The patients registered most recently, newest first.
///
/// Five of them: `PatientsRepository.recentLimit`, because a memory aid rather than
/// a list - the pharmacy's last few registrations are the ones at the door again
/// this week, and anything older is what the search field is for.
@riverpod
Future<List<Customer>> recentPatients(Ref ref) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref.watch(patientsRepositoryProvider).recent(pharmacyId: pharmacyId);
}

/// Every episode of [patientId], active first.
///
/// Read when a patient is pinned on an IPD sale, because a patient with a single
/// open episode is billed against it without asking and one with several has to
/// choose. A failed read costs the list, not the sale: the counter can still type
/// the hospital's number, which is the other half of what the server accepts.
@riverpod
Future<List<Admission>> patientAdmissions(Ref ref, String patientId) async {
  return ref
      .watch(patientsRepositoryProvider)
      .admissionsFor(patientId: patientId);
}
