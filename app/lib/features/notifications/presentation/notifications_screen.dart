/// The in-app list: this user's notifications, and the two alerts beside them.
///
/// Three sections, three reads, three independent states - deliberately. The
/// notification list is one query, low stock and expiring stock are one RPC each,
/// and a failure in one of them must not blank the other two: the screen's job is
/// to say *which* part of itself could not be loaded, because "still loading",
/// "nothing here" and "could not load" are three different sentences with three
/// different affordances (T-5's lesson).
///
/// Nothing on this screen derives an alert. Low stock and expiry come from
/// `low_stock_products()` and `expiring_batches()` (D-047), which is why a
/// twenty-row *page* no longer stands in for the whole catalogue (I-1).
///
/// The list is where a message is visible whether or not it could be *delivered*
/// (D-029/D-046): Phase 5 dispatches nothing, so this is the surface that carries
/// the message either way.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/data/models/alert_payloads.dart';
import 'package:app/data/models/app_notification.dart';
import 'package:app/features/notifications/application/alert_providers.dart';
import 'package:app/features/notifications/application/notifications_controller.dart';
import 'package:app/features/notifications/data/notifications_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The user's notifications, and what is running out and about to expire.
class NotificationsScreen extends ConsumerWidget {
  /// Creates the notifications screen.
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppScaffold(
      title: 'Notifications',
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
          // Re-reads all three: they are three answers about *now*, and a refresh
          // that left one of them stale would be the reader's problem to notice.
          onPressed: () => ref
            ..invalidate(notificationsControllerProvider)
            ..invalidate(lowStockAlertsProvider)
            ..invalidate(expiringAlertsProvider),
        ),
      ],
      body: RefreshIndicator(
        // The invalidations below do not wait for the re-reads, and deliberately
        // so: awaiting a provider's `.future` never completes when that read fails
        // (Riverpod 3, D-015), which would leave this indicator spinning forever.
        // Each section shows its own spinner while it loads instead.
        onRefresh: () async => ref
          ..invalidate(notificationsControllerProvider)
          ..invalidate(lowStockAlertsProvider)
          ..invalidate(expiringAlertsProvider),
        child: ListView(
          // Always scrollable, so the pull-to-refresh gesture exists even when the
          // three sections are short.
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: const <Widget>[
            _InboxSection(),
            SizedBox(height: 16),
            _LowStockSection(),
            SizedBox(height: 16),
            _ExpiringSection(),
          ],
        ),
      ),
    );
  }
}

/// This user's notifications, newest first.
class _InboxSection extends ConsumerWidget {
  const _InboxSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications = ref.watch(notificationsControllerProvider);

    return _AlertSection<AppNotification>(
      title: 'Notifications',
      value: notifications,
      loading: 'Loading notifications…',
      empty: 'No notifications yet',
      onRetry: () => ref.invalidate(notificationsControllerProvider),
      rows: (items) => <Widget>[
        for (final notification in items)
          _NotificationTile(
            notification: notification,
            onMarkRead: () => _markRead(context, ref, notification.id),
          ),
      ],
    );
  }

  /// Marks a row read, reporting a failure without losing the list.
  ///
  /// The controller puts the row back before this runs, so the sentence below is
  /// all that is left to do - the screen must not also blank itself.
  Future<void> _markRead(BuildContext context, WidgetRef ref, String id) async {
    try {
      await ref.read(notificationsControllerProvider.notifier).markRead(id);
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

/// One notification, tappable to mark it read.
class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.notification,
    required this.onMarkRead,
  });

  /// The row.
  final AppNotification notification;

  /// Called when an unread row is tapped.
  final VoidCallback onMarkRead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUnread = !notification.isRead;
    final title = notification.title;
    final dispatched = notification.dispatchChannel;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isUnread ? Icons.notifications_active : Icons.notifications_none,
        color: isUnread ? theme.colorScheme.primary : null,
      ),
      title: Text(
        title == null || title.isEmpty ? _typeLabel(notification.type) : title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: isUnread ? FontWeight.w600 : null,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(notification.message, maxLines: 3),
          const SizedBox(height: 2),
          Text(
            // What went out alongside it, when anything did, and when it arrived.
            <String>[
              Formatters.dateTimeDdMmmYyyyHm(notification.createdAt),
              if (dispatched != null) 'via ${_channelLabel(dispatched)}',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      // Only an unread row has anything to do. A read row is left alone rather
      // than offering a control that would do nothing.
      trailing: isUnread
          ? Text('Unread', style: theme.textTheme.labelSmall)
          : null,
      onTap: isUnread ? onMarkRead : null,
    );
  }
}

/// What is at or below its reorder level.
class _LowStockSection extends ConsumerWidget {
  const _LowStockSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lowStock = ref.watch(lowStockAlertsProvider);

    return _AlertSection<LowStockProduct>(
      title: 'Low stock',
      value: lowStock,
      loading: 'Checking stock…',
      empty: 'Nothing is below its reorder level',
      onRetry: () => ref.invalidate(lowStockAlertsProvider),
      rows: (items) => <Widget>[
        for (final product in items) _LowStockTile(product: product),
      ],
    );
  }
}

/// One product that needs reordering.
class _LowStockTile extends StatelessWidget {
  const _LowStockTile({required this.product});

  /// The alert.
  final LowStockProduct product;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.inventory_2_outlined),
      title: Text(product.name),
      subtitle: Text(
        <String>[
          '${product.totalQty} in stock',
          'reorder at ${product.minStockLevel}',
          if (product.packSize != null) product.packSize!,
        ].join(' · '),
      ),
      trailing: Text(
        'Order ${_units(product.shortfall)}',
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}

/// What has stock left and is about to expire.
class _ExpiringSection extends ConsumerWidget {
  const _ExpiringSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expiring = ref.watch(expiringAlertsProvider);
    const days = NotificationsRepository.expiryHorizonDays;

    return _AlertSection<ExpiringBatch>(
      title: 'Expiring soon',
      value: expiring,
      loading: 'Checking expiry…',
      empty: 'Nothing expires in the next $days days',
      onRetry: () => ref.invalidate(expiringAlertsProvider),
      rows: (items) => <Widget>[
        for (final batch in items) _ExpiringTile(batch: batch),
      ],
    );
  }
}

/// One batch that is expiring, or already has.
class _ExpiringTile extends StatelessWidget {
  const _ExpiringTile({required this.batch});

  /// The alert.
  final ExpiringBatch batch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        batch.isExpired ? Icons.event_busy : Icons.event_outlined,
        color: batch.isExpired ? theme.colorScheme.error : null,
      ),
      title: Text(batch.productName),
      subtitle: Text(
        <String>[
          'Batch ${batch.batchNo}',
          '${_units(batch.qty)} left',
          Formatters.dateDdMmmYyyy(batch.expiryDate),
          if (batch.packSize != null) batch.packSize!,
        ].join(' · '),
      ),
      trailing: Text(
        _daysLeft(batch.daysLeft),
        style: theme.textTheme.labelMedium?.copyWith(
          color: batch.isExpired ? theme.colorScheme.error : null,
        ),
      ),
    );
  }
}

/// One titled section with its own loading, empty and failed states.
///
/// One widget for all three sections so that the three sentences cannot drift
/// apart between them - which is exactly the bug T-5 records, where "still
/// loading" and "nothing here" looked the same.
class _AlertSection<T> extends StatelessWidget {
  const _AlertSection({
    required this.title,
    required this.value,
    required this.loading,
    required this.empty,
    required this.onRetry,
    required this.rows,
  });

  /// The card's heading.
  final String title;

  /// The read behind it.
  final AsyncValue<List<T>> value;

  /// What to say while it is loading.
  final String loading;

  /// What to say when it loaded and there is nothing.
  final String empty;

  /// Re-runs the read.
  final VoidCallback onRetry;

  /// The rows, when there are some.
  final List<Widget> Function(List<T> items) rows;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: title,
      child: value.when(
        loading: () => _Status(caption: loading, isBusy: true),
        error: (error, _) =>
            ErrorView(message: describeError(error), onRetry: onRetry),
        data: (items) => items.isEmpty
            ? _Status(caption: empty)
            : Column(children: rows(items)),
      ),
    );
  }
}

/// A one-line loading or empty state, sized for inside a card.
class _Status extends StatelessWidget {
  const _Status({required this.caption, this.isBusy = false});

  /// What to say.
  final String caption;

  /// Whether to show a spinner beside it.
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: <Widget>[
        if (isBusy)
          const SizedBox(
            height: 16,
            width: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(
            Icons.check_circle_outline,
            size: 18,
            color: theme.colorScheme.outline,
          ),
        const SizedBox(width: 12),
        Expanded(child: Text(caption, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

/// `3 units`, or `1 unit`.
String _units(int count) => '$count ${count == 1 ? 'unit' : 'units'}';

/// How long a batch has, in words: negative is how long it has been gone.
String _daysLeft(int days) {
  if (days == 0) {
    return 'Expires today';
  }
  final count = days.abs();
  final unit = count == 1 ? 'day' : 'days';
  return days < 0 ? 'Expired $count $unit ago' : 'In $count $unit';
}

/// A readable name for a notification's own `type`.
String _typeLabel(String type) {
  if (type == 'message') {
    return 'Notification';
  }
  final words = type.replaceAll('_', ' ').trim();
  if (words.isEmpty) {
    return 'Notification';
  }
  return words[0].toUpperCase() + words.substring(1);
}

/// A readable name for a dispatch channel, from the row's own `data`.
String _channelLabel(String channel) => switch (channel) {
  'whatsapp' => 'WhatsApp',
  'email' => 'Email',
  'push' => 'push',
  _ => channel,
};
