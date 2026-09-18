/// Tests for the expenses screen and its entry sheet.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/data/models/expense.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/expenses/data/expenses_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_expenses_repository.dart';
import '../../../support/fake_reports_repository.dart';
import '../../../support/reports_test_app.dart';

/// Opens the entry sheet from the expenses screen.
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('Add expense'));
  await tester.pumpAndSettle();
}

/// Picks [category] in the sheet's category dropdown.
Future<void> _pickCategory(WidgetTester tester, String category) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(category).last);
  await tester.pumpAndSettle();
}

/// Taps the sheet's submit button.
Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ElevatedButton, 'Record expense'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists what was spent, newest first', (tester) async {
    final repository = FakeExpensesRepository(
      expenses: <Expense>[
        buildExpense(
          category: 'Freight',
          amount: 250,
          expenseDate: DateTime(2026, 9, 10),
          paymentMode: PaymentMode.upi,
          notes: 'Courier',
        ),
        buildExpense(amount: 20000, expenseDate: DateTime(2026, 9)),
      ],
    );

    await pumpReportsApp(
      tester,
      reports: FakeReportsRepository(),
      expenses: repository,
      initialLocation: Routes.expenses,
    );

    expect(find.text('Freight'), findsOneWidget);
    expect(find.text('Rent'), findsOneWidget);
    expect(find.text('Courier'), findsOneWidget);
    // The date and the mode are on one line, as one label.
    expect(
      find.textContaining(Formatters.dateDdMmmYyyy(DateTime(2026, 9, 10))),
      findsOneWidget,
    );
    expect(find.textContaining(PaymentMode.upi.label), findsOneWidget);
    // Each row's own amount.
    expect(find.text(Formatters.currency(250)), findsOneWidget);
    expect(find.text(Formatters.currency(20000)), findsOneWidget);
    // And what the loaded rows add up to.
    expect(find.text(Formatters.currency(20250)), findsOneWidget);
    expect(find.textContaining('2 loaded'), findsOneWidget);
  });

  testWidgets('says so when nothing has been recorded', (tester) async {
    await pumpReportsApp(
      tester,
      reports: FakeReportsRepository(),
      initialLocation: Routes.expenses,
    );

    expect(find.text('No expenses recorded'), findsOneWidget);
    expect(find.text('Add expense'), findsOneWidget);
  });

  testWidgets('records an expense and shows it in the list', (tester) async {
    final repository = FakeExpensesRepository(
      expenses: <Expense>[
        buildExpense(amount: 20000, expenseDate: DateTime(2026, 9)),
      ],
    );
    await pumpReportsApp(
      tester,
      reports: FakeReportsRepository(),
      expenses: repository,
      initialLocation: Routes.expenses,
    );

    await _openSheet(tester);
    await _pickCategory(tester, 'Freight');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount'),
      '450.5',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Notes'),
      'Courier to the wholesaler',
    );
    await _submit(tester);

    expect(repository.lastCategory, 'Freight');
    expect(repository.lastAmount, 450.5);
    expect(repository.lastPaymentMode, PaymentMode.cash);
    expect(repository.lastNotes, 'Courier to the wholesaler');
    expect(find.text('Expense recorded.'), findsOneWidget);
    expect(find.text('Freight'), findsOneWidget);
    expect(find.text(Formatters.currency(450.5)), findsOneWidget);
    // The new row is in the list's own total as well.
    expect(find.text(Formatters.currency(20450.5)), findsOneWidget);
  });

  testWidgets('refuses a missing category at the field', (tester) async {
    final repository = FakeExpensesRepository();
    await pumpReportsApp(
      tester,
      reports: FakeReportsRepository(),
      expenses: repository,
      initialLocation: Routes.expenses,
    );

    await _openSheet(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '450');
    await _submit(tester);

    expect(find.text('Choose a category'), findsOneWidget);
    expect(
      repository.lastAmount,
      isNull,
      reason: 'nothing reaches the write for a form that has not passed',
    );
  });

  testWidgets('refuses an amount of zero at the field', (tester) async {
    final repository = FakeExpensesRepository();
    await pumpReportsApp(
      tester,
      reports: FakeReportsRepository(),
      expenses: repository,
      initialLocation: Routes.expenses,
    );

    await _openSheet(tester);
    await _pickCategory(tester, 'Rent');
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '0');
    await _submit(tester);

    expect(find.text('Must be more than zero'), findsOneWidget);
    expect(repository.lastAmount, isNull);
  });

  testWidgets('reports a refused expense and stays open to fix it', (
    tester,
  ) async {
    final repository = FakeExpensesRepository()
      ..errorToThrow = const ValidationException(
        message: 'new row for relation "expenses" violates check constraint',
      );
    await pumpReportsApp(
      tester,
      reports: FakeReportsRepository(),
      expenses: repository,
      initialLocation: Routes.expenses,
    );

    await _openSheet(tester);
    await _pickCategory(tester, 'Rent');
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '450');
    await _submit(tester);

    expect(
      find.textContaining('violates check constraint'),
      findsOneWidget,
      reason: 'what the database refused is more useful than a generic message',
    );
    expect(
      find.widgetWithText(ElevatedButton, 'Record expense'),
      findsOneWidget,
      reason: 'the sheet stays open so the entry can be corrected',
    );
  });

  testWidgets('fetches the next page on request', (tester) async {
    final repository = FakeExpensesRepository(
      expenses: <Expense>[
        for (var index = 0; index < ExpensesRepository.pageSize + 5; index++)
          buildExpense(
            amount: index + 1,
            expenseDate: DateTime(2026, 1, index + 1),
          ),
      ],
    );

    await pumpReportsApp(
      tester,
      reports: FakeReportsRepository(),
      expenses: repository,
      initialLocation: Routes.expenses,
      size: const Size(1200, 12000),
    );

    expect(find.text('Load more'), findsOneWidget);

    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();

    expect(repository.requestedOffsets, <int>[0, ExpensesRepository.pageSize]);
    expect(
      find.text('Load more'),
      findsNothing,
      reason: 'the second page is not full',
    );
    expect(find.textContaining('55 loaded'), findsOneWidget);
  });
}
