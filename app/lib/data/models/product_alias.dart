/// Freezed/JSON model for the `product_aliases` table: a learned mapping from
/// supplier-invoice text to a catalogue product.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'product_alias.freezed.dart';
part 'product_alias.g.dart';

/// One alias row.
///
/// `normalized_name` is what matching actually runs against, so it is never
/// computed here: it is produced by the database's `normalize_product_name()`
/// function, which keeps the Dart side and the GIN trigram index in agreement.
@freezed
abstract class ProductAlias with _$ProductAlias {
  /// Creates an immutable [ProductAlias].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class; on
  /// the class itself it would be ignored (keys would stay camelCase).
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory ProductAlias({
    required String id,
    required String pharmacyId,
    required String rawName,
    required String normalizedName,
    required String productId,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? supplierId,
  }) = _ProductAlias;

  /// Decodes a snake_case Postgres/Supabase row into a [ProductAlias].
  factory ProductAlias.fromJson(Map<String, dynamic> json) =>
      _$ProductAliasFromJson(json);
}
