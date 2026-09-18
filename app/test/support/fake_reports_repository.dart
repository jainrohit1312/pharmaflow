/// Shared test double for the reports screen.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/report_summary.dart';
import 'package:app/features/reports/data/reports_repository.dart';

/// Builds a summary with only the figures a test cares about.
///
/// Every block is spelled out rather than defaulted, because `ReportSummary` is an
/// RPC envelope with no defaults of its own - the server always sends every key -
/// so an omitted block here stands for a window in which nothing happened.
ReportSummary buildSummary({
  ReportSalesTotals? sales,
  ReportPurchaseTotals? purchases,
  ReportReturnsTotals? returns,
  ReportExpenseTotals? expenses,
  ReportStockTotals? stock,
  ReportExpiringTotals? expiring,
  DateTime? from,
  DateTime? to,
}) => ReportSummary(
  from: from ?? DateTime(2026, 9),
  to: to ?? DateTime(2026, 9, 30),
  sales:
      sales ??
      const ReportSalesTotals(
        count: 0,
        subTotal: 0,
        taxTotal: 0,
        grandTotal: 0,
        collected: 0,
        outstanding: 0,
      ),
  purchases:
      purchases ??
      const ReportPurchaseTotals(count: 0, taxTotal: 0, grandTotal: 0),
  returns:
      returns ??
      const ReportReturnsTotals(
        saleCount: 0,
        saleTotal: 0,
        purchaseCount: 0,
        purchaseTotal: 0,
      ),
  expenses: expenses ?? const ReportExpenseTotals(count: 0, total: 0),
  stock:
      stock ??
      const ReportStockTotals(
        products: 0,
        units: 0,
        valueAtCost: 0,
        valueAtMrp: 0,
      ),
  expiring:
      expiring ??
      const ReportExpiringTotals(
        expiredValueAtMrp: 0,
        criticalValueAtMrp: 0,
        warningValueAtMrp: 0,
      ),
);

/// One window the fake was asked to add up.
class ReportWindowRequest {
  /// Creates a recorded request.
  const ReportWindowRequest({required this.from, required this.to});

  /// The first day asked for.
  final DateTime from;

  /// The last day asked for.
  final DateTime to;
}

/// An in-memory [ReportsRepository] that records the windows it was handed.
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing:
/// `implements` does not require a constructor, so the fake never needs a
/// Supabase client - which is the whole point, because a real `SupabaseClient`
/// cannot be constructed without an initialised backend.
class FakeReportsRepository implements ReportsRepository {
  /// Creates a fake returning [result] for every window.
  FakeReportsRepository({ReportSummary? result})
    : result = result ?? buildSummary();

  /// What every call returns.
  ReportSummary result;

  /// When set, *every* call throws it until the test clears it.
  ///
  /// Persistent rather than one-shot on purpose: a route can be built more than
  /// once before the first frame settles, so a failure that cleared itself would
  /// be retried into a success before a test could look at the error state.
  Exception? errorToThrow;

  /// Every window asked for, in order.
  final List<ReportWindowRequest> requests = <ReportWindowRequest>[];

  @override
  Future<ReportSummary> summary({
    required DateTime from,
    required DateTime to,
  }) async {
    requests.add(ReportWindowRequest(from: from, to: to));

    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
