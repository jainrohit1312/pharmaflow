/// One product that has fallen below the level it is meant to keep.
library;

import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/alert_payloads.dart';
import 'package:flutter/material.dart';

/// A tappable summary of one reorder alert.
///
/// Every figure comes off the `low_stock_products` answer (migration
/// 20260919000027): the comparison, the order and the shortfall all arrive
/// decided, so this card renders three numbers and computes none (D-047, I-1).
///
/// **The shortfall is the point of it.** "How many units close the gap" is what
/// someone working down a reorder list needs, and it is what the RPC adds to
/// the old client-side list. The stock tab's value at cost is deliberately
/// *not* here: that figure belongs to the `product_stock` rollup - which is
/// what values stock at landed cost (D-012) - and the reorder answer does not
/// carry it. Rendering a default would put a wrong rupee figure on screen.
class LowStockCard extends StatelessWidget {
  /// Creates a reorder card.
  const LowStockCard({required this.product, super.key, this.onTap});

  /// The alert to show.
  final LowStockProduct product;

  /// Called when the card is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = <String>[
      if (_hasText(product.genericName)) product.genericName!,
      if (_hasText(product.packSize)) product.packSize!,
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
                      product.name,
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
                      '${_units(product.totalQty)} · '
                      'reorder at ${product.minStockLevel}',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        // No "Low stock" badge: every row of this list is low,
                        // so a badge saying so on all of them says nothing -
                        // the same reason `StockLevelBadge` stays quiet for a
                        // healthy row on the stock tab. "Out of stock" still
                        // separates the zero rows from the rest.
                        if (product.totalQty <= 0)
                          const StatusBadge(
                            label: 'Out of stock',
                            tone: BadgeTone.danger,
                            icon: Icons.remove_shopping_cart_outlined,
                          ),
                        StatusBadge(
                          label: 'Order ${_units(product.shortfall)}',
                          tone: BadgeTone.warning,
                          icon: Icons.shopping_cart_outlined,
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
