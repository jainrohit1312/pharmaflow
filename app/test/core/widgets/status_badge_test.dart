/// Widget tests for [StatusBadge].
library;

import 'package:app/core/theme/app_theme.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps [badge] inside the smallest tree that can render it.
Future<void> _pumpBadge(WidgetTester tester, Widget badge) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: Center(child: badge)),
  ),
);

void main() {
  testWidgets('renders its label', (tester) async {
    await _pumpBadge(tester, const StatusBadge(label: 'Schedule H'));

    expect(find.text('Schedule H'), findsOneWidget);
  });

  testWidgets('renders an icon only when one is supplied', (tester) async {
    await _pumpBadge(tester, const StatusBadge(label: 'Expired'));
    expect(find.byIcon(Icons.error_outline), findsNothing);

    await _pumpBadge(
      tester,
      const StatusBadge(label: 'Expired', icon: Icons.error_outline),
    );
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('gives different tones different colours', (tester) async {
    /// The resolved text colour of the badge currently on screen.
    Color colourOf() {
      final text = tester.widget<Text>(find.text('Tone'));
      return text.style!.color!;
    }

    await _pumpBadge(
      tester,
      const StatusBadge(label: 'Tone', tone: BadgeTone.danger),
    );
    final danger = colourOf();

    await _pumpBadge(
      tester,
      const StatusBadge(label: 'Tone', tone: BadgeTone.success),
    );
    final success = colourOf();

    expect(danger, isNot(equals(success)));
  });

  testWidgets('lifts tones towards white on a dark surface', (tester) async {
    /// Luminance of the same badge under [theme].
    ///
    /// The app's own themes are used rather than `ThemeData(brightness: ...)`,
    /// because a bare brightness does not give the theme a matching
    /// `colorScheme` - and the colour scheme's brightness is what the badge
    /// branches on. `pumpAndSettle` is required because `MaterialApp` swaps
    /// themes through an `AnimatedTheme`: reading straight after the pump would
    /// still see the previous theme mid-transition.
    Future<double> luminanceUnder(ThemeData theme) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: Center(
              child: StatusBadge(label: 'Tone', tone: BadgeTone.warning),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(find.text('Tone'));
      return text.style!.color!.computeLuminance();
    }

    final light = await luminanceUnder(AppTheme.light);
    final dark = await luminanceUnder(AppTheme.dark);

    // Relative to the light rendering rather than an absolute threshold, so the
    // test fails if the dark-surface lift is ever dropped.
    expect(dark, greaterThan(light));
  });
}
