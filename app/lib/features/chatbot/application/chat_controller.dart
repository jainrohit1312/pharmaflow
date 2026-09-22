/// The conversation: what was asked, what was answered, and what could not be.
///
/// A controller rather than an `AsyncValue`, and a plain state rather than one
/// wrapped in one. A conversation is not a single read: it is a transcript, a
/// question that is still in flight, and — separately — a question that could not
/// be asked at all. Three situations, and the whole point of this screen is that
/// they never look alike (T-5's lesson):
///
///   - **still waiting** is [ChatState.asking]: the question is on screen and the
///     answer has not arrived;
///   - **no answer to that** is an ordinary answer — `rpc: null` — which is a
///     *successful* answer and lives in [ChatState.messages] like any other;
///   - **could not ask** is [ChatState.failure], which is deliberately **not** a
///     message: it is a turn that did not happen, it is sent to nobody, and it is
///     the only one of the three that offers a retry.
///
/// Two more rules are load-bearing:
///
///   1. **One model call per user action, and nothing retries on its own** (N-2,
///      D-032). The key is a free tier of five requests a minute shared with the
///      bill reader, so a second `ask` while one is in flight is refused before it
///      can spend anything, and this controller never re-sends a failure. The retry
///      is the user's tap, and [ChatController.retry] is that tap.
///   2. **The conversation is not a provider build.** `build` returns a constant
///      and never throws, which matters in Riverpod 3: a provider whose *build*
///      threw is re-run on its own backoff, so an error state reached that way is
///      not stable across pumps (D-051). Reaching it from a failed write — as here
///      — is. Found the hard way while testing the alerts' count.
library;

import 'package:app/data/models/answer_language.dart';
import 'package:app/data/models/chat_message.dart';
import 'package:app/services/chat_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'chat_controller.g.dart';

/// Everything the screen knows about the conversation.
class ChatState {
  /// Creates a state.
  const ChatState({
    this.messages = const <ChatMessage>[],
    this.asking,
    this.failure,
  });

  /// The turns that happened, oldest first.
  ///
  /// A completed answer to a question no report covers (`rpc: null`) is in here:
  /// it is a message, not a failure.
  final List<ChatMessage> messages;

  /// The question being asked right now, or `null`.
  ///
  /// Held as the question's own text rather than as a flag so the screen can keep
  /// showing what was asked while it waits — which is what makes *"still waiting"*
  /// a sentence about this question rather than a spinner in a corner.
  final String? asking;

  /// The question that could not be asked, or `null`.
  final ChatFailure? failure;

  /// Whether an answer is outstanding.
  bool get isAsking => asking != null;

  /// Whether there is a conversation to show.
  ///
  /// `false` is the invitation — example questions and an empty input — and it is
  /// not an error and not a loading state. A history with nothing in it is simply
  /// a conversation that has not started.
  bool get isStarted =>
      messages.isNotEmpty || asking != null || failure != null;

  /// Whether the failure that is showing is worth another go (D-033).
  ///
  /// Only this decides the *sentence*; the retry itself is offered either way,
  /// because re-asking is the only action a failure leaves a user.
  bool get failureIsRetryable {
    final failed = failure;
    return failed != null && isRetryableChatError(failed.error);
  }
}

/// A question that could not be asked, and why.
class ChatFailure {
  /// Creates a failure.
  const ChatFailure({required this.question, required this.error});

  /// The question, trimmed, exactly as it was sent.
  ///
  /// Kept so [ChatController.retry] re-asks *this* question rather than whatever
  /// happens to be in the input field by then — a retry is a second attempt at one
  /// question, not a new one.
  final String question;

  /// What went wrong: an `AppException` from the service, in the server's own
  /// words where there were any.
  final Object error;
}

/// The language the assistant is asked to answer in.
///
/// A provider rather than a field on [ChatState], because the language is a choice about
/// the NEXT answer rather than part of the conversation: a transcript in two languages is
/// perfectly fine, and switching one's mind should not rewrite what has already been said.
/// The controller reads it once per question, so every answer in a conversation is written
/// in the language that was chosen when it was asked.
@riverpod
class AnswerLanguageChoice extends _$AnswerLanguageChoice {
  @override
  AnswerLanguage build() => AnswerLanguage.english;

  /// Answers the next question — and every one after it — in [language].
  ///
  /// Choosing the language already in use is a no-op rather than a rebuild: tapping the
  /// chip that is already selected should not make the screen redraw for nothing.
  void choose(AnswerLanguage language) {
    if (language != state) {
      state = language;
    }
  }
}

/// Holds the conversation and asks the assistant one question at a time.
@riverpod
class ChatController extends _$ChatController {
  @override
  ChatState build() => const ChatState();

  /// Sends [question], with the conversation so far as its context.
  ///
  /// A blank question and a second question while one is in flight are both
  /// refused before any call is made — the screen checks the same thing before it
  /// clears its input, because whether there is anything to clear is the input's
  /// own business; the check here is what guarantees no call is spent either way.
  /// Asking supersedes a previous failure: that failure described one question's
  /// attempt, and the user has moved past it.
  ///
  /// The answer is asked for in the language chosen when the question is sent
  /// ([AnswerLanguageChoice]), read here rather than on the screen so that a retry
  /// cannot be the one turn that goes out in a different language by accident.
  Future<void> ask(String question) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty || state.isAsking) {
      return;
    }

    // The conversation as it was, captured before the await: it is what the turn
    // is appended to on success, and what is left untouched on failure.
    final history = state.messages;
    final language = ref.read(answerLanguageChoiceProvider);
    state = ChatState(messages: history, asking: trimmed);

    try {
      final response = await ref
          .read(chatServiceProvider)
          .ask(question: trimmed, language: language, history: history);
      // A screen that navigated away stops watching this provider, and Riverpod
      // then disposes it: writing state afterwards would throw from a future
      // nobody is awaiting (D-034).
      if (!ref.mounted) {
        return;
      }
      state = ChatState(
        messages: <ChatMessage>[
          ...history,
          ChatMessage.question(trimmed),
          ChatMessage.answer(response),
        ],
      );
    } on Object catch (error) {
      if (!ref.mounted) {
        return;
      }
      // The question is not added to the transcript: it did not happen. It is
      // held, with its failure, so the screen can show both and offer the retry.
      state = ChatState(
        messages: history,
        failure: ChatFailure(question: trimmed, error: error),
      );
    }
  }

  /// Asks the failed question again, exactly as it was asked.
  ///
  /// One call, on a user's tap, with no loop behind it (N-2). Nothing else in this
  /// controller re-sends anything.
  Future<void> retry() async {
    final failed = state.failure;
    if (failed == null) {
      return;
    }
    await ask(failed.question);
  }
}
