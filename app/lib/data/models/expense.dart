/// Freezed/JSON model for the `expenses` table.
library;

import 'package:app/data/models/sale.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'expense.freezed.dart';
part 'expense.g.dart';

/// A cost the pharmacy paid: rent, electricity, salaries, freight.
///
/// No party column, which is why an expense does not reach the party ledger: a
/// `ledger_entries` row needs a `party_type` and exactly one matching party id
/// (migration 00007), and rent has nobody on the other side of it. Phase 4's reports
/// read expenses from this table instead.
@freezed
abstract class Expense with _$Expense {
  /// Creates an immutable [Expense].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed forwards
  /// constructor-level metadata onto the generated concrete class.
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Expense({
    required String id,
    required String pharmacyId,
    required String category,
    required double amount,
    required DateTime expenseDate,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(PaymentMode.cash) @PaymentModeConverter() PaymentMode paymentMode,
    String? notes,
    String? createdBy,
  }) = _Expense;

  /// Decodes a snake_case Postgres/Supabase row into an [Expense].
  factory Expense.fromJson(Map<String, dynamic> json) =>
      _$ExpenseFromJson(json);
}

/// The categories the expense form offers.
///
/// A fixed list rather than free text, because the point of recording expenses is to
/// report on them, and "rent", "Rent" and "shop rent" are three categories that
/// cannot be added up. The column is still text: an unusual cost can be typed in.
const List<String> expenseCategories = <String>[
  'Rent',
  'Salaries',
  'Electricity',
  'Freight',
  'Licences',
  'Maintenance',
  'Marketing',
  'Other',
];
