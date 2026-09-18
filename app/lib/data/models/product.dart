/// Freezed/JSON model for the `products` table plus the drug-schedule enum.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'product.freezed.dart';
part 'product.g.dart';

/// The statutory drug schedule a product is sold under.
enum ScheduleType {
  /// Over the counter; no prescription needed.
  otc,

  /// Schedule H; sold only against a prescription.
  h,

  /// Schedule H1; prescription required and recorded.
  h1,

  /// Schedule X; prescription required, tightly controlled.
  x,

  /// Narcotic; prescription required, tightly controlled.
  narcotic,
}

/// Parses a Postgres `schedule_type` literal into a [ScheduleType].
///
/// The DB literals `'OTC'`, `'H'`, `'H1'`, `'X'` and `'narcotic'` are
/// accepted case-insensitively; anything else falls back to
/// [ScheduleType.otc].
ScheduleType scheduleTypeFromDb(String? raw) =>
    switch (raw?.trim().toLowerCase()) {
      'h' => ScheduleType.h,
      'h1' => ScheduleType.h1,
      'x' => ScheduleType.x,
      'narcotic' => ScheduleType.narcotic,
      _ => ScheduleType.otc,
    };

/// Maps [ScheduleType] to its DB literal, UI label and prescription rule.
extension ScheduleTypeX on ScheduleType {
  /// The literal stored in the Postgres `schedule_type` column.
  String get dbValue => switch (this) {
    ScheduleType.otc => 'OTC',
    ScheduleType.h => 'H',
    ScheduleType.h1 => 'H1',
    ScheduleType.x => 'X',
    ScheduleType.narcotic => 'narcotic',
  };

  /// The label shown in the UI.
  String get label => switch (this) {
    ScheduleType.otc => 'OTC',
    ScheduleType.h => 'Schedule H',
    ScheduleType.h1 => 'Schedule H1',
    ScheduleType.x => 'Schedule X',
    ScheduleType.narcotic => 'Narcotic',
  };

  /// Whether a prescription is required (H, H1, X and narcotic).
  bool get requiresPrescription => switch (this) {
    ScheduleType.otc => false,
    _ => true,
  };
}

/// Round-trips [ScheduleType] with the Postgres `schedule_type` literal.
class ScheduleTypeConverter extends JsonConverter<ScheduleType, String?> {
  /// Creates the converter referenced by `@ScheduleTypeConverter()`.
  const ScheduleTypeConverter();

  /// Decodes `'OTC'`, `'H'`, `'H1'`, `'X'` or `'narcotic'`.
  @override
  ScheduleType fromJson(String? json) => scheduleTypeFromDb(json);

  /// Emits the DB literal, e.g. `'H1'` or `'narcotic'`.
  @override
  String? toJson(ScheduleType object) => object.dbValue;
}

/// A sellable product (medicine) belonging to a pharmacy.
@freezed
abstract class Product with _$Product {
  /// Creates an immutable [Product].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class; on
  /// the class itself it would be ignored (keys would stay camelCase).
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Product({
    required String id,
    required String pharmacyId,
    required String name,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? genericName,
    String? brand,
    String? manufacturer,
    String? hsnCode,
    String? category,
    @Default(ScheduleType.otc)
    @ScheduleTypeConverter()
    ScheduleType scheduleType,
    String? packSize,
    String? unit,
    @Default(0) int minStockLevel,
    String? rackLocation,
    String? barcode,
    @Default(true) bool isActive,
  }) = _Product;

  /// Decodes a snake_case Postgres/Supabase row into a [Product].
  factory Product.fromJson(Map<String, dynamic> json) =>
      _$ProductFromJson(json);
}
