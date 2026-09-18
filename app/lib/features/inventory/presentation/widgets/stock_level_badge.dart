/// Badge for how a product's on-hand quantity stands against its reorder level.
library;

import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/product_stock.dart';
import 'package:flutter/material.dart';

/// The stock level, as a badge - drawn only when it needs attention.
///
/// A green "In stock" on every row of a long list is noise: the stock list
/// exists to show what is wrong, so a healthy row says nothing rather than
/// saying that everything is fine. The product detail screen, which shows one
/// product at a time, does label the healthy case, because there the badge is
/// answering "is this in stock" rather than "which of these need me".
class StockLevelBadge extends StatelessWidget {
  /// Creates a stock level badge for [stock].
  const StockLevelBadge({required this.stock, super.key});

  /// The row to judge.
  final ProductStock stock;

  @override
  Widget build(BuildContext context) {
    if (stock.isOutOfStock) {
      return const StatusBadge(
        label: 'Out of stock',
        tone: BadgeTone.danger,
        icon: Icons.remove_shopping_cart_outlined,
      );
    }
    if (stock.isLowStock) {
      return const StatusBadge(
        label: 'Low stock',
        tone: BadgeTone.warning,
        icon: Icons.trending_down,
      );
    }
    return const SizedBox.shrink();
  }
}
