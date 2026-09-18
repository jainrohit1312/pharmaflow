/// Freezed/JSON model for the `product_stock` view: on-hand quantity and
/// valuation rolled up per product.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'product_stock.freezed.dart';
part 'product_stock.g.dart';

/// One row of the `product_stock` view (migration 20260918000013).
///
/// The view sums only batches with `qty > 0`, so a product that is entirely out
/// of stock still appears here with a `totalQty` of 0.
@freezed
abstract class ProductStock with _$ProductStock {
  /// Creates an immutable [ProductStock].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class; on
  /// the class itself it would be ignored (keys would stay camelCase).
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory ProductStock({
    required String productId,
    required String pharmacyId,
    required String name,
    required int totalQty,
    @Default(0) int minStockLevel,
    @Default(0) double stockValueAtCost,
    @Default(0) double stockValueAtMrp,
    String? genericName,
    String? brand,
  }) = _ProductStock;

  /// Decodes a snake_case `product_stock` row into a [ProductStock].
  factory ProductStock.fromJson(Map<String, dynamic> json) =>
      _$ProductStockFromJson(json);
}

/// Stock-level helpers for [ProductStock].
extension ProductStockX on ProductStock {
  /// Whether on-hand quantity has fallen below the product's reorder level.
  ///
  /// A [minStockLevel] of 0 means "no threshold configured", so a product that
  /// merely has no stock is not reported as low stock - a threshold has to have
  /// been set for anything to be below it.
  bool get isLowStock => totalQty < minStockLevel;

  /// Whether nothing at all is on hand.
  bool get isOutOfStock => totalQty <= 0;
}
