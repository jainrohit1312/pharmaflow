/// Tests for the inbox controller.
///
/// Two properties are the point, and each exists for a reason the UI depends on:
/// the read state changes *before* the network answers (a tap that waits for a
/// round trip before the unread dot clears feels broken), and if the write fails
/// the row goes back exactly as it was rather than leaving the screen claiming
/// something the database did not record.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/app_notification.dart';
import 'package:app/features/notifications/application/notifications_controller.dart';
import 'package:app/features/notifications/data/notifications_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_notifications_repository.dart';

/// A container with the repository stubbed out.
///
/// The override list is inferred rather than annotated: `Override` is declared in
/// the `riverpod` package, which is a transitive dependency here, so naming it
/// would mean importing a package this app does not depend on directly.
ProviderContainer _container(NotificationsRepository repository) {
  final container = ProviderContainer(
    overrides: [notificationsRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);
  return container;
}

/// Keeps [container]'s inbox alive and lets its first read settle.
///
/// The subscription matters: an auto-dispose provider read once can be disposed
/// mid-build, and awaiting `.future` on a provider that failed never completes in
/// Riverpod 3, so the state is read after the build has had a turn instead.
Future<void> _loaded(ProviderContainer container) async {
  final subscription = container.listen(
    notificationsControllerProvider,
    (previous, next) {},
  );
  addTearDown(subscription.close);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('the list', () {
    test('is whatever the repository read, in its order', () async {
      final repository = FakeNotificationsRepository(
        notifications: <AppNotification>[
          buildAppNotification(id: 'n-2', title: 'Newer'),
          buildAppNotification(id: 'n-1', title: 'Older'),
        ],
      );
      final container = _container(repository);
      await _loaded(container);

      final rows = container.read(notificationsControllerProvider).value;

      expect(rows, hasLength(2));
      expect(rows!.first.id, 'n-2');
      expect(repository.listReads, 1);
    });

    test('an empty inbox is a loaded empty list, not an error', () async {
      final container = _container(FakeNotificationsRepository());
      await _loaded(container);

      final state = container.read(notificationsControllerProvider);

      expect(state.hasValue, isTrue);
      expect(state.value, isEmpty);
    });

    test('a failed read is an error state, and a retry re-reads', () async {
      final repository = FakeNotificationsRepository()
        ..listError = const ServerException(
          message: 'Unable to read your notifications.',
        );
      final container = _container(repository);
      await _loaded(container);

      expect(container.read(notificationsControllerProvider).hasError, isTrue);

      // What the retry button does: invalidate, and the second answer is shown.
      // The number of reads is deliberately not asserted: Riverpod 3 re-runs a
      // build that threw on its own backoff, so a read count is not the retry
      // button's signature - the state it produces is.
      repository.listError = null;
      container.invalidate(notificationsControllerProvider);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(notificationsControllerProvider).hasValue, isTrue);
    });
  });

  group('the unread count', () {
    test('counts the rows with no read_at', () async {
      final repository = FakeNotificationsRepository(
        notifications: <AppNotification>[
          buildAppNotification(id: 'n-1'),
          buildAppNotification(id: 'n-2', readAt: DateTime(2026, 9, 19, 11)),
          buildAppNotification(id: 'n-3'),
        ],
      );
      final container = _container(repository);
      await _loaded(container);

      expect(container.read(unreadNotificationCountProvider).value, 2);
    });

    test(
      'an empty inbox counts zero, which is a different thing from unknown',
      () async {
        final container = _container(FakeNotificationsRepository());
        await _loaded(container);

        expect(container.read(unreadNotificationCountProvider).value, 0);
      },
    );

    test(
      'a failed count stays a failure rather than reading as zero',
      () async {
        final repository = FakeNotificationsRepository()
          ..listError = const ServerException(
            message: 'Unable to read your notifications.',
          );
        final container = _container(repository);
        await _loaded(container);

        final count = container.read(unreadNotificationCountProvider);

        expect(count.hasError, isTrue);
        expect(count.value, isNull);
      },
    );
  });

  group('markRead', () {
    test('changes the row before the write answers', () async {
      final repository = FakeNotificationsRepository(
        notifications: <AppNotification>[buildAppNotification(id: 'n-1')],
      );
      final container = _container(repository);
      await _loaded(container);

      final pending = container
          .read(notificationsControllerProvider.notifier)
          .markRead('n-1');

      // Not awaited yet: the row is already read, which is the whole point of
      // writing it optimistically.
      expect(
        container.read(notificationsControllerProvider).value!.single.isRead,
        isTrue,
      );

      await pending;
      expect(repository.markReadRequests, <String>['n-1']);
      // And the count the dashboard shows moved with it.
      expect(container.read(unreadNotificationCountProvider).value, 0);
    });

    test('a failed write puts the row back and reports it', () async {
      final repository =
          FakeNotificationsRepository(
              notifications: <AppNotification>[buildAppNotification(id: 'n-1')],
            )
            ..markReadError = const ServerException(
              message: 'Unable to mark that notification read.',
            );
      final container = _container(repository);
      await _loaded(container);

      await expectLater(
        container
            .read(notificationsControllerProvider.notifier)
            .markRead('n-1'),
        throwsA(isA<ServerException>()),
      );

      final state = container.read(notificationsControllerProvider);
      expect(state.value!.single.isRead, isFalse);
      expect(state.value!.single.readAt, isNull);
      // A failed write is not a failed read: the list is still there.
      expect(state.hasError, isFalse);
    });

    test('marking an already-read row writes nothing', () async {
      final repository = FakeNotificationsRepository(
        notifications: <AppNotification>[
          buildAppNotification(id: 'n-1', readAt: DateTime(2026, 9, 19, 11)),
        ],
      );
      final container = _container(repository);
      await _loaded(container);

      await container
          .read(notificationsControllerProvider.notifier)
          .markRead('n-1');

      expect(repository.markReadRequests, isEmpty);
    });

    test('marking a row that is not in the list writes nothing', () async {
      final repository = FakeNotificationsRepository(
        notifications: <AppNotification>[buildAppNotification(id: 'n-1')],
      );
      final container = _container(repository);
      await _loaded(container);

      await container
          .read(notificationsControllerProvider.notifier)
          .markRead('not-here');

      expect(repository.markReadRequests, isEmpty);
    });
  });
}
