/// Unit tests for the matcher's wire model.
///
/// The bodies here are the ones observed on the deployed function: the first test
/// decodes, verbatim, the 200 that `match-product` answered for a real pharmacy's
/// catalogue on 2026-09-19 —
///
///   {"matches":[{"raw_name":"Dolo650Tab15s","candidates":[{"name":"dolo 650",
///     "score":0.4545,"reason":"trigram","evidence":{"similarity":0.4545},
///     "is_active":true,"pack_size":"15","product_id":"1ac034e9-…",
///     "generic_name":"paracetamol"}]}, …],
///    "meta":{"model":"gemini-embedding-001","line_count":3,"embedded":3,
///            "vector_used":true,"warnings":[]}}
///
/// — so the app is tested against the shape it actually receives rather than one
/// it wishes it received.
library;

import 'package:app/data/models/product_match.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_match_service.dart';

void main() {
  group('ProductMatches.fromJson', () {
    test('reads the body the deployed function answered with', () {
      final matches = ProductMatches.fromJson(<String, dynamic>{
        'matches': <dynamic>[
          <String, dynamic>{
            'raw_name': 'Dolo650Tab15s',
            'candidates': <dynamic>[
              <String, dynamic>{
                'name': 'dolo 650',
                'score': 0.4545,
                'reason': 'trigram',
                'evidence': <String, dynamic>{'similarity': 0.4545},
                'is_active': true,
                'pack_size': '15',
                'product_id': '1ac034e9-ac20-4754-8592-45276b3ca671',
                'generic_name': 'paracetamol',
              },
            ],
          },
          // A line the matcher had nothing for keeps its own empty entry: that is
          // what makes the answer line up with the bill, position for position.
          <String, dynamic>{
            'raw_name': 'AMOXYCLAV 625 10S',
            'candidates': <dynamic>[],
          },
        ],
        'meta': <String, dynamic>{
          'model': 'gemini-embedding-001',
          'line_count': 2,
          'embedded': 2,
          'vector_used': true,
          'warnings': <dynamic>[],
        },
      });

      expect(matches.lines, hasLength(2));
      expect(matches.meta.model, 'gemini-embedding-001');
      expect(matches.meta.vectorUsed, isTrue);
      expect(matches.meta.embedded, 2);

      final candidate = matches.candidatesAt(0).single;
      expect(candidate.productId, '1ac034e9-ac20-4754-8592-45276b3ca671');
      expect(candidate.name, 'dolo 650');
      expect(candidate.genericName, 'paracetamol');
      expect(candidate.packSize, '15');
      expect(candidate.score, 0.4545);
      expect(candidate.reason, MatchReason.trigram);
      expect(candidate.evidence.similarity, 0.4545);

      expect(matches.candidatesAt(1), isEmpty);
      expect(matches.isEmpty, isFalse);
    });

    test('a line with nothing suggested is empty, not a failure', () {
      final matches = ProductMatches.fromJson(<String, dynamic>{
        'matches': <dynamic>[
          <String, dynamic>{
            'raw_name': 'ZZQQ nonsense 9999',
            'candidates': <dynamic>[],
          },
        ],
      });

      expect(matches.isEmpty, isTrue);
      expect(matches.meta.warnings, isEmpty);
    });

    test('tolerates what the function might send anyway', () {
      // A body with no `matches`, a `matches` that is not a list, an entry that is
      // not an object, a candidate with no product id, and a similarity that
      // arrived as text. None of it may throw: a matcher that produced an error
      // from a shape it did not expect would take a saveable bill down with it.
      final matches = ProductMatches.fromJson(<String, dynamic>{
        'matches': <dynamic>[
          'not a line',
          <String, dynamic>{
            'raw_name': 'x',
            'candidates': <dynamic>[
              'nor this',
              <String, dynamic>{'name': 'no id here'},
              <String, dynamic>{
                'product_id': 'p-1',
                'reason': 'trigram',
                'evidence': <String, dynamic>{'similarity': '0.9'},
              },
            ],
          },
        ],
      });

      expect(matches.lines, hasLength(1));
      expect(matches.candidatesAt(0), hasLength(1));
      expect(matches.candidatesAt(0).single.productId, 'p-1');
      expect(matches.candidatesAt(0).single.reasonLabel, '90% similar');

      expect(
        ProductMatches.fromJson(<String, dynamic>{'matches': 'no'}).lines,
        isEmpty,
      );
    });

    test('a position past the end has no candidates', () {
      final matches = ProductMatches.fromJson(<String, dynamic>{});

      expect(matches.candidatesAt(0), isEmpty);
      expect(matches.candidatesAt(-1), isEmpty);
    });
  });

  group('MatchCandidate.reasonLabel', () {
    test('an alias names the text it was learned from', () {
      final candidate = buildCandidate(
        'Dolo 650',
        reason: MatchReason.alias,
        score: 1,
        aliasName: 'DOLO-650 TAB',
      );

      expect(candidate.reasonLabel, 'Also called DOLO-650 TAB');
    });

    test('an alias whose own name is the product says so instead', () {
      // The mapping exists, but there is nothing to tell the user: the catalogue
      // and the invoice agree on the spelling.
      final candidate = buildCandidate(
        'Dolo 650',
        reason: MatchReason.alias,
        score: 1,
        aliasName: 'dolo 650',
      );

      expect(candidate.reasonLabel, 'You matched this text before');
    });

    test('a trigram hit carries its number', () {
      expect(
        buildCandidate('Dolo 650', score: 0.4545).reasonLabel,
        '45% similar',
      );
      expect(
        buildCandidate('Amoxyclav 625', score: 0.778).reasonLabel,
        '78% similar',
      );
    });

    test('a vector hit says what it is without inventing a number', () {
      // A cosine similarity is not a spelling similarity, and dressing one up as
      // "87% similar" beside a trigram hit would make two different claims look
      // like the same one.
      expect(
        buildCandidate(
          'Dolo 650',
          reason: MatchReason.vector,
          score: 0.88,
        ).reasonLabel,
        'Looks similar',
      );
    });

    test('a leg this app does not know still says something', () {
      expect(
        buildCandidate('Dolo 650', reason: MatchReason.unknown).reasonLabel,
        'Suggested',
      );
    });
  });

  group('MatchMeta', () {
    test('carries the sentences a screen has to show', () {
      final meta = MatchMeta.fromJson(<String, dynamic>{
        'warnings': <dynamic>[
          'The lines could not be embedded (the model was busy), so they were matched by name and alias only.',
          '',
          42,
        ],
      });

      expect(meta.warnings, hasLength(1));
      expect(
        meta.warnings.single,
        startsWith('The lines could not be embedded'),
      );
      expect(meta.vectorUsed, isFalse);
    });
  });
}
