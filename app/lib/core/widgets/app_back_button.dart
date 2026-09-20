/// App-bar back affordance that returns to a fixed location.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// A back button that navigates to [location] rather than popping.
///
/// PharmaFlow navigates with `context.go`, so screens do not sit on a push
/// stack: `context.pop()` has nothing to pop, and on the web a deep link or a
/// page refresh leaves the user with no history at all. A fixed destination is
/// deterministic on every platform and every entry point.
class AppBackButton extends StatelessWidget {
  /// Creates a back button that goes to [location].
  const AppBackButton({
    required this.location,
    super.key,
    this.tooltip = 'Back',
    this.enabled = true,
  });

  /// Where the button navigates to.
  final String location;

  /// Tooltip and screen-reader label.
  final String tooltip;

  /// Whether the button can be pressed.
  ///
  /// False renders it greyed and inert. For a screen with a step that must
  /// finish - an import being written, a file being sent - leaving is not a
  /// choice it can honour, so the affordance is disabled rather than removed:
  /// the button the user knows is there is the one that comes back.
  final bool enabled;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back),
    tooltip: tooltip,
    onPressed: enabled ? () => context.go(location) : null,
  );
}
