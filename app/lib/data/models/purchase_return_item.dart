/// Freezed/JSON model for `purchase_return_items`: one line of a return.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'purchase_return_item.freezed.dart';
part 'purchase_return_item.g.dart';

/// One line of a purchase return.
///
/// `qty` is positive, like every quantity in the schema, and the direction is
/// the document's: a return_item with a `batch_id` takes that many units *out* of
/// the batch, in the same transaction (see `stock_update_on_purchase_return()`).
///
/// `purchase_item_id` is what ties a line back to the invoice line it came from.
/// It is the column the "how much of this line has already gone back" question is
/// answered from, which is what stops a supplier being credited twice for the
/// same units - the batch balance alone would allow it, because a batch can hold
/// stock from more than one receipt.
@freezed
abstract class PurchaseReturnItem with _$PurchaseReturnItem {
  /// Creates an immutable [PurchaseReturnItem].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory PurchaseReturnItem({
    required String id,
    required String pharmacyId,
    required String purchaseReturnId,
    required int qty,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(0) double purchaseRate,
    @Default(0) double mrp,
    @Default(0) double gstPercent,
    @Default(0) double taxAmount,
    @Default(0) double totalAmount,
    String? purchaseItemId,
    String? productId,
    String? batchId,
  }) = _PurchaseReturnItem;

  /// Decodes a snake_case Postgres/Supabase row into a [PurchaseReturnItem].
  factory PurchaseReturnItem.fromJson(Map<String, dynamic> json) =>
      _$PurchaseReturnItemFromJson(json);
}

/// Line helpers for [PurchaseReturnItem].
extension PurchaseReturnItemX on PurchaseReturnItem {
  /// Value of the line before tax.
  ///
  /// Derived, because the schema stores only the tax and the total: subtracting
  /// keeps the three figures adding up even when the tax was rounded.
  double get taxableAmount => totalAmount - taxAmount;
}
