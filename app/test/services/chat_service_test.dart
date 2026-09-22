/// Unit tests for the assistant's wire mapping and its answer's provenance.
///
/// These drive the pure functions the service is built from — the interesting
/// behaviour is not the HTTP call, which is a line, but what the app makes of what
/// comes back. Every body below is one of the shapes **recorded from the live
/// function** in E-part-1 (the four probe invocations), plus the refusals a gateway
/// produces itself.
///
/// The one thing this file exists to pin: **`rpc: null` is an answer.** A refusal
/// that read as a failure, or as a blank answer, would be the worst bug this
/// feature could ship — it would make a working chatbot look broken, or a broken one
/// look like it was working.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/errors/function_error.dart';
import 'package:app/data/models/chat_message.dart';
import 'package:app/data/models/chat_response.dart';
import 'package:app/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_chat_service.dart';

void main() {
  group('decodeChatAnswer', () {
    test('reads a report answer the function actually sent', () {
      final response = decodeChatAnswer(<String, dynamic>{
        'answer':
            '1 product is below its reorder level. The biggest gap is '
            '**dolo 650**: **20 units short** (0 in stock against a level of 20).',
        'rpc': 'low_stock_products',
        'params': <String, dynamic>{'p_limit': null},
        'data': <dynamic>[
          <String, dynamic>{
            'name': 'dolo 650',
            'shortfall': 20,
            'total_qty': 0,
            'min_stock_level': 20,
          },
        ],
        'meta': <String, dynamic>{
          'model': 'gemini-3.6-flash',
          'warnings': <dynamic>[],
        },
      });

      expect(response.hasReport, isTrue);
      expect(response.rpc, 'low_stock_products');
      expect(response.params, <String, Object?>{'p_limit': null});
      expect(response.model, 'gemini-3.6-flash');
      expect(response.warnings, isEmpty);
      // The report's own envelope, verbatim and un-modelled.
      expect(response.data, isA<List<dynamic>>());
    });

    test('a refusal is an answer: rpc null, no error, nothing to attribute', () {
      // The live probe's third invocation, verbatim. It is a 200, and reading it
      // as anything else is the failure this test exists to prevent.
      final response = decodeChatAnswer(<String, dynamic>{
        'answer':
            'I cannot answer that. I can answer questions about sales and '
            'purchases, stock levels, expiring batches, what sells best, and '
            'what has stopped selling.',
        'rpc': null,
        'params': <String, dynamic>{},
        'data': null,
        'meta': <String, dynamic>{
          'model': 'gemini-3.6-flash',
          'warnings': <dynamic>[],
        },
      });

      expect(response.hasReport, isFalse);
      expect(response.rpc, isNull);
      expect(response.data, isNull);
      expect(response.answer, startsWith('I cannot answer that.'));
      expect(
        describeAnswerOrigin(response),
        isNull,
        reason: 'a refusal came from no report, and its sentence is the answer',
      );
    });

    test('a body that is not an object is a fault, not an empty answer', () {
      // "I cannot answer that" and "the assistant answered nonsense" are different
      // situations, and only one of them is worth the user's time.
      expect(
        () => decodeChatAnswer('the assistant said no'),
        throwsA(
          isA<ServerException>().having(
            (error) => error.code,
            'code',
            'unexpected_response',
          ),
        ),
      );
      expect(() => decodeChatAnswer(null), throwsA(isA<ServerException>()));
      expect(
        () => decodeChatAnswer(<dynamic>['not', 'an', 'envelope']),
        throwsA(isA<ServerException>()),
      );
    });

    test('a body with no answer string is a fault too', () {
      // The blank bubble is the one wrong answer this feature could give: it would
      // look like the assistant had said nothing rather than like a defect.
      expect(
        () => decodeChatAnswer(<String, dynamic>{'rpc': 'top_products'}),
        throwsA(isA<ServerException>()),
      );
      expect(
        () => decodeChatAnswer(<String, dynamic>{'answer': 42}),
        throwsA(isA<ServerException>()),
        reason: 'a number is not a sentence',
      );
      expect(
        () => decodeChatAnswer(<String, dynamic>{'answer': '   '}),
        throwsA(isA<ServerException>()),
      );
    });

    test('the parts around the sentence are read defensively', () {
      final response = decodeChatAnswer(<String, dynamic>{
        'answer': 'Nothing sold between 2026-08-21 and 2026-09-19.',
        'rpc': 'top_products',
        // Not a map: nothing to read, and no reason to fail the answer over it.
        'params': 'p_limit=20',
        'meta': <String, dynamic>{
          'model': 'gemini-3.6-flash',
          'warnings': <dynamic>['', '  ', 7, 'The report ran.'],
        },
      });

      expect(response.params, isEmpty);
      expect(
        response.warnings,
        <String>['The report ran.'],
        reason: 'a warning is a sentence somebody wrote for a person',
      );
    });

    test('a response with no meta at all still reads', () {
      final response = decodeChatAnswer(<String, dynamic>{
        'answer': 'Nothing is below its reorder level.',
        'rpc': 'low_stock_products',
      });

      expect(response.model, isNull);
      expect(response.warnings, isEmpty);
      expect(response.params, isEmpty);
    });
  });

  group('chatException', () {
    test("keeps the function's own sentence and code", () {
      final error = chatException(<String, dynamic>{
        'error': <String, dynamic>{
          'code': 'internal',
          'message': 'The answer could not be read: connection closed',
        },
      });

      expect(error, isA<ServerException>());
      expect(error.message, 'The answer could not be read: connection closed');
      expect(error.code, 'internal');
    });

    test('a caller with no pharmacy is an auth failure', () {
      final error = chatException(<String, dynamic>{
        'error': <String, dynamic>{
          'code': 'unauthorized',
          'message': 'This account is not linked to a pharmacy yet.',
        },
      });

      expect(error, isA<AuthException>());
    });

    test('a question the function refused is a validation failure', () {
      final error = chatException(<String, dynamic>{
        'error': <String, dynamic>{
          'code': 'invalid_request',
          'message': 'That question is longer than 1000 characters.',
        },
      });

      expect(error, isA<ValidationException>());
      expect(error.message, 'That question is longer than 1000 characters.');
    });

    test('a busy model is a server failure in the server words', () {
      final error = chatException(<String, dynamic>{
        'error': <String, dynamic>{
          'code': 'provider_unavailable',
          'message': 'The model is busy right now.',
        },
      });

      expect(error, isA<ServerException>());
      expect(error.code, providerUnavailableChatCode);
      expect(error.message, 'The model is busy right now.');
    });

    test('a body the app cannot read falls back to its own sentence', () {
      // What a gateway rejection looks like: a body with no `error` object. The
      // status is kept in the code so the sentence can still be traced.
      final error = chatException('<html>502</html>', status: 502);

      expect(error, isA<ServerException>());
      expect(error.message, 'Unable to ask that question.');
      expect(error.code, 'http_502');
    });

    test('is the one reader every function shares', () {
      // Thin name over `functionException` (D-042), so the three features cannot
      // describe one envelope in three dialects.
      final shared = functionException(<String, dynamic>{
        'error': <String, dynamic>{'code': 'not_found', 'message': 'No such.'},
      }, fallbackMessage: 'fallback');

      expect(shared, isA<NotFoundException>());
      expect(shared.message, 'No such.');
    });
  });

  group('isRetryableChatError', () {
    test('a busy model and an unreachable one are worth another go', () {
      expect(isRetryableChatError(busyAssistantFailure()), isTrue);
      expect(
        isRetryableChatError(
          const NetworkException(message: 'gone', code: unreachableChatCode),
        ),
        isTrue,
      );
    });

    test('a refusal that will fail twice is not', () {
      expect(
        isRetryableChatError(
          const ValidationException(
            message: 'Too long.',
            code: 'invalid_request',
          ),
        ),
        isFalse,
      );
      expect(
        isRetryableChatError(
          const AuthException(message: 'No pharmacy.', code: 'unauthorized'),
        ),
        isFalse,
      );
      expect(isRetryableChatError('not an exception'), isFalse);
    });
  });

  group('describeAnswerOrigin', () {
    test('names the report that answered', () {
      expect(describeAnswerOrigin(buildChatAnswer()), 'Low stock products');
    });

    test('a report this app does not know is named, not dropped', () {
      expect(
        describeAnswerOrigin(buildChatAnswer(rpc: 'stock_ageing')),
        'stock_ageing',
      );
    });

    test('what was asked for, in words, with the blanks left out', () {
      // A null argument means the report's own default applied, and its sentence
      // already says what that default did — so it is not restated as a rule here.
      expect(
        describeAnswerOrigin(
          buildChatAnswer(
            rpc: 'top_products',
            params: const <String, Object?>{
              'p_from': '2026-08-21',
              'p_to': '2026-09-19',
              'p_limit': null,
              'p_metric': 'revenue',
            },
          ),
        ),
        'Top products · from 2026-08-21 · to 2026-09-19 · by revenue',
      );
    });

    test('a limit and a horizon read as the request they were', () {
      expect(
        describeAnswerOrigin(
          buildChatAnswer(
            rpc: 'expiring_batches',
            params: const <String, Object?>{'p_days': 90, 'p_limit': 5},
          ),
        ),
        'Expiring batches · within 90 days · at most 5 rows',
      );
    });

    test('an argument this app cannot name is still shown', () {
      expect(
        describeAnswerOrigin(
          buildChatAnswer(
            rpc: 'report_summary',
            params: const <String, Object?>{'p_branch': 'main'},
          ),
        ),
        'Report summary · branch main',
      );
    });

    test('the caveat a report states about itself reaches the reader', () {
      // D-053's whole point: `top_products` says in its own envelope that returns
      // are not netted, and no sentence anywhere says it. The note is where a
      // reader gets to see the rule.
      expect(
        describeAnswerOrigin(
          buildChatAnswer(
            rpc: 'top_products',
            data: <String, dynamic>{
              'meta': <String, dynamic>{
                'window_from': '2026-08-21',
                'window_to': '2026-09-19',
                'metric_used': 'units',
                'returns_not_netted': true,
                'limit': 20,
              },
              'rows': <dynamic>[],
            },
          ),
        ),
        'Top products · returns are not subtracted',
      );
    });

    test('a report whose meta says nothing extra adds nothing', () {
      expect(
        describeAnswerOrigin(
          buildChatAnswer(
            data: <String, dynamic>{
              'meta': <String, dynamic>{'limit': 50},
            },
          ),
        ),
        'Low stock products',
      );
    });

    test('the day a report meant by "today" reaches the reader', () {
      // The business clock (migration 20260922000050): every report that means "today"
      // resolved it in the pharmacy's own zone, and a period is meaningless without the
      // boundary it was cut at - so the envelope states it and this line shows it.
      expect(
        describeAnswerOrigin(
          buildChatAnswer(
            data: <String, dynamic>{
              'meta': <String, dynamic>{
                'rule': 'total_qty < min_stock_level',
                'as_of': '2026-09-22',
                'timezone': 'Asia/Kolkata',
                'total_count': 120,
                'returned_count': 1,
                'has_more': true,
              },
              'rows': <dynamic>[
                <String, dynamic>{'name': 'Dolo 650'},
              ],
            },
          ),
        ),
        'Low stock products · as of 2026-09-22 (Asia/Kolkata)',
      );
    });

    test('an envelopeless report_summary states its boundary too', () {
      // `report_summary` is a flat envelope - no `meta` - so its `as_of` sits beside its
      // `from` and `to`, and the same rule reads it.
      expect(
        describeAnswerOrigin(
          buildChatAnswer(
            rpc: 'report_summary',
            data: <String, dynamic>{
              'from': '2026-09-22',
              'to': '2026-09-22',
              'as_of': '2026-09-22',
              'timezone': 'Asia/Kolkata',
            },
          ),
        ),
        'Report summary · as of 2026-09-22 (Asia/Kolkata)',
      );
    });

    test(
      'a meta that is not a map, or a data that is a list, is not a crash',
      () {
        expect(
          describeAnswerOrigin(buildChatAnswer(data: 'no')),
          'Low stock products',
        );
        expect(
          describeAnswerOrigin(
            buildChatAnswer(data: <dynamic>[<String, dynamic>{}]),
          ),
          'Low stock products',
        );
      },
    );
  });

  group('reportLabel', () {
    test('names the five reports and nothing else', () {
      expect(reportLabel('report_summary'), 'Report summary');
      expect(reportLabel('low_stock_products'), 'Low stock products');
      expect(reportLabel('expiring_batches'), 'Expiring batches');
      expect(reportLabel('top_products'), 'Top products');
      expect(reportLabel('dead_stock'), 'Dead stock');
    });

    test('no report and a blank name both read as none', () {
      expect(reportLabel(null), isNull);
      expect(reportLabel('   '), isNull);
      expect(reportLabel(''), isNull);
    });
  });

  group('chatHistoryFor', () {
    test('a short conversation travels whole', () {
      final turns = <ChatMessage>[
        ChatMessage.question('one'),
        ChatMessage.answer(buildChatAnswer()),
      ];

      expect(chatHistoryFor(turns), turns);
    });

    test('a long one travels as its last six turns', () {
      // The bound is what keeps a request body flat and a prompt bounded, and the
      // function trims to the same number of its own accord.
      final turns = <ChatMessage>[
        for (var index = 1; index <= 8; index++)
          ChatMessage.question('q$index'),
      ];

      final sent = chatHistoryFor(turns);
      expect(chatHistoryTurns, 6);
      expect(sent, hasLength(6));
      expect(sent.first.text, 'q3');
      expect(sent.last.text, 'q8');
    });
  });

  group('ChatMessage', () {
    test(
      'a question and an answer travel as the history the function reads',
      () {
        final question = ChatMessage.question('What is low on stock?');
        final answer = ChatMessage.answer(buildChatAnswer());

        expect(question.toJson(), <String, dynamic>{
          'role': 'user',
          'text': 'What is low on stock?',
        });
        expect(answer.toJson(), <String, dynamic>{
          'role': 'model',
          'text': 'Nothing is below its reorder level.',
        });
        expect(
          answer.response,
          isNotNull,
          reason: 'the envelope stays with the answer it produced',
        );
      },
    );

    test('a refusal is a message like any other', () {
      final refusal = ChatMessage.answer(buildChatRefusal());

      expect(refusal.isQuestion, isFalse);
      expect(refusal.response!.hasReport, isFalse);
      expect(refusal.text, buildChatRefusal().answer);
    });
  });
}
