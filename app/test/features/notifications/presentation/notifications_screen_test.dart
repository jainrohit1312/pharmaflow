/// Tests for the notifications screen.
///
/// The screen's hardest requirement is not that it renders - it is that its three
/// reads fail independently and that "still loading", "nothing here" and "could not
/// load" are three distinguishable states (T-5's lesson). Most of what follows
/// asserts one of those three, because a screen that shows an empty list when the
/// read failed is the bug that matters: a pharmacy would read "nothing is low on
/// stock" off it and stop looking.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/alert_payloads.dart';
import 'package:app/data/models/app_notification.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_notifications_repository.dart';
import '../../../support/notifications_test_app.dart';

void main() {
  group('the inbox section', () {
    testWidgets(
      'renders each notification, and marks the unread one as unread',
      (tester) async {
        final repository = FakeNotificationsRepository(
          notifications: <AppNotification>[
            buildAppNotification(id: 'n-1', title: 'Goods arrived'),
            buildAppNotification(
              id: 'n-2',
              title: 'Your bill',
              readAt: DateTime(2026, 9, 19, 11),
            ),
          ],
        );
        await pumpNotificationsApp(tester, notifications: repository);

        expect(find.text('Goods arrived'), findsOneWidget);
        expect(find.text('Your bill'), findsOneWidget);
        expect(
          find.text('Come to the counter and collect it.'),
          findsNWidgets(2),
        );
        // Exactly one row is unread, and the screen says which one.
        expect(find.text('Unread'), findsOneWidget);
        expect(find.byIcon(Icons.notifications_active), findsOneWidget);
        expect(find.byIcon(Icons.notifications_none), findsOneWidget);
      },
    );

    testWidgets(
      'tapping an unread row marks it read, and it stops saying unread',
      (tester) async {
        final repository = FakeNotificationsRepository(
          notifications: <AppNotification>[buildAppNotification(id: 'n-1')],
        );
        await pumpNotificationsApp(tester, notifications: repository);

        expect(find.text('Unread'), findsOneWidget);

        await tester.tap(find.text('Your order is ready'));
        await tester.pumpAndSettle();

        expect(repository.markReadRequests, <String>['n-1']);
        expect(find.text('Unread'), findsNothing);
      },
    );

    testWidgets('a row nothing dispatched shows no channel', (tester) async {
      final repository = FakeNotificationsRepository(
        notifications: <AppNotification>[buildAppNotification(id: 'n-1')],
      );
      await pumpNotificationsApp(tester, notifications: repository);

      expect(find.textContaining('via '), findsNothing);
    });

    testWidgets('a dispatched row says which channel carried it', (
      tester,
    ) async {
      final repository = FakeNotificationsRepository(
        notifications: <AppNotification>[
          buildAppNotification(
            id: 'n-1',
            data: <String, dynamic>{'dispatch_channel': 'whatsapp'},
          ),
        ],
      );
      await pumpNotificationsApp(tester, notifications: repository);

      expect(find.textContaining('via WhatsApp'), findsOneWidget);
    });

    testWidgets('a notification with no title falls back to its own type', (
      tester,
    ) async {
      final repository = FakeNotificationsRepository(
        notifications: <AppNotification>[
          buildAppNotification(id: 'n-1', title: null, type: 'low_stock'),
        ],
      );
      await pumpNotificationsApp(tester, notifications: repository);

      expect(find.text('Low stock'), findsWidgets);
    });

    testWidgets('a failed mark-read reports itself without losing the list', (
      tester,
    ) async {
      final repository =
          FakeNotificationsRepository(
              notifications: <AppNotification>[buildAppNotification(id: 'n-1')],
            )
            ..markReadError = const ServerException(
              message: 'Unable to mark that notification read.',
            );
      await pumpNotificationsApp(tester, notifications: repository);

      await tester.tap(find.text('Your order is ready'));
      await tester.pumpAndSettle();

      expect(
        find.text('Unable to mark that notification read.'),
        findsOneWidget,
      );
      // The row is back to unread and the list is still on screen.
      expect(find.text('Your order is ready'), findsOneWidget);
      expect(find.text('Unread'), findsOneWidget);
    });
  });

  group('the three states are three different sentences', () {
    testWidgets('loading says loading, and not yet that there is nothing', (
      tester,
    ) async {
      await pumpNotificationsApp(
        tester,
        notifications: FakeNotificationsRepository(),
        settle: false,
      );

      // Before the fakes answer.
      expect(find.text('Loading notifications…'), findsOneWidget);
      expect(find.text('Checking stock…'), findsOneWidget);
      expect(find.text('Checking expiry…'), findsOneWidget);
      expect(find.text('No notifications yet'), findsNothing);

      await tester.pumpAndSettle();

      // After: three honest empties, and no loading sentence left.
      expect(find.text('Loading notifications…'), findsNothing);
      expect(find.text('No notifications yet'), findsOneWidget);
      expect(find.text('Nothing is below its reorder level'), findsOneWidget);
      expect(find.text('Nothing expires in the next 90 days'), findsOneWidget);
    });

    testWidgets(
      'a failed inbox says so, with a retry, and the empty sentence is absent',
      (tester) async {
        final repository = FakeNotificationsRepository()
          ..listError = const ServerException(
            message: 'Unable to read your notifications.',
          );
        await pumpNotificationsApp(tester, notifications: repository);

        expect(find.text('Unable to read your notifications.'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('No notifications yet'), findsNothing);
      },
    );

    testWidgets('the retry re-reads, and the list replaces the failure', (
      tester,
    ) async {
      final repository = FakeNotificationsRepository()
        ..listError = const ServerException(
          message: 'Unable to read your notifications.',
        );
      await pumpNotificationsApp(tester, notifications: repository);

      // Not asserted by read count: Riverpod 3 re-runs a build that threw on its
      // own backoff, so what the retry button did is proven by the list replacing
      // the failure below rather than by how many reads happened.
      repository
        ..listError = null
        ..notifications = <AppNotification>[
          buildAppNotification(id: 'n-1', title: 'Goods arrived'),
        ];
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Goods arrived'), findsOneWidget);
      expect(find.text('Unable to read your notifications.'), findsNothing);
    });
  });

  group('the sections fail independently', () {
    testWidgets(
      'a failed stock alert leaves the inbox and the expiry section alone',
      (tester) async {
        final repository =
            FakeNotificationsRepository(
                notifications: <AppNotification>[
                  buildAppNotification(id: 'n-1', title: 'Goods arrived'),
                ],
                expiringBatches: <ExpiringBatch>[buildExpiringBatch()],
              )
              ..lowStockError = const ServerException(
                message: 'Unable to check which products are low.',
              );
        await pumpNotificationsApp(tester, notifications: repository);

        // The failure is reported where it happened...
        expect(
          find.text('Unable to check which products are low.'),
          findsOneWidget,
        );
        // ...and the other two sections are untouched.
        expect(find.text('Goods arrived'), findsOneWidget);
        expect(find.text('Dolo 650'), findsOneWidget);
        expect(find.text('Nothing is below its reorder level'), findsNothing);
      },
    );
  });

  group('the alert sections', () {
    testWidgets('low stock renders from the RPC, with the shortfall in words', (
      tester,
    ) async {
      final repository = FakeNotificationsRepository(
        lowStockProducts: <LowStockProduct>[
          // Only the shortfall is named: the name, the stock and the reorder level
          // come from the builder, so the assertions below are reading the
          // fixture's own values rather than ones this test happens to repeat.
          buildLowStockProduct(shortfall: 12),
        ],
      );
      await pumpNotificationsApp(tester, notifications: repository);

      expect(find.text('Dolo 650'), findsOneWidget);
      expect(find.text('Order 12 units'), findsOneWidget);
      expect(find.textContaining('6 in stock'), findsOneWidget);
      expect(find.textContaining('reorder at 10'), findsOneWidget);
      expect(find.text('Nothing is below its reorder level'), findsNothing);
    });

    testWidgets('a shortfall of one is one unit, not one units', (
      tester,
    ) async {
      final repository = FakeNotificationsRepository(
        lowStockProducts: <LowStockProduct>[buildLowStockProduct(shortfall: 1)],
      );
      await pumpNotificationsApp(tester, notifications: repository);

      expect(find.text('Order 1 unit'), findsOneWidget);
    });

    testWidgets('a section that is only part of the list says so', (
      tester,
    ) async {
      // The envelope states the whole set's size (migration 00050). A screen that holds 200
      // of 315 low products and says nothing is a screen that quietly truncates - which is the
      // one thing a reader could act on wrongly.
      final repository =
          FakeNotificationsRepository(
              lowStockProducts: <LowStockProduct>[buildLowStockProduct()],
              expiringBatches: <ExpiringBatch>[buildExpiringBatch()],
            )
            ..lowStockTotal = 120
            ..expiringTotal = 96;
      await pumpNotificationsApp(tester, notifications: repository);

      expect(find.text('Showing the 1 worst of 120'), findsOneWidget);
      expect(find.text('Showing the 1 soonest of 96'), findsOneWidget);
    });

    testWidgets('a list that is the whole set carries no "showing" caption', (
      tester,
    ) async {
      // The other half of the rule: a caption on a complete list would be noise, and would
      // teach a reader to ignore the one that matters.
      final repository = FakeNotificationsRepository(
        lowStockProducts: <LowStockProduct>[buildLowStockProduct()],
        expiringBatches: <ExpiringBatch>[buildExpiringBatch()],
      );
      await pumpNotificationsApp(tester, notifications: repository);

      expect(find.textContaining('Showing the'), findsNothing);
    });

    testWidgets(
      'expiry renders the batch, and an expired one is coloured as gone',
      (tester) async {
        final repository = FakeNotificationsRepository(
          expiringBatches: <ExpiringBatch>[
            buildExpiringBatch(
              batchId: 'b-1',
              batchNo: 'A-EXPIRED',
              daysLeft: -1,
              qty: 2,
            ),
            buildExpiringBatch(
              batchId: 'b-2',
              productName: 'Amoxyclav 625',
              batchNo: 'B-1',
              daysLeft: 6,
              qty: 3,
            ),
          ],
        );
        await pumpNotificationsApp(tester, notifications: repository);

        expect(find.textContaining('Batch A-EXPIRED'), findsOneWidget);
        expect(find.text('Expired 1 day ago'), findsOneWidget);
        expect(find.text('In 6 days'), findsOneWidget);
        expect(find.textContaining('2 units left'), findsOneWidget);
        // The one that has already gone off gets the error icon; the other does not.
        expect(find.byIcon(Icons.event_busy), findsOneWidget);
        expect(find.byIcon(Icons.event_outlined), findsOneWidget);
      },
    );

    testWidgets('a batch expiring today says so rather than "in 0 days"', (
      tester,
    ) async {
      final repository = FakeNotificationsRepository(
        expiringBatches: <ExpiringBatch>[buildExpiringBatch(daysLeft: 0)],
      );
      await pumpNotificationsApp(tester, notifications: repository);

      expect(find.text('Expires today'), findsOneWidget);
    });
  });
}
