/// Tests for the onboarding controller.
///
/// The write itself is a server-side RPC and is covered by
/// `supabase/tests/profile_privileges.sql`, which impersonates the
/// `authenticated` role. These tests cover what the app does with the answer:
/// publishes the new pharmacy id, surfaces the RPC's own message on a rejection,
/// and reports a failure without pretending it succeeded.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/features/onboarding/application/onboarding_controller.dart';
import 'package:app/features/onboarding/data/onboarding_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [OnboardingRepository] that records what it was asked to do.
///
/// `implements` rather than `extends`: it needs no Supabase client, which is the
/// whole point - a real one cannot be constructed without an initialised
/// backend.
class _FakeOnboardingRepository implements OnboardingRepository {
  /// The details of the last call, or `null` when it was never called.
  OnboardingDetails? lastDetails;

  /// What the next call returns, or throws.
  Exception? errorToThrow;

  /// The id the next successful call returns.
  String pharmacyId = 'ph-new';

  @override
  Future<String> createPharmacy(OnboardingDetails details) async {
    lastDetails = details;
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    return pharmacyId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}

/// A container wired to [repository].
ProviderContainer _container(_FakeOnboardingRepository repository) {
  final container = ProviderContainer(
    overrides: [onboardingRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a successful onboarding publishes the new pharmacy id', () async {
    final repository = _FakeOnboardingRepository();
    final container = _container(repository);

    final pharmacyId = await container
        .read(onboardingControllerProvider.notifier)
        .createPharmacy(const OnboardingDetails(pharmacyName: 'Arihant'));

    expect(pharmacyId, 'ph-new');
    expect(container.read(onboardingControllerProvider).value, 'ph-new');
    expect(repository.lastDetails?.pharmacyName, 'Arihant');
  });

  test('a rejection surfaces the RPC message and records an error', () async {
    final repository = _FakeOnboardingRepository()
      ..errorToThrow = const ValidationException(
        message: 'This account is already linked to a pharmacy',
        code: '23505',
      );
    final container = _container(repository);

    await expectLater(
      container
          .read(onboardingControllerProvider.notifier)
          .createPharmacy(const OnboardingDetails(pharmacyName: 'Arihant')),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          'This account is already linked to a pharmacy',
        ),
      ),
    );

    final state = container.read(onboardingControllerProvider);
    expect(state.hasError, isTrue);
    expect(state.value, isNull, reason: 'no pharmacy id was earned');
  });

  test('optional details are passed through as given', () async {
    final repository = _FakeOnboardingRepository();
    final container = _container(repository);

    await container
        .read(onboardingControllerProvider.notifier)
        .createPharmacy(
          const OnboardingDetails(
            pharmacyName: 'Arihant',
            gstin: '27ABCDE1234F1Z5',
            city: 'Mumbai',
          ),
        );

    final details = repository.lastDetails;
    expect(details?.gstin, '27ABCDE1234F1Z5');
    expect(details?.city, 'Mumbai');
    expect(details?.drugLicense, isNull);
    expect(details?.pincode, isNull);
  });
}
