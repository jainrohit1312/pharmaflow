/// Freezed/JSON model for the `purchases` table plus the document status enum.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'purchase.freezed.dart';
part 'purchase.g.dart';

/// Where a purchase document stands in its life.
///
/// The status is not cosmetic: `received` is the single event that posts stock
/// to batches and a payable to the ledger (D-013), and it can only happen once.
enum PurchaseStatus {
  /// Being prepared; nothing has been posted.
  draft,

  /// Sent to the supplier; still nothing posted.
  ordered,

  /// Goods arrived and were booked in. Stock and the ledger are now posted.
  received,

  /// Abandoned before receipt.
  cancelled,
}

/// Parses a Postgres `purchase_status` literal into a [PurchaseStatus].
///
/// Anything unrecognised falls back to [PurchaseStatus.draft], which is the
/// least destructive reading: a draft can still be corrected.
PurchaseStatus purchaseStatusFromDb(String? raw) =>
    switch (raw?.trim().toLowerCase()) {
      'ordered' => PurchaseStatus.ordered,
      'received' => PurchaseStatus.received,
      'cancelled' => PurchaseStatus.cancelled,
      _ => PurchaseStatus.draft,
    };

/// Maps [PurchaseStatus] between its DB literal, its UI label and what it allows.
extension PurchaseStatusX on PurchaseStatus {
  /// The literal stored in the `purchase_status` column.
  String get dbValue => switch (this) {
    PurchaseStatus.draft => 'draft',
    PurchaseStatus.ordered => 'ordered',
    PurchaseStatus.received => 'received',
    PurchaseStatus.cancelled => 'cancelled',
  };

  /// The label shown in the UI.
  String get label => switch (this) {
    PurchaseStatus.draft => 'Draft',
    PurchaseStatus.ordered => 'Ordered',
    PurchaseStatus.received => 'Received',
    PurchaseStatus.cancelled => 'Cancelled',
  };

  /// Whether stock and the ledger have been posted for this document.
  bool get isPosted => this == PurchaseStatus.received;

  /// Whether its lines may still be edited.
  ///
  /// Once received, a line may not be added, changed or removed: that would
  /// change a document whose stock has already been applied, and the triggers
  /// deliberately do not reverse it. Corrections go through a purchase return or
  /// a stock adjustment.
  bool get isEditable =>
      this == PurchaseStatus.draft || this == PurchaseStatus.ordered;
}

/// Round-trips [PurchaseStatus] with the `purchase_status` literal.
class PurchaseStatusConverter extends JsonConverter<PurchaseStatus, String?> {
  /// Creates the converter referenced by `@PurchaseStatusConverter()`.
  const PurchaseStatusConverter();

  /// Decodes `'draft'`, `'ordered'`, `'received'` or `'cancelled'`.
  @override
  PurchaseStatus fromJson(String? json) => purchaseStatusFromDb(json);

  /// Emits the DB literal, e.g. `'received'`.
  @override
  String? toJson(PurchaseStatus object) => object.dbValue;
}

/// A purchase document: a supplier invoice the pharmacy owes money against.
@freezed
abstract class Purchase with _$Purchase {
  /// Creates an immutable [Purchase].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class; on
  /// the class itself it would be ignored (keys would stay camelCase).
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Purchase({
    required String id,
    required String pharmacyId,
    required String supplierId,
    required String invoiceNo,
    required DateTime invoiceDate,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(PurchaseStatus.draft)
    @PurchaseStatusConverter()
    PurchaseStatus status,
    @Default(0) double subTotal,
    @Default(0) double discountTotal,
    @Default(0) double taxTotal,
    @Default(0) double grandTotal,
    String? notes,
    String? createdBy,
    DateTime? stockPostedAt,
  }) = _Purchase;

  /// Decodes a snake_case Postgres/Supabase row into a [Purchase].
  factory Purchase.fromJson(Map<String, dynamic> json) =>
      _$PurchaseFromJson(json);
}

/// Document-level helpers for [Purchase].
extension PurchaseX on Purchase {
  /// How many units were received, counting the scheme only when asked.
  ///
  /// Kept here rather than summed from items so a list screen can show a
  /// meaningful quantity without loading every line.
  bool get hasTax => taxTotal > 0;

  /// Whether the document was received but never posted to stock.
  ///
  /// The `received` transition stamps `stock_posted_at` in the same transaction,
  /// so this should never be true; when it is, something interrupted the write
  /// and the document is worth looking at rather than trusting.
  bool get isReceivedButUnposted =>
      status == PurchaseStatus.received && stockPostedAt == null;
}
