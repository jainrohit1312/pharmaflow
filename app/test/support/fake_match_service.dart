/// A [MatchService] that records what it was asked and can be told to fail.
///
/// The **batch** is the thing under test, so this fake records calls rather than
/// lines of them: a screen that asked once per line would satisfy every assertion
/// about the answers and fail the one that matters here — `matchCalls` has to be
/// one entry long for a bill, because the model key is on a free tier shared with
/// the bill reader (N-2, D-036).
///
/// Failures are listed per attempt rather than being one-shot, the same way
/// `FakePurchaseOcrRepository` does it: a list that runs out keeps using its last
/// entry, so `[failure]` is "fails for ever" and `[failure, null]` is "once".
library;

import 'dart:async';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/product_match.dart';
import 'package:app/services/match_service.dart';

/// A fake matcher and alias learner.
class FakeMatchService implements MatchService {
  /// One entry per line sent, in the order sent.
  ///
  /// A line past the end of this list is answered with no candidates, which is
  /// what a real matcher does when it has nothing to suggest.
  List<List<MatchCandidate>> candidatesByLine = <List<MatchCandidate>>[];

  /// What every successful answer says about the run.
  MatchMeta meta = const MatchMeta();

  /// Failures `matchBill` throws, one per call; `null` entries succeed.
  final List<Exception?> matchFailures = <Exception?>[];

  /// Failures `learnAliases` throws, one per call; `null` entries succeed.
  final List<Exception?> learnFailures = <Exception?>[];

  /// The lines of every `matchBill` call, in order.
  final List<List<MatchLineRequest>> matchCalls = <List<MatchLineRequest>>[];

  /// The aliases of every `learnAliases` call, in order.
  final List<List<ConfirmedAlias>> learnCalls = <List<ConfirmedAlias>>[];

  /// Held open to keep a call in flight while a test does something else.
  ///
  /// The save-while-matching rule cannot be asserted any other way: the screen has
  /// to be driven *during* the call.
  Completer<void>? gate;

  @override
  Future<ProductMatches> matchBill({
    required List<MatchLineRequest> lines,
  }) async {
    matchCalls.add(lines);

    final held = gate;
    if (held != null) {
      await held.future;
    }

    final failure = _next(matchFailures);
    if (failure != null) {
      throw failure;
    }

    return ProductMatches(
      lines: <ProductMatch>[
        for (var index = 0; index < lines.length; index++)
          ProductMatch(
            rawName: lines[index].rawName,
            candidates: index < candidatesByLine.length
                ? candidatesByLine[index]
                : const <MatchCandidate>[],
          ),
      ],
      meta: meta,
    );
  }

  @override
  Future<int> learnAliases({required List<ConfirmedAlias> aliases}) async {
    learnCalls.add(aliases);

    final failure = _next(learnFailures);
    if (failure != null) {
      throw failure;
    }
    return aliases.length;
  }

  /// The next scripted failure: consumed in order, and the last one repeats.
  Exception? _next(List<Exception?> queue) {
    if (queue.isEmpty) {
      return null;
    }
    if (queue.length == 1) {
      return queue.first;
    }
    return queue.removeAt(0);
  }
}

/// Builds a candidate the way the matcher would offer one.
///
/// The evidence follows the reason, because that is the contract the RPC keeps:
/// an alias carries the alias's spelling, a trigram hit carries the similarity,
/// and a vector hit carries the distance. A test that has to break that contract
/// can build a [MatchCandidate] by hand.
MatchCandidate buildCandidate(
  String name, {
  String? id,
  MatchReason reason = MatchReason.trigram,
  double score = 0.87,
  String? packSize,
  String? aliasName,
  bool supplierScoped = false,
}) => MatchCandidate(
  productId: id ?? 'id-$name',
  name: name,
  packSize: packSize,
  score: score,
  reason: reason,
  evidence: switch (reason) {
    MatchReason.alias => MatchEvidence(
      aliasName: aliasName,
      supplierScoped: supplierScoped,
    ),
    MatchReason.trigram => MatchEvidence(similarity: score),
    MatchReason.vector => MatchEvidence(distance: 1 - score),
    MatchReason.unknown => const MatchEvidence(),
  },
);

/// The failure a matcher that could not be reached produces.
NetworkException unreachableMatcherFailure() => const NetworkException(
  message: 'Could not reach the catalogue matcher. Check the connection.',
  code: 'unreachable',
);
