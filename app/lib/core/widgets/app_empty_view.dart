/// Empty-state placeholder for list screens that have nothing to show.
library;

import 'package:app/core/widgets/app_button.dart';
import 'package:flutter/material.dart';

/// Centred icon, explanation and optional call to action.
///
/// Distinct from `ErrorView`: nothing has gone wrong here, the result set is
/// simply empty, so the copy and the call to action differ.
class AppEmptyView extends StatelessWidget {
  /// Creates an empty state captioned with [message].
  const AppEmptyView({
    required this.message,
    super.key,
    this.icon = Icons.inbox_outlined,
    this.title,
    this.actionLabel,
    this.actionIcon = Icons.add,
    this.onAction,
  });

  /// Explanation shown under the icon.
  final String message;

  /// Icon representing the empty result.
  final IconData icon;

  /// Optional heading above [message].
  final String? title;

  /// Label for the optional call to action.
  final String? actionLabel;

  /// Icon for the optional call to action.
  final IconData actionIcon;

  /// Handler for the optional call to action.
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = title;
    final label = actionLabel;
    final action = onAction;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            if (heading != null) ...<Widget>[
              const SizedBox(height: 16),
              Text(heading, style: theme.textTheme.titleMedium),
            ],
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (label != null && action != null) ...<Widget>[
              const SizedBox(height: 24),
              AppButton.primary(
                label: label,
                icon: actionIcon,
                expand: false,
                onPressed: action,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
