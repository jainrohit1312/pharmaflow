/// Tests for the follow-up questions.
///
/// One property matters, and it is the whole reason a follow-up is safe to offer: **a chip is a
/// promise.** The set of questions this feature can answer equals the set of reports it can run
/// (D-026), so a follow-up that is not one of the example questions would be a chip that comes
/// back as "I cannot answer that" - a promise this feature cannot keep, offered by it.
library;

import 'package:app/features/chatbot/presentation/chat_follow_ups.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every follow-up offered is a question this feature can answer', () {
    expect(
      chatFollowUps,
      isNotEmpty,
      reason:
          'a report with nothing to offer is a map entry that should not exist',
    );

    for (final entry in chatFollowUps.entries) {
      expect(
        entry.value,
        isNotEmpty,
        reason: '${entry.key} offers nothing, so it does not belong in the map',
      );
      for (final question in entry.value) {
        expect(
          chatExampleQuestions,
          contains(question),
          reason:
              '"$question" is offered under ${entry.key} but is not one of the closed set '
              'the classifier can answer',
        );
      }
    }
  });

  test('no report offers the question it just answered', () {
    // A chip that repeats what is already on screen would spend a model call to say the same
    // thing again (N-2), and the examples are one per report, so each report's own example is
    // the question to avoid.
    const byReport = <String, String>{
      'report_summary': 'How did last month go?',
      'low_stock_products': 'What is low on stock?',
      'expiring_batches': 'What is expiring soon?',
      'top_products': 'What sells best this month?',
      'dead_stock': 'What has stopped selling?',
    };

    for (final entry in chatFollowUps.entries) {
      expect(
        entry.value,
        isNot(contains(byReport[entry.key])),
        reason: '${entry.key} offers the question that produced its own answer',
      );
    }
  });

  test('every report the function can choose has something to offer', () {
    // Five reports (D-026) and no sixth: a report with no chips is not a bug, but a report
    // that was *forgotten* here is a feature that quietly does not appear.
    expect(
      chatFollowUps.keys,
      containsAll(<String>[
        'report_summary',
        'low_stock_products',
        'expiring_batches',
        'top_products',
        'dead_stock',
      ]),
    );
  });

  test('a refusal is offered nothing, and neither is an unknown report', () {
    // A refusal is a complete answer to a question outside the closed set; offering more of
    // the same would be offering what it just said it cannot do. A report this build does not
    // know shows no chips until the map names it, which is the safe direction.
    expect(followUpsFor(null), isEmpty);
    expect(followUpsFor('some_future_report'), isEmpty);
    expect(followUpsFor('low_stock_products'), isNotEmpty);
  });
}
