/// Freezed/JSON model for the `customers` table (walk-in and ledger).
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'customer.freezed.dart';
part 'customer.g.dart';

/// A customer a pharmacy bills, optionally on credit.
///
/// Since Phase 7a this is also the **patient master** (D-074): the same row carries
/// a server-minted [patientCode] and the demographics the details step collects.
/// Every patient column is nullable, and a `null` [patientCode] means exactly
/// "registered before Phase 7a and not yet used as a patient" - existing customers
/// are not converted, and it is not "patient number zero".
///
/// [patientCode] is minted by `next_patient_code()` inside `save_patient()`, never
/// by a client, and the unique key is on the code rather than on [phone]: families
/// share a mobile number, so two rows may legitimately carry one number.
@freezed
abstract class Customer with _$Customer {
  /// Creates an immutable [Customer].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class; on
  /// the class itself it would be ignored (keys would stay camelCase).
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake, includeIfNull: false)
  const factory Customer({
    required String id,
    required String pharmacyId,
    required String name,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? phone,
    String? email,
    String? address,
    String? gstin,
    @Default(0) double openingBalance,
    @Default(0) int loyaltyPoints,
    @Default(true) bool isActive,
    String? patientCode,
    DateTime? dateOfBirth,
    int? ageYears,
    int? ageMonths,
    String? sex,
    String? guardianName,
    String? guardianPhone,
    String? notes,
  }) = _Customer;

  /// Decodes a snake_case Postgres/Supabase row into a [Customer].
  factory Customer.fromJson(Map<String, dynamic> json) =>
      _$CustomerFromJson(json);
}
