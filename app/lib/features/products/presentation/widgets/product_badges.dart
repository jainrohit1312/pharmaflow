/// Badges for product-domain states.
///
/// The translation from a domain enum to a [BadgeTone] lives here rather than on
/// the model, so the data layer never depends on the widget layer.
library;

import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:flutter/material.dart';

/// How tightly controlled a drug schedule is, as a badge tone.
extension ScheduleTypeBadgeX on ScheduleType {
  /// Over-the-counter is unremarkable; the prescription-only schedules are not.
  BadgeTone get badgeTone => switch (this) {
    ScheduleType.otc => BadgeTone.neutral,
    ScheduleType.h => BadgeTone.info,
    ScheduleType.h1 => BadgeTone.warning,
    ScheduleType.x || ScheduleType.narcotic => BadgeTone.danger,
  };
}

/// How urgent an expiry bucket is, as a badge tone.
extension ExpiryStatusBadgeX on ExpiryStatus {
  /// A batch that is expired and one that is about to expire both need action.
  BadgeTone get badgeTone => switch (this) {
    ExpiryStatus.safe => BadgeTone.success,
    ExpiryStatus.warning => BadgeTone.warning,
    ExpiryStatus.critical || ExpiryStatus.expired => BadgeTone.danger,
  };
}

/// The statutory schedule a product is sold under.
class ScheduleBadge extends StatelessWidget {
  /// Creates a schedule badge.
  const ScheduleBadge({required this.scheduleType, super.key});

  /// Schedule to label.
  final ScheduleType scheduleType;

  @override
  Widget build(BuildContext context) => StatusBadge(
    label: scheduleType.label,
    tone: scheduleType.badgeTone,
    icon: scheduleType.requiresPrescription ? Icons.assignment_outlined : null,
  );
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
