/// A [ChatService] that records what it was asked and can be told to fail.
///
/// It records **questions** rather than calls, because the count of calls is the
/// thing under test: the model key is a free tier of five requests a minute shared
/// with the bill reader (N-2), so "one question, one call" and "a retry is one
/// more call and nothing else" are the two assertions this fake exists for.
///
/// Failures are listed per attempt rather than being one-shot, the same way
/// `FakeMatchService` does it: a list that runs out keeps using its last entry, so
/// `[failure]` is "fails for ever" and `[failure, null]` is "once". A **persistent**
/// flag would be wrong here for the same reason the notifications fake explains: a
/// failure that cleared itself could be consumed by a build the test is not looking
/// at.
library;

import 'dart:async';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/answer_language.dart';
import 'package:app/data/models/chat_message.dart';
import 'package:app/data/models/chat_response.dart';
import 'package:app/services/chat_service.dart';

/// A fake assistant.
class FakeChatService implements ChatService {
  /// Every question asked, in order.
  final List<String> questions = <String>[];

  /// The history sent with each call, aligned by position with [questions].
  final List<List<ChatMessage>> histories = <List<ChatMessage>>[];

  /// The language each call was asked for, aligned by position with [questions].
  ///
  /// Recorded for the same reason the questions are: "the answer comes back in the language
  /// that was chosen" is a claim about what this app SENDS, and the server's half of it is
  /// `answer_test.ts`'s.
  final List<AnswerLanguage> languages = <AnswerLanguage>[];

  /// What every successful call answers with.
  ChatResponse answer = buildChatAnswer();

  /// Failures, one per call; `null` entries succeed and the last one repeats.
  final List<Exception?> failures = <Exception?>[];

  /// Held open to keep a call in flight while a test looks at the screen.
  ///
  /// The loading state cannot be asserted any other way: the screen has to be
  /// looked at *during* the call, which means the call has to be pausable.
  Completer<void>? gate;

  @override
  Future<ChatResponse> ask({
    required String question,
    required AnswerLanguage language,
    List<ChatMessage> history = const <ChatMessage>[],
  }) async {
    questions.add(question);
    histories.add(history);
    languages.add(language);

    final held = gate;
    if (held != null) {
      await held.future;
    }

    final failure = _next(failures);
    if (failure != null) {
      throw failure;
    }
    return answer;
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

/// An answer a report gave, with only the fields a test cares about.
///
/// The defaults are the shape the live function actually answers with, so a test
/// that changes one field is changing one field of a real envelope.
ChatResponse buildChatAnswer({
  String answer = 'Nothing is below its reorder level.',
  String? rpc = 'low_stock_products',
  Map<String, Object?> params = const <String, Object?>{},
  Object? data,
  List<String> warnings = const <String>[],
  String? model = 'gemini-3.6-flash',
}) => ChatResponse(
  answer: answer,
  rpc: rpc,
  params: params,
  data: data,
  model: model,
  warnings: warnings,
);

/// The refusal the function answers a question none of its reports covers with.
///
/// Copied verbatim from the live probe: it is a **200**, it carries `rpc: null`, and
/// it is the whole of what the user sees — no report to attribute, no error.
ChatResponse buildChatRefusal() => const ChatResponse(
  answer:
      'I cannot answer that. I can answer questions about sales and purchases, '
      'stock levels, expiring batches, what sells best, and what has stopped '
      'selling.',
  model: 'gemini-3.6-flash',
);

/// The failure an assistant that could not be reached produces.
NetworkException unreachableAssistantFailure() => const NetworkException(
  message: 'Could not reach the assistant. Check the connection and try again.',
  code: unreachableChatCode,
);

/// The failure a busy model produces: the free tier's `503`, worth another go.
ServerException busyAssistantFailure() => const ServerException(
  message: 'The model is busy right now. Try again in a moment.',
  code: providerUnavailableChatCode,
);
