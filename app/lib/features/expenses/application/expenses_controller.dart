/// The paginated expense list, and the write that adds to it.
library;

import 'package:app/data/models/expense.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/expenses/data/expenses_repository.dart';
import 'package:app/features/reports/application/reports_controller.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'expenses_controller.g.dart';

/// One loaded page of expenses, and whether another exists.
class ExpenseListPage {
  /// Creates a page.
  const ExpenseListPage({
    required this.items,
    required this.hasMore,
    this.isLoadingMore = false,
  });

  /// The expenses loaded so far, newest first.
  final List<Expense> items;

  /// Whether the last fetch filled a whole page.
  final bool hasMore;

  /// Whether a load-more is in flight.
  final bool isLoadingMore;

  /// What the loaded rows add up to.
  ///
  /// The loaded ones, not all of them: this is a list a user is reading, and the
  /// windowed total is the reports screen's job (`report_summary`).
  double get loadedTotal =>
      items.fold<double>(0, (total, expense) => total + expense.amount);

  /// A copy with individual fields replaced.
  ExpenseListPage copyWith({
    List<Expense>? items,
    bool? hasMore,
    bool? isLoadingMore,
  }) => ExpenseListPage(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

/// The expense list.
@riverpod
class ExpensesListController extends _$ExpensesListController {
  @override
  Future<ExpenseListPage> build() async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final items = await ref
        .watch(expensesRepositoryProvider)
        .list(pharmacyId: pharmacyId);

    return ExpenseListPage(
      items: items,
      hasMore: items.length == ExpensesRepository.pageSize,
    );
  }

  /// Appends the next page, restoring the current one and rethrowing on failure.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.isLoadingMore) {
      return;
    }

    state = AsyncData<ExpenseListPage>(current.copyWith(isLoadingMore: true));
    try {
      final items = await ref
          .read(expensesRepositoryProvider)
          .list(
            pharmacyId: ref.read(requirePharmacyIdProvider),
            offset: current.items.length,
          );

      state = AsyncData<ExpenseListPage>(
        ExpenseListPage(
          items: <Expense>[...current.items, ...items],
          hasMore: items.length == ExpensesRepository.pageSize,
        ),
      );
    } on Object {
      state = AsyncData<ExpenseListPage>(current);
      rethrow;
    }
  }
}

/// Records an expense.
///
/// The reports summary is invalidated too: an expense moves the window it was
/// recorded in, and a report that still showed the old total would be wrong in the
/// quiet way that matters most.
@riverpod
class ExpenseFormController extends _$ExpenseFormController {
  @override
  Future<Expense?> build() async => null;

  /// Records one expense.
  Future<Expense> createExpense({
    required String category,
    required double amount,
    required DateTime expenseDate,
    required PaymentMode paymentMode,
    String? notes,
  }) async {
    state = const AsyncLoading<Expense?>();
    try {
      final saved = await ref
          .read(expensesRepositoryProvider)
          .create(
            pharmacyId: ref.read(requirePharmacyIdProvider),
            category: category,
            amount: amount,
            expenseDate: expenseDate,
            paymentMode: paymentMode,
            notes: notes,
          );
      state = AsyncData<Expense?>(saved);
      ref
        ..invalidate(expensesListControllerProvider)
        ..invalidate(reportSummaryProvider);
      return saved;
    } on Object catch (error, stackTrace) {
      state = AsyncError<Expense?>(error, stackTrace);
      rethrow;
    }
  }
}
