/// Tests for the in-app notification row.
///
/// The columns are the API's, so what is worth asserting is the two things the
/// model decides rather than reads: that `read_at` is the *whole* read state, and
/// that the dispatch context is dug out of `data` rather than guessed at.
library;

import 'package:app/data/models/app_notification.dart';
import 'package:app/data/models/notification_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fromJson', () {
    test('reads a row as the API sends it', () {
      final notification = AppNotification.fromJson(<String, dynamic>{
        'id': 'n-1',
        'user_id': 'u-1',
        'pharmacy_id': 'p-1',
        'type': 'message',
        'title': 'Your order is ready',
        'message': 'Come and collect it.',
        'channel': 'in_app',
        'data': <String, dynamic>{'dispatch_channel': 'whatsapp'},
        'read_at': null,
        'created_at': '2026-09-19T10:00:00.000Z',
        'updated_at': '2026-09-19T10:00:00.000Z',
      });

      expect(notification.id, 'n-1');
      expect(notification.userId, 'u-1');
      expect(notification.pharmacyId, 'p-1');
      expect(notification.type, 'message');
      expect(notification.title, 'Your order is ready');
      expect(notification.message, 'Come and collect it.');
      expect(notification.channel, NotificationChannel.inApp);
      expect(notification.createdAt, DateTime.utc(2026, 9, 19, 10));
    });

    test(
      'an absent data column reads as an empty payload, not as a failure',
      () {
        final notification = AppNotification.fromJson(<String, dynamic>{
          'id': 'n-1',
          'user_id': 'u-1',
          'type': 'message',
          'message': 'Come and collect it.',
          'created_at': '2026-09-19T10:00:00.000Z',
          'updated_at': '2026-09-19T10:00:00.000Z',
        });

        expect(notification.data, isEmpty);
        expect(notification.title, isNull);
        expect(notification.pharmacyId, isNull);
        expect(notification.channel, NotificationChannel.inApp);
      },
    );

    test('a channel this build does not know reads as in-app', () {
      final notification = AppNotification.fromJson(<String, dynamic>{
        'id': 'n-1',
        'user_id': 'u-1',
        'type': 'message',
        'message': 'Come and collect it.',
        'channel': 'carrier_pigeon',
        'created_at': '2026-09-19T10:00:00.000Z',
        'updated_at': '2026-09-19T10:00:00.000Z',
      });

      expect(notification.channel, NotificationChannel.inApp);
    });
  });

  group('read state', () {
    test('a row with no read_at is unread', () {
      final notification = AppNotification.fromJson(<String, dynamic>{
        'id': 'n-1',
        'user_id': 'u-1',
        'type': 'message',
        'message': 'Come and collect it.',
        'created_at': '2026-09-19T10:00:00.000Z',
        'updated_at': '2026-09-19T10:00:00.000Z',
      });

      expect(notification.isRead, isFalse);
    });

    test('read_at is the whole read state, and copyWith keeps it', () {
      final notification = AppNotification.fromJson(<String, dynamic>{
        'id': 'n-1',
        'user_id': 'u-1',
        'type': 'message',
        'message': 'Come and collect it.',
        'read_at': '2026-09-19T11:00:00.000Z',
        'created_at': '2026-09-19T10:00:00.000Z',
        'updated_at': '2026-09-19T10:00:00.000Z',
      }).copyWith(readAt: DateTime(2026, 9, 19, 12));

      expect(notification.isRead, isTrue);
      expect(notification.readAt, DateTime(2026, 9, 19, 12));
    });
  });

  group('dispatchChannel', () {
    test('is read out of data when a dispatch wrote it', () {
      final notification = AppNotification.fromJson(<String, dynamic>{
        'id': 'n-1',
        'user_id': 'u-1',
        'type': 'message',
        'message': 'Come and collect it.',
        'data': <String, dynamic>{'dispatch_channel': 'email'},
        'created_at': '2026-09-19T10:00:00.000Z',
        'updated_at': '2026-09-19T10:00:00.000Z',
      });

      expect(notification.dispatchChannel, 'email');
    });

    test(
      'is null when nothing dispatched this notification, which is the usual case',
      () {
        final notification = AppNotification.fromJson(<String, dynamic>{
          'id': 'n-1',
          'user_id': 'u-1',
          'type': 'message',
          'message': 'Come and collect it.',
          'data': <String, dynamic>{'dispatch_channel': ''},
          'created_at': '2026-09-19T10:00:00.000Z',
          'updated_at': '2026-09-19T10:00:00.000Z',
        });

        expect(notification.dispatchChannel, isNull);
      },
    );
  });
}
