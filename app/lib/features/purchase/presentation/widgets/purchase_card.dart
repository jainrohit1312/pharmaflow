/// One purchase document row in the list.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_status_badge.dart';
import 'package:flutter/material.dart';

/// A tappable summary of a purchase document.
///
/// Shows what tells one invoice from another - who it came from, the number on
/// it, when it was dated and what it is worth - plus its status, because the
/// status is what decides whether its stock has been booked in.
class PurchaseCard extends StatelessWidget {
  /// Creates a purchase card.
  const PurchaseCard({
    required this.purchase,
    super.key,
    this.supplierName,
    this.onTap,
  });

  /// The document to summarise.
  final Purchase purchase;

  /// The supplier's name, when it could be resolved.
  final String? supplierName;

  /// Called when the card is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rawName = supplierName?.trim();
    // Blank counts as missing: a document whose supplier row could not be read
    // should say so rather than render an empty title.
    final name = rawName != null && rawName.isNotEmpty ? rawName : null;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      name ?? 'Supplier not recorded',
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${purchase.invoiceNo} · '
                      '${Formatters.dateDdMmmYyyy(purchase.invoiceDate)}',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    PurchaseStatusBadge(
                      status: purchase.status,
                      stockPostedAt: purchase.stockPostedAt,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    Formatters.currency(purchase.grandTotal),
                    style: theme.textTheme.titleSmall,
                  ),
                  if (purchase.hasTax) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      'incl. ${Formatters.currency(purchase.taxTotal)} tax',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
