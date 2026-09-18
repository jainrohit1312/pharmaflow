/// One product's stock row.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/product_stock.dart';
import 'package:app/features/inventory/presentation/widgets/stock_level_badge.dart';
import 'package:flutter/material.dart';

/// A tappable summary of what one product holds and what it is worth.
///
/// Every figure comes off the `product_stock` row itself, which is the same view
/// the repository read: the quantity and the value at cost are the rollup's, not
/// a sum recomputed here from batches the row does not carry. That keeps this
/// card and the product detail screen from disagreeing, and keeps the valuation
/// on the landed cost (D-012) instead of the purchase rate.
class ProductStockCard extends StatelessWidget {
  /// Creates a stock card.
  const ProductStockCard({required this.stock, super.key, this.onTap});

  /// The rollup row to show.
  final ProductStock stock;

  /// Called when the card is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = <String>[
      if (_hasText(stock.genericName)) stock.genericName!,
      if (_hasText(stock.brand)) stock.brand!,
    ].join(' · ');

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      stock.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      '${_units(stock.totalQty)} · '
                      '${Formatters.currency(stock.stockValueAtCost)} at cost',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        StockLevelBadge(stock: stock),
                        if (stock.minStockLevel > 0)
                          StatusBadge(
                            label: 'Reorder at ${stock.minStockLevel}',
                            icon: Icons.flag_outlined,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

/// `12 units`, or `1 unit`.
String _units(int qty) => '$qty ${qty == 1 ? 'unit' : 'units'}';

/// Whether [value] holds anything worth rendering.
bool _hasText(String? value) => value != null && value.trim().isNotEmpty;
