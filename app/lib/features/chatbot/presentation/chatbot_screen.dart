/// The chatbot: ask a question about this pharmacy, read the answer.
///
/// The screen exists to keep three sentences apart, which is T-5's lesson applied
/// where it costs the most — a question and an answer look like each other, and a
/// failure would happily borrow their clothes:
///
///   - **still waiting** is a question on screen with a spinner beside it, and it
///     is a *question*, not an answer: nothing has been claimed yet;
///   - **no answer to that** is the server's refusal sentence (`rpc: null`) in an
///     ordinary answer bubble, in prose, with no error styling and nothing to
///     retry — it is a successful answer that says the question is outside what the
///     five reports cover;
///   - **could not ask** is a turn that did not happen: no bubble of prose, an
///     error icon, the server's own sentence, and the only retry here.
///
/// And a fourth, before any of them: an empty conversation is an *invitation*, not
/// an error and not a spinner. A history with nothing in it is a conversation that
/// has not started, and it says so and offers examples drawn from the reports the
/// function can answer from.
///
/// Nothing on this screen computes a figure. The sentence is written on the server
/// from a report's own `jsonb` (D-053); the note beneath it is read from the
/// envelope's own fields (`describeAnswerOrigin`); and the only thing the widget
/// decides is where a turn sits and how it looks.
library;

import 'dart:async';

import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/app_text_field.dart';
import 'package:app/data/models/answer_language.dart';
import 'package:app/features/chatbot/application/chat_controller.dart';
import 'package:app/features/chatbot/presentation/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The questions the invitation offers, one per report the function can choose.
///
/// Not decoration: the set of questions this feature can answer *equals* the set of
/// reports (D-026's first consequence), so the examples are the honest way to say
/// what the thing is for — and they are the reason a user's first attempt is not a
/// guess that comes back as a refusal.
const List<String> chatExampleQuestions = <String>[
  'What is low on stock?',
  'What sells best this month?',
  'What is expiring soon?',
  'What has stopped selling?',
  'How did last month go?',
];

/// Asks the assistant, and reads what it says.
class ChatbotScreen extends ConsumerStatefulWidget {
  /// Creates the chatbot screen.
  const ChatbotScreen({super.key});

  @override
  ConsumerState<ChatbotScreen> createState() => _ChatbotScreenState();
}

class _ChatbotScreenState extends ConsumerState<ChatbotScreen> {
  /// The question being typed.
  final TextEditingController _question = TextEditingController();

  /// The transcript's scroll position, so a new turn is brought into view.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _question.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Asks [question], taking the input's text with it.
  ///
  /// The input is cleared before the call rather than after it, so a user who has
  /// started typing the next question while the first is in flight does not lose
  /// what they typed. The guard here is the same one the controller makes, for a
  /// different reason: the *input* has to know whether its text was taken, while
  /// the controller's is what guarantees no call is spent either way.
  Future<void> _ask(String question) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty || ref.read(chatControllerProvider).isAsking) {
      return;
    }

    _question.clear();
    _bringNewestIntoView();

    await ref.read(chatControllerProvider.notifier).ask(trimmed);
    _bringNewestIntoView();
  }

  /// Asks the failed question again — the same question, not a new one.
  Future<void> _retry() async {
    _bringNewestIntoView();
    await ref.read(chatControllerProvider.notifier).retry();
    _bringNewestIntoView();
  }

  /// Scrolls to the end once the frame that added the newest turn is laid out.
  ///
  /// After the frame rather than now: the turn is not in the list until the build
  /// that follows this one, so the extent being scrolled to does not exist yet.
  void _bringNewestIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      final position = _scroll.position;
      if (position.maxScrollExtent <= position.pixels) {
        return;
      }
      unawaited(
        _scroll.animateTo(
          position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatControllerProvider);

    return AppScaffold(
      title: 'Chatbot',
      body: Column(
        children: <Widget>[
          Expanded(
            child: state.isStarted
                ? _Transcript(
                    state: state,
                    scroll: _scroll,
                    onRetry: () => unawaited(_retry()),
                  )
                : _Invitation(onAsk: (question) => unawaited(_ask(question))),
          ),
          const Divider(height: 1),
          const _LanguageBar(),
          _Composer(
            controller: _question,
            isAsking: state.isAsking,
            onAsk: (question) => unawaited(_ask(question)),
          ),
        ],
      ),
    );
  }
}

/// The conversation so far, oldest first.
class _Transcript extends StatelessWidget {
  const _Transcript({
    required this.state,
    required this.scroll,
    required this.onRetry,
  });

  /// What the conversation holds.
  final ChatState state;

  /// Its scroll position.
  final ScrollController scroll;

  /// Re-asks the failed question.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failure = state.failure;
    final asking = state.asking;

    return ListView(
      controller: scroll,
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        for (final message in state.messages) MessageBubble(message: message),
        // The outstanding turn is always the newest, so appending it is the whole
        // of the ordering rule. Only one of the two can exist: asking supersedes a
        // failure, and a failure ends the asking.
        if (asking != null) PendingTurn(question: asking),
        if (failure != null)
          FailedTurn(
            failure: failure,
            isRetryable: state.failureIsRetryable,
            onRetry: onRetry,
          ),
      ],
    );
  }
}

/// The empty conversation: what this is for, and a few questions to start with.
///
/// Deliberately not a spinner and deliberately not an error. *"Nothing has been
/// asked yet"* is its own situation, and the one place a user most needs to be
/// told what the thing can do.
class _Invitation extends StatelessWidget {
  const _Invitation({required this.onAsk});

  /// Asks one of the offered questions.
  final ValueChanged<String> onAsk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: <Widget>[
          const SizedBox(height: 24),
          Icon(
            Icons.forum_outlined,
            size: 48,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text('Ask about this pharmacy', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Stock, sales, what is expiring and what has stopped selling — '
            'answered from your own numbers, never guessed.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final question in chatExampleQuestions)
                ActionChip(
                  label: Text(question),
                  onPressed: () => onAsk(question),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The language the next answer is written in.
///
/// Two chips here rather than a setting under `/settings`, and that is a decision: the
/// choice is felt at the moment a question is asked, it only ever affects the *next*
/// answer, and it costs no migration — a profile column would, and a setting nobody visits
/// is a setting nobody finds. The language a question is *asked* in is irrelevant to it;
/// the classifier answers whatever language it is asked in.
class _LanguageBar extends ConsumerWidget {
  const _LanguageBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chosen = ref.watch(answerLanguageChoiceProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Wrap(
        spacing: 8,
        children: <Widget>[
          for (final language in AnswerLanguage.values)
            ChoiceChip(
              label: Text(language.label),
              selected: language == chosen,
              // Tapping the language already in use does nothing rather than
              // deselecting: an answer has to be written in *some* language, so
              // "none" is not a state this control can reach.
              onSelected: (_) => ref
                  .read(answerLanguageChoiceProvider.notifier)
                  .choose(language),
            ),
        ],
      ),
    );
  }
}

/// The question field and its button.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.isAsking,
    required this.onAsk,
  });

  /// The question being typed.
  final TextEditingController controller;

  /// Whether a question is already in flight.
  final bool isAsking;

  /// Asks the typed question.
  final ValueChanged<String> onAsk;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: AppTextField(
              controller: controller,
              label: 'Ask a question',
              hint: 'e.g. what is low on stock?',
              textInputAction: TextInputAction.send,
              // Enter asks, so a desktop user never has to reach for the button.
              // A browser has no submit key to rely on, which is why the button
              // exists beside it (D-005: web is the first platform here).
              onSubmitted: onAsk,
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => AppButton.primary(
              label: 'Ask',
              icon: Icons.send,
              expand: false,
              // One question at a time: the model key is a free tier of five
              // requests a minute shared with the bill reader (N-2), so the button
              // says so rather than letting a second tap be swallowed.
              onPressed: value.text.trim().isEmpty || isAsking
                  ? null
                  : () => onAsk(value.text),
            ),
          ),
        ],
      ),
    );
  }
}
