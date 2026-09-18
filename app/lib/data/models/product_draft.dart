/// Freezed/JSON model for the writable half of a product: what a form collects.
library;

import 'package:app/data/models/product.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'product_draft.freezed.dart';
part 'product_draft.g.dart';

/// The fields a create/edit form owns.
///
/// Kept separate from [Product] because a form cannot invent `id`, `pharmacyId`
/// or the timestamps, and because the write payload should be explicit rather
/// than "whatever the entity happens to carry".
///
/// Unlike the entity models, this one serialises nulls: a form that clears an
/// optional field (removing a barcode, say) has to send an explicit null so the
/// column is cleared, not left at its previous value.
@freezed
abstract class ProductDraft with _$ProductDraft {
  /// Creates an immutable [ProductDraft].
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory ProductDraft({
    required String name,
    @Default(ScheduleType.otc)
    @ScheduleTypeConverter()
    ScheduleType scheduleType,
    @Default(0) int minStockLevel,
    @Default(true) bool isActive,
    String? genericName,
    String? brand,
    String? manufacturer,
    String? hsnCode,
    String? category,
    String? packSize,
    String? unit,
    String? rackLocation,
    String? barcode,
  }) = _ProductDraft;

  /// Decodes a draft from JSON (used by tests and for round-trips).
  factory ProductDraft.fromJson(Map<String, dynamic> json) =>
      _$ProductDraftFromJson(json);

  /// Seeds a draft from an existing product, for the edit form.
  factory ProductDraft.fromProduct(Product product) => ProductDraft(
    name: product.name,
    scheduleType: product.scheduleType,
    minStockLevel: product.minStockLevel,
    isActive: product.isActive,
    genericName: product.genericName,
    brand: product.brand,
    manufacturer: product.manufacturer,
    hsnCode: product.hsnCode,
    category: product.category,
    packSize: product.packSize,
    unit: product.unit,
    rackLocation: product.rackLocation,
    barcode: product.barcode,
  );
}
