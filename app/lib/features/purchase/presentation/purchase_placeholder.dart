/// Phase 1 placeholder screen for the purchase feature.
library;

import 'package:app/core/widgets/app_scaffold.dart';
import 'package:flutter/material.dart';

/// Stand-in for the purchase and goods-received screen.
///
/// The body renders the literal `TODO(phase-1)` marker so the Phase 0 scope is
/// visible when navigating the shell.
class PurchasePlaceholder extends StatelessWidget {
  /// Creates the purchase placeholder screen.
  const PurchasePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppScaffold(
      title: 'Purchase',
      body: Center(child: Text('TODO(phase-1)')),
    );
  }
}
