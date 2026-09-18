/// Expenses: what the pharmacy spent, newest first.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/data/models/expense.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/expenses/application/expenses_controller.dart';
import 'package:app/features/expenses/presentation/widgets/expense_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The expense ledger: rent, salaries, freight and everything else the counter
/// takings have to cover.
///
/// Kept apart from the party ledger rather than inside it, because an expense has
/// nobody on the other side of it: `ledger_entries` needs a `party_type` and
/// exactly one matching party id (migration 00007), and rent has no supplier. The
/// reports screen reads this table instead.
class ExpensesScreen extends ConsumerWidget {
  /// Creates the expenses screen.
  const ExpensesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(expensesListControllerProvider);

    ref.listen<AsyncValue<ExpenseListPage>>(expensesListControllerProvider, (
      previous,
      next,
    ) {
      final error = next.error;
      if (error == null || !context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    });

    return AppScaffold(
      title: 'Expenses',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add expense'),
      ),
      body: _ExpensesBody(page: page),
    );
  }

  /// Opens the entry sheet, and confirms what it wrote.
  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final written = await showExpenseSheet(context);
    if (!written || !context.mounted) {
      return;
    }
    // The controller has already invalidated the list and the reports summary;
    // this only confirms the row was written.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Expense recorded.')));
  }
}

/// Renders whichever of the list's states applies.
class _ExpensesBody extends ConsumerWidget {
  const _ExpensesBody({required this.page});

  /// Current list state.
  final AsyncValue<ExpenseListPage> page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loaded = page.value;
    if (loaded != null) {
      if (loaded.items.isEmpty) {
        return const AppEmptyView(
          icon: Icons.price_change_outlined,
          title: 'No expenses recorded',
          message:
              'Rent, salaries, electricity and freight are recorded here, and '
              'the reports screen subtracts them from what the counter took.',
        );
      }
      return Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SectionCard(
              title: 'Recorded so far',
              child: _LoadedTotal(page: loaded),
            ),
          ),
          Expanded(child: _ExpenseList(page: loaded)),
        ],
      );
    }

    if (page.hasError) {
      return ErrorView(
        message: describeError(page.error!),
        onRetry: () => ref.invalidate(expensesListControllerProvider),
      );
    }

    return const LoadingView(message: 'Loading expenses…');
  }
}

/// What the rows fetched so far add up to.
///
/// The loaded rows, not every expense ever recorded: this is a list the user is
/// reading, and the windowed figure is `report_summary`'s job. The note says so,
/// because a total that silently means "the part you scrolled to" is worse than
/// no total.
class _LoadedTotal extends StatelessWidget {
  const _LoadedTotal({required this.page});

  /// The rows loaded so far.
  final ExpenseListPage page;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          Formatters.currency(page.loadedTotal),
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(
          '${page.items.length} loaded${page.hasMore ? ' · more below' : ''}. '
          'The reports screen totals the whole window.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// The loaded rows, with a trailing control to fetch the next page.
class _ExpenseList extends ConsumerWidget {
  const _ExpenseList({required this.page});

  /// The rows loaded so far.
  final ExpenseListPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoadingMore = page.isLoadingMore;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      itemCount: page.items.length + (page.hasMore ? 1 : 0),
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index >= page.items.length) {
          return Center(
            child: AppButton.outlined(
              label: isLoadingMore ? 'Loading…' : 'Load more',
              icon: Icons.expand_more,
              expand: false,
              isLoading: isLoadingMore,
              onPressed: isLoadingMore ? null : () => _loadMore(context, ref),
            ),
          );
        }
        return _ExpenseTile(expense: page.items[index]);
      },
    );
  }

  /// Fetches the next page, reporting a failure without clearing the list.
  ///
  /// The controller restores the previous page and rethrows, so the failure has
  /// to be reported here rather than through `ref.listen` on the provider.
  Future<void> _loadMore(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(expensesListControllerProvider.notifier).loadMore();
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

/// One expense.
class _ExpenseTile extends StatelessWidget {
  const _ExpenseTile({required this.expense});

  /// The expense.
  final Expense expense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = expense.notes;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(expense.category, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    '${Formatters.dateDdMmmYyyy(expense.expenseDate)} · '
                    '${expense.paymentMode.label}',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (notes != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      notes,
                      style: theme.textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              Formatters.currency(expense.amount),
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
      ),
    );
  }
}
