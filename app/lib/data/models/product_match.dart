/// Plain models for what the catalogue matcher returns.
///
/// Not Freezed, for `ReportSummary`'s and `OcrPurchaseBill`'s reason: this is a
/// function's response envelope rather than a table row, no migration owns its
/// shape, and the decode happens once so no screen ever reaches into raw JSON.
///
/// Two facts about the shape are load-bearing:
///
/// - **The answer is aligned by position with the lines that were sent.** One
///   entry per line, in the order asked, and a line with no candidates keeps its
///   own empty entry rather than disappearing. [`rawName`] is the matcher's own
///   trimmed echo of what it was handed — useful in a note, and never a key.
///   `ProductMatches.candidatesAt` is how a screen looks a line up.
/// - **A candidate is an offer, not a decision.** Nothing here is applied to
///   anything; the human still chooses, because a wrong auto-fill on a received
///   invoice is a stock error rather than a typo.
library;

/// Why a candidate is being offered.
///
/// The three legs score differently and mean different things, and the reason is
/// what makes a suggestion checkable: a mapping a human confirmed here once is a
/// certainty, a spelling similarity is an estimate, and a vector hit is a model's
/// opinion that two names are about the same product.
enum MatchReason {
  /// An invoice text a human already confirmed means this product (score 1.0).
  alias,

  /// pg_trgm spelling similarity.
  trigram,

  /// Cosine similarity over the catalogue's embeddings.
  vector,

  /// A leg this app does not know. Kept rather than dropped, so a newer server
  /// offering a new kind of evidence still shows the candidate.
  unknown,
}

/// Parses the matcher's `reason` literal into a [MatchReason].
MatchReason matchReasonFrom(String? raw) => switch (raw?.trim().toLowerCase()) {
  'alias' => MatchReason.alias,
  'trigram' => MatchReason.trigram,
  'vector' => MatchReason.vector,
  _ => MatchReason.unknown,
};

/// The evidence behind a candidate's score.
///
/// Exactly one of these is meaningful for a given candidate, and which one is
/// implied by its [MatchCandidate.reason]: an alias hit carries the alias's own
/// printed spelling, a trigram hit carries the similarity, a vector hit carries
/// the cosine distance.
class MatchEvidence {
  /// Creates evidence.
  const MatchEvidence({
    this.aliasName,
    this.supplierScoped = false,
    this.similarity,
    this.distance,
  });

  /// Decodes the `evidence` object.
  factory MatchEvidence.fromJson(Map<String, dynamic> json) => MatchEvidence(
    aliasName: _text(json['alias_name']),
    supplierScoped: json['supplier_scoped'] == true,
    similarity: _number(json['similarity']),
    distance: _number(json['distance']),
  );

  /// The alias's printed text, for an `alias` hit.
  final String? aliasName;

  /// Whether the alias that answered was scoped to the bill's supplier.
  ///
  /// `false` on an alias hit means the mapping is pharmacy-wide, which is the one
  /// that answers the same text on any distributor's bill (D-036). Always `false`
  /// for the other legs, where it means nothing.
  final bool supplierScoped;

  /// pg_trgm similarity, for a `trigram` hit.
  final double? similarity;

  /// Cosine distance, for a `vector` hit.
  final double? distance;
}

/// One product the matcher thinks a line might mean.
class MatchCandidate {
  /// Creates a candidate.
  const MatchCandidate({
    required this.productId,
    required this.name,
    required this.reason,
    required this.score,
    this.genericName,
    this.packSize,
    this.isActive = true,
    this.evidence = const MatchEvidence(),
  });

  /// Decodes one candidate, or `null` when the entry is not one.
  ///
  /// A candidate with no product id cannot be applied — the whole point of
  /// offering it is that tapping it fills the line — so it is dropped rather than
  /// carried as a row whose only outcome is a failure.
  static MatchCandidate? tryDecode(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final json = raw.cast<String, dynamic>();
    final id = _text(json['product_id']);
    if (id == null) {
      return null;
    }

    return MatchCandidate(
      productId: id,
      // A nameless candidate would be a blank row; the id is a poor label but an
      // honest one.
      name: _text(json['name']) ?? id,
      genericName: _text(json['generic_name']),
      packSize: _text(json['pack_size']),
      isActive: json['is_active'] != false,
      score: _number(json['score']) ?? 0,
      reason: matchReasonFrom(json['reason'] as String?),
      evidence: json['evidence'] is Map
          ? MatchEvidence.fromJson(
              (json['evidence'] as Map).cast<String, dynamic>(),
            )
          : const MatchEvidence(),
    );
  }

  /// The catalogue product's id.
  final String productId;

  /// Its name, as the catalogue spells it.
  final String name;

  /// Its generic name, when it has one.
  final String? genericName;

  /// Its pack size, when it has one.
  final String? packSize;

  /// Whether the catalogue row is active. Never `false` in practice — the matcher
  /// does not offer a deactivated product — but the flag travels, so a screen can
  /// say so rather than assume.
  final bool isActive;

  /// 0…1, the value the ranking used.
  final double score;

  /// Which leg produced it.
  final MatchReason reason;

  /// What that leg saw.
  final MatchEvidence evidence;

  /// The one sentence that says *why* this is being offered.
  ///
  /// The reason has to be visible to be trusted, and the three legs are three
  /// different claims: an alias is a mapping a human confirmed for this bill's
  /// supplier, a trigram hit is a spelling similarity with a number attached, and
  /// a vector hit is "these two look alike to a model". Pure, so a test can assert
  /// the wording without pumping a widget.
  String get reasonLabel => switch (reason) {
    MatchReason.alias => _aliasLabel,
    MatchReason.trigram =>
      evidence.similarity == null
          ? 'Looks similar'
          : '${(evidence.similarity! * 100).round()}% similar',
    MatchReason.vector => 'Looks similar',
    MatchReason.unknown => 'Suggested',
  };

  /// The alias sentence: naming the alias is the point, unless it *is* the name.
  String get _aliasLabel {
    final alias = evidence.aliasName;
    if (alias == null ||
        alias.trim().toLowerCase() == name.trim().toLowerCase()) {
      return 'You matched this text before';
    }
    return 'Also called $alias';
  }
}

/// One line's worth of the answer: the text that was asked about, and what came
/// back for it.
class ProductMatch {
  /// Creates one line's answer.
  const ProductMatch({required this.candidates, this.rawName});

  /// Decodes one entry of `matches`.
  factory ProductMatch.fromJson(Map<String, dynamic> json) {
    final candidates = json['candidates'];

    return ProductMatch(
      // The matcher's trimmed echo of the text it was sent. Not a key: the answer
      // is aligned by position, and a line whose text had surrounding spaces would
      // find nothing by matching this string back.
      rawName: _text(json['raw_name']),
      candidates: candidates is List
          ? <MatchCandidate>[
              for (final entry in candidates) ?MatchCandidate.tryDecode(entry),
            ]
          : const <MatchCandidate>[],
    );
  }

  /// The invoice text this answer belongs to, as the matcher echoed it.
  final String? rawName;

  /// Ranked candidates, best first. Empty is a normal answer.
  final List<MatchCandidate> candidates;
}

/// What the matcher said about the run itself.
class MatchMeta {
  /// Creates the metadata.
  const MatchMeta({
    this.model,
    this.lineCount = 0,
    this.embedded = 0,
    this.vectorUsed = false,
    this.warnings = const <String>[],
  });

  /// Decodes the `meta` object.
  factory MatchMeta.fromJson(Map<String, dynamic> json) {
    final warnings = json['warnings'];

    return MatchMeta(
      model: _text(json['model']),
      lineCount: (_number(json['line_count']) ?? 0).round(),
      embedded: (_number(json['embedded']) ?? 0).round(),
      vectorUsed: json['vector_used'] == true,
      warnings: warnings is List
          ? <String>[
              // Strings only: a warning is a sentence somebody wrote for the user.
              for (final warning in warnings)
                if (warning is String && warning.trim().isNotEmpty)
                  warning.trim(),
            ]
          : const <String>[],
    );
  }

  /// The embedding model that answered, when the vector leg ran (D-030).
  final String? model;

  /// How many lines were sent.
  final int lineCount;

  /// How many of them got a query vector.
  final int embedded;

  /// Whether the vector leg ran at all.
  final bool vectorUsed;

  /// Sentences written for a person: why a leg was skipped, or that the bill was
  /// truncated. The screen shows these rather than logging them.
  final List<String> warnings;
}

/// The whole answer for one bill: one entry per line, and the run's metadata.
class ProductMatches {
  /// Creates an answer.
  const ProductMatches({required this.lines, required this.meta});

  /// Decodes the function's 200 body.
  factory ProductMatches.fromJson(Map<String, dynamic> json) {
    final matches = json['matches'];

    return ProductMatches(
      lines: matches is List
          ? <ProductMatch>[
              for (final line in matches)
                if (line is Map)
                  ProductMatch.fromJson(line.cast<String, dynamic>()),
            ]
          : const <ProductMatch>[],
      meta: MatchMeta.fromJson(
        json['meta'] is Map
            ? (json['meta'] as Map).cast<String, dynamic>()
            : const {},
      ),
    );
  }

  /// One entry per line sent, in the order sent.
  final List<ProductMatch> lines;

  /// What the run said about itself.
  final MatchMeta meta;

  /// The candidates for the line that was sent at [index], or none.
  ///
  /// Position is the only key: `raw_name` comes back trimmed by the server, so
  /// looking a line up by its text is a lookup that fails on an untrimmed line and
  /// silently shifts every later line onto the wrong product.
  List<MatchCandidate> candidatesAt(int index) =>
      index >= 0 && index < lines.length
      ? lines[index].candidates
      : const <MatchCandidate>[];

  /// Whether the matcher found nothing for any line.
  bool get isEmpty => lines.every((line) => line.candidates.isEmpty);
}

/// A trimmed string, or `null` for anything missing or empty.
String? _text(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is num) {
    return value.toString();
  }
  return null;
}

/// A number that may arrive as a number or as text.
double? _number(Object? value) => switch (value) {
  final num number => number.toDouble(),
  final String text => double.tryParse(text.trim()),
  _ => null,
};
