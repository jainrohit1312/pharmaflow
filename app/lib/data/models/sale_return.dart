/// Freezed/JSON models for `sale_returns` and `sale_return_items`.
library;

import 'package:app/data/models/sale.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'sale_return.freezed.dart';
part 'sale_return.g.dart';

/// A document recording goods a customer brought back.
///
/// The mirror of `PurchaseReturn`: a credit note. `restock` says whether the units
/// go back on the shelf - `false` for damaged or unsellable goods, which come back
/// to the paperwork but not to the shelf - and `refund_mode` says how the money
/// went back out.
///
/// Nothing here posts to the customer's ledger by hand: a trigger does it, from
/// `grand_total` (migration 20260918000019).
@freezed
abstract class SaleReturn with _$SaleReturn {
  /// Creates an immutable [SaleReturn].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed forwards
  /// constructor-level metadata onto the generated concrete class.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory SaleReturn({
    required String id,
    required String pharmacyId,
    required String saleId,
    required DateTime returnDate,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(PaymentMode.cash) @PaymentModeConverter() PaymentMode refundMode,
    @Default(0) double subTotal,
    @Default(0) double taxTotal,
    @Default(0) double grandTotal,
    @Default(true) bool restock,
    // A plain text column in the schema with one value in use today, like
    // `purchase_returns.status`.
    @Default('completed') String status,
    String? customerId,
    String? reason,
    String? createdBy,
  }) = _SaleReturn;

  /// Decodes a snake_case Postgres/Supabase row into a [SaleReturn].
  factory SaleReturn.fromJson(Map<String, dynamic> json) =>
      _$SaleReturnFromJson(json);
}

/// One line of a sale return.
///
/// `sale_item_id` is what ties a line back to the sold line it came from, and it is
/// the column "how much of this line has already come back" is answered from - the
/// batch balance alone would allow the same units to be refunded twice.
@freezed
abstract class SaleReturnItem with _$SaleReturnItem {
  /// Creates an immutable [SaleReturnItem].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed forwards
  /// constructor-level metadata onto the generated concrete class.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory SaleReturnItem({
    required String id,
    required String pharmacyId,
    required String saleReturnId,
    required int qty,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(0) double rate,
    @Default(0) double gstPercent,
    @Default(0) double taxAmount,
    @Default(0) double totalAmount,
    String? saleItemId,
    String? productId,
    String? batchId,
  }) = _SaleReturnItem;

  /// Decodes a snake_case Postgres/Supabase row into a [SaleReturnItem].
  factory SaleReturnItem.fromJson(Map<String, dynamic> json) =>
      _$SaleReturnItemFromJson(json);
}

/// Line helpers for [SaleReturnItem].
extension SaleReturnItemX on SaleReturnItem {
  /// Value of the line before tax, derived so the three figures add up.
  double get taxableAmount => totalAmount - taxAmount;
}
