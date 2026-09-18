/// Freezed/JSON model for the `sale_items` table: one line of a sale.
library;

import 'package:app/data/models/product.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'sale_item.freezed.dart';
part 'sale_item.g.dart';

/// One line of a sale.
///
/// `batch_id` is `not null` and `on delete restrict` (migration 00006), so a
/// line always names the batch it came out of: FEFO is decided when the line is
/// written, not reconstructed afterwards, and the stock trigger has something to
/// decrement.
///
/// `schedule_type` is a **snapshot**, not a join. It records how the product was
/// classified at the moment of sale, which is what the statutory drug register
/// has to report even if the catalogue is reclassified later.
@freezed
abstract class SaleItem with _$SaleItem {
  /// Creates an immutable [SaleItem].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory SaleItem({
    required String id,
    required String pharmacyId,
    required String saleId,
    required String batchId,
    required int qty,
    required double rate,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(0) double discountPercent,
    @Default(0) double discountAmount,
    @Default(0) double gstPercent,
    @Default(0) double cgstAmount,
    @Default(0) double sgstAmount,
    @Default(0) double igstAmount,
    @Default(0) double taxAmount,
    @Default(0) double totalAmount,
    @Default(ScheduleType.otc)
    @ScheduleTypeConverter()
    ScheduleType scheduleType,
    String? productId,
  }) = _SaleItem;

  /// Decodes a snake_case Postgres/Supabase row into a [SaleItem].
  factory SaleItem.fromJson(Map<String, dynamic> json) =>
      _$SaleItemFromJson(json);
}

/// Line helpers for [SaleItem].
extension SaleItemX on SaleItem {
  /// Value of the line before tax: quantity x rate, less its discount.
  ///
  /// Derived rather than stored: the schema holds `tax_amount` and
  /// `total_amount`, and subtracting keeps the three figures adding up even when
  /// the tax was rounded.
  double get taxableAmount => totalAmount - taxAmount;

  /// Whether this line needs the statutory register's attention.
  ///
  /// Schedule H, H1, X and narcotics are the prescription-only schedules; an
  /// over-the-counter line is not recorded individually.
  bool get isControlled => scheduleType.requiresPrescription;
}
