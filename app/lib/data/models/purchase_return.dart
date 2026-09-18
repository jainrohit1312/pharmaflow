/// Freezed/JSON model for `purchase_returns`: goods sent back to a supplier.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'purchase_return.freezed.dart';
part 'purchase_return.g.dart';

/// A document recording stock returned to a supplier against one purchase.
///
/// The money on it is a credit note: `grand_total` is what the supplier owes
/// back, which is why the totals are chosen from the purchase line's own stored
/// amounts rather than recomputed from a rate (see the return totals helper).
/// Nothing here posts to the ledger yet - Phase 4 owns supplier payments, and a
/// purchase return is currently a stock and paperwork event.
@freezed
abstract class PurchaseReturn with _$PurchaseReturn {
  /// Creates an immutable [PurchaseReturn].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory PurchaseReturn({
    required String id,
    required String pharmacyId,
    required String purchaseId,
    required String supplierId,
    required DateTime returnDate,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(0) double subTotal,
    @Default(0) double taxTotal,
    @Default(0) double grandTotal,
    // A plain text column in the schema with one value in use today. Modelling
    // it as an enum now would guess at the states Phase 3's sale returns need.
    @Default('completed') String status,
    String? reason,
    String? createdBy,
  }) = _PurchaseReturn;

  /// Decodes a snake_case Postgres/Supabase row into a [PurchaseReturn].
  factory PurchaseReturn.fromJson(Map<String, dynamic> json) =>
      _$PurchaseReturnFromJson(json);
}

/// Document-level helpers for [PurchaseReturn].
extension PurchaseReturnX on PurchaseReturn {
  /// The value before tax: what the credit note is for, tax aside.
  ///
  /// Stored as its own column rather than derived, because the header's three
  /// figures are written together and read together.
  bool get isCompleted => status == 'completed';
}
