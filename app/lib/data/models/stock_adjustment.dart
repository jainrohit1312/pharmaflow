/// The direction of a manual stock correction.
///
/// `stock_adjustments.qty` is always positive - a check constraint enforces it -
/// and this enum carries the sign, which is why the two live apart.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'stock_adjustment.freezed.dart';
part 'stock_adjustment.g.dart';

/// Which way an adjustment moves a batch.
enum AdjustmentType {
  /// Stock found or added to the batch.
  increase,

  /// Stock written off: breakage, spillage, a counting correction.
  decrease,
}

/// Parses an `adjustment_type` enum literal into an [AdjustmentType].
///
/// Anything unrecognised falls back to [AdjustmentType.increase], which is the
/// least destructive reading: an increase can be corrected by its opposite, while
/// a misread decrease moves stock the pharmacy still has. The same reasoning as
/// `purchaseStatusFromDb`.
AdjustmentType adjustmentTypeFromDb(String? raw) =>
    raw?.trim().toLowerCase() == 'decrease'
    ? AdjustmentType.decrease
    : AdjustmentType.increase;

/// Maps [AdjustmentType] between its DB literal, its label and its sign.
extension AdjustmentTypeX on AdjustmentType {
  /// The literal stored in the `adjustment_type` enum.
  String get dbValue => switch (this) {
    AdjustmentType.increase => 'increase',
    AdjustmentType.decrease => 'decrease',
  };

  /// The label shown in the UI.
  String get label => switch (this) {
    AdjustmentType.increase => 'Increase',
    AdjustmentType.decrease => 'Decrease',
  };

  /// What this direction does to the batch's quantity.
  int get sign => switch (this) {
    AdjustmentType.increase => 1,
    AdjustmentType.decrease => -1,
  };
}

// `stock_adjustments` still has no read path: nothing lists the table, and the batch
// balance an adjustment moved is read from `product_stock`/`batch_status` like every other
// figure on the inventory screens. The row model below exists for one reason only, and it is
// a Phase 6.5c one: `record_stock_adjustment()` answers with the row it wrote, so the answer
// has a type. Nothing else reads a stock adjustment back; if the ledger history ever surfaces
// here, that is when a list would be written.

/// One `stock_adjustments` row: a manual correction and the audit trail it leaves.
@freezed
abstract class StockAdjustment with _$StockAdjustment {
  /// Creates an immutable [StockAdjustment].
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory StockAdjustment({
    required String id,
    required String pharmacyId,
    required String productId,
    @AdjustmentTypeConverter() required AdjustmentType adjustmentType,
    required int qty,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? batchId,
    String? reason,
    String? createdBy,
  }) = _StockAdjustment;

  /// Decodes a snake_case Postgres/Supabase row into a [StockAdjustment].
  factory StockAdjustment.fromJson(Map<String, dynamic> json) =>
      _$StockAdjustmentFromJson(json);
}

/// Round-trips [AdjustmentType] with the `adjustment_type` literal.
class AdjustmentTypeConverter extends JsonConverter<AdjustmentType, String?> {
  /// Creates the converter referenced by `@AdjustmentTypeConverter()`.
  const AdjustmentTypeConverter();

  /// Decodes `'increase'` or `'decrease'`.
  @override
  AdjustmentType fromJson(String? json) => adjustmentTypeFromDb(json);

  /// Emits the DB literal.
  @override
  String? toJson(AdjustmentType object) => object.dbValue;
}
