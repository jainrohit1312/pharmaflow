/// Centered progress indicator with an optional status message.
library;

import 'package:flutter/material.dart';

/// Loading state shown while a screen's data is being fetched.
class LoadingView extends StatelessWidget {
  /// Creates a loading view, optionally captioned with [message].
  const LoadingView({super.key, this.message});

  /// Optional caption rendered underneath the spinner.
  final String? message;

  @override
  Widget build(BuildContext context) {
    final caption = message;
    const spinner = SizedBox(
      height: 36,
      width: 36,
      child: CircularProgressIndicator(strokeWidth: 3),
    );

    if (caption == null) {
      return const Center(child: spinner);
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          spinner,
          const SizedBox(height: 16),
          Text(caption, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
