/// Phase 1 placeholder screen for the products feature.
library;

import 'package:app/core/widgets/app_scaffold.dart';
import 'package:flutter/material.dart';

/// Stand-in for the product catalogue screen.
///
/// The body renders the literal `TODO(phase-1)` marker so the Phase 0 scope is
/// visible when navigating the shell.
class ProductsPlaceholder extends StatelessWidget {
  /// Creates the products placeholder screen.
  const ProductsPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppScaffold(
      title: 'Products',
      body: Center(child: Text('TODO(phase-1)')),
    );
  }
}
