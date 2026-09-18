/// Riverpod controller that owns the signed-in user's profile.
library;

import 'package:app/data/models/profile.dart';
import 'package:app/features/auth/data/auth_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

part 'auth_controller.g.dart';

/// Emits the raw Supabase auth state every time the session changes.
///
/// `appRouterProvider` listens to this provider to refresh its redirects, and
/// [AuthController] uses it to refresh the profile when the user changes.
@riverpod
Stream<AuthState> authStateChanges(Ref ref) =>
    ref.watch(authRepositoryProvider).authStateChanges();

/// Owns the [Profile] of the user Supabase reports as signed in.
///
/// `build` resolves that profile and returns `null` when nobody is signed in,
/// or when the account has not been linked to a pharmacy yet. It also
/// subscribes to the auth state stream and invalidates itself whenever the
/// signed-in user id changes, which is how the app refreshes on login and
/// logout.
///
/// Kept alive because it is session state that several features read, and
/// because the auth-state subscription is what keeps the cached profile honest:
/// an auto-dispose controller would drop that subscription whenever no screen
/// was listening, and a profile changed during that window (a pharmacy linked,
/// a role changed) would go unnoticed until something rebuilt it. Being kept
/// alive is also what lets the tenant-scope providers below it be kept alive,
/// which `riverpod_lint` requires.
@Riverpod(keepAlive: true)
class AuthController extends _$AuthController {
  @override
  Future<Profile?> build() async {
    final repository = ref.watch(authRepositoryProvider);
    final signedInUserId = repository.currentUser?.id;

    var isBuilding = true;
    final subscription = repository.authStateChanges().listen((authState) {
      // Invalidation is skipped while the first profile fetch is still in
      // flight: invalidating during `build` would restart the provider.
      if (isBuilding) {
        return;
      }
      if (authState.session?.user.id != signedInUserId) {
        ref.invalidateSelf();
        return;
      }
      // A token refresh is the only signal that the profile row itself may have
      // changed underneath an already-signed-in user: an owner linking this
      // account to a pharmacy, changing its role, or the row being edited
      // directly in the database. Without this the cached profile - including a
      // null `pharmacy_id` - survives until the user signs out and back in,
      // which is the failure that was reported.
      if (authState.event == AuthChangeEvent.tokenRefreshed) {
        ref.invalidateSelf();
      }
    });
    ref.onDispose(subscription.cancel);

    final profile = signedInUserId == null
        ? null
        : await repository.fetchProfile(signedInUserId);
    isBuilding = false;
    return profile;
  }

  /// Signs [email] and [password] in, then loads the resulting profile.
  ///
  /// On failure this writes an `AsyncError` to `state` **and** rethrows the
  /// original exception. The rethrow is deliberate: the error state lets the
  /// screen react through `ref.listen`, while the rethrow lets the awaiting
  /// button handler log the failure.
  Future<void> signIn({required String email, required String password}) async {
    final repository = ref.read(authRepositoryProvider);
    state = const AsyncLoading<Profile?>();
    try {
      await repository.signInWithEmail(email: email, password: password);
    } on Object catch (error, stackTrace) {
      state = AsyncError<Profile?>(error, stackTrace);
      rethrow;
    }
    state = await AsyncValue.guard(_loadProfile);
  }

  /// Creates an account, then loads the resulting profile.
  ///
  /// Behaves like [signIn]: the error state is written to `state` and the
  /// original exception is rethrown, so both `ref.listen` and the awaiting
  /// screen see the failure.
  Future<void> signUp({
    required String email,
    required String password,
    required String fullName,
  }) async {
    final repository = ref.read(authRepositoryProvider);
    state = const AsyncLoading<Profile?>();
    try {
      await repository.signUpWithEmail(
        email: email,
        password: password,
        fullName: fullName,
      );
    } on Object catch (error, stackTrace) {
      state = AsyncError<Profile?>(error, stackTrace);
      rethrow;
    }
    state = await AsyncValue.guard(_loadProfile);
  }

  /// Signs the current user out and clears the cached profile.
  Future<void> signOut() async {
    final repository = ref.read(authRepositoryProvider);
    state = const AsyncLoading<Profile?>();
    try {
      await repository.signOut();
    } on Object catch (error, stackTrace) {
      state = AsyncError<Profile?>(error, stackTrace);
      rethrow;
    }
    state = const AsyncData<Profile?>(null);
  }

  /// Reads the profile of the user who is signed in right now.
  Future<Profile?> _loadProfile() async {
    final repository = ref.read(authRepositoryProvider);
    final user = repository.currentUser;
    if (user == null) {
      return null;
    }
    return repository.fetchProfile(user.id);
  }
}
