/// One product row in the catalogue list.
library;

import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/products/presentation/widgets/product_badges.dart';
import 'package:flutter/material.dart';

/// A tappable summary of a product.
///
/// Shows what distinguishes one catalogue entry from another at a glance -
/// name, what it is, how tightly it is controlled - and nothing that would need
/// a second query to draw. Stock and expiry live on the detail screen, where
/// the batch data is already loaded.
class ProductCard extends StatelessWidget {
  /// Creates a product card.
  const ProductCard({required this.product, super.key, this.onTap});

  /// The product to summarise.
  final Product product;

  /// Called when the card is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = <String>[
      if (_hasText(product.genericName)) product.genericName!,
      if (_hasText(product.brand)) product.brand!,
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
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        ScheduleBadge(scheduleType: product.scheduleType),
                        if (!product.isActive)
                          const StatusBadge(label: 'Inactive'),
                        if (_hasText(product.category))
                          StatusBadge(label: product.category!),
                        if (_hasText(product.rackLocation))
                          StatusBadge(
                            label: 'Rack ${product.rackLocation}',
                            tone: BadgeTone.info,
                            icon: Icons.place_outlined,
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

/// Whether [value] holds anything worth rendering.
bool _hasText(String? value) => value != null && value.trim().isNotEmpty;
