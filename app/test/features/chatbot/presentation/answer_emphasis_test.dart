/// Unit tests for the reader of the server's emphasis marker.
///
/// The property this file exists for: **the marker is decoration, and reading it can
/// only take the markers out.** Every run put back together is the original sentence
/// minus its `**` pairs — no character invented, none dropped except a marker that had
/// a partner around non-empty text. That is what makes it safe for the client to
/// render a sentence it did not write.
///
/// The other half is the failure direction: a sentence that is *not* shaped the way
/// `answer.ts` writes one — a single `*`, a half-written marker, an empty pair — comes
/// back as the characters it is made of rather than as a swallowed sentence or a bold
/// run of nothing.
///
/// The runs are read back as **the sentence with each emphasis re-marked**, which is
/// what makes one comparison say the whole parse: `**text**` on a strong run, bare
/// `text` on a plain one.
library;

import 'package:app/features/chatbot/presentation/answer_emphasis.dart';
import 'package:flutter_test/flutter_test.dart';

/// [sentence]'s runs, each emphasis marked the way the server wrote it.
///
/// A projection rather than an `==` on [AnswerRun], because a parser's output is
/// read in order: this reads as the sentence with its parts split out, which is the
/// thing under test.
List<String> markedRuns(String sentence) => parseAnswerEmphasis(sentence)
    .map(
      (run) =>
          run.isStrong ? '$emphasisMarker${run.text}$emphasisMarker' : run.text,
    )
    .toList();

void main() {
  test('a sentence with no marker is one plain run', () {
    expect(markedRuns('Nothing is below its reorder level.'), <String>[
      'Nothing is below its reorder level.',
    ]);
  });

  test(
    'a marked part comes back as its own run, in the order it was written',
    () {
      expect(
        markedRuns('The biggest gap is **Dolo 650**: **40 units short**.'),
        <String>[
          'The biggest gap is ',
          '**Dolo 650**',
          ': ',
          '**40 units short**',
          '.',
        ],
      );
    },
  );

  test('a whole sentence can be the emphasised part', () {
    expect(markedRuns('**already expired 6 days ago**'), <String>[
      '**already expired 6 days ago**',
    ]);
  });

  test(
    'adjacent runs stay separate, so the space between them is not bold',
    () {
      expect(markedRuns('**a** **b**'), <String>['**a**', ' ', '**b**']);
    },
  );

  test('reading a sentence only ever takes the markers out', () {
    // The general rule, over the shapes the server actually writes.
    const sentences = <String>[
      'Nothing is below its reorder level.',
      '12 sales for **₹45230.00**, ₹40000.00 collected and **₹5230.00** still due.',
      'The biggest gap is **Dolo 650**: **40 units short** (10 in stock against a level of 50).',
      'The soonest is **Amoxy 500** batch A-9, **6 days left** (2026-09-28) - 12 units on the shelf.',
      'No batches expire within 30 days.',
    ];
    const long =
        'By units sold, between 2026-08-21 and 2026-09-19 the top seller is **Dolo 650**: '
        '**120 units** for **₹6000.00**. Next is Crocin with 80 units.';

    for (final sentence in <String>[...sentences, long]) {
      final runs = parseAnswerEmphasis(sentence);

      expect(
        runs.map((run) => run.text).join(),
        sentence.replaceAll(emphasisMarker, ''),
        reason: 'runs must rebuild the sentence with the markers taken out',
      );
      expect(
        runs.any((run) => run.text.isEmpty),
        isFalse,
        reason: 'a run of nothing is not a run',
      );
    }
  });

  test('a single asterisk is ordinary text, not a marker', () {
    // A batch number or a multiplication sign must not turn into emphasis.
    expect(markedRuns('Crocin 2 * 3 pack'), <String>['Crocin 2 * 3 pack']);
  });

  test('an unclosed marker is text, so the sentence is not half-swallowed', () {
    expect(markedRuns('a ** b'), <String>['a ** b']);
    expect(markedRuns('**Dolo'), <String>['**Dolo']);
  });

  test('an empty pair is text too: a marker never brackets nothing', () {
    expect(markedRuns('a****b'), <String>['a****b']);
    expect(markedRuns('**'), <String>['**']);
  });

  test(
    'a trailing stray marker stays literal while the real pair is still read',
    () {
      expect(markedRuns('**b** **'), <String>['**b**', ' **']);
    },
  );
}
