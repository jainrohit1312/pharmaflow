/// One customer-return row in the returns list.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_return.dart';
import 'package:flutter/material.dart';

/// A tappable summary of a sale return.
///
/// The customer's name arrives already looked up, because `sale_returns` stores the
/// customer by id. Tapping opens the *sale* it came from rather than a screen of its
/// own: the bill is the context a return is read against, and a return's own fields
/// are small enough to live on this card.
class SaleReturnCard extends StatelessWidget {
  /// Creates a sale return card.
  const SaleReturnCard({
    required this.saleReturn,
    required this.customerName,
    super.key,
    this.onTap,
  });

  /// The return to summarise.
  final SaleReturn saleReturn;

  /// The customer's name, or `null` for a walk-in.
  final String? customerName;

  /// Called when the card is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = saleReturn.reason?.trim();

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
                      customerName ?? 'Walk-in',
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Returned '
                      '${Formatters.dateDdMmmYyyy(saleReturn.returnDate)} · '
                      'refunded by ${saleReturn.refundMode.label.toLowerCase()}',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (reason != null && reason.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        reason,
                        style: theme.textTheme.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        StatusBadge(
                          label:
                              'Refund ${Formatters.currency(saleReturn.grandTotal)}',
                          tone: BadgeTone.info,
                          icon: Icons.assignment_return_outlined,
                        ),
                        StatusBadge(
                          label: saleReturn.restock
                              ? 'Back on the shelf'
                              : 'Not resellable',
                          tone: saleReturn.restock
                              ? BadgeTone.success
                              : BadgeTone.warning,
                          icon: saleReturn.restock
                              ? Icons.inventory_2_outlined
                              : Icons.delete_outline,
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
