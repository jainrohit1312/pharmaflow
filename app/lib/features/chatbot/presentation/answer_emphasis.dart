/// The one piece of punctuation the assistant's sentences carry, and its reader.
///
/// A sentence written by `chat-sql-agent`'s `answer.ts` marks the part worth
/// pointing at with `**...**`: the figure an owner would circle, the product or
/// batch it belongs to, and any exception ("already expired 6 days ago"). The
/// alternative — a paragraph of uniform text — is what this feature was reported
/// for: the number is in there and nobody can find it.
///
/// **Nothing here decides what is worth pointing at.** The server writes the words,
/// the figures and the marker; this file only turns a marker into bold. That is
/// what keeps D-053 true — the model never produces a numeral, and the client never
/// composes a sentence — while the answer becomes readable.
///
/// Only `**` is understood, and deliberately:
///
///   - a single `*` is ordinary text, so a multiplication sign or an asterisk in a
///     batch number is safe;
///   - an unclosed `**` — one with no `**` to its right at all — is ordinary text,
///     so a half-written marker shows the reader the characters rather than
///     swallowing the rest of the sentence;
///   - an empty pair (`a****b`) is ordinary text too, so a marker can never bracket
///     nothing.
///
/// The marker is also read left to right and greedily: a stray `**` before a real
/// pair pairs with it. That is the shape a malformed sentence takes and nothing more
/// — the server never writes one — and it is why the rule worth stating is the one
/// above rather than "every unpaired marker stays literal".
///
/// The alternative — a general markdown renderer — would be a new dependency for
/// one marker's worth of job (and this project does not change its pinned
/// dependencies casually). The rules above exist so that the *worst* case is a
/// sentence that renders as the words it is made of.
library;

/// One run of an answer: plain text, or a part the server pointed at.
///
/// Deliberately a plain class with no equality of its own: this project's value
/// types are Freezed's, and a parser's output is read in order rather than compared
/// — the tests project [parseAnswerEmphasis] back into sentences and compare those
/// (see `answer_emphasis_test.dart`).
class AnswerRun {
  /// Creates a run.
  const AnswerRun(this.text, {this.isStrong = false});

  /// The words, with no marker in them.
  final String text;

  /// Whether this run is the part the server emphasised.
  final bool isStrong;
}

/// The marker `answer.ts` wraps an emphasised part in.
const String emphasisMarker = '**';

/// Splits [text] into its plain and emphasised runs, in order.
///
/// The runs put back together are exactly [text] with the pairs of markers removed:
/// no character is invented and none is lost except a `**` that had a partner
/// around non-empty text. A sentence with no marker comes back as the single plain
/// run it is, which is why nothing about an unmarked answer changes by being read
/// here.
List<AnswerRun> parseAnswerEmphasis(String text) {
  final runs = <AnswerRun>[];
  final plain = StringBuffer();

  void flushPlain() {
    if (plain.isNotEmpty) {
      runs.add(AnswerRun(plain.toString()));
      plain.clear();
    }
  }

  var index = 0;
  while (index < text.length) {
    final opening = text.indexOf(emphasisMarker, index);
    if (opening < 0) {
      plain.write(text.substring(index));
      break;
    }

    final afterOpening = opening + emphasisMarker.length;
    final closing = text.indexOf(emphasisMarker, afterOpening);

    if (closing < 0 || closing == afterOpening) {
      // Not an emphasis: the marker is text. Scanning resumes *after* it rather
      // than at it, so `****` cannot pair with itself and vanish.
      plain.write(text.substring(index, afterOpening));
      index = afterOpening;
      continue;
    }

    plain.write(text.substring(index, opening));
    flushPlain();
    runs.add(AnswerRun(text.substring(afterOpening, closing), isStrong: true));
    index = closing + emphasisMarker.length;
  }

  flushPlain();
  return runs;
}
