/// Freezed/JSON model for the `product_batches` table — one row per lot.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'product_batch.freezed.dart';
part 'product_batch.g.dart';

/// A received batch of a product, with its own expiry date and rates.
@freezed
abstract class ProductBatch with _$ProductBatch {
  /// Creates an immutable [ProductBatch].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class; on
  /// the class itself it would be ignored (keys would stay camelCase).
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory ProductBatch({
    required String id,
    required String pharmacyId,
    required String productId,
    required String batchNo,
    required DateTime expiryDate,
    required DateTime createdAt,
    required DateTime updatedAt,
    DateTime? mfgDate,
    @Default(0) int qty,
    @Default(0) double purchaseRate,
    @Default(0) double mrp,
    @Default(0) double sellingRate,
  }) = _ProductBatch;

  /// Decodes a snake_case Postgres/Supabase row into a [ProductBatch].
  factory ProductBatch.fromJson(Map<String, dynamic> json) =>
      _$ProductBatchFromJson(json);
}

/// Expiry helpers for [ProductBatch].
extension ProductBatchX on ProductBatch {
  /// Whether the batch has already expired.
  bool get isExpired => expiryDate.isBefore(DateTime.now());

  /// Whole days from now until `expiryDate`; negative once expired.
  int get daysToExpiry => expiryDate.difference(DateTime.now()).inDays;

  /// Whether the batch expires within the next 90 days but has not yet.
  bool get isExpiringSoon {
    final days = daysToExpiry;
    return days > 0 && days <= 90;
  }
}
