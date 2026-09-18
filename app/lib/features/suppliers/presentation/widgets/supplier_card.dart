/// One supplier row in the master list.
library;

import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/supplier.dart';
import 'package:flutter/material.dart';

/// A tappable summary of a supplier.
///
/// Shows what distinguishes one supplier from another at a glance - who they
/// are, how to reach them, and whether they are registered - and nothing that
/// would need a second query to draw. The ledger balance lives on the detail
/// screen, where the totals have already been read.
class SupplierCard extends StatelessWidget {
  /// Creates a supplier card.
  const SupplierCard({required this.supplier, super.key, this.onTap});

  /// The supplier to summarise.
  final Supplier supplier;

  /// Called when the card is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = <String>[
      if (_hasText(supplier.contactPerson)) supplier.contactPerson!,
      if (_hasText(supplier.phone)) supplier.phone!,
      if (_hasText(supplier.city)) supplier.city!,
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
                      supplier.name,
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
                        if (_hasText(supplier.gstin))
                          StatusBadge(
                            label: supplier.gstin!,
                            tone: BadgeTone.info,
                            icon: Icons.receipt_long_outlined,
                          ),
                        if (!supplier.isActive)
                          const StatusBadge(label: 'Inactive'),
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
