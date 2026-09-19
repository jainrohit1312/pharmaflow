/// Unit tests for the batch matcher's controller.
///
/// The controller is where three rules live, and this file is their evidence:
/// **one call for the whole bill**, **a failure is not an error state**, and **the
/// answer stays aligned with the lines that were sent** (including the blank ones,
/// which is what keeps a blank row from shifting every later line).
///
/// The provider is kept alive with `container.listen` wherever a test drives it
/// directly, the way `purchase_ocr_controller_test.dart` does: an unlistened
/// auto-dispose provider is disposed mid-flight, which measures disposal rather
/// than behaviour (D-034).
library;

import 'dart:async';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/product_match.dart';
import 'package:app/features/purchase_ocr/application/purchase_match_controller.dart';
import 'package:app/services/match_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_match_service.dart';

/// A container whose match controller is watched the way a screen watches it.
ProviderContainer pumpController({required FakeMatchService matcher}) {
  final container = ProviderContainer(
    // Not `<Override>[...]`: `Override` is not exported by `flutter_riverpod`,
    // so the list is inferred the way the other test apps infer theirs.
    overrides: [matchServiceProvider.overrideWithValue(matcher)],
  );
  addTearDown(container.dispose);
  container.listen(purchaseMatchControllerProvider, (_, __) {});
  return container;
}

void main() {
  test(
    'asks once for the whole bill, in the order the lines were given',
    () async {
      final matcher = FakeMatchService();
      final container = pumpController(matcher: matcher);

      final lines = <MatchLineRequest>[
        const MatchLineRequest(rawName: 'Dolo650Tab15s', supplierId: 'sup-1'),
        const MatchLineRequest(
          rawName: 'AMOXYCLAV 625 10S',
          supplierId: 'sup-1',
        ),
        const MatchLineRequest(rawName: 'Cetirizine 10', supplierId: 'sup-1'),
      ];
      await container
          .read(purchaseMatchControllerProvider.notifier)
          .matchBill(lines: lines);

      expect(
        matcher.matchCalls,
        hasLength(1),
        reason: 'twenty lines are one round trip and one embedding request',
      );
      expect(matcher.matchCalls.single, hasLength(3));
      expect(matcher.matchCalls.single.first.rawName, 'Dolo650Tab15s');
      expect(matcher.matchCalls.single.first.supplierId, 'sup-1');
    },
  );

  test('answers stay aligned by position, blank lines included', () async {
    final matcher = FakeMatchService()
      ..candidatesByLine = <List<MatchCandidate>>[
        <MatchCandidate>[buildCandidate('Dolo 650')],
        const <MatchCandidate>[],
        <MatchCandidate>[buildCandidate('Cetirizine 10')],
      ]
      ..meta = const MatchMeta(vectorUsed: true, embedded: 2);
    final container = pumpController(matcher: matcher);

    final answers = await container
        .read(purchaseMatchControllerProvider.notifier)
        .matchBill(
          lines: <MatchLineRequest>[
            const MatchLineRequest(rawName: 'Dolo650Tab15s'),
            // No text: still sent, so the third line's candidates do not slide
            // up into its place.
            const MatchLineRequest(),
            const MatchLineRequest(rawName: 'Cetzine 10mg'),
          ],
        );

    expect(answers, hasLength(3));
    expect(answers[0].candidates.single.name, 'Dolo 650');
    expect(answers[1].candidates, isEmpty);
    expect(answers[2].candidates.single.name, 'Cetirizine 10');
    expect(container.read(purchaseMatchControllerProvider).meta?.embedded, 2);
  });

  test('a failure is reported, not retried, and answers nothing', () async {
    final matcher = FakeMatchService();
    matcher.matchFailures.add(unreachableMatcherFailure());
    final container = pumpController(matcher: matcher);

    final answers = await container
        .read(purchaseMatchControllerProvider.notifier)
        .matchBill(
          lines: <MatchLineRequest>[const MatchLineRequest(rawName: 'Dolo')],
        );

    expect(answers, isEmpty, reason: 'no suggestion is not a failure');
    final state = container.read(purchaseMatchControllerProvider);
    expect(state.isMatching, isFalse);
    expect(state.hasFailure, isTrue);
    expect(state.error, isA<NetworkException>());

    // Nothing asks again by itself: the key is shared with the bill reader and the
    // per-minute budget buys nothing by being spent twice (D-036; the screen offers
    // a manual retry instead).
    await Future<void>.delayed(Duration.zero);
    expect(matcher.matchCalls, hasLength(1));
  });

  test(
    'a bill with nothing readable on it is not asked about at all',
    () async {
      final matcher = FakeMatchService();
      final container = pumpController(matcher: matcher);

      final answers = await container
          .read(purchaseMatchControllerProvider.notifier)
          .matchBill(
            lines: <MatchLineRequest>[
              const MatchLineRequest(),
              const MatchLineRequest(rawName: '   '),
            ],
          );

      expect(answers, isEmpty);
      expect(
        matcher.matchCalls,
        isEmpty,
        reason: 'an embedding request to be told nothing is a request wasted',
      );
      expect(
        container.read(purchaseMatchControllerProvider).hasFailure,
        isFalse,
      );
    },
  );

  test("the server's warnings come back with the answer", () async {
    final matcher = FakeMatchService()
      ..meta = const MatchMeta(
        warnings: <String>[
          'The lines could not be embedded (the model is busy), so they were matched by name and alias only.',
        ],
      );
    final container = pumpController(matcher: matcher);

    await container
        .read(purchaseMatchControllerProvider.notifier)
        .matchBill(
          lines: <MatchLineRequest>[const MatchLineRequest(rawName: 'Dolo')],
        );

    final state = container.read(purchaseMatchControllerProvider);
    expect(state.hasWarnings, isTrue);
    expect(state.meta!.vectorUsed, isFalse);
    expect(state.hasFailure, isFalse);
  });

  test('a screen that goes away mid-flight is not written to', () async {
    // D-034: an answer that arrives after the provider is disposed must not be
    // assigned. The gate holds the call open while the container is disposed.
    final matcher = FakeMatchService()..gate = Completer<void>();
    final container = ProviderContainer(
      overrides: [matchServiceProvider.overrideWithValue(matcher)],
    );

    final future = container
        .read(purchaseMatchControllerProvider.notifier)
        .matchBill(
          lines: <MatchLineRequest>[const MatchLineRequest(rawName: 'Dolo')],
        );

    container.dispose();
    matcher.gate!.complete();

    expect(
      await future,
      isEmpty,
      reason: 'a discarded answer is the whole job at that point',
    );
  });
}
