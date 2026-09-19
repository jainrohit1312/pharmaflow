/// Freezed/JSON model for the `notifications` table - one row of somebody's
/// in-app inbox.
///
/// Not to be confused with [NotificationLog], which is the operator's record of a
/// *dispatch*. This is what a recipient reads: migration 00008's table, with
/// `read_at` as the only state it carries. The row is **user-addressed** - RLS
/// enforces `user_id = auth.uid()` - and its `pharmacy_id` is a routing hint
/// rather than a scope, so nothing here filters by tenant.
///
/// The class is named `AppNotification` because `Notification` is already
/// Flutter's own abstract widget class, and a name collision there would be paid
/// for at every import site.
library;

import 'package:app/data/models/notification_log.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'app_notification.freezed.dart';
part 'app_notification.g.dart';

/// One message in a user's in-app list.
@freezed
abstract class AppNotification with _$AppNotification {
  /// Creates an immutable [AppNotification].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed forwards
  /// constructor-level metadata onto the generated concrete class; on the class
  /// itself it would be ignored (keys would stay camelCase).
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory AppNotification({
    required String id,

    /// The recipient. RLS is the reason this is not a query filter.
    required String userId,

    /// What kind of notification this is - `'message'` for one written by
    /// `send-notification`, and whatever a later feature writes for its own.
    required String type,

    /// The message itself.
    required String message,

    required DateTime createdAt,
    required DateTime updatedAt,

    /// A routing hint, nullable by design (migration 00008), not a scope.
    String? pharmacyId,

    /// A headline. Nullable: WhatsApp has no subject, and an in-app row written
    /// from one has nothing to put here.
    String? title,

    @Default(NotificationChannel.inApp)
    @NotificationChannelConverter()
    NotificationChannel channel,

    /// Arbitrary payload for deep-linking / channel rendering - the column's own
    /// purpose. `send-notification` puts the dispatch channel and the recipient in
    /// here.
    @Default(<String, dynamic>{}) Map<String, dynamic> data,

    /// When the recipient read it, or `null` while it is unread. The whole read
    /// state of the row.
    DateTime? readAt,
  }) = _AppNotification;

  /// Reads one row from the API.
  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      _$AppNotificationFromJson(json);
}

/// The read state, which is the only thing about an inbox row that changes.
extension AppNotificationX on AppNotification {
  /// Whether the recipient has opened it.
  bool get isRead => readAt != null;

  /// The dispatch channel it accompanied, when `send-notification` wrote it.
  ///
  /// Null for a row nothing dispatched, which is the common case in Phase 5: the
  /// alerts are derived (D-047) and no alert is dispatched anywhere yet (D-046).
  String? get dispatchChannel {
    final value = data['dispatch_channel'];
    return value is String && value.isNotEmpty ? value : null;
  }
}
