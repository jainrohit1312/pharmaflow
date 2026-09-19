/// Tests for the dashboard's notification card (D-048).
///
/// The card's whole point is that it is **always there** and that it never lies: at
/// zero it says so rather than vanishing, and a read that failed says it could not
/// check rather than reporting an empty inbox. Both of those are asserted here,
/// because both are the kind of thing that looks fine until someone trusts it.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/data/models/app_notification.dart';
import 'package:app/features/notifications/data/notifications_repository.dart';
import 'package:app/features/notifications/presentation/notification_summary_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/fake_notifications_repository.dart';
import '../../../support/notifications_test_app.dart';

/// Pumps the card on the dashboard, with `/notifications` reachable from it.
Future<GoRouter> _pumpCard(
  WidgetTester tester,
  FakeNotificationsRepository repository,
) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = notificationsTestRouter(
    initialLocation: Routes.dashboard,
    atDashboard: const Scaffold(body: NotificationSummaryCard()),
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        notificationsRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('at zero it is still there, and says there is nothing new', (
    tester,
  ) async {
    await _pumpCard(tester, FakeNotificationsRepository());

    // The card does not hide when it has nothing to say (D-048).
    expect(find.byType(NotificationSummaryCard), findsOneWidget);
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('No new notifications'), findsOneWidget);
    expect(find.textContaining('('), findsNothing);
  });

  testWidgets('with unread ones it counts them', (tester) async {
    final repository = FakeNotificationsRepository(
      notifications: <AppNotification>[
        buildAppNotification(id: 'n-1'),
        buildAppNotification(id: 'n-2'),
        buildAppNotification(id: 'n-3'),
        buildAppNotification(id: 'n-4', readAt: DateTime(2026, 9, 19, 11)),
      ],
    );
    await _pumpCard(tester, repository);

    expect(find.text('Notifications (3)'), findsOneWidget);
    expect(find.text('Tap to read them'), findsOneWidget);
    expect(find.text('No new notifications'), findsNothing);
  });

  testWidgets(
    'a read that failed says so rather than reporting an empty inbox',
    (tester) async {
      final repository = FakeNotificationsRepository()
        ..listError = const ServerException(
          message: 'Unable to read your notifications.',
        );
      await _pumpCard(tester, repository);

      expect(find.text('Could not check'), findsOneWidget);
      expect(find.text('No new notifications'), findsNothing);
    },
  );

  testWidgets('tapping it opens the notifications screen', (tester) async {
    final router = await _pumpCard(tester, FakeNotificationsRepository());

    await tester.tap(find.byType(NotificationSummaryCard));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, Routes.notifications);
    expect(find.text('No notifications yet'), findsOneWidget);
  });
}
