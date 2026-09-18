/// One customer row in the master list.
library;

import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/customer.dart';
import 'package:flutter/material.dart';

/// A tappable summary of a customer.
///
/// Shows what distinguishes one customer from another at a glance - name, how to
/// reach them, whether they are registered - and nothing that would need a
/// second query to draw. What they owe lives on the detail screen, where the
/// ledger is already loaded.
class CustomerCard extends StatelessWidget {
  /// Creates a customer card.
  const CustomerCard({required this.customer, super.key, this.onTap});

  /// The customer to summarise.
  final Customer customer;

  /// Called when the card is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The schema keeps one free-text address and no separate city column, so the
    // last comma-separated segment is the closest thing to a locality the card
    // can show without inventing one.
    final locality = _locality(customer.address);
    final subtitle = <String>[
      if (_hasText(customer.phone)) customer.phone!,
      if (_hasText(customer.email)) customer.email!,
      if (locality != null) locality,
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
                      customer.name,
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
                        if (_hasText(customer.gstin))
                          StatusBadge(
                            label: customer.gstin!,
                            tone: BadgeTone.info,
                            icon: Icons.receipt_long_outlined,
                          ),
                        if (!customer.isActive)
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

/// The locality implied by [address], or `null` when there is nothing to read.
///
/// A single-line address is returned whole: with no commas there is no way to
/// tell which part is the town, so showing the line as written is more honest
/// than guessing at the last word.
String? _locality(String? address) {
  final trimmed = address?.trim() ?? '';
  if (trimmed.isEmpty) {
    return null;
  }
  final parts = trimmed
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) {
    return null;
  }
  return parts.length == 1 ? parts.first : parts.last;
}
