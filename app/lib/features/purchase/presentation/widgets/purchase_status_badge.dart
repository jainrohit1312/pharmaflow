/// Colour-coded badge for a purchase document's status.
library;

import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/purchase.dart';
import 'package:flutter/material.dart';

/// Shows [status] as a badge, in the tone that status deserves.
///
/// Tone carries the one distinction that matters here: `received` is the single
/// status whose stock and supplier payable have been posted (D-013), so it is
/// the only one that reads as success, and `cancelled` is the only one that
/// reads as a problem. Draft and ordered are both "not real yet" and stay quiet
/// on purpose. A waiting document takes the warning tone, because it is the one
/// state somebody has to act on - the owner, by answering it.
class PurchaseStatusBadge extends StatelessWidget {
  /// Creates a badge for [status].
  const PurchaseStatusBadge({
    required this.status,
    super.key,
    this.stockPostedAt,
  });

  /// The document status to render.
  final PurchaseStatus status;

  /// The receipt marker, used to flag a document that reached `received`
  /// without stock being posted.
  final DateTime? stockPostedAt;

  @override
  Widget build(BuildContext context) {
    final (label, tone, icon) = _describe();
    return StatusBadge(label: label, tone: tone, icon: icon);
  }

  /// The badge's label, tone and icon for this status.
  ///
  /// `received` normally stamps `stock_posted_at` in the same transaction, so a
  /// missing stamp means the write was interrupted. That is worth showing rather
  /// than hiding: the document claims stock it may not have applied.
  (String, BadgeTone, IconData) _describe() {
    if (status == PurchaseStatus.received && stockPostedAt == null) {
      return (
        'Received, not posted',
        BadgeTone.warning,
        Icons.report_problem_outlined,
      );
    }

    return switch (status) {
      PurchaseStatus.draft => (
        status.label,
        BadgeTone.neutral,
        Icons.edit_note_outlined,
      ),
      PurchaseStatus.ordered => (
        status.label,
        BadgeTone.info,
        Icons.local_shipping_outlined,
      ),
      PurchaseStatus.received => (
        status.label,
        BadgeTone.success,
        Icons.inventory_2_outlined,
      ),
      PurchaseStatus.cancelled => (
        status.label,
        BadgeTone.danger,
        Icons.cancel_outlined,
      ),
      PurchaseStatus.pendingApproval => (
        status.label,
        BadgeTone.warning,
        Icons.hourglass_top_outlined,
      ),
    };
  }
}
