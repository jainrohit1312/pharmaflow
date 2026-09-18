/// Phase 1 placeholder screen for the returns feature.
library;

import 'package:app/core/widgets/app_scaffold.dart';
import 'package:flutter/material.dart';

/// Stand-in for the sales returns and credit notes screen.
///
/// The body renders the literal `TODO(phase-1)` marker so the Phase 0 scope is
/// visible when navigating the shell.
class ReturnsPlaceholder extends StatelessWidget {
  /// Creates the returns placeholder screen.
  const ReturnsPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppScaffold(
      title: 'Returns',
      body: Center(child: Text('TODO(phase-1)')),
    );
  }
}
