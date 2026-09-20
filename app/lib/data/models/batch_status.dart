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
/// Anything unrecognised - **including the view's `'unknown'`, which it emits for a
/// batch whose expiry nobody recorded** - falls back to [ExpiryStatus.safe], so
/// [BatchStatusX.hasKnownExpiry] is the question to ask when the two cases have to
/// be told apart. Treating an unknown bucket as safe is a recorded open item from
/// migration 00031 rather than an oversight, and the screens that show a date ask
/// the date, not the bucket.
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
///
/// [expiryDate] is nullable, and [expiryStatus] is `unknown` when it is: the view
/// (migration 00031) reports a batch whose expiry nobody recorded as its own
/// bucket rather than as `safe`. [expiryStatusFromDb] still folds an unrecognised
/// literal - including `'unknown'` - into [ExpiryStatus.safe], so **check
/// [hasKnownExpiry] rather than the bucket** when the difference matters: a screen
/// that prints a date, or a receipt, must say "unknown" rather than draw a bucket
/// for a date that does not exist.
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
    required DateTime createdAt,
    required DateTime updatedAt,
    DateTime? expiryDate,
    @Default(false) bool isUnknownBatch,
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

  /// Whether the pack's expiry was recorded at all.
  ///
  /// The authoritative question, because [expiryStatus] cannot answer it - see the
  /// class note on the `'unknown'` bucket folding into [ExpiryStatus.safe].
  bool get hasKnownExpiry => expiryDate != null;

  /// Whether the batch is past its expiry date.
  ///
  /// From the server's own bucket, so it is decided against the database's today
  /// rather than the device's clock.
  bool get isExpired => expiryStatus == ExpiryStatus.expired;

  /// Whole days from now until [expiryDate], or `null` when none is recorded.
  ///
  /// Computed locally from the date. The authoritative bucket is [expiryStatus],
  /// which the database evaluates against its own today.
  int? get daysToExpiry => expiryDate?.difference(DateTime.now()).inDays;
}
