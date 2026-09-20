/// One row the server refused, with the line it came from.
///
/// The row number is the whole point of this widget: a file of 314 rows is fixed
/// in a spreadsheet, and "row 138" is what makes that possible. It comes from the
/// server rather than from the position on screen, so the number here is the same
/// number the refusal sentence and the audit trail use.
library;

import 'package:app/core/widgets/status_badge.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_models.dart';
import 'package:flutter/material.dart';

/// A refused row: which line, what it said, and why it was refused.
class ImportErrorRow extends StatelessWidget {
  /// Creates a refusal row for [row].
  const ImportErrorRow({required this.row, super.key});

  /// The row the server refused.
  final OpeningStockPreviewRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAmbiguous = row.outcome == OpeningStockOutcome.ambiguous;
    final names = row.productNames.join(', ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text(
              'Row ${row.rowNumber}',
              style: theme.textTheme.labelLarge,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  row.itemName.isEmpty ? '(no item name)' : row.itemName,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  row.errorNote ?? 'This row cannot be imported.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (isAmbiguous && names.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    'Catalogue matches: $names',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          StatusBadge(
            label: isAmbiguous ? 'Ambiguous' : 'Refused',
            tone: BadgeTone.danger,
          ),
        ],
      ),
    );
  }
}
