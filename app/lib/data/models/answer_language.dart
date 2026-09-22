/// The languages the assistant can answer in.
///
/// The same shape `ChatRole` has: a closed set with a `wireName`, because what travels to
/// `chat-sql-agent` is a name the server's own enum carries (`ANSWER_LANGUAGES` in
/// `schema.ts`), and writing that name in one place is how the two stay in step. A name the
/// server does not know is English there — a language is a preference, and a caller asking
/// for one this build does not have should still get its question answered.
///
/// This is the **caller's** choice rather than the model's, which is why it is not part of
/// `ChatParams`: it changes which sentence is written, never which report is run or which
/// figure is read.
library;

/// One of the languages a sentence can be written in.
enum AnswerLanguage {
  /// The language this feature shipped with, and the default.
  english('en', 'English'),

  /// Hindi in Roman script, with the business nouns left in English.
  hinglish('hinglish', 'Hinglish');

  const AnswerLanguage(this.wireName, this.label);

  /// The name the function's own enum uses for this language.
  final String wireName;

  /// What the choice is called on screen.
  ///
  /// Kept beside the wire name on purpose: a chip that said one thing and sent another
  /// would be a two-word bug nobody would look for.
  final String label;
}
