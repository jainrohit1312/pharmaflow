/// Phase 1 placeholder screen for the inventory feature.
library;

import 'package:app/core/widgets/app_scaffold.dart';
import 'package:flutter/material.dart';

/// Stand-in for the batch-level stock inventory screen.
///
/// The body renders the literal `TODO(phase-1)` marker so the Phase 0 scope is
/// visible when navigating the shell.
class InventoryPlaceholder extends StatelessWidget {
  /// Creates the inventory placeholder screen.
  const InventoryPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppScaffold(
      title: 'Inventory',
      body: Center(child: Text('TODO(phase-1)')),
    );
  }
}
