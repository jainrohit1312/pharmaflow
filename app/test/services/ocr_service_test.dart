/// Unit tests for the bill reader's wire mapping.
///
/// These drive the two pure functions the service is built from, because the
/// interesting behaviour is not the HTTP call — that is one line — but what the
/// app makes of what comes back. Every code here was observed on the deployed
/// function in Chunk B1, including the ones the platform produced itself.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/services/ocr_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decodeOcrBill', () {
    test('reads a body the function promised', () {
      final bill = decodeOcrBill(<String, dynamic>{
        'document': <String, dynamic>{'invoice_no': 'INV-1'},
        'lines': <dynamic>[],
        'meta': <String, dynamic>{
          'warnings': <dynamic>['nothing to read'],
        },
      });

      expect(bill.document.invoiceNo, 'INV-1');
      expect(bill.meta.warnings, hasLength(1));
    });

    test(
      'a body that is not an object is a server fault, not an empty bill',
      () {
        expect(
          () => decodeOcrBill('the reader said no'),
          throwsA(
            isA<ServerException>().having(
              (error) => error.code,
              'code',
              'unexpected_response',
            ),
          ),
        );
        expect(() => decodeOcrBill(null), throwsA(isA<ServerException>()));
      },
    );
  });

  group('ocrException', () {
    /// The exception [body] produces.
    AppException from(Map<String, dynamic> body) =>
        ocrException(body, fallbackMessage: 'Unable to read that bill.');

    test("keeps the function's own sentence and code", () {
      final error = from(<String, dynamic>{
        'error': <String, dynamic>{
          'code': 'not_found',
          'message': 'That bill could not be read.',
        },
      });

      expect(error, isA<NotFoundException>());
      expect(error.message, 'That bill could not be read.');
      expect(error.code, 'not_found');
    });

    test('a bill the reader refused is a validation failure', () {
      for (final code in <String>[
        'invalid_request',
        'forbidden',
        'too_large',
      ]) {
        final error = from(<String, dynamic>{
          'error': <String, dynamic>{'code': code, 'message': 'No.'},
        });

        expect(error, isA<ValidationException>(), reason: code);
        expect(error.code, code);
      }
    });

    test('a caller with no pharmacy is an auth failure', () {
      final error = from(<String, dynamic>{
        'error': <String, dynamic>{
          'code': 'unauthorized',
          'message': 'This account is not linked to a pharmacy yet.',
        },
      });

      expect(error, isA<AuthException>());
      expect(error.message, 'This account is not linked to a pharmacy yet.');
    });

    test('a busy reader is a server failure carrying the retryable code', () {
      final error = from(<String, dynamic>{
        'error': <String, dynamic>{
          'code': 'provider_unavailable',
          'message':
              'The bill reader is busy right now. Try again in a moment.',
        },
      });

      expect(error, isA<ServerException>());
      expect(error.code, providerUnavailableOcrCode);
      expect(isRetryableOcrError(error), isTrue);
    });

    test('an error body that arrived as text is still read', () {
      final error = ocrException(
        '{"error":{"code":"not_found","message":"That bill could not be read."}}',
        fallbackMessage: 'Unable to read that bill.',
      );

      expect(error, isA<NotFoundException>());
      expect(error.code, 'not_found');
    });

    test('a body with no envelope falls back, and keeps the status', () {
      final error = ocrException(
        <String, dynamic>{'code': 'UNAUTHORIZED_NO_AUTH_HEADER'},
        fallbackMessage: 'Unable to read that bill.',
        status: 401,
      );

      expect(error.message, 'Unable to read that bill.');
      expect(error.code, 'http_401');
      expect(isRetryableOcrError(error), isFalse);
    });

    test('an unreadable body does not throw on the way out', () {
      final error = ocrException(
        'not json at all',
        fallbackMessage: 'Unable to read that bill.',
      );

      expect(error.message, 'Unable to read that bill.');
    });
  });

  group('isRetryableOcrError', () {
    test('a busy reader and an unreachable one are worth another try', () {
      expect(
        isRetryableOcrError(
          const ServerException(
            message: 'busy',
            code: providerUnavailableOcrCode,
          ),
        ),
        isTrue,
      );
      expect(
        isRetryableOcrError(
          const NetworkException(message: 'offline', code: unreachableOcrCode),
        ),
        isTrue,
      );
    });

    test('everything else will fail the same way twice', () {
      expect(
        isRetryableOcrError(
          const NotFoundException(message: 'gone', code: 'not_found'),
        ),
        isFalse,
      );
      expect(
        isRetryableOcrError(
          const ValidationException(message: 'too big', code: 'too_large'),
        ),
        isFalse,
      );
      expect(isRetryableOcrError(StateError('not an AppException')), isFalse);
      expect(isRetryableOcrError(null), isFalse);
    });
  });
}
