/// Phase 1 placeholder screen for the reports feature.
library;

import 'package:app/core/widgets/app_scaffold.dart';
import 'package:flutter/material.dart';

/// Stand-in for the reports and analytics screen.
///
/// The body renders the literal `TODO(phase-1)` marker so the Phase 0 scope is
/// visible when navigating the shell.
class ReportsPlaceholder extends StatelessWidget {
  /// Creates the reports placeholder screen.
  const ReportsPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppScaffold(
      title: 'Reports',
      body: Center(child: Text('TODO(phase-1)')),
    );
  }
}
