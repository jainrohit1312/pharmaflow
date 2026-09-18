/// One expiring batch row.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/expiry_badge.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/features/inventory/application/expiry_batch.dart';
import 'package:flutter/material.dart';

/// A batch that needs an expiry decision, with the one action that resolves it.
///
/// The action is a stock adjustment, because that is the only correction the
/// system supports once goods are in a batch: writing the units off pulls them
/// out of stock with a reason attached, and a return to the supplier is a
/// purchase return raised against the invoice instead.
class ExpiryBatchCard extends StatelessWidget {
  /// Creates an expiry batch card.
  const ExpiryBatchCard({
    required this.entry,
    super.key,
    this.onTap,
    this.onAdjust,
  });

  /// The batch, with the product name the view does not carry.
  final ExpiryBatch entry;

  /// Called when the card is tapped, e.g. to open the product's batches.
  final VoidCallback? onTap;

  /// Called when the user wants to correct this batch's quantity.
  final VoidCallback? onAdjust;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final batch = entry.batch;
    final adjust = onAdjust;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      entry.productName,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ExpiryBadge(status: batch.expiryStatus),
                  if (adjust != null)
                    IconButton(
                      icon: const Icon(Icons.tune),
                      tooltip: 'Adjust this batch',
                      onPressed: adjust,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Batch ${batch.batchNo} · expires '
                '${Formatters.dateDdMmmYyyy(batch.expiryDate)}'
                '${_remaining(batch)}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              Text(
                '${_units(entry.qty)} · MRP '
                '${Formatters.currency(batch.mrp)} · '
                '${Formatters.currency(entry.valueAtMrp)} at MRP',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How long the batch has left, or nothing once it is past its date.
String _remaining(BatchStatus batch) =>
    batch.isExpired ? '' : ' (${_daysLabel(batch.daysToExpiry)})';

/// `in 12 days`, `tomorrow` or `today`.
String _daysLabel(int days) => switch (days) {
  <= 0 => 'today',
  1 => 'tomorrow',
  _ => 'in $days days',
};

/// `12 units`, or `1 unit`.
String _units(int qty) => '$qty ${qty == 1 ? 'unit' : 'units'}';
