/// Phase 1 placeholder screen for the ledger feature.
library;

import 'package:app/core/widgets/app_scaffold.dart';
import 'package:flutter/material.dart';

/// Stand-in for the customer and supplier ledger screen.
///
/// The body renders the literal `TODO(phase-1)` marker so the Phase 0 scope is
/// visible when navigating the shell.
class LedgerPlaceholder extends StatelessWidget {
  /// Creates the ledger placeholder screen.
  const LedgerPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppScaffold(
      title: 'Ledger',
      body: Center(child: Text('TODO(phase-1)')),
    );
  }
}
