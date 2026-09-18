/// Freezed/JSON model for the `pharmacies` table — one tenant per row.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'pharmacy.freezed.dart';
part 'pharmacy.g.dart';

/// A pharmacy tenant: the top-level organisation of a PharmaFlow install.
@freezed
abstract class Pharmacy with _$Pharmacy {
  /// Creates an immutable [Pharmacy].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class; on
  /// the class itself it would be ignored, so JSON keys would stay camelCase.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Pharmacy({
    required String id,
    required String name,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? address,
    String? city,
    String? state,
    String? pincode,
    String? phone,
    String? email,
    String? gstin,
    String? drugLicenseNo,
    String? logoUrl,
  }) = _Pharmacy;

  /// Decodes a snake_case Postgres/Supabase row into a [Pharmacy].
  factory Pharmacy.fromJson(Map<String, dynamic> json) =>
      _$PharmacyFromJson(json);
}

/// Display helpers for [Pharmacy].
extension PharmacyDisplayX on Pharmacy {
  /// The non-empty parts of `address`, `city`, `state` and `pincode`
  /// joined with `', '`, or an empty string when all four are `null`.
  String get displayAddress => [address, city, state, pincode]
      .whereType<String>()
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .join(', ');
}
