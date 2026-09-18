/// The shared application logger.
library;

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

/// Process-wide logger used by every layer.
///
/// Verbose in debug builds; release builds are capped at [Level.warning] so
/// that production logs stay small and cheap.
///
/// The filter is stated explicitly because logger's default
/// (`DevelopmentFilter`) discards *every* record as soon as asserts are
/// compiled out, which would make the release level a no-op.
final Logger appLogger = Logger(
  filter: kReleaseMode ? ProductionFilter() : DevelopmentFilter(),
  level: kReleaseMode ? Level.warning : Level.trace,
  printer: PrettyPrinter(
    methodCount: 0,
    printEmojis: false,
    // ANSI colours only make sense where a terminal renders them.
    colors: !kIsWeb,
  ),
);
