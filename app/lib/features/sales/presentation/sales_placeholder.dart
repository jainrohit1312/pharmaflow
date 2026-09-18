/// Phase 1 placeholder screen for the sales feature.
library;

import 'package:app/core/widgets/app_scaffold.dart';
import 'package:flutter/material.dart';

/// Stand-in for the billing and point of sale screen.
///
/// The body renders the literal `TODO(phase-1)` marker so the Phase 0 scope is
/// visible when navigating the shell.
class SalesPlaceholder extends StatelessWidget {
  /// Creates the sales placeholder screen.
  const SalesPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppScaffold(
      title: 'Sales',
      body: Center(child: Text('TODO(phase-1)')),
    );
  }
}
