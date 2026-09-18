/// Typed, fail-fast access to the environment loaded from the `.env` asset.
library;

import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Environment variables required by the PharmaFlow client.
///
/// These are `static get` accessors rather than `static const` fields: the
/// values come from `flutter_dotenv`, which reads the `.env` asset through
/// `rootBundle` at runtime, and a `const` field must be known at compile time.
/// Use [assertLoaded] during bootstrap to fail fast when a key is missing.
abstract final class Env {
  /// Supabase project URL, for example `https://project.supabase.co`.
  static String get supabaseUrl => _value('SUPABASE_URL');

  /// Public (anon) Supabase API key used by the client.
  static String get supabaseAnonKey => _value('SUPABASE_ANON_KEY');

  /// Throws a [StateError] naming every required key that is missing or empty.
  ///
  /// Call this once during bootstrap, after `dotenv.load()`, so that a
  /// misconfigured build fails loudly instead of issuing anonymous requests.
  static void assertLoaded() {
    final missing = <String>[];
    for (final key in _requiredKeys) {
      if (_value(key).isEmpty) {
        missing.add(key);
      }
    }
    if (missing.isNotEmpty) {
      throw StateError(
        'Missing required environment variable(s): ${missing.join(', ')}. '
        'Provide them in the `.env` asset (listed under `flutter.assets` in '
        'pubspec.yaml) before starting the app.',
      );
    }
  }

  /// Keys that must be present for the client to boot.
  static const List<String> _requiredKeys = <String>[
    'SUPABASE_URL',
    'SUPABASE_ANON_KEY',
  ];

  /// Reads [key] from the loaded dotenv map, returning `''` when unavailable.
  ///
  /// The `isInitialized` guard keeps the accessors safe before `dotenv.load()`
  /// has run (widget tests, error reporting paths) instead of throwing
  /// flutter_dotenv's `NotInitializedError`.
  static String _value(String key) =>
      dotenv.isInitialized ? (dotenv.env[key] ?? '') : '';
}
