/// Debouncer used to coalesce rapid input before it reaches a provider.
library;

import 'dart:async';

/// Runs an action once, a fixed delay after the last [run] call.
///
/// Owned by the controller that creates it and released with [dispose], so a
/// pending timer can never outlive the provider or fire into a disposed state.
class Debouncer {
  /// Creates a debouncer that waits [delay] after the most recent call.
  Debouncer({this.delay = const Duration(milliseconds: 350)});

  /// How long to wait after the most recent [run] before firing.
  final Duration delay;

  Timer? _timer;

  /// Schedules [action], replacing any action that was still pending.
  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  /// Cancels a pending action without running it.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Cancels any pending action; call from the owner's disposal path.
  void dispose() => cancel();
}
