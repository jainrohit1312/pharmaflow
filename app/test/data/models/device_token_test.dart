/// Unit tests for [DeviceToken] decoding and the platform enum round-trip.
library;

import 'package:app/data/models/device_token.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceToken.fromJson', () {
    test('decodes a snake_case device_tokens row', () {
      final token = DeviceToken.fromJson(<String, dynamic>{
        'id': 'dt-1',
        'pharmacy_id': 'ph-1',
        'user_id': 'u-1',
        'platform': 'android',
        'token': 'fcm-token-abc',
        'is_active': false,
        'last_seen_at': '2026-09-19T10:00:00Z',
        'created_at': '2026-09-19T09:00:00Z',
        'updated_at': '2026-09-19T10:00:00Z',
      });

      expect(token.id, 'dt-1');
      expect(token.pharmacyId, 'ph-1');
      expect(token.userId, 'u-1');
      expect(token.platform, DevicePlatform.android);
      expect(token.token, 'fcm-token-abc');
      expect(token.isActive, isFalse);
      expect(token.lastSeenAt, DateTime.utc(2026, 9, 19, 10));
    });

    test('defaults a row that omits the platform and the active flag', () {
      final token = DeviceToken.fromJson(<String, dynamic>{
        'id': 'dt-2',
        'pharmacy_id': 'ph-1',
        'user_id': 'u-1',
        'token': 'fcm-token-def',
        'last_seen_at': '2026-09-19T10:00:00Z',
        'created_at': '2026-09-19T09:00:00Z',
        'updated_at': '2026-09-19T10:00:00Z',
      });

      expect(token.platform, DevicePlatform.web);
      expect(token.isActive, isTrue);
    });
  });

  group('DevicePlatform', () {
    test('round-trips every literal through its DB value', () {
      for (final platform in DevicePlatform.values) {
        expect(devicePlatformFromDb(platform.dbValue), platform);
      }
    });

    test('reads a literal case-insensitively and falls back to web', () {
      expect(devicePlatformFromDb('ANDROID'), DevicePlatform.android);
      expect(devicePlatformFromDb('solaris'), DevicePlatform.web);
      expect(devicePlatformFromDb(null), DevicePlatform.web);
    });

    test(
      'every platform has a label, and the awkward ones read as intended',
      () {
        for (final platform in DevicePlatform.values) {
          expect(platform.label, isNotEmpty);
        }
        expect(DevicePlatform.ios.label, 'iOS');
        expect(DevicePlatform.macos.label, 'macOS');
      },
    );
  });
}
