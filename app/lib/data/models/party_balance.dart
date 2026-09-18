/// A party's ledger balance, and the kinds of party a ledger is kept for.
///
/// Shared by the supplier and customer modules so that "what does this balance
/// mean" is answered once. A supplier balance and a customer balance are the
/// same two columns read in opposite directions, which is exactly the sort of
/// thing that drifts into two subtly different implementations if each feature
/// computes it for itself.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'party_balance.freezed.dart';
part 'party_balance.g.dart';

/// Which side of a ledger entry a party sits on.
enum PartyType {
  /// Someone the pharmacy buys from; a purchase credits them.
  supplier,

  /// Someone the pharmacy sells to; a sale debits them.
  customer,
}

/// Parses a Postgres `party_type` literal into a [PartyType].
///
/// Anything unrecognised falls back to [PartyType.supplier], mirroring how the
/// other enum decoders in this package treat unknown values.
PartyType partyTypeFromDb(String? raw) => switch (raw?.trim().toLowerCase()) {
  'customer' => PartyType.customer,
  _ => PartyType.supplier,
};

/// Maps [PartyType] between its DB literal and its UI label.
extension PartyTypeX on PartyType {
  /// The literal stored in the `party_type` column.
  String get dbValue => switch (this) {
    PartyType.supplier => 'supplier',
    PartyType.customer => 'customer',
  };

  /// The label shown in the UI.
  String get label => switch (this) {
    PartyType.supplier => 'Supplier',
    PartyType.customer => 'Customer',
  };
}

/// Round-trips [PartyType] with the Postgres `party_type` literal.
class PartyTypeConverter extends JsonConverter<PartyType, String?> {
  /// Creates the converter referenced by `@PartyTypeConverter()`.
  const PartyTypeConverter();

  /// Decodes `'supplier'` or `'customer'`.
  @override
  PartyType fromJson(String? json) => partyTypeFromDb(json);

  /// Emits the DB literal, e.g. `'supplier'`.
  @override
  String? toJson(PartyType object) => object.dbValue;
}

/// Totals of one party's ledger entries.
///
/// Both directions are carried, rather than a single signed number, because the
/// sign convention differs by party type and a lone `balance` field would leave
/// every caller to guess which way round it is.
@freezed
abstract class PartyBalance with _$PartyBalance {
  /// Creates immutable totals.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory PartyBalance({
    @Default(0) double totalDebit,
    @Default(0) double totalCredit,
    @Default(0) int entryCount,
  }) = _PartyBalance;

  /// Decodes a totals payload.
  factory PartyBalance.fromJson(Map<String, dynamic> json) =>
      _$PartyBalanceFromJson(json);
}

/// Reads [PartyBalance] in the direction each party type is owed.
extension PartyBalanceX on PartyBalance {
  /// How much the pharmacy owes a supplier. Positive is a payable.
  ///
  /// A purchase credits the supplier (migration 00015 posts debit 0, credit
  /// grand_total), so credit minus debit is what is still owed.
  double get payable => totalCredit - totalDebit;

  /// How much a customer owes the pharmacy. Positive is a receivable.
  ///
  /// A sale debits the customer, and a receipt credits them, so debit minus
  /// credit is what is still outstanding.
  double get receivable => totalDebit - totalCredit;

  /// Whether anything has been posted to this party at all.
  bool get isEmpty => entryCount == 0;
}
