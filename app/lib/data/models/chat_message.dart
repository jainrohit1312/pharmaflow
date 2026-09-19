/// One turn of the conversation: a question the user asked, or a report's answer.
///
/// The same class in both directions on purpose — it *is* the turn the function's
/// history accepts (`{role, text}`), so the context a screen sends is the
/// transcript it is already holding rather than a second shape kept in step by
/// hand. An answer carries the envelope it came from, so the bubble can render the
/// sentence and, under it, where the sentence came from.
///
/// **A turn that failed is deliberately not one of these.** A failure is a turn
/// that did not happen: it has no answer, it is sent to nobody, and it must not be
/// able to be confused with the refusal `rpc: null` produces, which *is* an answer
/// and *is* a message. That distinction is structural here rather than a matter of
/// how a widget paints a bubble.
library;

import 'package:app/data/models/chat_response.dart';

/// Who said a turn.
enum ChatRole {
  /// The person at the counter.
  user('user'),

  /// The assistant.
  model('model');

  const ChatRole(this.wireName);

  /// The name the function's history uses for this role.
  final String wireName;
}

/// One thing said in the conversation.
class ChatMessage {
  /// Creates a turn.
  const ChatMessage({required this.role, required this.text, this.response});

  /// A question the user asked.
  factory ChatMessage.question(String text) =>
      ChatMessage(role: ChatRole.user, text: text);

  /// An answer the assistant gave, with the envelope behind it.
  ///
  /// A refusal (`rpc: null`) is an answer too, and is created here like any other:
  /// what makes it a refusal is that its envelope carries no report, not that it
  /// is a lesser kind of message.
  factory ChatMessage.answer(ChatResponse response) => ChatMessage(
    role: ChatRole.model,
    // The sentence, exactly as the server wrote it. Nothing on the client edits
    // it, shortens it or re-renders it (D-053).
    text: response.answer,
    response: response,
  );

  /// The turn's text: the question as typed, or the answer as written.
  final String text;

  /// Who said it.
  final ChatRole role;

  /// The envelope an answer came from, and `null` on a question.
  final ChatResponse? response;

  /// Whether this turn is the user's.
  bool get isQuestion => role == ChatRole.user;

  /// This turn as the function's `history` reads it.
  ///
  /// Only the role and the text travel: the envelope is this device's copy of
  /// where the sentence came from, and re-sending it would be sending the model
  /// its own metadata back as conversation.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'role': role.wireName,
    'text': text,
  };
}
