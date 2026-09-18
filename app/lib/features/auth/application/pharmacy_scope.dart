/// The pharmacy the signed-in user belongs to, exposed as a provider.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/logger.dart';
import 'package:app/data/models/profile.dart';
import 'package:app/features/auth/application/auth_controller.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'pharmacy_scope.g.dart';

/// The signed-in user's profile state, exactly as the auth controller holds it.
///
/// A seam, deliberately: it lets one place answer "is the profile still loading,
/// absent, or failed?", and it lets tests drive all three answers without
/// standing up Supabase or a real session.
@Riverpod(keepAlive: true)
AsyncValue<Profile?> profileState(Ref ref) => ref.watch(authControllerProvider);

/// The `pharmacy_id` every repository call must be scoped by (D-004), or a
/// thrown [AuthException] naming what is missing.
///
/// Synchronous on purpose. An asynchronous version chained through `.future`
/// reads better but breaks in two ways that only surface at runtime:
///
///  * Riverpod 3 keeps a *failed* build as a result and rethrows it at read
///    sites rather than completing the future, so `await provider.future` on a
///    provider that failed never returns. Every dependent would spin forever
///    instead of reporting the failure - worse than the bug being fixed here.
///  * a one-shot `ref.read(provider.future)` of an auto-dispose provider can be
///    disposed while its build is still in flight, which fails the read with
///    "disposed during loading state".
///
/// The three states are kept distinct, which is the defect this fixes: the
/// earlier version read `authControllerProvider.value`, and that value is `null`
/// while the profile is still loading - so "your profile has not arrived yet"
/// reached the user as "your account is not linked to a pharmacy".
@Riverpod(keepAlive: true)
String requirePharmacyId(Ref ref) {
  final state = ref.watch(profileStateProvider);

  // A value wins even while a refresh is in flight: after a token refresh the
  // previous profile is still a usable scope, so it must not be withheld.
  if (state.hasValue) {
    return _requirePharmacyId(state.value?.pharmacyId);
  }

  // A failed read is reported as itself. Reporting it as a missing link would
  // send the user to fix an account that is already linked correctly.
  if (state.hasError) {
    Error.throwWithStackTrace(
      state.error!,
      state.stackTrace ?? StackTrace.current,
    );
  }

  throw const AuthException(
    message: 'Your pharmacy is still loading. Please try again in a moment.',
    code: 'auth/pharmacy-loading',
  );
}

/// The id, or a failure that names what is actually missing.
String _requirePharmacyId(String? pharmacyId) {
  if (pharmacyId == null) {
    appLogger.w(
      'No pharmacy scope: the signed-in profile loaded but has no pharmacy_id. '
      'Repository calls are tenant-scoped, so this is a hard stop.',
    );
    throw const AuthException(
      message: 'Your account is not linked to a pharmacy yet.',
      code: 'auth/no-pharmacy',
    );
  }
  return pharmacyId;
}
