/// Brand and semantic colours used by the PharmaFlow visual system.
library;

import 'dart:ui' show Color;

/// Colour tokens consumed by the app theme and by feature widgets that need a
/// semantic colour outside of the Material colour scheme.
abstract final class AppColors {
  /// Seed colour from which the Material 3 colour scheme is generated.
  static const Color seed = Color(0xFF00897B);

  /// Confirmation, completion and "in stock" states.
  static const Color success = Color(0xFF2E7D32);

  /// Expiry warnings, low stock and other attention states.
  static const Color warning = Color(0xFFF9A825);

  /// Destructive actions, errors and "out of stock" states.
  static const Color danger = Color(0xFFC62828);

  /// Neutral, informational highlights.
  static const Color info = Color(0xFF1565C0);
}
