/// Freezed/JSON model for `ledger_entries`, plus the reference-type enum.
library;

import 'package:app/data/models/party_balance.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'ledger_entry.freezed.dart';
part 'ledger_entry.g.dart';

/// What kind of document produced a ledger entry.
///
/// The column is polymorphic - `reference_id` points at a purchase, a sale, a
/// return or a payment depending on this - and deliberately **not** FK-enforced,
/// so a ledger row survives the document it describes being archived.
enum LedgerReferenceType {
  /// An opening balance entered by hand.
  opening,

  /// A supplier invoice, posted when a purchase reaches `received`.
  purchase,

  /// A credit note from a supplier: the contra of a purchase.
  purchaseReturn,

  /// A customer bill, posted when a sale is written.
  sale,

  /// A credit note to a customer: the contra of a sale.
  saleReturn,

  /// Money moving either way against a party.
  payment,

  /// A cost with a party attached. Nothing writes this yet: `expenses` has no
  /// party column, so a rent bill cannot be posted here (migration 00020).
  expense,

  /// A stock adjustment's ledger effect, if one is ever valued.
  adjustment,
}

/// Parses a Postgres `ledger_reference_type` literal.
///
/// Anything unrecognised falls back to [LedgerReferenceType.opening], the entry
/// kind that asserts the least about where a row came from.
LedgerReferenceType ledgerReferenceTypeFromDb(String? raw) =>
    switch (raw?.trim().toLowerCase()) {
      'purchase' => LedgerReferenceType.purchase,
      'purchase_return' => LedgerReferenceType.purchaseReturn,
      'sale' => LedgerReferenceType.sale,
      'sale_return' => LedgerReferenceType.saleReturn,
      'payment' => LedgerReferenceType.payment,
      'expense' => LedgerReferenceType.expense,
      'adjustment' => LedgerReferenceType.adjustment,
      _ => LedgerReferenceType.opening,
    };

/// Maps [LedgerReferenceType] between its DB literal and its UI label.
extension LedgerReferenceTypeX on LedgerReferenceType {
  /// The literal stored in `ledger_entries.reference_type`.
  String get dbValue => switch (this) {
    LedgerReferenceType.opening => 'opening',
    LedgerReferenceType.purchase => 'purchase',
    LedgerReferenceType.purchaseReturn => 'purchase_return',
    LedgerReferenceType.sale => 'sale',
    LedgerReferenceType.saleReturn => 'sale_return',
    LedgerReferenceType.payment => 'payment',
    LedgerReferenceType.expense => 'expense',
    LedgerReferenceType.adjustment => 'adjustment',
  };

  /// The label shown in the ledger list.
  String get label => switch (this) {
    LedgerReferenceType.opening => 'Opening',
    LedgerReferenceType.purchase => 'Purchase',
    LedgerReferenceType.purchaseReturn => 'Purchase return',
    LedgerReferenceType.sale => 'Sale',
    LedgerReferenceType.saleReturn => 'Sale return',
    LedgerReferenceType.payment => 'Payment',
    LedgerReferenceType.expense => 'Expense',
    LedgerReferenceType.adjustment => 'Adjustment',
  };
}

/// Round-trips [LedgerReferenceType] with the Postgres literal.
class LedgerReferenceTypeConverter
    extends JsonConverter<LedgerReferenceType, String?> {
  /// Creates the converter referenced by `@LedgerReferenceTypeConverter()`.
  const LedgerReferenceTypeConverter();

  /// Decodes `'purchase'`, `'sale'`, `'payment'`, and the rest.
  @override
  LedgerReferenceType fromJson(String? json) => ledgerReferenceTypeFromDb(json);

  /// Emits the DB literal, e.g. `'sale_return'`.
  @override
  String? toJson(LedgerReferenceType object) => object.dbValue;
}

/// One line of a party ledger: money owed, or money settled.
///
/// Append-only by construction. Both directions are carried rather than one signed
/// number, because which way is "increasing" depends on the party type: a purchase
/// *credits* a supplier (what the pharmacy owes) while a sale *debits* a customer
/// (what the customer owes). `PartyBalance` reads the two in the direction each
/// party is owed.
@freezed
abstract class LedgerEntry with _$LedgerEntry {
  /// Creates an immutable [LedgerEntry].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed forwards
  /// constructor-level metadata onto the generated concrete class.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory LedgerEntry({
    required String id,
    required String pharmacyId,
    required DateTime entryDate,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(PartyType.supplier) @PartyTypeConverter() PartyType partyType,
    @Default(LedgerReferenceType.opening)
    @LedgerReferenceTypeConverter()
    LedgerReferenceType referenceType,
    @Default(0) double debit,
    @Default(0) double credit,
    String? supplierId,
    String? customerId,
    String? referenceId,
    String? description,
    String? createdBy,
  }) = _LedgerEntry;

  /// Decodes a snake_case Postgres/Supabase row into a [LedgerEntry].
  factory LedgerEntry.fromJson(Map<String, dynamic> json) =>
      _$LedgerEntryFromJson(json);
}

/// Helpers for reading a [LedgerEntry] in the direction a party is owed.
extension LedgerEntryX on LedgerEntry {
  /// What this entry adds to a supplier's payable.
  ///
  /// A purchase credits the supplier (the pharmacy owes more), a payment and a
  /// purchase return debit them (it owes less).
  double get supplierEffect => credit - debit;

  /// What this entry adds to a customer's receivable.
  ///
  /// A sale debits the customer (they owe more), a payment and a sale return credit
  /// them (they owe less).
  double get customerEffect => debit - credit;
}
