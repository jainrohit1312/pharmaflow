/// Unit tests for the conversation's controller.
///
/// The controller is where three rules live, and this file is their evidence:
/// **one model call per user action**, **nothing retries on its own** (N-2/D-032),
/// and **a failure is not a message** — the structural difference between *"I
/// cannot answer that"*, which is an answer, and *"could not ask"*, which is a turn
/// that did not happen.
///
/// The provider is kept alive with `container.listen` wherever a test drives it
/// directly, the way `purchase_match_controller_test.dart` does: an unlistened
/// auto-dispose provider is disposed mid-flight, which measures disposal rather
/// than behaviour (D-034).
library;

import 'dart:async';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/features/chatbot/application/chat_controller.dart';
import 'package:app/services/chat_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_chat_service.dart';

/// A container whose chat controller is watched the way a screen watches it.
ProviderContainer pumpController({required FakeChatService assistant}) {
  final container = ProviderContainer(
    // Not `<Override>[...]`: `Override` is not exported by `flutter_riverpod`,
    // so the list is inferred the way the other test apps infer theirs.
    overrides: [chatServiceProvider.overrideWithValue(assistant)],
  );
  addTearDown(container.dispose);
  container.listen(chatControllerProvider, (_, __) {});
  return container;
}

/// The state the controller is holding.
ChatState stateOf(ProviderContainer container) =>
    container.read(chatControllerProvider);

/// The controller itself.
ChatController notifier(ProviderContainer container) =>
    container.read(chatControllerProvider.notifier);

void main() {
  test(
    'a question is asked once, and becomes a question and an answer',
    () async {
      final assistant = FakeChatService();
      final container = pumpController(assistant: assistant);

      await notifier(container).ask('What is low on stock?');

      expect(assistant.questions, <String>['What is low on stock?']);
      final state = stateOf(container);
      expect(state.isAsking, isFalse);
      expect(state.failure, isNull);
      expect(state.messages, hasLength(2));
      expect(state.messages.first.isQuestion, isTrue);
      expect(state.messages.first.text, 'What is low on stock?');
      expect(state.messages.last.isQuestion, isFalse);
      expect(state.messages.last.text, assistant.answer.answer);
      expect(state.isStarted, isTrue);
    },
  );

  test(
    'the next question carries the conversation so far as its history',
    () async {
      final assistant = FakeChatService();
      final container = pumpController(assistant: assistant);

      await notifier(container).ask('What is low on stock?');
      await notifier(container).ask('and what is expiring?');

      expect(assistant.histories, hasLength(2));
      expect(
        assistant.histories.first,
        isEmpty,
        reason: 'the first question has nothing behind it',
      );
      expect(
        assistant.histories.last.map((turn) => turn.toJson()).toList(),
        <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'text': 'What is low on stock?'},
          <String, dynamic>{'role': 'model', 'text': assistant.answer.answer},
        ],
        reason:
            'the second question is asked with the first exchange behind it',
      );
      expect(stateOf(container).messages, hasLength(4));
    },
  );

  test('a blank question is never sent', () async {
    final assistant = FakeChatService();
    final container = pumpController(assistant: assistant);

    await notifier(container).ask('   ');

    expect(assistant.questions, isEmpty);
    expect(stateOf(container).isStarted, isFalse);
  });

  test('a question asked while one is in flight spends nothing', () async {
    // The key is a free tier of five requests a minute shared with the bill reader
    // (N-2), so a stray second question must be refused before any call is made -
    // not sent and then discarded.
    final assistant = FakeChatService()..gate = Completer<void>();
    final container = pumpController(assistant: assistant);

    final first = notifier(container).ask('What is low on stock?');
    expect(stateOf(container).isAsking, isTrue);
    expect(stateOf(container).asking, 'What is low on stock?');

    await notifier(container).ask('What sells best?');

    expect(assistant.questions, <String>['What is low on stock?']);
    expect(stateOf(container).asking, 'What is low on stock?');

    assistant.gate!.complete();
    await first;

    expect(stateOf(container).isAsking, isFalse);
    expect(stateOf(container).messages, hasLength(2));
  });

  test(
    'a failure is held as a turn that did not happen, not as a message',
    () async {
      final assistant = FakeChatService()
        ..failures.add(unreachableAssistantFailure());
      final container = pumpController(assistant: assistant);

      await notifier(container).ask('What is low on stock?');

      final state = stateOf(container);
      expect(
        state.messages,
        isEmpty,
        reason: 'nothing was said, so there is nothing in the transcript',
      );
      expect(state.isAsking, isFalse);
      expect(state.failure!.question, 'What is low on stock?');
      expect(state.failure!.error, isA<NetworkException>());
      expect(state.failureIsRetryable, isTrue);
      expect(state.isStarted, isTrue, reason: 'the question is on screen');
    },
  );

  test('a failure that will fail twice is not called retryable', () async {
    final assistant = FakeChatService()
      ..failures.add(
        const ValidationException(
          message: 'That question is longer than 1000 characters.',
          code: 'invalid_request',
        ),
      );
    final container = pumpController(assistant: assistant);

    await notifier(container).ask('a very long question indeed');

    expect(stateOf(container).failureIsRetryable, isFalse);
  });

  test(
    'retry asks the same question once, and nothing asks again by itself',
    () async {
      final assistant = FakeChatService()
        // Fails once, then succeeds: the same list semantics the matcher's fake uses.
        ..failures.addAll(<Exception?>[unreachableAssistantFailure(), null]);
      final container = pumpController(assistant: assistant);

      await notifier(container).ask('What is low on stock?');
      expect(assistant.questions, hasLength(1));

      // Nothing retried while the test did nothing: the budget buys nothing by being
      // spent twice on its own (D-032/D-033).
      await Future<void>.delayed(Duration.zero);
      expect(assistant.questions, hasLength(1));

      await notifier(container).retry();

      expect(
        assistant.questions,
        <String>['What is low on stock?', 'What is low on stock?'],
        reason: "the retry is the same question, one more call, and the user's",
      );
      final state = stateOf(container);
      expect(state.failure, isNull);
      expect(state.messages, hasLength(2));
      expect(state.messages.last.text, assistant.answer.answer);
    },
  );

  test('a retry with nothing failed spends nothing', () async {
    final assistant = FakeChatService();
    final container = pumpController(assistant: assistant);

    await notifier(container).retry();

    expect(assistant.questions, isEmpty);
    expect(stateOf(container).isStarted, isFalse);
  });

  test('a refusal is a message like any other, not a failure', () async {
    // The distinction this whole screen is built on: `rpc: null` is a *successful*
    // answer that says the question is outside what the reports cover.
    final assistant = FakeChatService()..answer = buildChatRefusal();
    final container = pumpController(assistant: assistant);

    await notifier(container).ask('what is the weather in Mumbai?');

    final state = stateOf(container);
    expect(state.failure, isNull);
    expect(state.messages, hasLength(2));
    expect(state.messages.last.response!.hasReport, isFalse);
    expect(state.messages.last.text, buildChatRefusal().answer);
  });

  test(
    'asking a new question supersedes a failure rather than stacking them',
    () async {
      final assistant = FakeChatService()
        ..failures.addAll(<Exception?>[unreachableAssistantFailure()]);
      final container = pumpController(assistant: assistant);

      await notifier(container).ask('What is low on stock?');
      expect(stateOf(container).failure, isNotNull);

      // The failure cleared is the *previous* one: the user moved on.
      assistant.failures.clear();
      await notifier(container).ask('What sells best?');

      final state = stateOf(container);
      expect(state.failure, isNull);
      expect(state.messages, hasLength(2));
      expect(state.messages.first.text, 'What sells best?');
    },
  );

  test('a screen that goes away mid-flight is not written to', () async {
    // D-034: an answer that arrives after the provider is disposed must not be
    // assigned. The gate holds the call open while the container is disposed.
    final assistant = FakeChatService()..gate = Completer<void>();
    final container = ProviderContainer(
      overrides: [chatServiceProvider.overrideWithValue(assistant)],
    );

    final future = container
        .read(chatControllerProvider.notifier)
        .ask('What is low on stock?');

    container.dispose();
    assistant.gate!.complete();

    // The assertion is that this completes at all: without the guard, the write
    // lands on a disposed provider and the error surfaces here.
    await future;
  });
}
