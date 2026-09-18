/// Badges for product-domain states.
///
/// The translation from a domain enum to a [BadgeTone] lives here rather than on
/// the model, so the data layer never depends on the widget layer.
///
/// `ExpiryBadge` used to live here too; it moved to `core/widgets/expiry_badge.dart`
/// when the inventory expiry dashboard needed the same badge, so the two screens
/// cannot drift apart on which expiry bucket is urgent.
library;

import 'package:app/core/widgets/status_badge.dart';
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
