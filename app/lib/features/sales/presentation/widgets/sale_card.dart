/// One sale row in the sales list.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/sales/presentation/widgets/sale_status_badge.dart';
import 'package:flutter/material.dart';

/// A tappable summary of a sale: who it was for, when, and what it came to.
///
/// The customer name arrives already looked up, because `sales` stores the
/// customer by id and the list would otherwise resolve a name per row - and a
/// walk-in has no name to look up at all.
class SaleCard extends StatelessWidget {
  /// Creates a sale card.
  const SaleCard({
    required this.sale,
    required this.customerName,
    super.key,
    this.onTap,
  });

  /// The sale to summarise.
  final Sale sale;

  /// The customer's name, or `null` for a walk-in.
  final String? customerName;

  /// Called when the card is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
                      sale.invoiceNo,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${customerName ?? 'Walk-in'} · '
                      '${Formatters.dateTimeDdMmmYyyyHm(sale.saleDate)}',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        StatusBadge(
                          label: Formatters.currency(sale.grandTotal),
                          tone: BadgeTone.info,
                          icon: Icons.receipt_long_outlined,
                        ),
                        SaleStatusBadge(status: sale.status),
                        if (sale.isUnpaid)
                          StatusBadge(
                            label:
                                '${Formatters.currency(sale.balanceDue)} due',
                            tone: BadgeTone.warning,
                            icon: Icons.schedule_outlined,
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
