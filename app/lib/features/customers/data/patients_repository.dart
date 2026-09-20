/// Supabase-backed repository for the patient identity and its admissions.
///
/// Separate from `CustomersRepository` on purpose, and over the same table: the
/// customer master is written by PostgREST through the columns its form owns
/// (`CustomerDraft`), while a patient's identity columns are **RPC-only** since
/// migration 00038 - `patient_code` is minted server-side by `save_patient()`, and
/// editing an existing master needs the owner or a pharmacist through
/// `update_patient()`. Two write paths with two permission models is a reason to
/// keep two repositories, not one with a footgun in it.
///
/// A patient IS a `customers` row (D-074), so every read here answers with
/// [Customer] rather than a second identity model.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/admission.dart';
import 'package:app/data/models/customer.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'patients_repository.g.dart';

/// Exposes the single [PatientsRepository].
@riverpod
PatientsRepository patientsRepository(Ref ref) =>
    PatientsRepository(ref.watch(supabaseClientProvider));

/// One patient lookup hit, and whether they have an open episode.
///
/// `search_patients()` counts the patient's active admissions because the details
/// step has to know whether to ask **which** admission: a patient with two open
/// episodes must choose one rather than be billed against an arbitrary one.
class PatientMatch {
  /// Creates a match.
  const PatientMatch({
    required this.patient,
    required this.activeAdmissionCount,
  });

  /// The patient themselves.
  final Customer patient;

  /// How many admissions of theirs are still active.
  final int activeAdmissionCount;

  /// Whether an IPD bill will have to ask which episode is being billed.
  bool get mustChooseAdmission => activeAdmissionCount > 1;

  /// Whether the patient is currently admitted at all.
  bool get isAdmitted => activeAdmissionCount > 0;
}

/// Data access for the patient identity, its admissions and the returning-patient
/// lookup.
///
/// Every call here goes through an RPC whose tenant is derived server-side from
/// `get_my_pharmacy_id()`, so - unlike `CustomersRepository` - none takes a
/// `pharmacyId`: there is no column to filter on from the client, and passing a
/// tenant the server ignores would suggest otherwise.
class PatientsRepository {
  /// Creates a repository backed by the shared Supabase client.
  PatientsRepository(this._client);

  final sb.SupabaseClient _client;

  /// Rows a lookup offers at once.
  ///
  /// The server caps the argument at 50; a counter looking for one person wants a
  /// short list to read, not a page.
  static const int searchLimit = 20;

  /// How many recent patients the counter opens with.
  static const int recentLimit = 5;

  /// Patients matching [term] by name, canonical mobile or patient-code prefix.
  ///
  /// An empty [term] is the pharmacy's own patient list rather than an error,
  /// which is what lets the same call serve "recent" and "searching".
  Future<List<PatientMatch>> search({
    String term = '',
    int limit = searchLimit,
    int offset = 0,
  }) async {
    try {
      final rows = await _client.rpc<dynamic>(
        'search_patients',
        params: <String, dynamic>{
          'p_term': term.trim().isEmpty ? null : term.trim(),
          'p_limit': limit,
          'p_offset': offset,
        },
      );
      return _rows(rows)
          .map(
            (row) => PatientMatch(
              patient: Customer.fromJson(row),
              activeAdmissionCount: _int(row['active_admission_count']),
            ),
          )
          .toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to search patients.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to search patients.',
        cause: error,
      );
    }
  }

  /// The patients registered most recently, newest first.
  ///
  /// A plain read rather than an RPC: "the last five patients this counter
  /// registered" is `order by created_at desc limit 5`, and inventing a server
  /// function for it would be a second place the ordering lives.
  Future<List<Customer>> recent({
    required String pharmacyId,
    int limit = recentLimit,
  }) async {
    try {
      final rows = await _client
          .from('customers')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .order('created_at', ascending: false)
          .limit(limit);
      return rows.map(Customer.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the recent patients.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the recent patients.',
        cause: error,
      );
    }
  }

  /// Registers a patient, or returns the one named by [patientId] unchanged.
  ///
  /// The code is minted by `next_patient_code()` inside the function, never here.
  /// A contact number is required - the patient's own, or a guardian's for a child
  /// or dependant - and the server refuses a patient with neither rather than
  /// inventing one. A repeat of the same registration inside ten minutes returns
  /// the same row instead of creating a second patient, which is what makes a
  /// double-tapped Save harmless.
  ///
  /// [patientId] is the returning-patient case: the operator picked an existing
  /// row, and passing it back is what assigns a code to a pre-Phase-7a customer
  /// without editing anything else about them.
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
    try {
      final row = await _client.rpc<dynamic>(
        'save_patient',
        params: <String, dynamic>{
          'p_name': name.trim(),
          'p_patient_id': patientId,
          'p_mobile': mobile,
          'p_address': address,
          'p_date_of_birth': dateOfBirth == null ? null : _isoDate(dateOfBirth),
          'p_age_years': ageYears,
          'p_age_months': ageMonths,
          'p_sex': sex,
          'p_guardian_name': guardianName,
          'p_guardian_phone': guardianPhone,
          'p_notes': notes,
        },
      );
      return Customer.fromJson(_row(row, 'the registered patient'));
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to register that patient.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to register that patient.',
        cause: error,
      );
    }
  }

  /// Every episode of [patientId], active first.
  Future<List<Admission>> admissionsFor({required String patientId}) async {
    try {
      final rows = await _client.rpc<dynamic>(
        'patient_admissions',
        params: <String, dynamic>{'p_customer_id': patientId},
      );
      return _rows(rows).map(Admission.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load that patient’s admissions.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load that patient’s admissions.',
        cause: error,
      );
    }
  }

  /// Finds or creates the episode named by (patient, hospital admission number).
  ///
  /// One call rather than a check-then-insert, because the screen has no way to
  /// know whether the hospital's number is new and a double submit would race
  /// itself. A number that already names an episode for this patient returns that
  /// episode, so re-billing a returning IPD patient does not open a second one.
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
    try {
      final row = await _client.rpc<dynamic>(
        'save_admission',
        params: <String, dynamic>{
          'p_customer_id': patientId,
          'p_admission_no': admissionNo.trim(),
          'p_hospital_id': hospitalId,
          'p_admitted_on': admittedOn == null ? null : _isoDate(admittedOn),
          'p_ward': ward,
          'p_bed': bed,
          'p_doctor_id': doctorId,
          'p_doctor_name': doctorName,
          'p_notes': notes,
        },
      );
      return Admission.fromJson(_row(row, 'the admission'));
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to open that admission.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to open that admission.',
        cause: error,
      );
    }
  }

  /// `YYYY-MM-DD`, the form a Postgres `date` argument wants.
  ///
  /// A full timestamp would compare as a different day once the server casts it,
  /// which for an admission date is the difference between the right episode and
  /// yesterday's.
  static String _isoDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  /// The single object a composite-returning function answers with.
  ///
  /// PostgREST returns a row-returning function as one JSON object; a `setof`
  /// would arrive as a list, so the list branch is tolerance for a shape
  /// difference rather than a case these functions can produce.
  static Map<String, dynamic> _row(dynamic response, String what) =>
      switch (response) {
        final List<dynamic> rows when rows.isNotEmpty =>
          (rows.first as Map).cast<String, dynamic>(),
        final Map<dynamic, dynamic> map => map.cast<String, dynamic>(),
        _ => throw ServerException(
          message: 'The till did not return $what it wrote.',
        ),
      };

  /// The rows a table-returning function answers with.
  static List<Map<String, dynamic>> _rows(dynamic response) =>
      switch (response) {
        final List<dynamic> rows =>
          rows
              .map((row) => (row as Map).cast<String, dynamic>())
              .toList(growable: false),
        final Map<dynamic, dynamic> map => <Map<String, dynamic>>[
          map.cast<String, dynamic>(),
        ],
        _ => const <Map<String, dynamic>>[],
      };

  /// A whole number out of a JSON value, whatever the driver typed it as.
  static int _int(dynamic value) => switch (value) {
    final int number => number,
    final num number => number.toInt(),
    final String text => int.tryParse(text) ?? 0,
    _ => 0,
  };
}
