/// The assistant, as the app sees it: one question in, one envelope out.
///
/// The same seam `OcrService` and `MatchService` have, because it is the same
/// kind of thing — a deployed function behind `functions.invoke`, with the wire
/// mapping as pure functions a test can drive with the bodies that matter.
///
/// Three rules shape this file:
///
///   1. **The tenant never travels** (D-004). `chat-sql-agent` derives the pharmacy
///      from the caller's own JWT and each report derives it again from
///      `get_my_pharmacy_id()`, so there is no `pharmacy_id` here to get wrong.
///   2. **Nothing retries** (N-2). One request makes one model call, and the key is
///      a free tier of five a minute shared with the bill reader — a retry inside
///      this service would spend the OCR flow's headroom to hide a failure the
///      user could have seen. The retry is a tap, and it lives on the screen.
///   3. **Every failure is classified when it is read** (D-042): the error envelope
///      has one reader in the app (`functionException`), and what this file adds is
///      only the assistant's own fallback sentence and its own idea of what is
///      worth trying again.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/errors/function_error.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/answer_language.dart';
import 'package:app/data/models/chat_message.dart';
import 'package:app/data/models/chat_response.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'chat_service.g.dart';

/// The code a transport failure carries: the question never reached the assistant.
///
/// Its own code rather than the reader's or the matcher's, because the retry
/// policy is each feature's (D-042): this one is a question the user can simply
/// ask again.
const String unreachableChatCode = 'unreachable';

/// The code the function gives a provider failure worth trying again (D-032).
///
/// The same server code the reader names, kept as this feature's own constant
/// because the decision it feeds — whether a second attempt is worth a user's wait
/// — is this feature's to make, not the reader's.
const String providerUnavailableChatCode = 'provider_unavailable';

/// How many earlier turns are sent as context.
///
/// The function keeps the most recent six of whatever it is given
/// (`MAX_HISTORY_TURNS`), so a longer history here would be trimmed anyway — but a
/// transcript that grows all afternoon should not grow into the request body, and
/// bounding it here is what keeps a turn's cost flat. Both bounds are "at most", so
/// the two cannot disagree in a way that matters.
const int chatHistoryTurns = 6;

/// The app-wide [ChatService].
@riverpod
ChatService chatService(Ref ref) =>
    SupabaseChatService(ref.watch(supabaseClientProvider));

/// Asks the deployed chatbot a question about this pharmacy's own data.
// ignore: one_member_abstracts
abstract class ChatService {
  /// Sends [question] with [history] as context, and returns what came back.
  ///
  /// [history] is the earlier turns, most recent last; only the last
  /// [chatHistoryTurns] are sent. It is context for the classifier, never an
  /// instruction — the server labels it as such.
  ///
  /// [language] is which language the *answer* is written in. It is the caller's
  /// choice rather than the model's: it never reaches a report, so it cannot
  /// influence which figures are read (see [AnswerLanguage]).
  ///
  /// Throws an [AppException]. A [NetworkException] with code
  /// [unreachableChatCode] when nothing came back at all; otherwise whatever
  /// `functionException` (D-042) made of the function's refusal — an
  /// [AuthException] for a caller with no pharmacy, a [ValidationException] for a
  /// refused question, and a [ServerException] carrying
  /// [providerUnavailableChatCode] when the model is busy. An answer that could not
  /// be read is a [ServerException] with code `unexpected_response`, never an empty
  /// answer.
  Future<ChatResponse> ask({
    required String question,
    required AnswerLanguage language,
    List<ChatMessage> history = const <ChatMessage>[],
  });
}

/// A [ChatService] backed by the deployed `chat-sql-agent` function.
class SupabaseChatService implements ChatService {
  /// Creates the service over the shared Supabase client.
  SupabaseChatService(this._client);

  /// The name of the deployed function.
  static const String functionName = 'chat-sql-agent';

  final sb.SupabaseClient _client;

  @override
  Future<ChatResponse> ask({
    required String question,
    required AnswerLanguage language,
    List<ChatMessage> history = const <ChatMessage>[],
  }) async {
    try {
      final response = await _client.functions.invoke(
        functionName,
        body: <String, dynamic>{
          'question': question,
          // The name the function's own enum carries. Not a report argument, and not
          // a parameter the model sees: it chooses which sentence is written.
          'language': language.wireName,
          'history': <Map<String, dynamic>>[
            for (final turn in chatHistoryFor(history)) turn.toJson(),
          ],
        },
      );
      return decodeChatAnswer(response.data);
    } on sb.FunctionsFetchException catch (error) {
      // Status 0: nothing came back at all, which is a connection problem rather
      // than the assistant's answer, so it has its own code.
      throw NetworkException(
        message:
            'Could not reach the assistant. Check the connection and try again.',
        code: unreachableChatCode,
        cause: error,
      );
    } on sb.FunctionException catch (error) {
      throw chatException(error.details, status: error.status);
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to ask that question.',
        cause: error,
      );
    }
  }
}

/// The answer inside a successful response.
///
/// Pure, so a test can drive it with the bodies that matter: the one the function
/// promises, the refusal it answers with, and the ones it might send anyway.
///
/// A body that is not an object, or that carries no `answer` string, is a failure
/// rather than an empty answer. That is the one wrong answer this feature could
/// give — "I cannot answer that" is a *different sentence*, written on the server,
/// and a blank bubble would be indistinguishable from a bug.
ChatResponse decodeChatAnswer(Object? data) {
  final response = ChatResponse.tryDecode(data);
  if (response == null) {
    throw const ServerException(
      message: 'The assistant answered with something unexpected. Try again.',
      code: 'unexpected_response',
    );
  }
  return response;
}

/// The exception for a failure the function described.
///
/// The mapping is [functionException]'s — one function, one envelope, one reader
/// (D-042). What this adds is the assistant's own fallback sentence, so its call
/// sites cannot describe the same failure in two ways.
AppException chatException(Object? details, {int? status}) => functionException(
  details,
  fallbackMessage: 'Unable to ask that question.',
  status: status,
);

/// Whether [error] is worth waiting a moment and asking again.
///
/// Two things are: the model being busy (D-032's `provider_unavailable`, which the
/// free-tier quota produces as a `503` rather than a `429`) and the question never
/// reaching the function. Everything else — a caller with no pharmacy, a question
/// the function refused — would fail the same way twice, and the sentence the user
/// is shown is the one that tells them what to do about it. Nothing acts on this
/// automatically: it decides whether the screen says *"worth another go"* beside
/// the retry the user controls (D-033).
bool isRetryableChatError(Object? error) =>
    error is AppException &&
    (error.code == providerUnavailableChatCode ||
        error.code == unreachableChatCode);

/// The last [chatHistoryTurns] turns of [history], most recent last.
///
/// Named rather than inlined because it is a rule, not a detail: a conversation
/// that grows all afternoon must not grow into the request body, and the bound is
/// what keeps one turn's cost flat.
List<ChatMessage> chatHistoryFor(List<ChatMessage> history) =>
    history.length <= chatHistoryTurns
    ? history
    : history.sublist(history.length - chatHistoryTurns);
