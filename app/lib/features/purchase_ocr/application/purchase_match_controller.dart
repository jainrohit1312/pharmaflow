/// The suggestions for one bill: one batch call, asked for once, and never
/// something the screen has to wait for.
///
/// Three rules shape this file, and each one is a decision rather than a style:
///
///   1. **One call for the whole bill.** `match-product` embeds every line in one
///      request (D-036/D-037) because the model key is on a free tier shared with
///      the bill reader (N-2); a per-line loop would spend twenty requests on one
///      invoice.
///   2. **A failure is not an error state the screen blocks on.** No suggestion is
///      not a failure — the human picks from the catalogue exactly as they did
///      before this chunk existed — so a failure here is reported as "nothing to
///      suggest this time, and here is why", and the save never consults it.
///   3. **Nothing is retried automatically.** `isRetryableOcrError`'s lesson is
///      that a retry belongs where the user's job is blocked on the answer; here
///      it is not, and a silent retry would spend another embedding request from a
///      per-minute budget for a convenience the user did not ask for. The screen
///      offers a manual retry instead, so the choice to spend one is a human's.
library;

import 'package:app/data/models/product_match.dart';
import 'package:app/services/match_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'purchase_match_controller.g.dart';

/// What the screen can say about the last attempt to match a bill.
///
/// Kept about *the run* rather than about the answers: which candidate belongs to
/// which line is a mapping the screen owns (it is the only thing that knows which
/// slot is which), while "was it asked, did it fail, and what did it say about
/// itself" is the same answer for the whole bill.
class PurchaseMatchState {
  /// Creates a state.
  const PurchaseMatchState({this.isMatching = false, this.meta, this.error});

  /// Whether the matcher is being asked right now.
  ///
  /// The screen shows a word about this and nothing more: the form stays live, and
  /// a bill with twenty lines can be saved while this is still true.
  final bool isMatching;

  /// What the matcher said about the run itself (its warnings, and whether the
  /// vector leg ran at all).
  final MatchMeta? meta;

  /// Why the last attempt produced nothing.
  final Object? error;

  /// Whether the last attempt failed.
  bool get hasFailure => error != null;

  /// Whether the matcher said part of what it could have done was unavailable —
  /// a bill matched by name and alias only, because the embedding call failed
  /// (D-036). Worth a sentence: the suggestions are real, but they are narrower
  /// than usual, and a user who is not told would read "no suggestion" as "the
  /// catalogue does not have it".
  bool get hasWarnings => meta != null && meta!.warnings.isNotEmpty;
}

/// Asks the matcher about one bill's lines.
///
/// The tenant is deliberately not read here: the function derives the pharmacy
/// from the caller's own identity (D-004), so there is no tenant to scope by and
/// none travels.
@riverpod
class PurchaseMatchController extends _$PurchaseMatchController {
  @override
  PurchaseMatchState build() => const PurchaseMatchState();

  /// The candidates for [lines], **aligned by position with what was sent**.
  ///
  /// Returns an empty list when there was nothing to ask about or the attempt
  /// failed — never a partial answer, because a partial list would silently shift
  /// every later line onto the previous line's candidates. Positions are kept
  /// exactly as given: a line with no text is still sent, which is what keeps a
  /// blank row from moving every line after it.
  Future<List<ProductMatch>> matchBill({
    required List<MatchLineRequest> lines,
  }) async {
    // Nothing readable anywhere on the bill: asking would spend an embedding
    // request to be told nothing. Positions do not matter when no line has text.
    final askable = lines.any((line) => (line.rawName ?? '').trim().isNotEmpty);
    if (!askable) {
      state = const PurchaseMatchState();
      return const <ProductMatch>[];
    }

    state = const PurchaseMatchState(isMatching: true);

    try {
      final matches = await ref
          .read(matchServiceProvider)
          .matchBill(lines: lines);
      if (!ref.mounted) {
        return const <ProductMatch>[];
      }
      state = PurchaseMatchState(meta: matches.meta);
      return matches.lines;
    } on Object catch (error) {
      // A screen that navigated away stops watching this provider, and Riverpod
      // then disposes it: writing state afterwards would throw from a future
      // nobody is awaiting (D-034).
      if (!ref.mounted) {
        return const <ProductMatch>[];
      }
      state = PurchaseMatchState(error: error);
      return const <ProductMatch>[];
    }
  }
}
