/// Tests for the reporting envelope: what `report_summary()` sends, and what the
/// repository's parse makes of it.
///
/// The server half of this seam is proved by
/// `supabase/tests/phase4_report_summary.sql`. This file covers the other half -
/// the Dart decode - because a figure that arrives under the wrong key, or as a
/// string, is a report that is wrong on screen with nothing raising an error.
library;

import 'package:app/data/models/report_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_reports_repository.dart';

void main() {
  group('ReportSummary.fromJson', () {
    test('reads every block the server sends', () {
      final summary = ReportSummary.fromJson(_envelope());

      expect(summary.from, DateTime(2026, 9));
      expect(summary.to, DateTime(2026, 9, 30));

      expect(summary.sales.count, 12);
      expect(summary.sales.subTotal, 1000);
      expect(summary.sales.taxTotal, 120);
      expect(summary.sales.grandTotal, 1120);
      expect(summary.sales.collected, 1000);
      expect(summary.sales.outstanding, 120);

      expect(summary.purchases.count, 4);
      expect(summary.purchases.taxTotal, 900);
      expect(summary.purchases.grandTotal, 5900);

      expect(summary.returns.saleCount, 1);
      expect(summary.returns.saleTotal, 200);
      expect(summary.returns.purchaseCount, 2);
      expect(summary.returns.purchaseTotal, 500);

      expect(summary.expenses.count, 3);
      expect(summary.expenses.total, 7000);

      expect(summary.stock.products, 40);
      expect(summary.stock.units, 900);
      expect(summary.stock.valueAtCost, 45000);
      expect(summary.stock.valueAtMrp, 60000);

      expect(summary.expiring.expiredValueAtMrp, 100);
      expect(summary.expiring.criticalValueAtMrp, 200);
      expect(summary.expiring.warningValueAtMrp, 300);
    });

    test('accepts a numeric that arrives as a string', () {
      // A Postgres `numeric` can reach Dart as a string. A decode that only
      // accepted `num` would report zero for a real figure - the quiet kind of
      // wrong that a report must not be.
      final summary = ReportSummary.fromJson(<String, dynamic>{
        'from': '2026-09-01',
        'to': '2026-09-30',
        'expenses': <String, dynamic>{'count': '3', 'total': '7000.50'},
      });

      expect(summary.expenses.count, 3);
      expect(summary.expenses.total, 7000.5);
    });

    test('a block the server omitted reads as zero rather than throwing', () {
      final summary = ReportSummary.fromJson(<String, dynamic>{});

      expect(summary.sales.grandTotal, 0);
      expect(summary.expenses.count, 0);
      expect(summary.stock.units, 0);
    });

    test('a value that is not a number at all does not throw', () {
      final summary = ReportSummary.fromJson(<String, dynamic>{
        'sales': <String, dynamic>{'count': 'twelve'},
      });

      expect(summary.sales.count, 0);
    });

    test('a whole number is rounded from whatever shape it arrives in', () {
      final summary = ReportSummary.fromJson(<String, dynamic>{
        'sales': <String, dynamic>{'count': 11.6},
      });

      expect(summary.sales.count, 12);
    });
  });

  group('the figures the screen derives', () {
    test('the average bill is the billed total over the bills', () {
      const sales = ReportSalesTotals(
        count: 4,
        subTotal: 0,
        taxTotal: 0,
        grandTotal: 1000,
        collected: 0,
        outstanding: 0,
      );

      expect(sales.averageBill, 250);
    });

    test(
      'nothing sold gives an average of zero rather than a division by it',
      () {
        const sales = ReportSalesTotals(
          count: 0,
          subTotal: 0,
          taxTotal: 0,
          grandTotal: 0,
          collected: 0,
          outstanding: 0,
        );

        expect(sales.averageBill, 0);
      },
    );

    test('returns net the two directions', () {
      // Positive means more was credited back by suppliers than refunded to
      // customers.
      const returns = ReportReturnsTotals(
        saleCount: 1,
        saleTotal: 200,
        purchaseCount: 2,
        purchaseTotal: 500,
      );

      expect(returns.net, 300);
    });

    test('what is at risk is the three expiry buckets together', () {
      const expiring = ReportExpiringTotals(
        expiredValueAtMrp: 100,
        criticalValueAtMrp: 200,
        warningValueAtMrp: 300,
      );

      expect(expiring.atRisk, 600);
    });

    test('contributed margin is billed, less refunds, less expenses', () {
      final summary = buildSummary(
        sales: const ReportSalesTotals(
          count: 1,
          subTotal: 1000,
          taxTotal: 0,
          grandTotal: 1000,
          collected: 1000,
          outstanding: 0,
        ),
        returns: const ReportReturnsTotals(
          saleCount: 1,
          saleTotal: 200,
          purchaseCount: 0,
          purchaseTotal: 0,
        ),
        expenses: const ReportExpenseTotals(count: 1, total: 300),
      );

      expect(summary.contributedMargin, 500);
    });
  });
}

/// The envelope `report_summary()` builds, as PostgREST hands it over.
Map<String, dynamic> _envelope() => <String, dynamic>{
  'from': '2026-09-01',
  'to': '2026-09-30',
  'sales': <String, dynamic>{
    'count': 12,
    'sub_total': 1000,
    'tax_total': 120,
    'grand_total': 1120,
    'collected': 1000,
    'outstanding': 120,
  },
  'purchases': <String, dynamic>{
    'count': 4,
    'tax_total': 900,
    'grand_total': 5900,
  },
  'returns': <String, dynamic>{
    'sale_count': 1,
    'sale_total': 200,
    'purchase_count': 2,
    'purchase_total': 500,
  },
  'expenses': <String, dynamic>{'count': 3, 'total': 7000},
  'stock': <String, dynamic>{
    'products': 40,
    'units': 900,
    'value_at_cost': 45000,
    'value_at_mrp': 60000,
  },
  'expiring': <String, dynamic>{
    'expired_value_at_mrp': 100,
    'critical_value_at_mrp': 200,
    'warning_value_at_mrp': 300,
  },
};
