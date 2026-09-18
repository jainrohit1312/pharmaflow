/// Freezed/JSON models for the `sales` table, plus its two enums.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'sale.freezed.dart';
part 'sale.g.dart';

/// Where a sale stands in its life.
///
/// There is no `draft`: `sale_status` (migration 00002) has three values, and a
/// sale is final the moment it is written, which is why its stock posts per line
/// rather than on a status change (migration 00019).
enum SaleStatus {
  /// Paid in full at the counter, or on account and settled.
  completed,

  /// Abandoned. Never took stock and never posted a ledger entry.
  cancelled,

  /// Partly or wholly unpaid: the balance is a customer receivable.
  credit,
}

/// Parses a Postgres `sale_status` literal into a [SaleStatus].
///
/// Anything unrecognised falls back to [SaleStatus.completed], which is what the
/// column defaults to - the least surprising reading for a document that exists.
SaleStatus saleStatusFromDb(String? raw) => switch (raw?.trim().toLowerCase()) {
  'cancelled' => SaleStatus.cancelled,
  'credit' => SaleStatus.credit,
  _ => SaleStatus.completed,
};

/// Maps [SaleStatus] between its DB literal and its UI label.
extension SaleStatusX on SaleStatus {
  /// The literal stored in the `sale_status` column.
  String get dbValue => switch (this) {
    SaleStatus.completed => 'completed',
    SaleStatus.cancelled => 'cancelled',
    SaleStatus.credit => 'credit',
  };

  /// The label shown in the UI.
  String get label => switch (this) {
    SaleStatus.completed => 'Paid',
    SaleStatus.cancelled => 'Cancelled',
    SaleStatus.credit => 'On credit',
  };

  /// Whether the document's stock and ledger effects have happened.
  bool get isPosted => this != SaleStatus.cancelled;
}

/// Round-trips [SaleStatus] with the `sale_status` literal.
class SaleStatusConverter extends JsonConverter<SaleStatus, String?> {
  /// Creates the converter referenced by `@SaleStatusConverter()`.
  const SaleStatusConverter();

  /// Decodes `'completed'`, `'cancelled'` or `'credit'`.
  @override
  SaleStatus fromJson(String? json) => saleStatusFromDb(json);

  /// Emits the DB literal, e.g. `'credit'`.
  @override
  String? toJson(SaleStatus object) => object.dbValue;
}

/// How a sale was settled.
///
/// `credit` is the one mode that means "not settled at the counter": the schema
/// uses it both as a `payment_mode` and, effectively, as the sale's status.
enum PaymentMode {
  /// Notes and coins at the counter.
  cash,

  /// Card at the counter or over the phone.
  card,

  /// UPI or another instant bank transfer.
  upi,

  /// On account: the balance is a receivable.
  credit,

  /// Bank transfer or cheque.
  bank,

  /// A wallet.
  wallet,

  /// Anything else, with a reference number to say what.
  other,
}

/// Parses a Postgres `payment_mode` literal into a [PaymentMode].
///
/// Anything unrecognised falls back to [PaymentMode.cash], the mode a counter
/// sale is overwhelmingly likely to be.
PaymentMode paymentModeFromDb(String? raw) =>
    switch (raw?.trim().toLowerCase()) {
      'card' => PaymentMode.card,
      'upi' => PaymentMode.upi,
      'credit' => PaymentMode.credit,
      'bank' => PaymentMode.bank,
      'wallet' => PaymentMode.wallet,
      'other' => PaymentMode.other,
      _ => PaymentMode.cash,
    };

/// Maps [PaymentMode] between its DB literal and its UI label.
extension PaymentModeX on PaymentMode {
  /// The literal stored in the `payment_mode` column.
  String get dbValue => switch (this) {
    PaymentMode.cash => 'cash',
    PaymentMode.card => 'card',
    PaymentMode.upi => 'upi',
    PaymentMode.credit => 'credit',
    PaymentMode.bank => 'bank',
    PaymentMode.wallet => 'wallet',
    PaymentMode.other => 'other',
  };

  /// The label shown in the UI.
  String get label => switch (this) {
    PaymentMode.cash => 'Cash',
    PaymentMode.card => 'Card',
    PaymentMode.upi => 'UPI',
    PaymentMode.credit => 'On credit',
    PaymentMode.bank => 'Bank',
    PaymentMode.wallet => 'Wallet',
    PaymentMode.other => 'Other',
  };

  /// Whether choosing it means the sale will not be settled at the counter.
  bool get isOnAccount => this == PaymentMode.credit;
}

/// Round-trips [PaymentMode] with the `payment_mode` literal.
class PaymentModeConverter extends JsonConverter<PaymentMode, String?> {
  /// Creates the converter referenced by `@PaymentModeConverter()`.
  const PaymentModeConverter();

  /// Decodes `'cash'`, `'card'`, `'upi'`, `'credit'`, `'bank'`, `'wallet'` or
  /// `'other'`.
  @override
  PaymentMode fromJson(String? json) => paymentModeFromDb(json);

  /// Emits the DB literal, e.g. `'upi'`.
  @override
  String? toJson(PaymentMode object) => object.dbValue;
}

/// A sale: what went out of the door, and what it came to.
@freezed
abstract class Sale with _$Sale {
  /// Creates an immutable [Sale].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class; on
  /// the class itself it would be ignored (keys would stay camelCase).
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Sale({
    required String id,
    required String pharmacyId,
    required String invoiceNo,
    required DateTime saleDate,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(SaleStatus.completed) @SaleStatusConverter() SaleStatus status,
    @Default(PaymentMode.cash) @PaymentModeConverter() PaymentMode paymentMode,
    @Default(0) double subTotal,
    @Default(0) double discountTotal,
    @Default(0) double taxTotal,
    @Default(0) double grandTotal,
    @Default(0) double amountPaid,
    @Default(0) double balanceDue,
    String? customerId,
    String? placeOfSupply,
    String? createdBy,
  }) = _Sale;

  /// Decodes a snake_case Postgres/Supabase row into a [Sale].
  factory Sale.fromJson(Map<String, dynamic> json) => _$SaleFromJson(json);
}

/// Document-level helpers for [Sale].
extension SaleX on Sale {
  /// Whether anything is still owed on this sale.
  bool get isUnpaid => balanceDue > 0;

  /// Whether the customer walked away owing nothing.
  ///
  /// A cancelled sale is not "paid", so it is excluded rather than being read
  /// off the arithmetic alone.
  bool get isSettled =>
      status != SaleStatus.cancelled && balanceDue <= 0 && grandTotal > 0;

  /// Whether any tax was charged at all.
  bool get hasTax => taxTotal > 0;
}
