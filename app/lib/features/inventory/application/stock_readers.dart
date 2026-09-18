/// The one place that knows which cached reads a batch balance feeds.
///
/// Three writes move stock - a purchase receipt, a stock adjustment and a sale -
/// and now a fourth, a sale return's restock. Each of them has to refresh the same
/// four providers, and a write that forgot one would leave a screen showing a
/// quantity that is merely out of date, with no error to explain it. D-021 records
/// the contract; this is the single implementation of it.
library;

import 'package:app/features/inventory/application/expiry_calendar_controller.dart';
import 'package:app/features/inventory/application/expiry_dashboard_controller.dart';
import 'package:app/features/inventory/application/low_stock_controller.dart';
import 'package:app/features/inventory/application/stock_list_controller.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

/// Drops every cached read that a batch balance feeds.
///
/// All four are invalidated rather than only the screen that asked: a movement
/// can lift a product out of the low-stock list or put it in, and it can move a
/// batch into or out of an expiry bucket, so which of the four actually changed is
/// not knowable from the write alone.
void refreshStockReaders(Ref ref) {
  ref
    ..invalidate(stockListControllerProvider)
    ..invalidate(lowStockListProvider)
    ..invalidate(expiryBoardControllerProvider)
    ..invalidate(expiryMonthControllerProvider);
}
