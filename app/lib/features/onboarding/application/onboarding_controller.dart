/// Creates the signed-in user's pharmacy.
library;

import 'package:app/features/auth/application/auth_controller.dart';
import 'package:app/features/onboarding/data/onboarding_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'onboarding_controller.g.dart';

/// Runs the onboarding write and refreshes the session's profile.
///
/// `state` holds the id of the pharmacy just created, so a screen can react to
/// success through `ref.listen` without threading the return value through the
/// widget. A failure publishes an [AsyncError] and rethrows, matching how
/// `AuthController` and the form controllers report failures.
@riverpod
class OnboardingController extends _$OnboardingController {
  @override
  Future<String?> build() async => null;

  /// Creates a pharmacy for the signed-in user and returns its id.
  ///
  /// The auth controller is invalidated on success, which is what makes the app
  /// usable from here: the tenant scope reads the profile, so the profile has to
  /// be refetched before anything else will load. The router watches that
  /// provider and moves the user on once the link is there.
  Future<String> createPharmacy(OnboardingDetails details) async {
    state = const AsyncLoading<String?>();
    try {
      final pharmacyId = await ref
          .read(onboardingRepositoryProvider)
          .createPharmacy(details);
      ref.invalidate(authControllerProvider);
      state = AsyncData<String?>(pharmacyId);
      return pharmacyId;
    } on Object catch (error, stackTrace) {
      state = AsyncError<String?>(error, stackTrace);
      rethrow;
    }
  }
}
