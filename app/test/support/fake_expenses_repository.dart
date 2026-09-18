/// Shared test double for the expenses screens.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/expense.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/expenses/data/expenses_repository.dart';

/// Builds an expense with only the fields a test cares about.
Expense buildExpense({
  String category = 'Rent',
  double amount = 1000,
  DateTime? expenseDate,
  DateTime? createdAt,
  PaymentMode paymentMode = PaymentMode.cash,
  String? notes,
  String? id,
}) => Expense(
  id: id ?? 'expense-$category-$amount',
  pharmacyId: 'ph-1',
  category: category,
  amount: amount,
  expenseDate: expenseDate ?? DateTime(2026, 9, 18),
  createdAt: createdAt ?? DateTime(2026),
  updatedAt: createdAt ?? DateTime(2026),
  paymentMode: paymentMode,
  notes: notes,
);

/// An in-memory [ExpensesRepository] that applies the writes and the ordering the
/// real one would.
///
/// The two checks `create` makes are repeated here rather than skipped, for the
/// same reason `FakePurchasesRepository` runs the real `validateLines`: a screen
/// test should fail when a screen skips a check the write enforces.
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing:
/// `implements` does not require a constructor, so the fake never needs a
/// Supabase client - which is the whole point, because a real `SupabaseClient`
/// cannot be constructed without an initialised backend.
class FakeExpensesRepository implements ExpensesRepository {
  /// Creates a fake holding [expenses].
  FakeExpensesRepository({List<Expense>? expenses})
    : expenses = List<Expense>.of(expenses ?? const <Expense>[]);

  /// The rows the fake holds.
  final List<Expense> expenses;

  /// Offsets asked for, in order.
  final List<int> requestedOffsets = <int>[];

  /// The category of the last expense written.
  String? lastCategory;

  /// The amount of the last expense written.
  double? lastAmount;

  /// The date of the last expense written.
  DateTime? lastExpenseDate;

  /// The mode of the last expense written.
  PaymentMode? lastPaymentMode;

  /// The notes of the last expense written.
  String? lastNotes;

  /// When true the next `list` call throws.
  bool failNextList = false;

  /// When set, the next write throws it and clears it, so a retry can succeed.
  Exception? errorToThrow;

  @override
  Future<List<Expense>> list({
    required String pharmacyId,
    int limit = ExpensesRepository.pageSize,
    int offset = 0,
  }) async {
    requestedOffsets.add(offset);
    if (failNextList) {
      failNextList = false;
      throw StateError('the fake was told to fail');
    }

    final sorted = List<Expense>.of(expenses)..sort(_newestFirst);
    return sorted.skip(offset).take(limit).toList(growable: false);
  }

  @override
  Future<Expense> create({
    required String pharmacyId,
    required String category,
    required double amount,
    required DateTime expenseDate,
    required PaymentMode paymentMode,
    String? notes,
  }) async {
    if (amount <= 0) {
      throw const ValidationException(
        message: 'Enter an amount greater than zero.',
      );
    }
    final trimmed = category.trim();
    if (trimmed.isEmpty) {
      throw const ValidationException(message: 'Choose a category.');
    }

    final error = errorToThrow;
    if (error != null) {
      errorToThrow = null;
      throw error;
    }

    lastCategory = trimmed;
    lastAmount = amount;
    lastExpenseDate = expenseDate;
    lastPaymentMode = paymentMode;
    lastNotes = notes;

    final saved = Expense(
      id: 'expense-${expenses.length + 1}',
      pharmacyId: pharmacyId,
      category: trimmed,
      amount: amount,
      expenseDate: expenseDate,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      paymentMode: paymentMode,
      notes: notes?.trim().isEmpty ?? true ? null : notes!.trim(),
    );
    expenses.add(saved);
    return saved;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}

/// Newest expense first, ties broken by insertion, as the real query orders.
int _newestFirst(Expense a, Expense b) {
  final byDate = b.expenseDate.compareTo(a.expenseDate);
  return byDate != 0 ? byDate : b.createdAt.compareTo(a.createdAt);
}
