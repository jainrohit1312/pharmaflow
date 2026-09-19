/// Post-login dashboard home screen.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/data/models/profile.dart';
import 'package:app/features/auth/application/auth_controller.dart';
import 'package:app/features/notifications/presentation/notification_summary_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Maps an async error payload to a user-facing message.
String _messageFor(Object error) =>
    error is AppException ? error.message : error.toString();

/// Landing screen for a signed-in user.
///
/// Renders whatever [AuthController] currently holds: a spinner while the
/// profile is loading, an [ErrorView] with a retry when it fails, a
/// "no pharmacy linked" card when the load succeeded but returned nothing, and
/// the profile summary otherwise.
class DashboardHome extends ConsumerWidget {
  /// Creates the dashboard home screen.
  const DashboardHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authControllerProvider);

    return AppScaffold(
      title: 'Dashboard',
      body: profile.when(
        data: (value) => value == null
            ? const _NoPharmacyCard()
            : _DashboardContent(profile: value),
        loading: () => const LoadingView(message: 'Loading your pharmacy…'),
        error: (error, stackTrace) => ErrorView(
          message: _messageFor(error),
          onRetry: () => ref.invalidate(authControllerProvider),
        ),
      ),
    );
  }
}

/// Profile summary plus the Phase 1 statistic placeholders.
class _DashboardContent extends ConsumerWidget {
  const _DashboardContent({required this.profile});

  /// The profile of the signed-in user.
  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Welcome, ${profile.displayName}',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    Chip(label: Text(profile.role.label)),
                    if (profile.pharmacyId != null)
                      Chip(
                        avatar: const Icon(Icons.storefront_outlined, size: 18),
                        label: Text('Pharmacy ${profile.pharmacyId}'),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                AppButton.outlined(
                  label: 'Sign Out',
                  expand: false,
                  onPressed: () =>
                      ref.read(authControllerProvider.notifier).signOut(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Always present, and at zero it says so (D-048): a notification surface
        // that hides when it has nothing to say is one the user forgets exists.
        const NotificationSummaryCard(),
        const SizedBox(height: 16),
        Text('Overview', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        // TODO(phase-1): replace these tiles with live counts once the sales
        // and inventory features land.
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 720 ? 4 : 2;
            return GridView.count(
              crossAxisCount: columns,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.4,
              children: const <Widget>[
                _StatTile(
                  label: 'Sales today',
                  value: '—',
                  icon: Icons.point_of_sale_outlined,
                ),
                _StatTile(
                  label: 'Low stock',
                  value: '—',
                  icon: Icons.inventory_2_outlined,
                ),
                _StatTile(
                  label: 'Expiring soon',
                  value: '—',
                  icon: Icons.event_busy_outlined,
                ),
                _StatTile(
                  label: 'Payables due',
                  value: '—',
                  icon: Icons.request_quote_outlined,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Shown when the signed-in account is not linked to a pharmacy yet.
class _NoPharmacyCard extends StatelessWidget {
  const _NoPharmacyCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        // TODO(phase-1): offer an invite or join flow once tenancy onboarding
        // exists.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: <Widget>[
                Icon(
                  Icons.storefront_outlined,
                  size: 48,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'No pharmacy linked yet',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Your account is not linked to a pharmacy. Ask an owner to '
                  'add you from Settings.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A single Phase 1 statistic placeholder tile.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  /// Caption under the value.
  final String label;

  /// Placeholder value rendered for this statistic.
  final String value;

  /// Icon representing the statistic.
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(height: 8),
            Text(value, style: theme.textTheme.headlineSmall),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
