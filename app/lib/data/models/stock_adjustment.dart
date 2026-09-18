/// The direction of a manual stock correction.
///
/// `stock_adjustments.qty` is always positive - a check constraint enforces it -
/// and this enum carries the sign, which is why the two live apart.
library;

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

// There is no row model for `stock_adjustments` yet, on purpose. Nothing reads
// the table back: an adjustment is a write plus the audit row it leaves behind,
// and the batch balance it moved is read from `product_stock`/`batch_status`
// like every other figure on the inventory screens. A model would be dead code.
// The Phase 4 ledger reports are where the history is expected to surface.
