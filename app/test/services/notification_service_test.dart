/// Tests for the Phase 5 notification service.
///
/// What this asserts is D-029's decision stated as behaviour: nothing throws, the
/// token is `null`, and a local notification is a call that completes without a
/// surface to show it on. That is the difference between this and the
/// `UnimplementedError` stub it replaced, and it is the difference every caller
/// would have had to work around.
library;

import 'package:app/services/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = UnavailableNotificationService();

  test(
    'init completes: there is no SDK, and awaiting it is not a mistake',
    () async {
      await expectLater(service.init(), completes);
    },
  );

  test('showing a local notification completes without showing one', () async {
    await expectLater(
      service.showLocal(
        title: 'Low stock',
        body: 'Dolo 650 is below its level.',
      ),
      completes,
    );
  });

  test(
    'a dropped local notification says so in debug, rather than silently',
    () async {
      // `debugPrint` is the hook Flutter routes its own debug output through, so
      // swapping it is how a test reads the line the app would print.
      final lines = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) {
          lines.add(message);
        }
      };
      addTearDown(() => debugPrint = original);

      await service.showLocal(
        title: 'Low stock',
        body: 'Dolo 650 is below its level.',
      );

      expect(lines, hasLength(1));
      expect(lines.single, contains('showLocal dropped "Low stock"'));
      expect(lines.single, contains('no local notification surface'));
    },
  );

  test(
    'there is no FCM token, and that is an answer rather than a failure',
    () async {
      expect(await service.getFcmToken(), isNull);
    },
  );

  test(
    'the provider hands out that implementation, and it behaves the same way',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final resolved = container.read(notificationServiceProvider);

      expect(resolved, isA<UnavailableNotificationService>());
      await expectLater(resolved.init(), completes);
      await expectLater(
        resolved.showLocal(
          title: 'Low stock',
          body: 'Dolo 650 is below its level.',
        ),
        completes,
      );
      expect(await resolved.getFcmToken(), isNull);
    },
  );
}
