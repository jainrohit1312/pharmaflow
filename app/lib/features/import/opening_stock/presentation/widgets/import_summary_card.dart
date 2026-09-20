/// What the file will do, before any of it is written.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_models.dart';
import 'package:flutter/material.dart';

/// The preview's counters, as the owner reads them: what goes in, what it is
/// worth, and everything the server had to say about it being unusual.
///
/// The unusual counts are shown, not warned about, because most of them are
/// normal for opening stock: a product with no stock (53 of the owner's rows), a
/// purchase rate of zero (one row), a batch number nobody recorded (138) and an
/// expiry nobody recorded (145). Only [OpeningStockSummary.refusedRowCount]
/// stops the import, and it is labelled as such.
class ImportSummaryCard extends StatelessWidget {
  /// Creates a summary card for [summary].
  const ImportSummaryCard({
    required this.summary,
    super.key,
    this.fileName,
    this.existingJob,
  });

  /// What the server counted.
  final OpeningStockSummary summary;

  /// The file these counters came from, for the heading.
  final String? fileName;

  /// The already-committed import of this same content, when there is one.
  final ExistingImportJob? existingJob;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = fileName;
    final job = existingJob;

    return SectionCard(
      title: file ?? 'What this file will do',
      trailing: StatusBadge(
        label: summary.canImport ? 'Ready to import' : 'Cannot be imported yet',
        tone: summary.canImport ? BadgeTone.success : BadgeTone.danger,
        icon: summary.canImport
            ? Icons.check_circle_outline
            : Icons.report_problem_outlined,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (job != null) ...<Widget>[
            _AlreadyImported(job: job),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: <Widget>[
              _Metric(label: 'Rows', value: '${summary.rowCount}'),
              _Metric(label: 'Units', value: '${summary.totalQty}'),
              _Metric(
                label: 'Value at cost',
                value: Formatters.currency(summary.totalCost),
              ),
              _Metric(
                label: 'New products',
                value: '${summary.newProductCount}',
              ),
              _Metric(
                label: 'Existing products',
                value: '${summary.matchedProductCount}',
              ),
              _Metric(
                label: 'Zero-qty rows',
                value: '${summary.zeroQtyRowCount}',
              ),
              _Metric(
                label: 'Unknown batch',
                value: '${summary.unknownBatchRowCount}',
              ),
              _Metric(
                label: 'Unknown expiry',
                value: '${summary.unknownExpiryRowCount}',
              ),
              _Metric(
                label: 'Already expired',
                value: '${summary.expiredRowCount}',
                isNoteworthy: summary.expiredRowCount > 0,
              ),
            ],
          ),
          if (summary.refusedRowCount > 0) ...<Widget>[
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.report_problem_outlined,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${summary.refusedRowCount} row'
                    '${summary.refusedRowCount == 1 ? '' : 's'} cannot be '
                    'imported, so nothing has been written. The rows are '
                    'listed below with the reason for each.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The note that this exact content is already in the database.
class _AlreadyImported extends StatelessWidget {
  const _AlreadyImported({required this.job});

  final ExistingImportJob job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final committed = job.committedAt;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(Icons.info_outline, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'This exact file has already been imported'
            '${committed == null ? '' : ' on ${Formatters.dateDdMmmYyyy(committed)}'}'
            ' (${job.rowCount} rows). Importing it again would do nothing, so '
            'there is nothing to press.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

/// One labelled figure.
class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.isNoteworthy = false,
  });

  final String label;
  final String value;
  final bool isNoteworthy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            color: isNoteworthy ? theme.colorScheme.error : null,
          ),
        ),
      ],
    );
  }
}
