/// Freezed/JSON models for the writable half of a purchase: what the forms
/// collect, including the batch details a GRN adds to each line.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'purchase_draft.freezed.dart';
part 'purchase_draft.g.dart';

/// The header fields a purchase form owns.
///
/// Kept separate from `Purchase` because a form cannot invent the id, the
/// pharmacy, the timestamps or `stock_posted_at`. Nulls are serialised so a
/// cleared note clears the column.
@freezed
abstract class PurchaseDraft with _$PurchaseDraft {
  /// Creates an immutable [PurchaseDraft].
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory PurchaseDraft({
    required String supplierId,
    required String invoiceNo,
    required DateTime invoiceDate,
    String? notes,
  }) = _PurchaseDraft;

  /// Decodes a draft from JSON (used by tests and for round-trips).
  factory PurchaseDraft.fromJson(Map<String, dynamic> json) =>
      _$PurchaseDraftFromJson(json);
}

/// One line as the forms collect it, before it becomes a `purchase_items` row.
///
/// The batch fields are nullable because the same draft serves both halves of a
/// purchase's life: a purchase order line has a product and quantities but no
/// batch yet, and the GRN adds the batch number, dates and rates. `isReceivable`
/// is what the repository checks before it is willing to create batches.
@freezed
abstract class PurchaseLineDraft with _$PurchaseLineDraft {
  /// Creates an immutable [PurchaseLineDraft].
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory PurchaseLineDraft({
    required int qty,
    required double purchaseRate,
    required double mrp,
    @Default(0) int freeQty,
    @Default(0) double sellingRate,
    @Default(0) double discountPercent,
    @Default(0) double gstPercent,
    String? productId,
    String? productNameRaw,
    String? batchNo,
    DateTime? mfgDate,
    DateTime? expiryDate,
    String? hsnCode,
  }) = _PurchaseLineDraft;

  /// Decodes a line draft from JSON (used by tests and for round-trips).
  factory PurchaseLineDraft.fromJson(Map<String, dynamic> json) =>
      _$PurchaseLineDraftFromJson(json);
}

/// Maps a line draft onto what a receipt needs.
extension PurchaseLineDraftX on PurchaseLineDraft {
  /// Whether this line has everything a batch row and a received item need.
  ///
  /// The raw product name is not required: it exists for later alias learning and
  /// is nullable in the schema.
  bool get isReceivable =>
      productId != null &&
      batchNo != null &&
      batchNo!.trim().isNotEmpty &&
      expiryDate != null &&
      qty > 0;
}

/// Where a line's JSON goes now.
///
/// This file used to carry `toItemJson` and `toBatchJson` - the two table payloads
/// `PurchasesRepository` wrote directly. There is no direct write any more: a purchase
/// is written by `save_purchase()` (migration `20260921000044`), so the wire shape
/// lives in one place, `PurchasePayload`, beside the call that sends it. The rule the
/// batch payload documented there - **never send `qty`**, or an upsert zeroes stock no
/// trigger would restore - is enforced in that function and asserted by
/// `supabase/tests/grn_write_order.sql`.
