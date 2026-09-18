/// Freezed/JSON model for the `device_tokens` table plus the platform enum.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'device_token.freezed.dart';
part 'device_token.g.dart';

/// What a registered push token belongs to.
///
/// Mirrors the Postgres `device_platform` enum (migration 00022). The app has to
/// state it because one user can hold several devices - a counter tablet and a
/// phone - and a notification that only reaches the wrong one is not delivered.
enum DevicePlatform {
  /// A browser, which is what this app is used on first (D-005).
  web,

  /// An Android device.
  android,

  /// An iOS device.
  ios,

  /// A Windows desktop.
  windows,

  /// A macOS desktop.
  macos,

  /// A Linux desktop.
  linux,
}

/// Parses a Postgres `device_platform` literal into a [DevicePlatform].
///
/// Anything unrecognised falls back to [DevicePlatform.web] rather than throwing:
/// a platform this build does not know about is still a device that registered,
/// and losing the row over its label would be the wrong failure.
DevicePlatform devicePlatformFromDb(String? raw) =>
    switch (raw?.trim().toLowerCase()) {
      'android' => DevicePlatform.android,
      'ios' => DevicePlatform.ios,
      'windows' => DevicePlatform.windows,
      'macos' => DevicePlatform.macos,
      'linux' => DevicePlatform.linux,
      _ => DevicePlatform.web,
    };

/// Maps [DevicePlatform] between its DB literal and its UI label.
extension DevicePlatformX on DevicePlatform {
  /// The literal stored in `device_tokens.platform`.
  String get dbValue => switch (this) {
    DevicePlatform.web => 'web',
    DevicePlatform.android => 'android',
    DevicePlatform.ios => 'ios',
    DevicePlatform.windows => 'windows',
    DevicePlatform.macos => 'macos',
    DevicePlatform.linux => 'linux',
  };

  /// The label shown in the device list.
  String get label => switch (this) {
    DevicePlatform.web => 'Web',
    DevicePlatform.android => 'Android',
    DevicePlatform.ios => 'iOS',
    DevicePlatform.windows => 'Windows',
    DevicePlatform.macos => 'macOS',
    DevicePlatform.linux => 'Linux',
  };
}

/// Round-trips [DevicePlatform] with the Postgres `device_platform` literal.
class DevicePlatformConverter extends JsonConverter<DevicePlatform, String?> {
  /// Creates the converter referenced by `@DevicePlatformConverter()`.
  const DevicePlatformConverter();

  /// Decodes `'web'`, `'android'`, and the rest.
  @override
  DevicePlatform fromJson(String? json) => devicePlatformFromDb(json);

  /// Emits the DB literal, e.g. `'windows'`.
  @override
  String? toJson(DevicePlatform object) => object.dbValue;
}

/// One device a notification can reach.
///
/// A token identifies the app instance, not the user: the same row is re-pointed
/// when somebody else signs in on that device, which is why the client registers
/// by upserting on `token` rather than inserting.
@freezed
abstract class DeviceToken with _$DeviceToken {
  /// Creates an immutable [DeviceToken].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed forwards
  /// constructor-level metadata onto the generated concrete class; on the class
  /// itself it would be ignored (keys would stay camelCase).
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory DeviceToken({
    required String id,
    required String pharmacyId,
    required String userId,
    required String token,
    required DateTime lastSeenAt,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(DevicePlatform.web)
    @DevicePlatformConverter()
    DevicePlatform platform,
    @Default(true) bool isActive,
  }) = _DeviceToken;

  /// Decodes a snake_case Postgres/Supabase row into a [DeviceToken].
  factory DeviceToken.fromJson(Map<String, dynamic> json) =>
      _$DeviceTokenFromJson(json);
}
