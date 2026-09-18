/// Tests for the reports screen.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/data/models/report_summary.dart';
import 'package:app/features/expenses/presentation/expenses_screen.dart';
import 'package:app/features/reports/application/reports_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_reports_repository.dart';
import '../../../support/reports_test_app.dart';

/// A window with a different figure in every row, so an assertion cannot pass on
/// a value some other card put on screen.
ReportSummary _summary() => buildSummary(
  sales: const ReportSalesTotals(
    count: 12,
    subTotal: 10000,
    taxTotal: 1200,
    grandTotal: 11200,
    collected: 9000,
    outstanding: 2200,
  ),
  purchases: const ReportPurchaseTotals(
    count: 4,
    taxTotal: 800,
    grandTotal: 5900,
  ),
  returns: const ReportReturnsTotals(
    saleCount: 1,
    saleTotal: 200,
    purchaseCount: 2,
    purchaseTotal: 500,
  ),
  expenses: const ReportExpenseTotals(count: 3, total: 700),
  stock: const ReportStockTotals(
    products: 40,
    units: 900,
    valueAtCost: 45000,
    valueAtMrp: 60000,
  ),
  expiring: const ReportExpiringTotals(
    expiredValueAtMrp: 150,
    criticalValueAtMrp: 250,
    warningValueAtMrp: 350,
  ),
);

void main() {
  testWidgets('shows every headline figure of the window', (tester) async {
    await pumpReportsApp(
      tester,
      reports: FakeReportsRepository(result: _summary()),
    );

    expect(find.text('Reports'), findsOneWidget);
    expect(find.text('Sales'), findsOneWidget);
    // What was billed, taken and still owed.
    expect(find.text(Formatters.currency(11200)), findsOneWidget);
    expect(find.text(Formatters.currency(10000)), findsOneWidget);
    expect(find.text(Formatters.currency(9000)), findsOneWidget);
    expect(find.text(Formatters.currency(2200)), findsOneWidget);
    // The average bill, derived rather than sent.
    expect(find.text(Formatters.currency(11200 / 12)), findsOneWidget);
    // Input tax, and the net the two tax heads leave.
    expect(find.text(Formatters.currency(800)), findsOneWidget);
    expect(find.text(Formatters.currency(1200 - 800)), findsOneWidget);
    // Both directions of returns, and their net.
    expect(find.text(Formatters.currency(200)), findsOneWidget);
    expect(find.text(Formatters.currency(500)), findsOneWidget);
    expect(find.text(Formatters.currency(500 - 200)), findsOneWidget);
    // Expenses, and what the window is worth after them.
    expect(find.text(Formatters.currency(700)), findsOneWidget);
    expect(find.text(Formatters.currency(10000 - 200 - 700)), findsOneWidget);
    // Stock, at cost and at MRP.
    expect(find.text(Formatters.currency(45000)), findsOneWidget);
    expect(find.text(Formatters.currency(60000)), findsOneWidget);
    // Expiry, bucket by bucket, and what needs a decision.
    expect(find.text(Formatters.currency(150)), findsOneWidget);
    expect(find.text(Formatters.currency(250)), findsOneWidget);
    expect(find.text(Formatters.currency(350)), findsOneWidget);
    expect(find.text(Formatters.currency(150 + 250 + 350)), findsOneWidget);
  });

  testWidgets('says what the contributed figure is not', (tester) async {
    await pumpReportsApp(
      tester,
      reports: FakeReportsRepository(result: _summary()),
    );

    expect(find.text('Not a profit'), findsOneWidget);
    expect(
      find.textContaining('nothing about'),
      findsOneWidget,
      reason: 'the screen must not let a cash figure read as a gross margin',
    );
  });

  testWidgets('the window says which days it covers', (tester) async {
    await pumpReportsApp(
      tester,
      reports: FakeReportsRepository(result: _summary()),
    );

    expect(find.textContaining('Both days are included'), findsOneWidget);
    expect(find.text('From'), findsOneWidget);
    expect(find.text('To'), findsOneWidget);
  });

  testWidgets('moving the window asks the server for the new one', (
    tester,
  ) async {
    final repository = FakeReportsRepository(result: _summary());
    await pumpReportsApp(tester, reports: repository);
    final expected = windowFor(ReportPreset.lastMonth, DateTime.now());

    await tester.tap(find.text('Last month'));
    await tester.pumpAndSettle();

    expect(repository.requests.last.from, expected.from);
    expect(repository.requests.last.to, expected.to);
  });

  testWidgets('a failed read offers a retry that reads again', (tester) async {
    final repository = FakeReportsRepository(result: _summary())
      ..errorToThrow = const ServerException(message: 'Unable to read.');

    await pumpReportsApp(tester, reports: repository);

    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.textContaining('Unable to read.'), findsOneWidget);
    expect(find.text(Formatters.currency(11200)), findsNothing);

    repository.errorToThrow = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsNothing);
    expect(find.text(Formatters.currency(11200)), findsOneWidget);
  });

  testWidgets('the refresh action asks again', (tester) async {
    final repository = FakeReportsRepository(result: _summary());
    await pumpReportsApp(tester, reports: repository);
    final before = repository.requests.length;

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();

    expect(repository.requests.length, greaterThan(before));
  });

  testWidgets('opens the expenses screen', (tester) async {
    await pumpReportsApp(
      tester,
      reports: FakeReportsRepository(result: _summary()),
    );

    await tester.tap(find.text('Manage'));
    await tester.pumpAndSettle();

    expect(find.byType(ExpensesScreen), findsOneWidget);
  });
}
