/// Freezed/JSON model for the `product_batches` table — one row per lot.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'product_batch.freezed.dart';
part 'product_batch.g.dart';

/// A received batch of a product, with its own expiry date and rates.
///
/// [expiryDate] is **nullable**, and that is a real distinction rather than a
/// convenience: `product_batches.expiry_date` was `not null` until migration
/// 00031, when the opening-stock import arrived with 145 rows whose source never
/// recorded a date. `null` therefore means exactly "the source did not say" - it
/// never means "no expiry". Nothing may invent a date to satisfy a formatter.
///
/// [isUnknownBatch] marks a batch whose number was **generated** (`OPENING-<uuid8>`)
/// because the source had none. The prefix is a convenience, not the contract:
/// this flag is what says the number was not printed on a box.
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
    required DateTime createdAt,
    required DateTime updatedAt,
    DateTime? expiryDate,
    @Default(false) bool isUnknownBatch,
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
  /// Whether the pack's expiry was recorded at all.
  bool get hasKnownExpiry => expiryDate != null;

  /// Whether the batch has already expired.
  ///
  /// False when no date is recorded: an unknown expiry is not an expired one, and
  /// reporting it as expired would take real stock off the shelf.
  bool get isExpired {
    final date = expiryDate;
    return date != null && date.isBefore(DateTime.now());
  }

  /// Whole days from now until `expiryDate`, or `null` when none is recorded.
  int? get daysToExpiry => expiryDate?.difference(DateTime.now()).inDays;

  /// Whether the batch expires within the next 90 days but has not yet.
  bool get isExpiringSoon {
    final days = daysToExpiry;
    return days != null && days > 0 && days <= 90;
  }
}
