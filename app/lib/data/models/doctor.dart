/// Freezed/JSON model for the `doctors` table: the prescriber a bill may name.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'doctor.freezed.dart';
part 'doctor.g.dart';

/// A prescriber, scoped to one pharmacy (D-072).
///
/// A doctor appears on a sale for **prescription compliance only** and takes no
/// share of anything, which is why there is no commercial column here: a Schedule
/// H/H1/X bill has to name who prescribed it, and that is the whole relationship.
/// A sale keeps its own `doctor_name` snapshot, so re-pointing or renaming a master
/// row later never rewrites a printed bill.
@freezed
abstract class Doctor with _$Doctor {
  /// Creates an immutable [Doctor].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Doctor({
    required String id,
    required String pharmacyId,
    required String name,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? specialization,
    String? contact,
    @Default(true) bool isActive,
  }) = _Doctor;

  /// Decodes a snake_case Postgres/Supabase row into a [Doctor].
  factory Doctor.fromJson(Map<String, dynamic> json) => _$DoctorFromJson(json);
}

/// Display helpers for [Doctor].
extension DoctorX on Doctor {
  /// The one-line label a picker shows: the name, and the speciality when there
  /// is one. The name always comes first, because it is what a bill prints.
  String get label {
    final speciality = specialization?.trim();
    if (speciality == null || speciality.isEmpty) {
      return name;
    }
    return '$name · $speciality';
  }
}
