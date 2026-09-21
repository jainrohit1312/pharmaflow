/// Phase 1 placeholder screen for the settings feature, and the one thing that
/// lives here today.
///
/// The body still renders the literal `TODO(phase-1)` marker so the Phase 0
/// scope stays visible, with the opening stock import beside it: that import is
/// a one-time migration an owner runs once, which is what makes Settings its
/// home rather than a rail destination of its own.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/data/models/profile.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Stand-in for the application and pharmacy settings screen.
class SettingsPlaceholder extends ConsumerWidget {
  /// Creates the settings placeholder screen.
  const SettingsPlaceholder({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // The import is the owner's action - the RPC behind it refuses anyone else -
    // so an entry nobody else can use is not offered to them. It is a courtesy,
    // not the guard: `preview_opening_stock` and `commit_opening_stock_import`
    // both check the role themselves.
    final isOwner =
        ref.watch(profileStateProvider).value?.role.isOwner ?? false;

    return AppScaffold(
      title: 'Settings',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            'TODO(phase-1)',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          if (isOwner) ...<Widget>[
            const SizedBox(height: 24),
            Card(
              child: ListTile(
                leading: const Icon(Icons.how_to_reg_outlined),
                title: const Text('Approvals'),
                subtitle: const Text(
                  'Everything your staff has asked to do, waiting for your answer.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go(Routes.approvals),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.upload_file),
                title: const Text('Opening stock import'),
                subtitle: const Text(
                  'Bring your existing stock in from a CSV export. Once.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go(Routes.openingStockImport),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
