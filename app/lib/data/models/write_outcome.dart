/// What a write did: it landed, or it is waiting for the owner.
library;

/// The answer to a write that the owner may have to approve first.
///
/// A purchase return, a sale return and a stock adjustment are **requests** for anybody but
/// the owner (Phase 6.5c): the whole document travels to the owner in the request's payload
/// and **nothing is written** until he approves it. So there is no row to answer with, and the
/// server's `record_*()` functions answer with this envelope instead:
///
///     {"outcome": "recorded", "document": {...}, "request_id": null}
///     {"outcome": "staged",   "document": null,  "request_id": "uuid"}
///
/// A screen branches on [isStaged] rather than on a role: it either opens the document that
/// now exists or says where the work went. Guessing from the viewer's role would show the owner
/// a "waiting" message for a write that had already landed.
class WriteOutcome<T> {
  /// Creates an outcome for a write that landed, with the document it wrote.
  const WriteOutcome.recorded(this.document) : requestId = null;

  /// Creates an outcome for a write that is waiting for the owner.
  const WriteOutcome.staged(this.requestId) : document = null;

  /// Decodes the envelope the `record_*()` functions answer with.
  ///
  /// [decode] turns the `document` member into [T] and is only called when there is one, so a
  /// staged write never has to invent a document to decode.
  factory WriteOutcome.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) decode,
  ) {
    final document = json['document'];
    if (json['outcome'] == 'recorded' && document is Map<String, dynamic>) {
      return WriteOutcome<T>.recorded(decode(document));
    }
    return WriteOutcome<T>.staged(json['request_id'] as String);
  }

  /// The document the write produced, or `null` when the owner has to answer first.
  final T? document;

  /// The approval request this write raised, or `null` when it landed.
  final String? requestId;

  /// Whether the owner still has to answer before this write counts.
  bool get isStaged => requestId != null;
}
