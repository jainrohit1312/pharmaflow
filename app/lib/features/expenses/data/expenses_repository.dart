/// Supabase-backed repository for expenses.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/expense.dart';
import 'package:app/data/models/sale.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'expenses_repository.g.dart';

/// Exposes the single [ExpensesRepository].
@riverpod
ExpensesRepository expensesRepository(Ref ref) =>
    ExpensesRepository(ref.watch(supabaseClientProvider));

/// Data access for the `expenses` table.
class ExpensesRepository {
  /// Creates a repository backed by the shared Supabase client.
  ExpensesRepository(this._client);

  final sb.SupabaseClient _client;

  /// Rows fetched per page.
  static const int pageSize = 50;

  /// Loads one page of expenses, newest first.
  Future<List<Expense>> list({
    required String pharmacyId,
    int limit = pageSize,
    int offset = 0,
  }) async {
    try {
      final rows = await _client
          .from('expenses')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .order('expense_date', ascending: false)
          .order('created_at', ascending: false)
          .range(offset, offset + limit - 1);
      return rows.map(Expense.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the expenses.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the expenses.',
        cause: error,
      );
    }
  }

  /// Records an expense.
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

    try {
      final row = await _client
          .from('expenses')
          .insert(<String, dynamic>{
            'pharmacy_id': pharmacyId,
            'category': trimmed,
            'amount': amount,
            'expense_date': Formatters.dateIso(expenseDate),
            'payment_mode': paymentMode.dbValue,
            'notes': notes?.trim().isEmpty ?? true ? null : notes!.trim(),
          })
          .select()
          .single();
      return Expense.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to record that expense.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to record that expense.',
        cause: error,
      );
    }
  }
}
