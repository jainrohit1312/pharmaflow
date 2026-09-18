/// Colour-coded status pill used for schedule, expiry, stock and document
/// states.
library;

import 'package:app/core/theme/app_colors.dart';
import 'package:flutter/material.dart';

/// Semantic meaning of a badge, independent of the domain enum behind it.
///
/// Feature widgets translate their own states (drug schedule, expiry bucket,
/// document status, stock level) into a tone. Keeping the translation in the
/// presentation layer is what stops the data models from depending on the
/// widget layer.
enum BadgeTone {
  /// No judgement either way; the default.
  neutral,

  /// Informational highlight.
  info,

  /// Confirmation, completion, "in stock".
  success,

  /// Attention needed: expiring soon, low stock.
  warning,

  /// Urgent: expired, out of stock, cancelled.
  danger,
}

/// A compact, colour-coded label.
class StatusBadge extends StatelessWidget {
  /// Creates a badge showing [label] in the colour for [tone].
  const StatusBadge({
    required this.label,
    super.key,
    this.tone = BadgeTone.neutral,
    this.icon,
  });

  /// Text shown inside the pill.
  final String label;

  /// Semantic colour family.
  final BadgeTone tone;

  /// Optional leading icon.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _toneColor(tone, theme.colorScheme);
    final badgeIcon = icon;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (badgeIcon != null) ...<Widget>[
            Icon(badgeIcon, size: 14, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Resolves a [BadgeTone] to a colour that stays legible on the current
/// surface.
///
/// The palette tokens are tuned for light surfaces, so on a dark surface they
/// are lifted towards white before use - otherwise every tone reads as a dark
/// smudge.
Color _toneColor(BadgeTone tone, ColorScheme scheme) {
  final token = switch (tone) {
    BadgeTone.neutral => scheme.onSurfaceVariant,
    BadgeTone.info => AppColors.info,
    BadgeTone.success => AppColors.success,
    BadgeTone.warning => AppColors.warning,
    BadgeTone.danger => AppColors.danger,
  };
  if (scheme.brightness != Brightness.dark || tone == BadgeTone.neutral) {
    return token;
  }
  return Color.alphaBlend(const Color(0x59FFFFFF), token);
}
