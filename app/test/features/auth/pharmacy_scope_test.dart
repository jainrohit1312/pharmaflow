/// Tests for the tenant-scope provider.
///
/// The regression these pin: `requirePharmacyId` used to read the profile's
/// `AsyncValue.value`, which is `null` while the profile is still loading. So
/// "your profile has not arrived yet" reached the user as "your account is not
/// linked to a pharmacy" - exactly the error reported from the product form for
/// a user whose `pharmacy_id` was set in the database all along.
///
/// All profile states are driven through [profileStateProvider], which exists as
/// that seam.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/profile.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderException;
import 'package:flutter_test/flutter_test.dart';

/// A profile whose pharmacy link is [pharmacyId].
Profile _profile(String? pharmacyId) => Profile(
  id: 'user-1',
  pharmacyId: pharmacyId,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// A container whose profile state is [state].
ProviderContainer _container(AsyncValue<Profile?> state) {
  final container = ProviderContainer(
    overrides: [profileStateProvider.overrideWithValue(state)],
  );
  addTearDown(container.dispose);
  return container;
}

/// Strips Riverpod's wrapper off [error], leaving what the app handled.
///
/// Reading a provider whose build threw raises a `ProviderException` around the
/// real failure. That is exactly what `describeError()` unwraps on screen, so
/// these tests unwrap the same way rather than asserting on the wrapper.
Object _unwrap(Object error) {
  var current = error;
  while (current is ProviderException) {
    current = current.exception;
  }
  return current;
}

/// The unwrapped exception [requirePharmacyIdProvider] throws for [state].
Object _thrownBy(AsyncValue<Profile?> state) {
  final container = _container(state);
  try {
    container.read(requirePharmacyIdProvider);
  } on Object catch (error) {
    return _unwrap(error);
  }
  fail('requirePharmacyId must not yield a scope for this state');
}

void main() {
  test('a still-loading profile is reported as loading, not as unlinked', () {
    // The reported bug in one assertion: this must not be `auth/no-pharmacy`.
    expect(
      _thrownBy(const AsyncLoading<Profile?>()),
      isA<AuthException>().having(
        (error) => error.code,
        'code',
        'auth/pharmacy-loading',
      ),
    );
  });

  test('a loaded profile yields its pharmacy id', () {
    final container = _container(AsyncData<Profile?>(_profile('ph-1')));

    expect(container.read(requirePharmacyIdProvider), 'ph-1');
  });

  test('a loaded profile with no pharmacy fails with the linking message', () {
    expect(
      _thrownBy(AsyncData<Profile?>(_profile(null))),
      isA<AuthException>()
          .having((error) => error.code, 'code', 'auth/no-pharmacy')
          .having(
            (error) => error.message,
            'message',
            'Your account is not linked to a pharmacy yet.',
          ),
    );
  });

  test('a failed profile read is reported as itself, not as a missing link', () {
    // A failed read and an unlinked account need different fixes, so they must
    // not arrive as the same error.
    expect(
      _thrownBy(
        const AsyncError<Profile?>(
          ServerException(message: 'profile read failed'),
          StackTrace.empty,
        ),
      ),
      isA<ServerException>().having(
        (error) => error.message,
        'message',
        'profile read failed',
      ),
    );
  });
}
