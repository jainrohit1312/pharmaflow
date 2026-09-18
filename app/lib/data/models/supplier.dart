/// Freezed/JSON model for the `suppliers` table (purchase counterparties).
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'supplier.freezed.dart';
part 'supplier.g.dart';

/// A supplier/distributor a pharmacy buys stock from.
@freezed
abstract class Supplier with _$Supplier {
  /// Creates an immutable [Supplier].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class; on
  /// the class itself it would be ignored (keys would stay camelCase).
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake, includeIfNull: false)
  const factory Supplier({
    required String id,
    required String pharmacyId,
    required String name,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? gstin,
    String? drugLicenseNo,
    String? contactPerson,
    String? phone,
    String? email,
    String? address,
    String? city,
    String? state,
    String? pincode,
    @Default(0) int creditDays,
    @Default(0) double openingBalance,
    @Default(true) bool isActive,
  }) = _Supplier;

  /// Decodes a snake_case Postgres/Supabase row into a [Supplier].
  factory Supplier.fromJson(Map<String, dynamic> json) =>
      _$SupplierFromJson(json);
}
