/// The file's rows, as the server classified them.
///
/// Every row is here, not only the problems: an owner checking a 314-row export
/// wants to see what the import made of the rows that are fine as much as of the
/// ones that are not. The list is built lazily, because a file of a few thousand
/// rows should not build a few thousand row widgets to show the first screenful.
library;

import 'package:app/core/theme/app_colors.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_models.dart';
import 'package:flutter/material.dart';

/// A scrollable, column-aligned table of previewed rows.
class PreviewTable extends StatelessWidget {
  /// Creates a preview table over [rows].
  const PreviewTable({required this.rows, super.key});

  /// Every row the server classified, in file order.
  final List<OpeningStockPreviewRow> rows;

  /// Flex weights shared by the header and every row, so the columns line up.
  ///
  /// The action column is wide enough for its longest badge ('Ambiguous'): a
  /// badge does not wrap, so a column narrower than its label overflows rather
  /// than growing.
  static const List<int> _flex = <int>[2, 9, 5, 5, 3, 4, 4, 6];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _Row(
          cells: <Widget>[
            _Heading('Row'),
            _Heading('Item'),
            _Heading('Batch'),
            _Heading('Expiry'),
            _Heading('Qty'),
            _Heading('Rate'),
            _Heading('MRP'),
            _Heading('Action'),
          ],
          flex: _flex,
        ),
        Divider(height: 1, color: theme.dividerColor),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (context, index) =>
                Divider(height: 1, color: theme.dividerColor),
            itemBuilder: (context, index) => _DataRow(row: rows[index]),
          ),
        ),
      ],
    );
  }
}

/// One row of the table, in the same column layout as the header.
class _DataRow extends StatelessWidget {
  const _DataRow({required this.row});

  final OpeningStockPreviewRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final expired = theme.textTheme.bodySmall?.copyWith(
      color: AppColors.danger,
      fontWeight: FontWeight.w600,
    );

    return _Row(
      flex: PreviewTable._flex,
      cells: <Widget>[
        Text('${row.rowNumber}', style: theme.textTheme.bodySmall),
        Text(row.itemName, style: theme.textTheme.bodySmall),
        Text(
          row.batchNo ?? 'unknown',
          style: row.batchNo == null ? muted : theme.textTheme.bodySmall,
        ),
        Text(
          row.expiryDate ?? 'unknown',
          style: row.isExpired
              ? expired
              : (row.expiryDate == null ? muted : theme.textTheme.bodySmall),
        ),
        Text('${row.qty ?? '—'}', style: theme.textTheme.bodySmall),
        Text(
          row.purchaseRate == null ? '—' : Formatters.amount(row.purchaseRate!),
          style: theme.textTheme.bodySmall,
        ),
        Text(
          row.mrp == null ? '—' : Formatters.amount(row.mrp!),
          style: theme.textTheme.bodySmall,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: _OutcomeBadge(outcome: row.outcome),
        ),
      ],
    );
  }
}

/// The classification, as a badge.
class _OutcomeBadge extends StatelessWidget {
  const _OutcomeBadge({required this.outcome});

  final OpeningStockOutcome outcome;

  @override
  Widget build(BuildContext context) => switch (outcome) {
    OpeningStockOutcome.created => const StatusBadge(
      label: 'New',
      tone: BadgeTone.info,
    ),
    OpeningStockOutcome.matched => const StatusBadge(label: 'Match'),
    OpeningStockOutcome.ambiguous => const StatusBadge(
      label: 'Ambiguous',
      tone: BadgeTone.danger,
    ),
    OpeningStockOutcome.error => const StatusBadge(
      label: 'Refused',
      tone: BadgeTone.danger,
    ),
  };
}

/// A row of cells laid out with a shared set of flex weights.
class _Row extends StatelessWidget {
  const _Row({required this.cells, required this.flex});

  final List<Widget> cells;
  final List<int> flex;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (var index = 0; index < cells.length; index++)
            Expanded(
              flex: index < flex.length ? flex[index] : 1,
              child: cells[index],
            ),
        ],
      ),
    );
  }
}

/// A column caption.
class _Heading extends StatelessWidget {
  const _Heading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Text(label, style: Theme.of(context).textTheme.labelMedium);
}
