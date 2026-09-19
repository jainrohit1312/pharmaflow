/// Unit tests for the matcher's wire mapping.
///
/// These drive the pure functions the service is built from — the interesting
/// behaviour is not the HTTP call, which is a line, but what the app makes of what
/// comes back. Every code here was observed on the deployed functions:
/// `match-product`'s 200 (live, 2026-09-19) and `learn_product_aliases`'s envelope
/// (its SQL test), plus the refusals a gateway produces itself.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/errors/function_error.dart';
import 'package:app/services/match_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decodeProductMatches', () {
    test('reads a body the function promised', () {
      final matches = decodeProductMatches(<String, dynamic>{
        'matches': <dynamic>[
          <String, dynamic>{
            'raw_name': 'Dolo650Tab15s',
            'candidates': <dynamic>[
              <String, dynamic>{
                'product_id': 'p-1',
                'name': 'dolo 650',
                'reason': 'alias',
                'score': 1,
                'evidence': <String, dynamic>{
                  'alias_name': 'DOLO-650 TAB',
                  'supplier_scoped': true,
                },
              },
            ],
          },
        ],
        'meta': <String, dynamic>{'vector_used': true},
      });

      expect(matches.candidatesAt(0).single.productId, 'p-1');
      expect(matches.candidatesAt(0).single.evidence.supplierScoped, isTrue);
    });

    test('a body that is not an object is a server fault, not an empty answer', () {
      // "Nothing like this in your catalogue" and "the matcher answered nonsense"
      // are different situations, and only one of them is worth the user's time.
      expect(
        () => decodeProductMatches('the matcher said no'),
        throwsA(
          isA<ServerException>().having(
            (error) => error.code,
            'code',
            'unexpected_response',
          ),
        ),
      );
      expect(() => decodeProductMatches(null), throwsA(isA<ServerException>()));
    });
  });

  group('decodeLearnedAliases', () {
    test('reads the count the RPC answered with', () {
      expect(decodeLearnedAliases(<String, dynamic>{'learned': 0}), 0);
      expect(
        decodeLearnedAliases(<String, dynamic>{
          'learned': 3,
          'skipped': <dynamic>[],
        }),
        3,
      );
    });

    test('a reply that is not the envelope means nothing was recorded', () {
      expect(
        () => decodeLearnedAliases(<String, dynamic>{'ok': true}),
        throwsA(isA<ServerException>()),
      );
      expect(
        () => decodeLearnedAliases('Fine!'),
        throwsA(isA<ServerException>()),
      );
    });
  });

  group('matchException', () {
    test("keeps the function's own sentence and code", () {
      final error = matchException(<String, dynamic>{
        'error': <String, dynamic>{
          'code': 'internal',
          'message': 'The catalogue match failed: connection closed',
        },
      });

      expect(error, isA<ServerException>());
      expect(error.message, 'The catalogue match failed: connection closed');
      expect(error.code, 'internal');
    });

    test('a caller with no pharmacy is an auth failure', () {
      final error = matchException(<String, dynamic>{
        'error': <String, dynamic>{
          'code': 'unauthorized',
          'message': 'This account is not linked to a pharmacy yet.',
        },
      });

      expect(error, isA<AuthException>());
    });

    test('an empty line is a validation failure, in the server words', () {
      final error = matchException(<String, dynamic>{
        'error': <String, dynamic>{
          'code': 'invalid_request',
          'message': 'Send the lines of the bill to match.',
        },
      });

      expect(error, isA<ValidationException>());
      expect(error.message, 'Send the lines of the bill to match.');
    });

    test('a body the app cannot read falls back to its own sentence', () {
      // What a gateway rejection looks like: a body with no `error` object. The
      // status is kept in the code so the sentence can still be traced.
      final error = matchException('<html>502</html>', status: 502);

      expect(error, isA<ServerException>());
      expect(error.message, 'Unable to look for matches in the catalogue.');
      expect(error.code, 'http_502');
    });

    test('an error body that arrived as text is read anyway', () {
      final error = matchException(
        '{"error":{"code":"not_found","message":"No such endpoint."}}',
      );

      expect(error, isA<NotFoundException>());
      expect(error.message, 'No such endpoint.');
    });
  });

  group('functionException', () {
    test('is the one reader both features share', () {
      // The reader's `ocrException` is a thin name over this, so the two features
      // cannot describe the same function envelope in two different ways.
      final shared = functionException(<String, dynamic>{
        'error': <String, dynamic>{
          'code': 'provider_unavailable',
          'message': 'Busy.',
        },
      }, fallbackMessage: 'fallback');

      expect(shared, isA<ServerException>());
      expect(shared.code, 'provider_unavailable');
      expect(shared.message, 'Busy.');
    });
  });
}
