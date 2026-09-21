/// The three shapes a turn can take, kept in one file so they cannot drift.
///
/// This file exists because of one rule (T-5's lesson, and the reason this screen
/// is worth building carefully): *"still waiting"*, *"no answer to that"* and
/// *"could not ask"* must never look alike. They are three different claims about
/// the same moment, and only one of them is a failure:
///
///   - [MessageBubble] is a turn that **happened** — a question, or an answer.
///     A refusal (`rpc: null`) is an answer and is rendered here, as prose, in the
///     same bubble a report's answer gets. It has nothing to retry, because
///     nothing went wrong.
///   - [PendingTurn] is a turn that is **happening** — the question plus a spinner.
///   - [FailedTurn] is a turn that **did not happen** — no answer, an error icon,
///     the server's own sentence, and the only retry on this screen.
///
/// Nothing here computes a figure. The sentence is the server's (D-053), and the
/// note under it is read from the envelope's own fields.
///
/// The one thing an answer's bubble does that a question's does not is read the
/// server's emphasis marker (`[parseAnswerEmphasis]`, and `answer.ts` for why the
/// marker exists): a question is the user's own text and is never markup, while an
/// answer's sentence is the server's and pointing at its own finding is the
/// server's job. A sentence with no marker is one plain run, so an unmarked answer
/// renders exactly as it did before markers existed.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/data/models/chat_message.dart';
import 'package:app/data/models/chat_response.dart';
import 'package:app/features/chatbot/application/chat_controller.dart';
import 'package:app/features/chatbot/presentation/answer_emphasis.dart';
import 'package:flutter/material.dart';

/// The widest a bubble grows before it wraps; a wide window should not turn a
/// one-line answer into a band across the screen.
const double _maxBubbleWidth = 560;

/// A turn that happened: a question, or an answer with its provenance.
class MessageBubble extends StatelessWidget {
  /// Creates a bubble for [message].
  const MessageBubble({required this.message, super.key});

  /// The turn to render.
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final response = message.response;

    return _Bubble(
      isQuestion: message.isQuestion,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // A question is the user's own words and is shown exactly as typed —
          // marker or no marker, it is not markup. An answer is the server's
          // sentence, and the part the server pointed at is shown the way a person
          // would have highlighted it on paper.
          if (response == null)
            Text(message.text)
          else
            _AnswerText(text: message.text),
          // An answer says where it came from; a question has nothing to say.
          if (response != null) _AnswerOrigin(response: response),
        ],
      ),
    );
  }
}

/// An answer's sentence, with the part the server pointed at set in bold.
///
/// [parseAnswerEmphasis] does the reading; this only paints what it found. The runs
/// carry no style of their own beyond the weight, so the sentence still takes the
/// bubble's own text style — and a sentence with no marker is one plain run, which
/// is the same widget it was before there were markers at all.
class _AnswerText extends StatelessWidget {
  const _AnswerText({required this.text});

  /// The server's sentence, marker and all.
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          for (final run in parseAnswerEmphasis(text))
            TextSpan(
              text: run.text,
              style: run.isStrong
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
        ],
      ),
    );
  }
}

/// A question that is still being answered.
class PendingTurn extends StatelessWidget {
  /// Creates the waiting turn for [question].
  const PendingTurn({required this.question, super.key});

  /// The question that is in flight.
  final String question;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Bubble(isQuestion: true, child: Text(question)),
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 2, bottom: 4),
          child: Row(
            children: <Widget>[
              const SizedBox(
                height: 14,
                width: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                // The question stays on screen above this, so the sentence is
                // about *that* question rather than a spinner in a corner.
                'Still waiting for an answer…',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A question that could not be asked.
///
/// The only turn on this screen with a retry, and the only one that shows an
/// error: a failure is a different claim from "I cannot answer that", and the two
/// must not borrow each other's clothes.
class FailedTurn extends StatelessWidget {
  /// Creates the failed turn.
  const FailedTurn({
    required this.failure,
    required this.isRetryable,
    required this.onRetry,
    super.key,
  });

  /// What could not be asked, and why.
  final ChatFailure failure;

  /// Whether the failure is worth another go — the model being busy, or the
  /// question never arriving (D-032/D-033). Only decides the extra sentence; the
  /// retry is offered either way.
  final bool isRetryable;

  /// Re-asks exactly this question.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Bubble(isQuestion: true, child: Text(failure.question)),
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 2, bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.error_outline,
                size: 18,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // The failure's own sentence: the server's, verbatim, or the
                    // service's when nothing came back (D-042).
                    Text(
                      describeError(failure.error),
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (isRetryable) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        'The assistant was busy, not beaten — worth another go.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 8),
                    AppButton.outlined(
                      label: 'Ask again',
                      icon: Icons.refresh,
                      expand: false,
                      onPressed: onRetry,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The turn frame: one bubble, aligned by who said it.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.isQuestion, required this.child});

  /// Whether this is the user's turn, which decides the side and the colour.
  final bool isQuestion;

  /// The bubble's contents.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Align(
      alignment: isQuestion ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: _maxBubbleWidth),
        decoration: BoxDecoration(
          color: isQuestion
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      ),
    );
  }
}

/// Where an answer came from, read from the envelope's own fields.
///
/// Built by [describeAnswerOrigin] and rendered as one line; the server's own
/// warnings, when it wrote any, follow it. A refusal has neither — there is no
/// report to name — so this renders nothing at all for one, which is how the
/// refusal bubble stays plain prose.
class _AnswerOrigin extends StatelessWidget {
  const _AnswerOrigin({required this.response});

  /// The answer's envelope.
  final ChatResponse response;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = describeAnswerOrigin(response);
    final warnings = response.warnings;

    if (note == null && warnings.isEmpty) {
      return const SizedBox.shrink();
    }

    final subtle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (note != null) Text(note, style: subtle),
          for (final warning in warnings)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.info_outline,
                    size: 14,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 6),
                  Flexible(child: Text(warning, style: subtle)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
