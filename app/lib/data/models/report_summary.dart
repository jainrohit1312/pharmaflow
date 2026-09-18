/// Plain models for what the reporting RPC returns.
///
/// Not Freezed, and deliberately so: this is an RPC's response envelope rather than
/// a table row, no migration owns its shape, and six nested Freezed classes would
/// generate more code than the parser below. What matters is that the numbers are
/// read exactly once, here, so a screen never reaches into raw JSON.
///
/// Every figure is a server-side aggregate (`report_summary()`, migration
/// 20260918000021): PostgREST cannot `sum()`, and a total assembled from one capped
/// page of rows would be wrong in a way nobody could see.
library;

/// Which direction money moved for a return.
class ReportReturnsTotals {
  /// Creates returns totals.
  const ReportReturnsTotals({
    required this.saleCount,
    required this.saleTotal,
    required this.purchaseCount,
    required this.purchaseTotal,
  });

  /// How many customer returns were recorded.
  final int saleCount;

  /// What they refunded.
  final double saleTotal;

  /// How many supplier returns were recorded.
  final int purchaseCount;

  /// What they credited back.
  final double purchaseTotal;

  /// The net of the two: negative means more went back to suppliers than came back
  /// from customers.
  double get net => purchaseTotal - saleTotal;
}

/// The sales figures for the window.
class ReportSalesTotals {
  /// Creates sales totals.
  const ReportSalesTotals({
    required this.count,
    required this.subTotal,
    required this.taxTotal,
    required this.grandTotal,
    required this.collected,
    required this.outstanding,
  });

  /// How many bills were written.
  final int count;

  /// Value before tax.
  final double subTotal;

  /// Output tax charged.
  final double taxTotal;

  /// What was billed.
  final double grandTotal;

  /// What was taken at the counter, walk-ins included.
  final double collected;

  /// What customers still owe.
  final double outstanding;

  /// The average bill, or 0 when nothing was sold.
  double get averageBill => count == 0 ? 0 : grandTotal / count;
}

/// The purchase figures for the window.
class ReportPurchaseTotals {
  /// Creates purchase totals.
  const ReportPurchaseTotals({
    required this.count,
    required this.taxTotal,
    required this.grandTotal,
  });

  /// How many invoices were received. Draft and cancelled orders are excluded.
  final int count;

  /// Input tax paid.
  final double taxTotal;

  /// What was payable.
  final double grandTotal;
}

/// The expense figures for the window.
class ReportExpenseTotals {
  /// Creates expense totals.
  const ReportExpenseTotals({required this.count, required this.total});

  /// How many expenses were recorded.
  final int count;

  /// What they came to.
  final double total;
}

/// What is on the shelf right now.
///
/// Not windowed: stock is a position, not a period.
class ReportStockTotals {
  /// Creates stock totals.
  const ReportStockTotals({
    required this.products,
    required this.units,
    required this.valueAtCost,
    required this.valueAtMrp,
  });

  /// How many products the catalogue holds.
  final int products;

  /// Units on hand, across every batch.
  final int units;

  /// What they cost, at landed cost (D-012).
  final double valueAtCost;

  /// What they would sell for at MRP.
  final double valueAtMrp;
}

/// What is expiring, valued at MRP.
///
/// MRP rather than cost because `batch_status` carries no landed cost (D-021): the
/// cost basis would have to be approximated, and a write-off's decision is usually
/// made on what the stock would have sold for.
class ReportExpiringTotals {
  /// Creates expiry totals.
  const ReportExpiringTotals({
    required this.expiredValueAtMrp,
    required this.criticalValueAtMrp,
    required this.warningValueAtMrp,
  });

  /// Value of batches already past their expiry date.
  final double expiredValueAtMrp;

  /// Value of batches expiring within 30 days.
  final double criticalValueAtMrp;

  /// Value of batches expiring within 90 days.
  final double warningValueAtMrp;

  /// Everything that needs a decision, at MRP.
  double get atRisk => expiredValueAtMrp + criticalValueAtMrp + warningValueAtMrp;
}

/// Everything the reports screen shows, for one window.
class ReportSummary {
  /// Creates a summary.
  const ReportSummary({
    required this.from,
    required this.to,
    required this.sales,
    required this.purchases,
    required this.returns,
    required this.expenses,
    required this.stock,
    required this.expiring,
  });

  /// Decodes the RPC's `jsonb` object.
  factory ReportSummary.fromJson(Map<String, dynamic> json) {
    final sales = _object(json, 'sales');
    final purchases = _object(json, 'purchases');
    final returns = _object(json, 'returns');
    final expenses = _object(json, 'expenses');
    final stock = _object(json, 'stock');
    final expiring = _object(json, 'expiring');

    return ReportSummary(
      from: _date(json, 'from'),
      to: _date(json, 'to'),
      sales: ReportSalesTotals(
        count: _int(sales, 'count'),
        subTotal: _double(sales, 'sub_total'),
        taxTotal: _double(sales, 'tax_total'),
        grandTotal: _double(sales, 'grand_total'),
        collected: _double(sales, 'collected'),
        outstanding: _double(sales, 'outstanding'),
      ),
      purchases: ReportPurchaseTotals(
        count: _int(purchases, 'count'),
        taxTotal: _double(purchases, 'tax_total'),
        grandTotal: _double(purchases, 'grand_total'),
      ),
      returns: ReportReturnsTotals(
        saleCount: _int(returns, 'sale_count'),
        saleTotal: _double(returns, 'sale_total'),
        purchaseCount: _int(returns, 'purchase_count'),
        purchaseTotal: _double(returns, 'purchase_total'),
      ),
      expenses: ReportExpenseTotals(
        count: _int(expenses, 'count'),
        total: _double(expenses, 'total'),
      ),
      stock: ReportStockTotals(
        products: _int(stock, 'products'),
        units: _int(stock, 'units'),
        valueAtCost: _double(stock, 'value_at_cost'),
        valueAtMrp: _double(stock, 'value_at_mrp'),
      ),
      expiring: ReportExpiringTotals(
        expiredValueAtMrp: _double(expiring, 'expired_value_at_mrp'),
        criticalValueAtMrp: _double(expiring, 'critical_value_at_mrp'),
        warningValueAtMrp: _double(expiring, 'warning_value_at_mrp'),
      ),
    );
  }

  /// First day of the window.
  final DateTime from;

  /// Last day of the window.
  final DateTime to;

  /// Sales in the window.
  final ReportSalesTotals sales;

  /// Purchases received in the window.
  final ReportPurchaseTotals purchases;

  /// Returns recorded in the window.
  final ReportReturnsTotals returns;

  /// Expenses in the window.
  final ReportExpenseTotals expenses;

  /// Stock as it stands.
  final ReportStockTotals stock;

  /// What is expiring.
  final ReportExpiringTotals expiring;

  /// What the window left: billed, less refunds, less expenses.
  ///
  /// Not a profit: it knows what was sold and what was spent, and nothing about the
  /// cost of the goods that were sold - which arrived on invoices, not on the bills.
  /// The name says exactly that much and no more.
  double get contributedMargin =>
      sales.subTotal - returns.saleTotal - expenses.total;
}

/// One nested object of the envelope.
Map<String, dynamic> _object(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};
}

/// A number that may arrive as int, double or a numeric string.
double _double(Map<String, dynamic> json, String key) {
  final value = json[key];
  return switch (value) {
    final num number => number.toDouble(),
    final String text => double.tryParse(text) ?? 0,
    _ => 0,
  };
}

/// A whole number, tolerant of the same shapes.
int _int(Map<String, dynamic> json, String key) => _double(json, key).round();

/// A `date` that Postgres serialises as `YYYY-MM-DD`.
DateTime _date(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is String
      ? DateTime.tryParse(value) ?? DateTime.now()
      : DateTime.now();
}
