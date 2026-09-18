/// One purchase return row in the returns list.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/purchase_return.dart';
import 'package:flutter/material.dart';

/// A tappable summary of a return: who it went back to, when, and what it credits.
///
/// The supplier name arrives already looked up, because `purchase_returns` stores
/// the supplier by id and the list would otherwise have to resolve one name per
/// row.
class PurchaseReturnCard extends StatelessWidget {
  /// Creates a purchase return card.
  const PurchaseReturnCard({
    required this.purchaseReturn,
    required this.supplierName,
    super.key,
    this.onTap,
  });

  /// The return to summarise.
  final PurchaseReturn purchaseReturn;

  /// Name of the supplier the goods went back to.
  final String supplierName;

  /// Called when the card is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = purchaseReturn.reason?.trim();

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
                      supplierName,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Returned ${Formatters.dateDdMmmYyyy(purchaseReturn.returnDate)}',
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
                              'Credit ${Formatters.currency(purchaseReturn.grandTotal)}',
                          tone: BadgeTone.info,
                          icon: Icons.assignment_return_outlined,
                        ),
                        if (!purchaseReturn.isCompleted)
                          StatusBadge(label: purchaseReturn.status),
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
