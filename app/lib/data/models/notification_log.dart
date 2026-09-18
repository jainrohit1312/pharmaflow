/// Freezed/JSON model for the `notification_logs` table plus its channel,
/// status and recipient-type enums.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'notification_log.freezed.dart';
part 'notification_log.g.dart';

/// How a dispatch was sent.
///
/// Mirrors the Postgres `notification_channel` enum (migration 00002), which
/// `notifications.channel` also uses, so the in-app list and the delivery log
/// cannot disagree about what `'whatsapp'` means.
enum NotificationChannel {
  /// A device push. Only the log side of this exists so far: FCM registration is
  /// deferred to Phase 6, and a stored row keeps its channel rather than having to
  /// be reinterpreted when it arrives.
  push,

  /// The WhatsApp Business API.
  whatsapp,

  /// Transactional email.
  email,

  /// Nothing left the building - the row is a message shown inside the app.
  inApp,
}

/// What happened to a dispatch.
enum NotificationStatus {
  /// Written, not yet answered by a provider.
  queued,

  /// The provider accepted it.
  sent,

  /// The provider refused it, or the attempt raised. `error` says why.
  failed,

  /// Deliberately not attempted - no channel configured, or the recipient opted
  /// out. A decision, not a failure.
  skipped,
}

/// Who a dispatch was addressed to.
enum NotificationRecipientType {
  /// A customer, e.g. a bill sent over WhatsApp.
  customer,

  /// A supplier, e.g. a purchase order sent by email.
  supplier,

  /// A staff account, e.g. a low-stock alert pushed to the owner.
  user,

  /// Someone with no row of their own - a number typed at the counter.
  other,
}

/// Parses a Postgres `notification_channel` literal.
///
/// Anything unrecognised falls back to [NotificationChannel.inApp]: a channel this
/// build does not know about still means the app showed it to somebody.
NotificationChannel notificationChannelFromDb(String? raw) =>
    switch (raw?.trim().toLowerCase()) {
      'push' => NotificationChannel.push,
      'whatsapp' => NotificationChannel.whatsapp,
      'email' => NotificationChannel.email,
      _ => NotificationChannel.inApp,
    };

/// Parses a Postgres `notification_status` literal.
///
/// Anything unrecognised falls back to [NotificationStatus.failed], the safe
/// reading of an outcome a build does not understand: it prompts a look rather
/// than reporting success that may not have happened.
NotificationStatus notificationStatusFromDb(String? raw) =>
    switch (raw?.trim().toLowerCase()) {
      'queued' => NotificationStatus.queued,
      'sent' => NotificationStatus.sent,
      'skipped' => NotificationStatus.skipped,
      _ => NotificationStatus.failed,
    };

/// Parses a Postgres `notification_recipient_type` literal.
///
/// Anything unrecognised falls back to [NotificationRecipientType.other].
NotificationRecipientType notificationRecipientTypeFromDb(String? raw) =>
    switch (raw?.trim().toLowerCase()) {
      'customer' => NotificationRecipientType.customer,
      'supplier' => NotificationRecipientType.supplier,
      'user' => NotificationRecipientType.user,
      _ => NotificationRecipientType.other,
    };

/// Maps [NotificationChannel] between its DB literal and its UI label.
extension NotificationChannelX on NotificationChannel {
  /// The literal stored in `notification_logs.channel`.
  String get dbValue => switch (this) {
    NotificationChannel.push => 'push',
    NotificationChannel.whatsapp => 'whatsapp',
    NotificationChannel.email => 'email',
    NotificationChannel.inApp => 'in_app',
  };

  /// The label shown in the dispatch list.
  String get label => switch (this) {
    NotificationChannel.push => 'Push',
    NotificationChannel.whatsapp => 'WhatsApp',
    NotificationChannel.email => 'Email',
    NotificationChannel.inApp => 'In app',
  };
}

/// Maps [NotificationStatus] between its DB literal and its UI label.
extension NotificationStatusX on NotificationStatus {
  /// The literal stored in `notification_logs.status`.
  String get dbValue => switch (this) {
    NotificationStatus.queued => 'queued',
    NotificationStatus.sent => 'sent',
    NotificationStatus.failed => 'failed',
    NotificationStatus.skipped => 'skipped',
  };

  /// The label shown in the dispatch list.
  String get label => switch (this) {
    NotificationStatus.queued => 'Queued',
    NotificationStatus.sent => 'Sent',
    NotificationStatus.failed => 'Failed',
    NotificationStatus.skipped => 'Skipped',
  };

  /// Whether the dispatch is over as far as this row is concerned.
  ///
  /// A queued row is the only one still in flight, which is what a retry control
  /// keys off.
  bool get isSettled => this != NotificationStatus.queued;
}

/// Maps [NotificationRecipientType] between its DB literal and its UI label.
extension NotificationRecipientTypeX on NotificationRecipientType {
  /// The literal stored in `notification_logs.recipient_type`.
  String get dbValue => switch (this) {
    NotificationRecipientType.customer => 'customer',
    NotificationRecipientType.supplier => 'supplier',
    NotificationRecipientType.user => 'user',
    NotificationRecipientType.other => 'other',
  };

  /// The label shown in the dispatch list.
  String get label => switch (this) {
    NotificationRecipientType.customer => 'Customer',
    NotificationRecipientType.supplier => 'Supplier',
    NotificationRecipientType.user => 'Staff',
    NotificationRecipientType.other => 'Other',
  };
}

/// Round-trips [NotificationChannel] with the Postgres literal.
class NotificationChannelConverter
    extends JsonConverter<NotificationChannel, String?> {
  /// Creates the converter referenced by `@NotificationChannelConverter()`.
  const NotificationChannelConverter();

  /// Decodes `'push'`, `'whatsapp'`, `'email'` or `'in_app'`.
  @override
  NotificationChannel fromJson(String? json) => notificationChannelFromDb(json);

  /// Emits the DB literal, e.g. `'in_app'`.
  @override
  String? toJson(NotificationChannel object) => object.dbValue;
}

/// Round-trips [NotificationStatus] with the Postgres literal.
class NotificationStatusConverter
    extends JsonConverter<NotificationStatus, String?> {
  /// Creates the converter referenced by `@NotificationStatusConverter()`.
  const NotificationStatusConverter();

  /// Decodes `'queued'`, `'sent'`, `'failed'` or `'skipped'`.
  @override
  NotificationStatus fromJson(String? json) => notificationStatusFromDb(json);

  /// Emits the DB literal, e.g. `'queued'`.
  @override
  String? toJson(NotificationStatus object) => object.dbValue;
}

/// Round-trips [NotificationRecipientType] with the Postgres literal.
class NotificationRecipientTypeConverter
    extends JsonConverter<NotificationRecipientType, String?> {
  /// Creates the converter referenced by `@NotificationRecipientTypeConverter()`.
  const NotificationRecipientTypeConverter();

  /// Decodes `'customer'`, `'supplier'`, `'user'` or `'other'`.
  @override
  NotificationRecipientType fromJson(String? json) =>
      notificationRecipientTypeFromDb(json);

  /// Emits the DB literal, e.g. `'supplier'`.
  @override
  String? toJson(NotificationRecipientType object) => object.dbValue;
}

/// One attempt to reach a party or a user over one channel.
///
/// The delivery record, not the in-app list: `notifications` is what a recipient
/// reads, this is what an operator audits when a message did not arrive. The body
/// is stored because "we sent something" is not an answer to "what did we tell
/// them".
@freezed
abstract class NotificationLog with _$NotificationLog {
  /// Creates an immutable [NotificationLog].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed forwards
  /// constructor-level metadata onto the generated concrete class; on the class
  /// itself it would be ignored (keys would stay camelCase).
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory NotificationLog({
    required String id,
    required String pharmacyId,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(NotificationRecipientType.other)
    @NotificationRecipientTypeConverter()
    NotificationRecipientType recipientType,
    @Default(NotificationChannel.inApp)
    @NotificationChannelConverter()
    NotificationChannel channel,
    @Default(NotificationStatus.queued)
    @NotificationStatusConverter()
    NotificationStatus status,
    String? notificationId,
    String? recipientId,
    String? destination,
    String? subject,
    String? body,
    String? provider,
    String? providerMessageId,
    String? error,
    String? createdBy,
  }) = _NotificationLog;

  /// Decodes a snake_case Postgres/Supabase row into a [NotificationLog].
  factory NotificationLog.fromJson(Map<String, dynamic> json) =>
      _$NotificationLogFromJson(json);
}
