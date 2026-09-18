/// Notification contract (phase 2) — abstract surface, not yet wired up.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

// TODO(phase-2): wire up FCM + local notifications.

/// The notification surface used by the rest of the app.
///
/// Deliberately not wired: no SDK is initialised and every method of the
/// default implementation throws [UnimplementedError] until phase 2 lands.
abstract class NotificationService {
  /// Initialises the underlying SDKs (permissions, channels, listeners).
  Future<void> init();

  /// Shows a local notification carrying [title] and [body].
  Future<void> showLocal({required String title, required String body});

  /// Returns the FCM registration token, or `null` when unavailable.
  Future<String?> getFcmToken();
}

/// A [NotificationService] whose methods all throw [UnimplementedError].
class UnimplementedNotificationService implements NotificationService {
  /// Creates the placeholder implementation.
  const UnimplementedNotificationService();

  /// Throws [UnimplementedError] until phase 2 lands.
  @override
  Future<void> init() {
    throw UnimplementedError('TODO(phase-2)');
  }

  /// Throws [UnimplementedError] until phase 2 lands.
  @override
  Future<void> showLocal({required String title, required String body}) {
    throw UnimplementedError('TODO(phase-2)');
  }

  /// Throws [UnimplementedError] until phase 2 lands.
  @override
  Future<String?> getFcmToken() {
    throw UnimplementedError('TODO(phase-2)');
  }
}

/// The app-wide [NotificationService].
final Provider<NotificationService> notificationServiceProvider =
    Provider<NotificationService>(
      (ref) => const UnimplementedNotificationService(),
    );
