/// Badge for a sale's status.
library;

import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/sale.dart';
import 'package:flutter/material.dart';

/// How a sale's status reads as a badge tone.
extension SaleStatusBadgeX on SaleStatus {
  /// A settled sale is unremarkable; a credit sale is money outstanding.
  BadgeTone get badgeTone => switch (this) {
    SaleStatus.completed => BadgeTone.success,
    SaleStatus.credit => BadgeTone.warning,
    SaleStatus.cancelled => BadgeTone.neutral,
  };

  /// The icon shown beside the label.
  IconData get badgeIcon => switch (this) {
    SaleStatus.completed => Icons.check_circle_outline,
    SaleStatus.credit => Icons.schedule_outlined,
    SaleStatus.cancelled => Icons.cancel_outlined,
  };
}

/// A sale's status, as a badge.
class SaleStatusBadge extends StatelessWidget {
  /// Creates a status badge for [status].
  const SaleStatusBadge({required this.status, super.key});

  /// The status to label.
  final SaleStatus status;

  @override
  Widget build(BuildContext context) => StatusBadge(
    label: status.label,
    tone: status.badgeTone,
    icon: status.badgeIcon,
  );
}
