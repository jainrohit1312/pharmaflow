/// Plain models for what the assistant answers with.
///
/// Not Freezed, for `ReportSummary`'s and `ProductMatches`' reason: this is an
/// Edge Function's response envelope rather than a table row, no migration owns
/// its shape, and the decode happens once so no screen ever reaches into raw
/// JSON.
///
/// Three facts about the shape are load-bearing:
///
/// - **`rpc: null` is a successful answer, not a failure.** It is the answer to a
///   question none of the five reports covers, and [ChatResponse.answer] is the
///   server's own sentence saying so (D-026). The screen renders it as prose, in
///   an ordinary answer bubble, with no error styling and nothing to retry —
///   because a refusal is not something that went wrong.
/// - **The sentence is the server's, always.** [ChatResponse.answer] is rendered
///   in code on the server, from a report's own `jsonb` (D-053). Nothing here
///   composes a figure and nothing on the client formats one.
/// - **`data` is kept verbatim and un-modelled.** Five reports answer in five
///   shapes, and no screen reads a figure out of this: what a screen reads from it
///   is the *provenance* the envelope states — the report, the parameters it was
///   handed, and the caveats its `meta` carries. [describeAnswerOrigin] is where
///   `top_products`' `returns_not_netted` reaches a reader's eye.
library;

/// What the assistant answered, and where the answer came from.
class ChatResponse {
  /// Creates an answer.
  const ChatResponse({
    required this.answer,
    this.rpc,
    this.params = const <String, Object?>{},
    this.data,
    this.model,
    this.warnings = const <String>[],
  });

  /// Decodes the function's 200 body, or `null` when it is not one.
  ///
  /// Strict about the one field that cannot be faked: a body with no `answer`
  /// string is not an answer, and rendering it as an empty one is the single
  /// wrong answer this feature could give. That decision belongs to
  /// `decodeChatAnswer`, which turns this `null` into a failure the screen can
  /// show — so an unreadable body never reaches a bubble.
  static ChatResponse? tryDecode(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final json = raw.cast<String, dynamic>();
    final answer = _text(json['answer']);
    if (answer == null) {
      return null;
    }

    final params = json['params'];
    final meta = json['meta'];
    final warnings = meta is Map ? meta['warnings'] : null;

    return ChatResponse(
      answer: answer,
      // `null` on purpose when nothing could answer, and kept as one: it is what
      // the screen uses to tell a refusal from a report's answer.
      rpc: _text(json['rpc']),
      params: params is Map
          ? params.cast<String, Object?>()
          : const <String, Object?>{},
      // Verbatim, deliberately: the report's own envelope is the screen's only
      // source for the caveats under an answer, and re-modelling five shapes
      // would be five chances to lose one.
      data: json['data'],
      model: meta is Map ? _text(meta['model']) : null,
      warnings: warnings is List
          ? <String>[
              for (final warning in warnings)
                // Strings only: a warning is a sentence somebody wrote for a
                // person, and anything else is not one.
                if (warning is String && warning.trim().isNotEmpty)
                  warning.trim(),
            ]
          : const <String>[],
    );
  }

  /// The sentence to render.
  ///
  /// Written on the server from the report's own numbers (D-053), so a screen
  /// shows it and never re-derives it.
  final String answer;

  /// The report that answered, or `null` when none could.
  ///
  /// One of the five the function's enum carries, or `null` for the refusal. A
  /// name this app does not know is kept as it arrived rather than dropped: the
  /// answer came from somewhere, and saying where is the point.
  final String? rpc;

  /// The arguments the function handed that report.
  ///
  /// **This is what was asked, not necessarily what the report used.** Each report
  /// applies its own defaults and clamps its own limit, and where it does so it
  /// says what it actually did in its `data.meta` — which is where the server's
  /// sentence reads it from. A `null` here means "no argument given, the report's
  /// own default applied", which is why [describeAnswerOrigin] skips those
  /// entries rather than rendering `limit: null` as though it were a rule.
  final Map<String, Object?> params;

  /// The report's own `jsonb` envelope, verbatim: `{meta, rows}`, a bare array, or
  /// `null` for the refusal.
  final Object? data;

  /// The model that classified the question (D-030).
  ///
  /// Read from `meta.model` and deliberately **not** rendered: it is provenance
  /// about the classifier, not about the answer, and nobody at a counter acts on
  /// it. It travels because the envelope carries it, and a test asserts it is read.
  final String? model;

  /// Sentences the server wrote about the run itself.
  ///
  /// The case that matters: a report that ran but answered in a shape the server
  /// could not render. The server's sentence already says so, so these are shown
  /// beside it rather than instead of it — a degraded answer must not look normal.
  final List<String> warnings;

  /// Whether a report answered. `false` is a refusal, which is not a failure.
  bool get hasReport => rpc != null;
}

/// One line describing where an answer came from and what was asked for it.
///
/// Built from the envelope's own fields and nothing else, which is D-053 reaching
/// the reader: an aggregate that says its figures are not netted out has to have
/// somewhere to say it, and this line is that place. It is deliberately *not* a
/// second copy of the sentence — the sentence is written on the server from the
/// report's numbers, while this line names the report, the arguments it was handed
/// and the caveats its `meta` states, none of which the sentence is obliged to
/// repeat. Nothing here computes a figure.
///
/// `null` when there is nothing to attribute — a refusal came from no report, and
/// its sentence is the whole answer.
String? describeAnswerOrigin(ChatResponse response) {
  final label = reportLabel(response.rpc);
  if (label == null) {
    return null;
  }

  return <String>[
    label,
    ..._askedNotes(response.params),
    ..._caveats(response.data),
  ].join(' · ');
}

/// A readable name for a report, or `null` for the refusal.
///
/// The five names are the server's own `enum` (D-026), and they are here rather
/// than on a screen because two surfaces are already going to want them (this one
/// and the example questions). A name this app does not know is passed through
/// unchanged, so a newer server reporting a sixth report is named rather than
/// silently attributed to nothing.
String? reportLabel(String? rpc) {
  final name = rpc?.trim();
  if (name == null || name.isEmpty) {
    return null;
  }
  return _reportLabels[name] ?? name;
}

/// The five reports the function chooses between, as a person reads them.
const Map<String, String> _reportLabels = <String, String>{
  'report_summary': 'Report summary',
  'low_stock_products': 'Low stock products',
  'expiring_batches': 'Expiring batches',
  'top_products': 'Top products',
  'dead_stock': 'Dead stock',
};

/// The order the reported parameters are read in, so one answer's note reads the
/// same way every time.
const List<String> _paramOrder = <String>[
  'p_from',
  'p_to',
  'p_days',
  'p_limit',
  'p_metric',
];

/// What was asked for, in words: `from 2026-08-01`, `at most 5 rows`, `by revenue`.
///
/// A parameter with no value is skipped: the report's own default applied, and its
/// sentence says what that default did. A key this app does not know is still
/// rendered — an argument the app cannot name is not the same as no argument.
Iterable<String> _askedNotes(Map<String, Object?> params) {
  final notes = <String>[];
  for (final key in _orderedKeys(params)) {
    final value = _scalar(params[key]);
    if (value != null) {
      notes.add(_askedNote(key, value));
    }
  }
  return notes;
}

/// The parameter keys, known ones first, then anything new in a stable order.
Iterable<String> _orderedKeys(Map<String, Object?> params) {
  final known = <String>[
    for (final key in _paramOrder)
      if (params.containsKey(key)) key,
  ];
  final rest = <String>[
    for (final key in params.keys)
      if (!_paramOrder.contains(key)) key,
  ]..sort();
  return <String>[...known, ...rest];
}

/// One parameter as the phrase a reader understands.
String _askedNote(String key, String value) => switch (key) {
  'p_from' => 'from $value',
  'p_to' => 'to $value',
  'p_days' => 'within $value days',
  'p_limit' => 'at most $value rows',
  'p_metric' => 'by $value',
  _ => '${key.replaceFirst('p_', '').replaceAll('_', ' ')} $value',
};

/// The caveats a report states about its own answer, in its own `meta`.
///
/// Kept to what a sentence does *not* say: `top_products` and `dead_stock` state
/// their window and metric in the sentence already (rendered server-side from this
/// same `meta`), while `returns_not_netted` has no sentence anywhere — which is
/// exactly why D-053 put it in the envelope.
Iterable<String> _caveats(Object? data) {
  if (data is! Map) {
    return const <String>[];
  }
  final meta = data['meta'];
  if (meta is! Map) {
    return const <String>[];
  }
  return <String>[
    if (meta['returns_not_netted'] == true) 'returns are not subtracted',
  ];
}

/// A non-empty trimmed string, or `null`.
///
/// A number is not a string here on purpose: an `answer` that is not text is not
/// an answer, and quietly stringifying it would be the blank-answer failure with
/// extra steps.
String? _text(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

/// A parameter value as its own text, or `null` when it is absent or blank.
String? _scalar(Object? value) => switch (value) {
  null => null,
  final String text => text.trim().isEmpty ? null : text.trim(),
  final num number => '$number',
  final bool flag => '$flag',
  _ => null,
};
