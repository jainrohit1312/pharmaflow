/// Freezed/JSON models for the writable half of a purchase: what the forms
/// collect, including the batch details a GRN adds to each line.
library;

import 'package:app/core/utils/formatters.dart';
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

/// Maps a line draft onto the two tables a receipt writes.
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

  /// The `product_batches` payload for this line.
  ///
  /// **`qty` is deliberately absent.** The batch's quantity belongs to the stock
  /// triggers (D-011): a new row takes the column default of 0, and the trigger
  /// then adds what this receipt brought in. Sending `qty: 0` here instead would
  /// look harmless and would be catastrophic on a re-receipt - an upsert would
  /// overwrite an existing batch's balance with zero, destroying live stock that
  /// no trigger would restore.
  ///
  /// `landed_cost_per_unit` is absent for the same reason: the trigger computes
  /// it from what was paid (D-012), and a client-written value would be
  /// overwritten on receipt anyway.
  Map<String, dynamic> toBatchJson({required String pharmacyId}) =>
      <String, dynamic>{
        'pharmacy_id': pharmacyId,
        'product_id': productId,
        'batch_no': batchNo,
        'expiry_date': Formatters.dateIso(expiryDate!),
        'mfg_date': mfgDate == null ? null : Formatters.dateIso(mfgDate!),
        'purchase_rate': purchaseRate,
        'mrp': mrp,
        'selling_rate': sellingRate,
      };

  /// The `purchase_items` payload for this line.
  Map<String, dynamic> toItemJson({
    required String pharmacyId,
    required String purchaseId,
    required String? batchId,
  }) => <String, dynamic>{
    'pharmacy_id': pharmacyId,
    'purchase_id': purchaseId,
    'product_id': productId,
    'batch_id': batchId,
    'product_name_raw': productNameRaw,
    'batch_no': batchNo,
    'expiry_date': expiryDate == null ? null : Formatters.dateIso(expiryDate!),
    'hsn_code': hsnCode,
    'qty': qty,
    'free_qty': freeQty,
    'purchase_rate': purchaseRate,
    'mrp': mrp,
    'selling_rate': sellingRate,
    'discount_percent': discountPercent,
    'gst_percent': gstPercent,
  };
}
