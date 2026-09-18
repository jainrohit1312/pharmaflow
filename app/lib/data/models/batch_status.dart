/// Freezed/JSON model for the `batch_status` view: a product batch plus the
/// expiry bucket the database computed for it.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'batch_status.freezed.dart';
part 'batch_status.g.dart';

/// Expiry bucket assigned by the `batch_status` view.
///
/// The buckets are evaluated most-urgent-first on the server (migration
/// 20260918000013), so an already-expired batch can never be reported as
/// [critical] or [warning].
enum ExpiryStatus {
  /// More than 90 days of shelf life left.
  safe,

  /// Expires within 90 days.
  warning,

  /// Expires within 30 days.
  critical,

  /// Already past its expiry date.
  expired,
}

/// Parses a `batch_status.expiry_status` literal into an [ExpiryStatus].
///
/// Anything unrecognised falls back to [ExpiryStatus.safe], mirroring how
/// `scheduleTypeFromDb` treats unknown schedule values.
ExpiryStatus expiryStatusFromDb(String? raw) =>
    switch (raw?.trim().toLowerCase()) {
      'expired' => ExpiryStatus.expired,
      'critical' => ExpiryStatus.critical,
      'warning' => ExpiryStatus.warning,
      _ => ExpiryStatus.safe,
    };

/// Maps [ExpiryStatus] between its DB literal and its UI label.
extension ExpiryStatusX on ExpiryStatus {
  /// The literal stored in `batch_status.expiry_status`.
  String get dbValue => switch (this) {
    ExpiryStatus.safe => 'safe',
    ExpiryStatus.warning => 'warning',
    ExpiryStatus.critical => 'critical',
    ExpiryStatus.expired => 'expired',
  };

  /// The label shown on the expiry badge.
  String get label => switch (this) {
    ExpiryStatus.safe => 'Safe',
    ExpiryStatus.warning => 'Expiring soon',
    ExpiryStatus.critical => 'Critical',
    ExpiryStatus.expired => 'Expired',
  };
}

/// Round-trips [ExpiryStatus] with the view's text literal.
class ExpiryStatusConverter extends JsonConverter<ExpiryStatus, String?> {
  /// Creates the converter referenced by `@ExpiryStatusConverter()`.
  const ExpiryStatusConverter();

  /// Decodes `'safe'`, `'warning'`, `'critical'` or `'expired'`.
  @override
  ExpiryStatus fromJson(String? json) => expiryStatusFromDb(json);

  /// Emits the DB literal, e.g. `'critical'`.
  @override
  String? toJson(ExpiryStatus object) => object.dbValue;
}

/// One row of the `batch_status` view: every `product_batches` column plus its
/// server-computed [expiryStatus].
@freezed
abstract class BatchStatus with _$BatchStatus {
  /// Creates an immutable [BatchStatus].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory BatchStatus({
    required String id,
    required String pharmacyId,
    required String productId,
    required String batchNo,
    required DateTime expiryDate,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(ExpiryStatus.safe)
    @ExpiryStatusConverter()
    ExpiryStatus expiryStatus,
    DateTime? mfgDate,
    @Default(0) int qty,
    @Default(0) double purchaseRate,
    @Default(0) double mrp,
    @Default(0) double sellingRate,
  }) = _BatchStatus;

  /// Decodes a snake_case `batch_status` row into a [BatchStatus].
  factory BatchStatus.fromJson(Map<String, dynamic> json) =>
      _$BatchStatusFromJson(json);
}

/// Stock and expiry helpers for [BatchStatus].
extension BatchStatusX on BatchStatus {
  /// Whether any of this batch is left to dispense.
  bool get hasStock => qty > 0;

  /// Whether the batch is past its expiry date.
  bool get isExpired => expiryStatus == ExpiryStatus.expired;

  /// Whole days from now until [expiryDate]; negative once expired.
  ///
  /// Computed locally from the date. The authoritative bucket is
  /// [expiryStatus], which the database evaluates against its own today.
  int get daysToExpiry => expiryDate.difference(DateTime.now()).inDays;
}
