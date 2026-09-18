/// Freezed/JSON model for the `customers` table (walk-in and ledger).
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'customer.freezed.dart';
part 'customer.g.dart';

/// A customer a pharmacy bills, optionally on credit.
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
  }) = _Customer;

  /// Decodes a snake_case Postgres/Supabase row into a [Customer].
  factory Customer.fromJson(Map<String, dynamic> json) =>
      _$CustomerFromJson(json);
}
