/// The platform half of notifications: the seam that push will arrive behind.
///
/// Phase 5 has no push SDK and no local-notification plugin (D-029). The Firebase
/// project, the web service worker, the VAPID key and the registration call that
/// fills `device_tokens` are Phase 6's work, because all three have to be
/// registered against a deploy target that does not exist yet. What is left for
/// this phase is to say honestly what a caller can rely on *now*:
///
///   - `init` **completes**. There is nothing to initialise, and a caller that
///     awaits it is not making a mistake - Phase 6 puts the registration here, and
///     every call site stays as it is.
///   - `getFcmToken` **answers `null`**, the documented "unavailable". `null` is
///     what a caller has to handle anyway, so nothing has to special-case a throw.
///   - `showLocal` **completes without showing anything**, because there is no
///     local-notification surface on any target in this phase. The in-app list is
///     the surface that carries the message either way (D-029/D-046), and it does
///     not call this method at all. It says so out loud in a debug build, so the
///     first caller - Phase 6's push handler - does not mistake a silent drop for a
///     delivered notification.
///
/// The value of the shape is the one D-035 gives it: a capability the app cannot
/// exercise in a test gets a seam, so Phase 6 swaps the implementation behind the
/// provider - and, because [NotificationService] is what a fake replaces, the
/// platform can stay out of every widget test.
library;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'notification_service.g.dart';

/// The notification surface the rest of the app calls.
abstract class NotificationService {
  /// Initialises the underlying SDKs (permissions, channels, listeners).
  ///
  /// A no-op in Phase 5: there is no SDK to initialise. Phase 6's push
  /// registration lands in this method, which is why it keeps its place.
  Future<void> init();

  /// Shows a message on this device, outside the app's own UI.
  ///
  /// A no-op in Phase 5, for the same reason: no plugin is installed to show it
  /// with. Nothing in the app calls it yet, and the in-app list is what carries a
  /// message in the meantime.
  Future<void> showLocal({required String title, required String body});

  /// Returns the FCM registration token, or `null` when unavailable.
  ///
  /// `null` in Phase 5, and deliberately not an exception: "push is not wired
  /// yet" is the state the app runs in for this whole phase, not a failure.
  Future<String?> getFcmToken();
}

/// The Phase 5 [NotificationService]: no platform, reported honestly.
///
/// Every method completes and says what it can do rather than throwing
/// `UnimplementedError`: a throwing stub would force every caller to special-case
/// this phase, and then to be edited again when Phase 6 lands.
class UnavailableNotificationService implements NotificationService {
  /// Creates the Phase 5 implementation.
  const UnavailableNotificationService();

  /// Nothing to initialise yet; Phase 6's registration goes here.
  @override
  Future<void> init() async {}

  /// Nothing to show it with yet, and a debug build says so rather than being
  /// silent: a caller that believed a notification had appeared when none did is a
  /// bug that would look like the platform's fault. `kDebugMode` is a const, so the
  /// branch compiles out of a release build entirely.
  @override
  Future<void> showLocal({required String title, required String body}) async {
    if (kDebugMode) {
      debugPrint(
        'NotificationService.showLocal dropped "$title": Phase 5 has no local '
        'notification surface (D-029). The in-app list carries the message.',
      );
    }
  }

  /// Push is not wired yet (D-029/N-1), so there is no token.
  @override
  Future<String?> getFcmToken() async => null;
}

/// The app-wide [NotificationService].
@riverpod
NotificationService notificationService(Ref ref) =>
    const UnavailableNotificationService();
