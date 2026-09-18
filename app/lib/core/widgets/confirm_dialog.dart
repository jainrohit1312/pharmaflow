/// Modal confirmation for destructive or irreversible actions.
library;

import 'package:flutter/material.dart';

/// Shows a confirmation dialog and resolves to whether the user confirmed.
///
/// Dismissing the dialog - barrier tap, back button or Cancel - resolves to
/// `false`, so a caller can `await` a single boolean instead of handling a
/// nullable result at every call site.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool isDestructive = false,
}) async {
  final errorColor = Theme.of(context).colorScheme.error;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancelLabel),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: isDestructive
              ? TextButton.styleFrom(foregroundColor: errorColor)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );

  return confirmed ?? false;
}
