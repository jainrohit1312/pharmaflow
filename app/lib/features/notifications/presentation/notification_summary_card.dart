/// The dashboard's notification widget: how many are unread, and the way in.
///
/// **Always visible, deliberately** (D-048). At zero it reads *No new
/// notifications* rather than disappearing: a surface that vanishes when it has
/// nothing to say is one the user forgets exists, and the first time they need it
/// is the time they would not find it. The same rule T-5 records for the
/// sale-return picker - "nothing here" and "still loading" must not look alike -
/// which is why there are three readings rather than two.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/features/notifications/application/notifications_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Shows the caller's unread count and opens `/notifications`.
class NotificationSummaryCard extends ConsumerWidget {
  /// Creates the dashboard notification card.
  const NotificationSummaryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final unread = ref.watch(unreadNotificationCountProvider);
    final count = unread.value;
    final hasUnread = count != null && count > 0;

    // Four readings, not two. Nobody has counted yet; the count itself failed;
    // there is nothing to read; there is something to read. Collapsing the first
    // two into "No new notifications" would make the card lie about the one thing
    // it exists to say.
    final String summary;
    if (unread.hasError) {
      summary = 'Could not check';
    } else if (count == null) {
      summary = 'Checking…';
    } else if (count == 0) {
      summary = 'No new notifications';
    } else {
      summary = 'Tap to read them';
    }

    return Card(
      child: ListTile(
        leading: Icon(
          hasUnread ? Icons.notifications_active : Icons.notifications_none,
          color: hasUnread ? theme.colorScheme.primary : null,
        ),
        title: Text(
          hasUnread ? 'Notifications ($count)' : 'Notifications',
          style: theme.textTheme.titleMedium,
        ),
        subtitle: Text(summary),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.go(Routes.notifications),
      ),
    );
  }
}
