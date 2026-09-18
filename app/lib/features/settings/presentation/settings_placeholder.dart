/// Phase 1 placeholder screen for the settings feature.
library;

import 'package:app/core/widgets/app_scaffold.dart';
import 'package:flutter/material.dart';

/// Stand-in for the application and pharmacy settings screen.
///
/// The body renders the literal `TODO(phase-1)` marker so the Phase 0 scope is
/// visible when navigating the shell.
class SettingsPlaceholder extends StatelessWidget {
  /// Creates the settings placeholder screen.
  const SettingsPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppScaffold(
      title: 'Settings',
      body: Center(child: Text('TODO(phase-1)')),
    );
  }
}
