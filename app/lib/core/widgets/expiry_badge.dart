/// Badge for a batch's expiry bucket.
///
/// Shared rather than owned by one feature: the products detail screen shows it
/// on a product's batches and the inventory expiry dashboard shows it on every
/// batch in the pharmacy, and two mappings of the same enum would eventually
/// disagree about which bucket is urgent.
library;

import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:flutter/material.dart';

/// How urgent an expiry bucket is, as a badge tone.
extension ExpiryStatusBadgeX on ExpiryStatus {
  /// A batch that is expired and one that is about to expire both need action.
  BadgeTone get badgeTone => switch (this) {
    ExpiryStatus.safe => BadgeTone.success,
    ExpiryStatus.warning => BadgeTone.warning,
    ExpiryStatus.critical || ExpiryStatus.expired => BadgeTone.danger,
  };
}

/// A batch's expiry bucket, as the database computed it.
class ExpiryBadge extends StatelessWidget {
  /// Creates an expiry badge.
  const ExpiryBadge({required this.status, super.key});

  /// Bucket to label.
  final ExpiryStatus status;

  @override
  Widget build(BuildContext context) => StatusBadge(
    label: status.label,
    tone: status.badgeTone,
    icon: status == ExpiryStatus.expired
        ? Icons.error_outline
        : Icons.event_outlined,
  );
}
