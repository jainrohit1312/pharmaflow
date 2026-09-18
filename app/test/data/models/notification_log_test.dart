/// Unit tests for [NotificationLog] decoding and its three enums.
library;

import 'package:app/data/models/notification_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NotificationLog.fromJson', () {
    test('decodes a snake_case notification_logs row', () {
      final log = NotificationLog.fromJson(<String, dynamic>{
        'id': 'nl-1',
        'pharmacy_id': 'ph-1',
        'notification_id': 'n-1',
        'recipient_type': 'supplier',
        'recipient_id': 'sup-1',
        'channel': 'whatsapp',
        'destination': '+910000000000',
        'subject': 'Purchase order',
        'body': 'Please supply the attached.',
        'status': 'sent',
        'provider': 'whatsapp_cloud',
        'provider_message_id': 'wamid.abc',
        'error': null,
        'created_by': 'u-1',
        'created_at': '2026-09-19T09:00:00Z',
        'updated_at': '2026-09-19T09:01:00Z',
      });

      expect(log.id, 'nl-1');
      expect(log.pharmacyId, 'ph-1');
      expect(log.notificationId, 'n-1');
      expect(log.recipientType, NotificationRecipientType.supplier);
      expect(log.recipientId, 'sup-1');
      expect(log.channel, NotificationChannel.whatsapp);
      expect(log.destination, '+910000000000');
      expect(log.status, NotificationStatus.sent);
      expect(log.provider, 'whatsapp_cloud');
      expect(log.providerMessageId, 'wamid.abc');
      expect(log.error, isNull);
      expect(log.createdBy, 'u-1');
    });

    test(
      'defaults a queued in-app dispatch with only its required columns',
      () {
        final log = NotificationLog.fromJson(<String, dynamic>{
          'id': 'nl-2',
          'pharmacy_id': 'ph-1',
          'created_at': '2026-09-19T09:00:00Z',
          'updated_at': '2026-09-19T09:00:00Z',
        });

        expect(log.recipientType, NotificationRecipientType.other);
        expect(log.channel, NotificationChannel.inApp);
        expect(log.status, NotificationStatus.queued);
        expect(log.destination, isNull);
        expect(log.status.isSettled, isFalse);
      },
    );
  });

  group('the enums', () {
    test('round-trip every literal through its DB value', () {
      for (final channel in NotificationChannel.values) {
        expect(notificationChannelFromDb(channel.dbValue), channel);
      }
      for (final status in NotificationStatus.values) {
        expect(notificationStatusFromDb(status.dbValue), status);
      }
      for (final type in NotificationRecipientType.values) {
        expect(notificationRecipientTypeFromDb(type.dbValue), type);
      }
    });

    test('in_app is the literal the channel column stores', () {
      expect(NotificationChannel.inApp.dbValue, 'in_app');
    });

    test('an unknown status reads as failed rather than sent', () {
      expect(notificationStatusFromDb('delivered'), NotificationStatus.failed);
      expect(notificationStatusFromDb(null), NotificationStatus.failed);
    });

    test('an unknown channel reads as in_app', () {
      expect(notificationChannelFromDb('telegram'), NotificationChannel.inApp);
    });

    test('isSettled is false only while queued', () {
      expect(NotificationStatus.queued.isSettled, isFalse);
      expect(NotificationStatus.sent.isSettled, isTrue);
      expect(NotificationStatus.failed.isSettled, isTrue);
      expect(NotificationStatus.skipped.isSettled, isTrue);
    });
  });
}
