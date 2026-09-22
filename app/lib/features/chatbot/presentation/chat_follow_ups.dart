/// The closed set of questions this feature answers, and what to offer next.
///
/// Both lists are **the user's words**, not the assistant's: a chip is rendered exactly as it
/// is written here and sent as the question. That is why nothing in this file is translated —
/// `AnswerLanguage` is about the language an *answer* is written in, and a chip that changed
/// with it would be a question the user did not choose to ask.
///
/// The two lists are one file because the second is a subset of the first, and the test that
/// keeps it that way is the whole reason the follow-ups are safe to offer: a chip is a promise
/// that this feature can answer what it says, so a follow-up that is not one of the example
/// questions would be a promise it cannot keep (D-026's first consequence — the set of
/// answerable questions *is* the set of reports).
library;

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

/// One or two questions to offer under an answer, by the report that gave it.
///
/// **Every question here is one of [chatExampleQuestions]**, which is asserted rather than
/// assumed: a follow-up is offered as a chip, and a chip is a promise. The map is structural
/// rather than generated on purpose — there is no model call behind it and no server surface
/// to add, so a wrong entry is a reviewable mistake rather than a runtime one.
///
/// The pairing is deliberately *alongside* rather than *instead of*: an answer that named the
/// low stock leads to what is expiring and how the last month went, which is the next question
/// an owner actually asks. No entry offers the question that was just answered, because a chip
/// that repeats what is already on screen is a chip that wastes a model call (N-2).
const Map<String, List<String>> chatFollowUps = <String, List<String>>{
  'report_summary': <String>[
    'What is low on stock?',
    'What sells best this month?',
  ],
  'low_stock_products': <String>[
    'What is expiring soon?',
    'How did last month go?',
  ],
  'expiring_batches': <String>[
    'What is low on stock?',
    'What has stopped selling?',
  ],
  'top_products': <String>[
    'What has stopped selling?',
    'How did last month go?',
  ],
  'dead_stock': <String>[
    'What sells best this month?',
    'What is expiring soon?',
  ],
};

/// The questions to offer under an answer from [rpc], or none.
///
/// `null` — a refusal — has none, and neither has a report this build does not know: a refusal
/// is a complete answer to a question outside the closed set, and a chip under it would offer
/// more of the same. A sixth report would simply show no chips until this map names it, which
/// is the safe direction.
List<String> followUpsFor(String? rpc) =>
    rpc == null ? const <String>[] : chatFollowUps[rpc] ?? const <String>[];
