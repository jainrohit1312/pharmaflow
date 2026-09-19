/// The in-app inbox's state: the caller's notifications, and marking one read.
///
/// One controller rather than a `FutureProvider` because a row's read state
/// changes without the list changing shape, and marking one read should not cost a
/// round trip and a spinner.
library;

import 'package:app/data/models/app_notification.dart';
import 'package:app/features/notifications/data/notifications_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'notifications_controller.g.dart';

/// The caller's own notifications, newest first.
///
/// Nothing is passed in: the repository's read is scoped by RLS to
/// `user_id = auth.uid()`, so "whose inbox" is answered by the token and not by an
/// argument a caller could get wrong (D-004/D-015).
@riverpod
class NotificationsController extends _$NotificationsController {
  @override
  Future<List<AppNotification>> build() =>
      ref.watch(notificationsRepositoryProvider).list();

  /// Marks one notification read, optimistically and reversibly.
  ///
  /// The row changes immediately - a tap that waits for the network before the
  /// unread dot clears feels broken - and is put back exactly as it was if the
  /// write fails, with the failure rethrown so the screen can say so. `ref.mounted`
  /// is checked first, because the screen may have been left while the write was in
  /// flight (D-034).
  Future<void> markRead(String id) async {
    final before = state.value;
    if (before == null) {
      return;
    }

    final index = before.indexWhere((notification) => notification.id == id);
    if (index < 0 || before[index].isRead) {
      return;
    }

    state = AsyncData<List<AppNotification>>(_read(before, index));

    try {
      await ref.read(notificationsRepositoryProvider).markRead(id);
    } on Object {
      if (!ref.mounted) {
        return;
      }
      state = AsyncData<List<AppNotification>>(before);
      rethrow;
    }
  }
}

/// How many of the caller's notifications are unread.
///
/// Derived from the controller rather than counted by its own query, so the
/// dashboard's number and the screen's dots cannot disagree - and because the
/// inbox is one capped page, not an aggregate worth a second round trip.
///
/// Mapped by hand rather than with `whenData`, which only carries the *data* case
/// across: a read that Riverpod is retrying is exposed as a `loading` state that
/// still carries the error, and `whenData`'s loading branch would hand back a plain
/// `AsyncLoading` - so a dashboard whose read kept failing would say "Checking…"
/// for ever instead of admitting it could not check. The order matters as much:
/// a count that exists is the last good answer and is used, a failure with no count
/// is reported, and only then is it genuinely "not counted yet".
@riverpod
AsyncValue<int> unreadNotificationCount(Ref ref) {
  final inbox = ref.watch(notificationsControllerProvider);

  final rows = inbox.value;
  if (rows != null) {
    return AsyncData<int>(
      rows.where((notification) => !notification.isRead).length,
    );
  }

  final error = inbox.error;
  if (error != null) {
    return AsyncError<int>(error, inbox.stackTrace ?? StackTrace.empty);
  }

  return const AsyncLoading<int>();
}

/// [rows] with the row at [index] marked read as of now.
///
/// The timestamp is this device's clock, which is what `read_at` holds - see the
/// repository for why, and for what would notice if it were wrong.
List<AppNotification> _read(List<AppNotification> rows, int index) {
  final updated = List<AppNotification>.of(rows, growable: false);
  updated[index] = rows[index].copyWith(readAt: DateTime.now());
  return updated;
}
