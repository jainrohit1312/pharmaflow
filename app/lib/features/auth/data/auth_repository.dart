/// Supabase-backed authentication repository for the auth feature.
///
/// This is the only place in the app that talks to Supabase Auth directly.
/// Every failure is translated into PharmaFlow's own `AuthException` so the
/// presentation layer never depends on Supabase exception types. The Supabase
/// symbols are imported behind the `sb` prefix because `supabase_flutter`
/// exports an `AuthException` of its own that would collide with ours.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/logger.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/profile.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'auth_repository.g.dart';

/// Exposes the single [AuthRepository] used by the auth feature.
///
/// Generated: `riverpod_generator` emits `authRepositoryProvider` from this
/// function name, so consumers are unaffected by the move off a hand-written
/// `Provider`.
@riverpod
AuthRepository authRepository(Ref ref) =>
    AuthRepository(ref.watch(supabaseClientProvider));

/// Wraps the Supabase auth API for PharmaFlow.
class AuthRepository {
  /// Creates a repository backed by the shared Supabase client.
  AuthRepository(this._client);

  final sb.SupabaseClient _client;

  /// The session of the signed-in user, or `null` when signed out.
  ///
  /// This reads straight from the Supabase client so the router can decide
  /// where to redirect without waiting for a provider to settle.
  sb.Session? get currentSession => _client.auth.currentSession;

  /// The signed-in user, or `null` when signed out.
  sb.User? get currentUser => _client.auth.currentUser;

  /// Emits a new value every time the client's auth state changes.
  Stream<sb.AuthState> authStateChanges() => _client.auth.onAuthStateChange;

  /// Signs an existing user in with [email] and [password].
  Future<sb.AuthResponse> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      return await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
    } on sb.AuthException catch (error) {
      throw AuthException(
        message: error.message,
        code: error.statusCode,
        cause: error,
      );
    } on sb.PostgrestException catch (error) {
      throw AuthException(
        message: error.message,
        code: error.code,
        cause: error,
      );
    } on Object catch (error) {
      throw AuthException(
        message: 'Unable to sign in right now. Please try again.',
        cause: error,
      );
    }
  }

  /// Creates an account for [email] with [password] and [fullName].
  ///
  /// The name travels as user metadata so the `handle_new_user()` database
  /// trigger can copy it onto the freshly created `profiles` row. The account
  /// is deliberately **not** auto-confirmed: the email confirmation flow
  /// configured in Supabase stays in force.
  Future<sb.AuthResponse> signUpWithEmail({
    required String email,
    required String password,
    required String fullName,
  }) async {
    try {
      return await _client.auth.signUp(
        email: email,
        password: password,
        data: <String, dynamic>{'full_name': fullName},
      );
    } on sb.AuthException catch (error) {
      throw AuthException(
        message: error.message,
        code: error.statusCode,
        cause: error,
      );
    } on sb.PostgrestException catch (error) {
      throw AuthException(
        message: error.message,
        code: error.code,
        cause: error,
      );
    } on Object catch (error) {
      throw AuthException(
        message: 'Unable to create your account right now.',
        cause: error,
      );
    }
  }

  /// Signs the current user out of this device.
  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } on sb.AuthException catch (error) {
      throw AuthException(
        message: error.message,
        code: error.statusCode,
        cause: error,
      );
    } on Object catch (error) {
      throw AuthException(
        message: 'Unable to sign out right now. Please try again.',
        cause: error,
      );
    }
  }

  /// Loads the `profiles` row of [userId].
  ///
  /// Returns `null` when the row is missing *or* when it exists but does not
  /// match [Profile] — a half-written row must never take the shell down.
  Future<Profile?> fetchProfile(String userId) async {
    final row = await _fetchProfileRow(userId);
    if (row == null) {
      return null;
    }
    try {
      return Profile.fromJson(row);
    } on Object catch (error) {
      appLogger.w('Ignoring unreadable profile row for $userId', error: error);
      return null;
    }
  }

  /// Reads the raw `profiles` row of [userId], or `null` when absent.
  Future<Map<String, dynamic>?> _fetchProfileRow(String userId) async {
    try {
      return await _client
          .from('profiles')
          .select()
          .eq('id', userId)
          .maybeSingle();
    } on sb.PostgrestException catch (error) {
      throw AuthException(
        message: error.message,
        code: error.code,
        cause: error,
      );
    } on Object catch (error) {
      throw AuthException(
        message: 'Unable to load your pharmacy profile.',
        cause: error,
      );
    }
  }
}
