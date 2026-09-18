/// Freezed/JSON model for the `purchase_items` table: one invoice line.
library;

import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'purchase_item.freezed.dart';
part 'purchase_item.g.dart';

/// One line of a purchase document.
@freezed
abstract class PurchaseItem with _$PurchaseItem {
  /// Creates an immutable [PurchaseItem].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory PurchaseItem({
    required String id,
    required String pharmacyId,
    required String purchaseId,
    required int qty,
    required double purchaseRate,
    required double mrp,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(0) int freeQty,
    @Default(0) double sellingRate,
    @Default(0) double discountPercent,
    @Default(0) double gstPercent,
    @Default(0) double cgstAmount,
    @Default(0) double sgstAmount,
    @Default(0) double igstAmount,
    @Default(0) double taxAmount,
    @Default(0) double totalAmount,
    String? productId,
    String? batchId,
    String? productNameRaw,
    String? batchNo,
    DateTime? expiryDate,
    String? hsnCode,
  }) = _PurchaseItem;

  /// Decodes a snake_case Postgres/Supabase row into a [PurchaseItem].
  factory PurchaseItem.fromJson(Map<String, dynamic> json) =>
      _$PurchaseItemFromJson(json);
}

/// Line helpers for [PurchaseItem].
extension PurchaseItemX on PurchaseItem {
  /// Units this line actually brought in, scheme goods included (D-011).
  int get receivedQty => qty + freeQty;

  /// Value of the line before tax: quantity x rate, less its discount.
  ///
  /// Derived, because there is no taxable column: it is what the invoice shows
  /// as the line's assessable value, and recomputing it with the same arithmetic
  /// the write used is what keeps a displayed total equal to the stored one.
  double get taxableAmount => PurchaseTotals.taxable(
    qty: qty,
    rate: purchaseRate,
    discountPercent: discountPercent,
  );

  /// Whether this line is fully priced and batched, so it can be received.
  bool get isReceivable =>
      productId != null &&
      batchNo != null &&
      batchNo!.trim().isNotEmpty &&
      expiryDate != null;
}
