/// Unit tests for [Debouncer].
library;

import 'package:app/core/utils/debouncer.dart';
import 'package:flutter_test/flutter_test.dart';

/// How long to wait for a [Debouncer] with a 20ms delay to settle.
const _settle = Duration(milliseconds: 60);

void main() {
  test('collapses a burst of calls into one action', () async {
    final debouncer = Debouncer(delay: const Duration(milliseconds: 20));
    var calls = 0;
    void schedule() => debouncer.run(() => calls++);

    for (var attempt = 0; attempt < 3; attempt++) {
      schedule();
    }

    expect(calls, isZero, reason: 'nothing runs before the delay elapses');

    await Future<void>.delayed(_settle);

    expect(calls, 1, reason: 'only the last action survives');
    debouncer.dispose();
  });

  test('cancel drops a pending action', () async {
    final debouncer = Debouncer(delay: const Duration(milliseconds: 20));
    var calls = 0;
    void schedule() => debouncer.run(() => calls++);

    schedule();
    debouncer.cancel();

    await Future<void>.delayed(_settle);

    expect(calls, isZero);
    debouncer.dispose();
  });

  test('is reusable after the previous action fired', () async {
    final debouncer = Debouncer(delay: const Duration(milliseconds: 20));
    var calls = 0;
    void schedule() => debouncer.run(() => calls++);

    schedule();
    await Future<void>.delayed(_settle);
    expect(calls, 1);

    schedule();
    await Future<void>.delayed(_settle);
    expect(calls, 2, reason: 'a debouncer is not single-shot');

    debouncer.dispose();
  });
}
