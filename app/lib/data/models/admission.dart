/// Freezed/JSON model for the `admissions` table: one hospital episode for one
/// patient.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'admission.freezed.dart';
part 'admission.g.dart';

/// One hospital episode (D-074).
///
/// An admission is a different thing from a patient: one patient has many over
/// time, each with its own outstanding balance, and they never mix.
/// [admissionNo] is the hospital's **own** IPD/OPD number - the external identity
/// of the episode, unique per pharmacy, and not a UUID of ours. It is what a bill
/// prints as `hospital_reference`, and what `save_admission()` finds an existing
/// episode by rather than creating a second one.
///
/// The model carries two projections, which is why several fields are nullable:
/// `patient_admissions()` names the hospital ([hospitalName]) but not the tenant,
/// while `save_admission()` returns the table row itself (with [pharmacyId] and
/// [customerId], and without the hospital's name).
@freezed
abstract class Admission with _$Admission {
  /// Creates an immutable [Admission].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Admission({
    required String id,
    required String admissionNo,
    required DateTime admittedOn,
    required DateTime createdAt,
    @Default('active') String status,
    String? pharmacyId,
    String? customerId,
    String? hospitalId,
    String? hospitalName,
    DateTime? dischargedOn,
    String? ward,
    String? bed,
    String? treatingDoctorId,
    String? treatingDoctorName,
    String? notes,
    DateTime? updatedAt,
  }) = _Admission;

  /// Decodes a snake_case Postgres/Supabase row into an [Admission].
  factory Admission.fromJson(Map<String, dynamic> json) =>
      _$AdmissionFromJson(json);
}

/// Episode helpers for [Admission].
extension AdmissionX on Admission {
  /// Whether the episode is still open to new charges.
  ///
  /// `checkout_sale()` refuses to bill a discharged episode - "open a new episode
  /// or bill this as a counter sale" - so the picker marks these first and the
  /// screen refuses the rest.
  bool get isActive => status == 'active';

  /// Whether the account is closed to new charges.
  bool get isDischarged => !isActive;

  /// The one line a picker shows: the hospital's number, then whatever else is
  /// known about the episode.
  String get label {
    final hospital = hospitalName?.trim();
    final doctor = treatingDoctorName?.trim();
    final wardBed = <String>[
      if ((ward ?? '').trim().isNotEmpty) 'Ward ${ward!.trim()}',
      if ((bed ?? '').trim().isNotEmpty) 'Bed ${bed!.trim()}',
    ].join(', ');
    return <String>[
      admissionNo,
      if (hospital != null && hospital.isNotEmpty) hospital,
      if (doctor != null && doctor.isNotEmpty) doctor,
      if (wardBed.isNotEmpty) wardBed,
    ].join(' · ');
  }
}
