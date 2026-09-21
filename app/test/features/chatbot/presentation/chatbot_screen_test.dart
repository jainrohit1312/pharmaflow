/// Widget tests for the chatbot screen.
///
/// This file pins the four situations the screen exists to keep apart, which is
/// T-5's lesson where it costs the most — every one of them is a question with
/// something underneath it, and getting them confused is how a working assistant
/// looks broken or a broken one looks like it is working:
///
///   - **nothing asked yet** is an invitation, not a spinner and not an error;
///   - **still waiting** is a question with a spinner, and claims nothing;
///   - **no answer to that** is the server's refusal sentence in an ordinary answer
///     bubble — prose, no error, nothing to retry;
///   - **could not ask** is an error icon, the server's own sentence, and the only
///     retry on the screen.
///
/// The screen is pumped on its own rather than through a router: nothing here
/// navigates, and GoRouter builds a route more than once before the first frame
/// settles, which is a class of surprise this file does not need.
library;

import 'dart:async';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/features/chatbot/presentation/chatbot_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/chatbot_test_app.dart';
import '../../../support/fake_chat_service.dart';

/// The text of every run this screen renders in bold, in order.
///
/// Only an answer builds a `TextSpan` — a question is a plain `Text` — so this can
/// never pick up the user's own words. That is the point of it: the two tests below
/// are about *where* the bold is allowed to come from.
List<String> boldRuns(WidgetTester tester) {
  final bold = <String>[];
  for (final text in tester.widgetList<Text>(
    find.byWidgetPredicate(
      (widget) => widget is Text && widget.textSpan != null,
    ),
  )) {
    text.textSpan!.visitChildren((span) {
      if (span is TextSpan && span.style?.fontWeight == FontWeight.bold) {
        bold.add(span.text ?? '');
      }
      return true;
    });
  }
  return bold;
}

void main() {
  testWidgets('an empty conversation is an invitation, not an error or a wait', (
    tester,
  ) async {
    await pumpChatbotApp(tester, service: FakeChatService());

    expect(find.text('Ask about this pharmacy'), findsOneWidget);
    // The examples are the honest way to say what this can answer: the questions it
    // can answer *are* the reports it can run (D-026).
    for (final question in chatExampleQuestions) {
      expect(
        find.widgetWithText(ActionChip, question),
        findsOneWidget,
        reason: '$question must be offered as a way in',
      );
    }

    // Neither of the two things an empty history is *not*.
    expect(find.byType(ErrorView), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Still waiting for an answer…'), findsNothing);
  });

  testWidgets('an example question is asked as it stands', (tester) async {
    final assistant = FakeChatService();
    await pumpChatbotApp(tester, service: assistant);

    await tester.tap(
      find.widgetWithText(ActionChip, chatExampleQuestions.first),
    );
    await tester.pumpAndSettle();

    expect(assistant.questions, <String>[chatExampleQuestions.first]);
    expect(find.text(chatExampleQuestions.first), findsOneWidget);
  });

  testWidgets('a typed question is asked, and the input gives up its text', (
    tester,
  ) async {
    final assistant = FakeChatService();
    await pumpChatbotApp(tester, service: assistant);

    expect(
      tester
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Ask'))
          .onPressed,
      isNull,
      reason: 'there is nothing to ask yet',
    );

    await askQuestion(tester, '  What is low on stock?  ');
    await tester.pumpAndSettle();

    expect(assistant.questions, <String>[
      'What is low on stock?',
    ], reason: 'the question is trimmed, and asked once');
    expect(
      find.text('What is low on stock?'),
      findsOneWidget,
      reason: 'the question is in the transcript',
    );
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      isEmpty,
      reason: 'the input has been taken, not left holding what was sent',
    );
  });

  testWidgets('an answer renders the sentence and where it came from', (
    tester,
  ) async {
    final assistant = FakeChatService()
      ..answer = buildChatAnswer(
        answer: '1 product is below its reorder level.',
        data: <String, dynamic>{'rows': <dynamic>[]},
      );
    await pumpChatbotApp(tester, service: assistant);

    await askQuestion(tester, 'What is low on stock?');
    await tester.pumpAndSettle();

    expect(find.text('1 product is below its reorder level.'), findsOneWidget);
    expect(
      find.text('Low stock products'),
      findsOneWidget,
      reason: 'the note names the report and what it was asked for (D-053)',
    );
    expect(find.byType(ErrorView), findsNothing);
  });

  testWidgets('an answer points at its finding, and shows no marker doing it', (
    tester,
  ) async {
    final assistant = FakeChatService()
      ..answer = buildChatAnswer(
        answer:
            'The biggest gap is **Dolo 650**: **40 units short** '
            '(10 in stock against a level of 50).',
      );
    await pumpChatbotApp(tester, service: assistant);

    await askQuestion(tester, 'What is low on stock?');
    await tester.pumpAndSettle();

    // The reader gets the sentence, not the punctuation that shaped it: what the
    // server marked is bold, and what it marked *with* is nowhere on screen.
    expect(
      find.text(
        'The biggest gap is Dolo 650: 40 units short '
        '(10 in stock against a level of 50).',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('**', findRichText: true),
      findsNothing,
      reason:
          'the marker is the server talking to this widget, not to a person',
    );
    expect(boldRuns(tester), <String>['Dolo 650', '40 units short']);
  });

  testWidgets("a question is the user's own words, never markup", (
    tester,
  ) async {
    final assistant = FakeChatService();
    await pumpChatbotApp(tester, service: assistant);

    await askQuestion(tester, 'is **Dolo 650** low?');
    await tester.pumpAndSettle();

    // Nothing the user types can reach the answer's styling: the question is shown
    // exactly as it was written, asterisks and all, and it is not bold. Otherwise a
    // user could make their own words look like something the server said.
    expect(find.text('is **Dolo 650** low?'), findsOneWidget);
    expect(boldRuns(tester), isEmpty);
  });

  testWidgets("the server's own warnings show beside the sentence", (
    tester,
  ) async {
    const warning =
        'The report ran, but its answer came back in a shape this app does not '
        'understand.';
    final assistant = FakeChatService()
      ..answer = buildChatAnswer(warnings: <String>[warning]);
    await pumpChatbotApp(tester, service: assistant);

    await askQuestion(tester, 'What is low on stock?');
    await tester.pumpAndSettle();

    expect(
      find.text(warning),
      findsOneWidget,
      reason: 'a degraded answer must not look like a normal one',
    );
  });

  testWidgets('waiting for an answer looks like neither an answer nor a fault', (
    tester,
  ) async {
    final assistant = FakeChatService()..gate = Completer<void>();
    await pumpChatbotApp(tester, service: assistant);

    await askQuestion(tester, 'What is low on stock?');
    // `pump`, never `pumpAndSettle`: the spinner animates while the call is open,
    // which is exactly the state being looked at.
    await tester.pump();

    expect(find.text('What is low on stock?'), findsOneWidget);
    expect(find.text('Still waiting for an answer…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // Nothing is claimed yet: not an answer, and not a failure either.
    expect(find.byType(ErrorView), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.text('Ask again'), findsNothing);
    expect(
      find.text('Ask about this pharmacy'),
      findsNothing,
      reason: 'a conversation has started, so the invitation is not the state',
    );

    assistant.gate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('Still waiting for an answer…'), findsNothing);
    expect(find.text(assistant.answer.answer), findsOneWidget);
    expect(
      find.text('Low stock products'),
      findsOneWidget,
      reason: 'the note arrives with the sentence it belongs to',
    );
  });

  testWidgets('a failure shows its own sentence, a retry, and nothing else', (
    tester,
  ) async {
    final assistant = FakeChatService()..failures.add(busyAssistantFailure());
    await pumpChatbotApp(tester, service: assistant);

    await askQuestion(tester, 'What is low on stock?');
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(
      find.text(busyAssistantFailure().message),
      findsOneWidget,
      reason: "the server's own words, verbatim (D-042)",
    );
    expect(find.text('Ask again'), findsOneWidget);
    expect(
      find.text('The assistant was busy, not beaten — worth another go.'),
      findsOneWidget,
      reason: 'a 503 is worth a second attempt and the screen says so',
    );
    // The question stays on screen: a failure is about *this* question.
    expect(find.text('What is low on stock?'), findsOneWidget);
    // And it is not an answer: no prose bubble, no note.
    expect(find.text('Low stock products'), findsNothing);
  });

  testWidgets('a failure that will fail twice is not called worth retrying', (
    tester,
  ) async {
    final assistant = FakeChatService()
      ..failures.add(
        const ValidationException(
          message: 'That question is longer than 1000 characters.',
          code: 'invalid_request',
        ),
      );
    await pumpChatbotApp(tester, service: assistant);

    await askQuestion(tester, 'a very long question indeed');
    await tester.pumpAndSettle();

    expect(
      find.text('That question is longer than 1000 characters.'),
      findsOneWidget,
    );
    expect(
      find.text('The assistant was busy, not beaten — worth another go.'),
      findsNothing,
    );
    expect(
      find.text('Ask again'),
      findsOneWidget,
      reason: 're-asking is the only action a failure leaves a user',
    );
  });

  testWidgets('the retry asks the same question again and the answer lands', (
    tester,
  ) async {
    final assistant = FakeChatService()
      ..failures.addAll(<Exception?>[unreachableAssistantFailure(), null]);
    await pumpChatbotApp(tester, service: assistant);

    await askQuestion(tester, 'What is low on stock?');
    await tester.pumpAndSettle();
    expect(find.text('Ask again'), findsOneWidget);

    await tester.tap(find.text('Ask again'));
    await tester.pumpAndSettle();

    expect(
      assistant.questions,
      <String>['What is low on stock?', 'What is low on stock?'],
      reason:
          'the retry is the same question, and one more call - not a new one',
    );
    expect(find.text('Ask again'), findsNothing);
    expect(find.text(assistant.answer.answer), findsOneWidget);
    expect(
      find.text('What is low on stock?'),
      findsOneWidget,
      reason: 'the question appears once, not twice',
    );
  });

  testWidgets('a refusal and a failure never look alike', (tester) async {
    // Both on screen at once, in one conversation: the strongest form of the
    // assertion this screen exists for.
    final assistant = FakeChatService()
      ..answer = buildChatRefusal()
      ..failures.addAll(<Exception?>[
        null,
        unreachableAssistantFailure(),
        null,
      ]);
    await pumpChatbotApp(tester, service: assistant);

    await askQuestion(tester, 'what is the weather in Mumbai?');
    await tester.pumpAndSettle();
    expect(find.text(buildChatRefusal().answer), findsOneWidget);

    await askQuestion(tester, 'and tomorrow?');
    await tester.pumpAndSettle();

    // The refusal: prose, and nothing offered.
    expect(find.text(buildChatRefusal().answer), findsOneWidget);
    expect(
      find.text('Low stock products'),
      findsNothing,
      reason: 'a refusal came from no report, so there is nothing to attribute',
    );

    // The failure: an error, the sentence, and a retry - exactly one of each,
    // because only one turn failed.
    expect(find.text(unreachableAssistantFailure().message), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('Ask again'), findsOneWidget);
    expect(
      find.text('Still waiting for an answer…'),
      findsNothing,
      reason: 'nothing is in flight once the failure has landed',
    );
  });
}
