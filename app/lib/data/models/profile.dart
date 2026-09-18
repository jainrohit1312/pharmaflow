/// Freezed/JSON model for the `profiles` table plus the app-side role enum.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'profile.freezed.dart';
part 'profile.g.dart';

/// The role a [Profile] holds inside its pharmacy.
enum AppRole {
  /// Owns the pharmacy; unrestricted access to every module.
  owner,

  /// Licensed pharmacist; may bill and manage stock.
  pharmacist,

  /// Counter staff; may bill but not manage stock.
  cashier,

  /// Read-only access.
  viewer,
}

/// Parses a Postgres `app_role` literal into an [AppRole].
///
/// `null` and unrecognised values fall back to [AppRole.viewer].
AppRole appRoleFromDb(String? raw) => switch (raw?.trim().toLowerCase()) {
  'owner' => AppRole.owner,
  'pharmacist' => AppRole.pharmacist,
  'cashier' => AppRole.cashier,
  _ => AppRole.viewer,
};

/// Maps [AppRole] to its Postgres literal, UI label and permissions.
extension AppRoleX on AppRole {
  /// The literal stored in the Postgres `app_role` enum column.
  String get dbValue => switch (this) {
    AppRole.owner => 'owner',
    AppRole.pharmacist => 'pharmacist',
    AppRole.cashier => 'cashier',
    AppRole.viewer => 'viewer',
  };

  /// The label shown in the UI.
  String get label => switch (this) {
    AppRole.owner => 'Owner',
    AppRole.pharmacist => 'Pharmacist',
    AppRole.cashier => 'Cashier',
    AppRole.viewer => 'Viewer',
  };

  /// Whether the role owns the pharmacy.
  bool get isOwner => this == AppRole.owner;

  /// Whether the role may manage stock (owner and pharmacist).
  bool get canManageStock =>
      this == AppRole.owner || this == AppRole.pharmacist;

  /// Whether the role may bill customers (owner, pharmacist, cashier).
  bool get canBill =>
      this == AppRole.owner ||
      this == AppRole.pharmacist ||
      this == AppRole.cashier;
}

/// Round-trips [AppRole] with the lowercase Postgres `app_role` literal.
class AppRoleConverter extends JsonConverter<AppRole, String?> {
  /// Creates the converter referenced by `@AppRoleConverter()`.
  const AppRoleConverter();

  /// Decodes `'owner'`, `'pharmacist'`, `'cashier'` or `'viewer'`.
  @override
  AppRole fromJson(String? json) => appRoleFromDb(json);

  /// Emits the lowercase DB literal.
  @override
  String? toJson(AppRole object) => object.dbValue;
}

/// A user profile row (`profiles` table), scoped to a pharmacy tenant.
@freezed
abstract class Profile with _$Profile {
  /// Creates an immutable [Profile].
  ///
  /// `@JsonSerializable` sits on the factory constructor because Freezed
  /// forwards constructor-level metadata onto the generated concrete class; on
  /// the class itself it would be ignored (keys would stay camelCase).
  // ignore: invalid_annotation_target
  @JsonSerializable(fieldRename: FieldRename.snake, includeIfNull: false)
  const factory Profile({
    required String id,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? pharmacyId,
    String? fullName,
    String? phone,
    String? avatarUrl,
    @Default(AppRole.viewer) @AppRoleConverter() AppRole role,
    @Default(true) bool isActive,
  }) = _Profile;

  /// Decodes a snake_case Postgres/Supabase row into a [Profile].
  factory Profile.fromJson(Map<String, dynamic> json) =>
      _$ProfileFromJson(json);
}

/// Display helpers for [Profile].
extension ProfileX on Profile {
  /// The best available name, or `'User'` when `fullName` is blank.
  String get displayName =>
      (fullName?.trim().isNotEmpty ?? false) ? fullName!.trim() : 'User';

  /// Up to two uppercased initials taken from `displayName`.
  String get initials => displayName
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .take(2)
      .map((word) => word.substring(0, 1).toUpperCase())
      .join();
}
