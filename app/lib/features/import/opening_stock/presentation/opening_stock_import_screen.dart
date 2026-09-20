/// Opening stock: the one-time import of a pharmacy's existing catalogue.
///
/// This screen is the whole of the migration's UI. It offers a file, shows what
/// the server makes of it, and writes it in one go - and the order matters,
/// because nothing is written until the owner has seen the numbers. A file whose
/// rows cannot all be imported is refused as a whole, with the offending lines
/// listed, so an import is never half-done.
///
/// Six steps, and the owner is never between them: the file is *confirmed* -
/// named, sized, and counted over its first rows - before anything is sent, the
/// upload says which of its three steps it is on, and a failure names the step it
/// happened in rather than returning to a screen that looks untouched.
///
/// Owner-only, and by construction rather than by hiding: the RPCs behind it
/// refuse anyone else (see `preview_opening_stock`), and the way in is a Settings
/// entry that only an owner is shown.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/confirm_dialog.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/features/import/opening_stock/application/opening_stock_controller.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_models.dart';
import 'package:app/features/import/opening_stock/presentation/widgets/import_error_row.dart';
import 'package:app/features/import/opening_stock/presentation/widgets/import_failure_card.dart';
import 'package:app/features/import/opening_stock/presentation/widgets/import_progress_card.dart';
import 'package:app/features/import/opening_stock/presentation/widgets/import_summary_card.dart';
import 'package:app/features/import/opening_stock/presentation/widgets/preview_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// How many refused rows the preview lists before deferring to the table.
///
/// The table below carries every row, so this list is a summary rather than an
/// inventory: ten is enough to see whether the file has one bad row or a broken
/// column, and short enough to keep the table on screen.
const int importRefusalListLimit = 10;

/// The opening stock import screen.
class OpeningStockImportScreen extends ConsumerWidget {
  /// Creates the import screen.
  const OpeningStockImportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(openingStockControllerProvider);
    final controller = ref.read(openingStockControllerProvider.notifier);

    return AppScaffold(
      title: 'Opening stock import',
      // Disabled, not removed, while a step is in flight: leaving mid-upload
      // would abandon work the screen cannot pick up again, and a button that
      // comes back where it was reads better than one that vanishes.
      leading: AppBackButton(location: Routes.settings, enabled: !state.isBusy),
      body: switch (state.stage) {
        OpeningStockStage.idle => _Offer(
          isPicking: state.isPicking,
          onPick: controller.pickFile,
        ),
        OpeningStockStage.confirmed => _FileConfirmed(
          state: state,
          controller: controller,
        ),
        OpeningStockStage.processing => ImportProgressCard(
          phase: state.phase,
          fileName: state.fileName,
        ),
        OpeningStockStage.preview => _Preview(
          state: state,
          controller: controller,
        ),
        OpeningStockStage.committing => LoadingView(
          message: 'Importing ${state.preview?.summary.rowCount ?? 0} rows…',
        ),
        OpeningStockStage.success => _Success(
          state: state,
          controller: controller,
        ),
        OpeningStockStage.error => ImportFailureCard(
          failure: state.shownFailure,
          onRetry: controller.retry,
          onChooseAnother: controller.reset,
        ),
      },
    );
  }
}

/// The first thing shown: what this does and what file it wants.
class _Offer extends StatelessWidget {
  const _Offer({required this.onPick, required this.isPicking});

  final Future<void> Function() onPick;

  /// Whether the dialog is open or a chosen file is being read.
  ///
  /// The button spins for it. The dialog is on top of the screen, so the spinner
  /// is mostly about the moment after it closes - a file being read shows that
  /// something is happening instead of leaving the offer looking untouched.
  final bool isPicking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        SectionCard(
          title: 'Import your existing stock',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Choose the CSV your present system exported, with the columns '
                'item_name, batch_no, expiry_date, qty, purchase_rate and mrp. '
                'Each row becomes one product and one batch, and the whole file '
                'is written in one step - so if any row cannot be imported, '
                'nothing is.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Leave a batch number or an expiry blank when you do not know '
                'it: a blank batch gets an internal reference and a blank '
                'expiry stays unknown rather than being guessed at.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              AppButton.primary(
                label: 'Choose the CSV file',
                icon: Icons.upload_file,
                isLoading: isPicking,
                onPressed: onPick,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The chosen file, before anything is sent anywhere.
class _FileConfirmed extends StatelessWidget {
  const _FileConfirmed({required this.state, required this.controller});

  final OpeningStockState state;
  final OpeningStockController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = state.fileSizeBytes;
    final rows = state.estimatedRowCount;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        SectionCard(
          title: 'The file you chose',
          trailing: const StatusBadge(
            label: 'Not sent yet',
            tone: BadgeTone.info,
            icon: Icons.check_circle_outline,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: 24,
                runSpacing: 12,
                children: <Widget>[
                  _Figure(label: 'File', value: state.fileName ?? 'unknown'),
                  _Figure(
                    label: 'Size',
                    value: bytes == null
                        ? 'unknown'
                        : Formatters.fileSize(bytes),
                  ),
                  _Figure(
                    label: 'Rows detected',
                    value: _rowCountLabel(rows, state.estimateTruncated),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Nothing has been sent to the server yet. Uploading reads the '
                'whole file and has every row classified; you will see what the '
                'import would do before anything is written.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              AppButton.primary(
                label: 'Upload & Preview',
                icon: Icons.cloud_upload_outlined,
                onPressed: controller.uploadAndPreview,
              ),
              const SizedBox(height: 8),
              AppButton.text(label: 'Cancel', onPressed: controller.reset),
            ],
          ),
        ),
      ],
    );
  }
}

/// The preview: what the file will do, what is wrong with it, and every row.
class _Preview extends StatelessWidget {
  const _Preview({required this.state, required this.controller});

  final OpeningStockState state;
  final OpeningStockController controller;

  @override
  Widget build(BuildContext context) {
    final preview = state.preview;
    if (preview == null) {
      return const LoadingView(message: 'Preparing the preview…');
    }

    final refusals = preview.refusedRows;
    final shown = refusals.take(importRefusalListLimit).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ImportSummaryCard(
            summary: preview.summary,
            fileName: state.fileName,
            existingJob: preview.existingJob,
          ),
          if (shown.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            SectionCard(
              title: 'Rows that cannot be imported',
              trailing: StatusBadge(
                label: '${refusals.length}',
                tone: BadgeTone.danger,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final row in shown) ImportErrorRow(row: row),
                  if (refusals.length > shown.length)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '…and ${refusals.length - shown.length} more, in the '
                        'table below.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Expanded(child: PreviewTable(rows: preview.rows)),
          const SizedBox(height: 12),
          AppButton.primary(
            label: state.canCommit
                ? 'Import ${preview.summary.rowCount} '
                      '${preview.summary.rowCount == 1 ? 'row' : 'rows'}'
                : 'Nothing to import',
            icon: Icons.save_alt,
            onPressed: state.canCommit
                ? () => _confirmAndCommit(context, controller, preview.summary)
                : null,
          ),
          const SizedBox(height: 4),
          AppButton.text(
            label: 'Back to file selection',
            onPressed: controller.reset,
          ),
        ],
      ),
    );
  }
}

/// Asks once, then commits.
///
/// The confirmation is not ceremony: pressing this writes a product and a batch
/// for every row into the pharmacy's stock, and Phase 6.5a's import has no undo.
/// The summary comes from the screen rather than from the controller because it
/// is the value the owner is looking at - the same one the button was labelled
/// with.
Future<void> _confirmAndCommit(
  BuildContext context,
  OpeningStockController controller,
  OpeningStockSummary summary,
) async {
  final confirmed = await showConfirmDialog(
    context,
    title: 'Import now?',
    message:
        'This writes ${summary.rowCount} products and batches into your stock, '
        'worth ${Formatters.currency(summary.totalCost)} at cost. It cannot be '
        'undone from here.',
    confirmLabel: 'Import',
  );
  if (!confirmed) {
    return;
  }
  await controller.commit();
}

/// What was written.
class _Success extends StatelessWidget {
  const _Success({required this.state, required this.controller});

  final OpeningStockState state;
  final OpeningStockController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = state.result;
    if (result == null) {
      return const LoadingView(message: 'Finishing…');
    }

    final savedTo = state.savedTo;
    final saveError = state.saveError;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        SectionCard(
          title: result.idempotent
              ? 'This file was already imported'
              : 'Import finished',
          trailing: StatusBadge(
            label: result.idempotent ? 'No change' : 'Imported',
            tone: result.idempotent ? BadgeTone.info : BadgeTone.success,
            icon: result.idempotent ? Icons.info_outline : Icons.check_circle,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                result.idempotent
                    ? 'These rows were already in your stock, so nothing was '
                          'written a second time.'
                    : 'Every row is now a product and a batch in your '
                          'inventory.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 24,
                runSpacing: 12,
                children: <Widget>[
                  _Figure(
                    label: 'Products created',
                    value: '${result.productsCreated}',
                  ),
                  _Figure(
                    label: 'Existing products used',
                    value: '${result.productsMatched}',
                  ),
                  _Figure(label: 'Batches', value: '${result.batchCount}'),
                  _Figure(label: 'Units', value: '${result.qtyTotal}'),
                  _Figure(
                    label: 'Value at cost',
                    value: Formatters.currency(result.costTotal),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              AppButton.primary(
                label: 'Download the audit CSV',
                icon: Icons.download,
                isLoading: state.isSaving,
                onPressed: controller.saveAudit,
              ),
              const SizedBox(height: 8),
              AppButton.outlined(
                label: 'Go to inventory',
                icon: Icons.inventory_2_outlined,
                onPressed: () => context.go(Routes.inventory),
              ),
              const SizedBox(height: 8),
              AppButton.text(
                label: 'Import another file',
                onPressed: controller.reset,
              ),
              if (savedTo != null) ...<Widget>[
                const SizedBox(height: 12),
                Text('Saved to $savedTo', style: theme.textTheme.bodySmall),
              ],
              if (saveError != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  describeError(saveError),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One labelled figure in a card.
class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});

  final String label;
  final String value;

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
        Text(value, style: theme.textTheme.titleMedium),
      ],
    );
  }
}

/// The count as the first pass can honestly state it.
String _rowCountLabel(int? rows, bool truncated) {
  if (rows == null) {
    return 'unknown';
  }
  return truncated ? 'at least $rows' : '$rows';
}
