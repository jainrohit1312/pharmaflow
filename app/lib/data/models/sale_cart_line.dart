/// One line of a sale being built at the counter.
///
/// The cart's line value, and the input to `SaleTotals`: it carries what the
/// counter chose - a product, the batch it comes out of, the quantity, the rate,
/// the discount and the slab - and none of the money, which is derived. The same
/// shape as `PurchaseLineDraft` on the purchase side, so the two money paths read
/// the same way.
library;

import 'package:app/data/models/product.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'sale_cart_line.freezed.dart';

/// A line chosen at the counter.
///
/// [mrp] is the batch's printed price at the moment the line was rung up, kept
/// because it is the **ceiling** a retail rate may not exceed - `rateRefusal`
/// mirrors the server's own check and needs it. It is not a price anything is
/// charged at: the rate is, and for a package or transfer line the server derives
/// even that.
@freezed
abstract class SaleCartLine with _$SaleCartLine {
  /// Creates an immutable cart line.
  const factory SaleCartLine({
    required String productId,
    required String productName,
    required ScheduleType scheduleType,
    required String batchId,
    required String batchNo,
    required int qty,
    required double rate,
    @Default(0) double discountPercent,
    @Default(0) double gstPercent,
    @Default(0) double mrp,
    String? expiryDateIso,
  }) = _SaleCartLine;
}

/// A line's identity at the counter.
///
/// Two cart lines may name the same product; they are the same line only when
/// they also name the same batch, so a second scan of the same barcode adds a
/// unit to the line already there rather than competing with it for the batch.
extension SaleCartLineX on SaleCartLine {
  /// Whether [other] is the same product out of the same batch.
  bool isSameLineAs(SaleCartLine other) =>
      productId == other.productId && batchId == other.batchId;
}
