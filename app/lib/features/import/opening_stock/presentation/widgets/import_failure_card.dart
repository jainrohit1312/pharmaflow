/// The explicit failure step: which step failed, why, and what to do next.
///
/// The import used to end a failed step in whatever the previous screen had been
/// showing, which for a picker that answered `null` was the offer the owner had
/// already left - indistinguishable from nothing having happened at all. Every
/// failure now lands here, with the step named.
library;

import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/features/import/opening_stock/application/opening_stock_controller.dart';
import 'package:flutter/material.dart';

/// A failure, on a surface that is not mistaken for good news.
class ImportFailureCard extends StatelessWidget {
  /// Creates a failure card for [failure].
  const ImportFailureCard({
    required this.failure,
    required this.onRetry,
    required this.onChooseAnother,
    super.key,
  });

  /// What failed, and where.
  final OpeningStockFailure failure;

  /// Tries the failed step again.
  final VoidCallback onRetry;

  /// Goes back to the file picker.
  final VoidCallback onChooseAnother;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = failure.rowNumber;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          // The theme's error surface rather than a red of its own, so the card
          // stays legible in both brightnesses.
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        _title(failure.phase),
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    StatusBadge(
                      // The line at fault gets the chip rather than the word
                      // "Failed": the row number is the thing an owner acts on,
                      // and it is already inside the sentence below as well.
                      label: row == null ? 'Failed' : 'Row $row',
                      tone: BadgeTone.danger,
                      icon: row == null
                          ? Icons.report_problem_outlined
                          : Icons.format_list_numbered,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  failure.message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
                const SizedBox(height: 20),
                AppButton.primary(
                  label: 'Try again',
                  icon: Icons.refresh,
                  onPressed: onRetry,
                ),
                const SizedBox(height: 8),
                AppButton.outlined(
                  label: 'Choose another file',
                  icon: Icons.upload_file,
                  onPressed: onChooseAnother,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// What to call the step that failed, in the owner's terms.
String _title(OpeningStockImportPhase phase) => switch (phase) {
  OpeningStockImportPhase.reading => 'The file could not be read',
  OpeningStockImportPhase.sending => 'The file could not be sent',
  OpeningStockImportPhase.classifying => 'The server could not check the file',
  OpeningStockImportPhase.writing => 'The import could not be written',
};
