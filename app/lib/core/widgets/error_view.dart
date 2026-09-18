/// Error state with an optional retry action.
library;

import 'package:app/core/widgets/app_button.dart';
import 'package:flutter/material.dart';

/// Error state shown when a screen's data cannot be loaded or is invalid.
class ErrorView extends StatelessWidget {
  /// Creates an error view, captioned with [message] and optionally retryable.
  const ErrorView({super.key, this.message, this.onRetry});

  /// What went wrong; falls back to a generic caption when `null`.
  final String? message;

  /// When provided, a retry button is rendered.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final retry = onRetry;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              message ?? 'Something went wrong.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (retry != null) ...<Widget>[
              const SizedBox(height: 24),
              AppButton.outlined(
                label: 'Retry',
                icon: Icons.refresh,
                expand: false,
                onPressed: retry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
