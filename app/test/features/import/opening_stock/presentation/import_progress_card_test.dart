/// The upload's progress card, step by step.
///
/// Pumped directly rather than through the screen, because the screen can only
/// ever show the last of the three steps: the read and the send are finished by
/// the time a frame renders them. Every step still has to be drawn correctly -
/// that is what the ticks mean - so each is pumped here.
library;

import 'package:app/features/import/opening_stock/application/opening_stock_controller.dart';
import 'package:app/features/import/opening_stock/presentation/widgets/import_progress_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps the card on [phase] with the real file name.
Future<void> pumpCard(WidgetTester tester, OpeningStockImportPhase phase) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImportProgressCard(
            phase: phase,
            fileName: 'PharmaFlow_Opening_Stock.csv',
          ),
        ),
      ),
    );

/// Tears the card down, which is what stops its clock.
Future<void> disposeCard(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

void main() {
  testWidgets('names the three steps and the file being read', (tester) async {
    await pumpCard(tester, OpeningStockImportPhase.classifying);

    expect(find.text('PharmaFlow_Opening_Stock.csv'), findsOneWidget);
    expect(find.text('Reading the file'), findsOneWidget);
    expect(find.text('Sending to the server'), findsOneWidget);
    expect(find.text('Classifying the products'), findsOneWidget);

    await disposeCard(tester);
  });

  testWidgets('ticks the read and spins on the send while it is in flight', (
    tester,
  ) async {
    await pumpCard(tester, OpeningStockImportPhase.sending);

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);

    await disposeCard(tester);
  });

  testWidgets('ticks the read and the send while the server classifies', (
    tester,
  ) async {
    await pumpCard(tester, OpeningStockImportPhase.classifying);

    // The send has no duration this app can see, so it is done the moment the
    // request exists - and the step the owner is waiting on is the server's.
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);

    await disposeCard(tester);
  });

  testWidgets('spins on the read, with nothing behind it, while reading', (
    tester,
  ) async {
    await pumpCard(tester, OpeningStockImportPhase.reading);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));

    await disposeCard(tester);
  });

  testWidgets('counts the seconds it has been working', (tester) async {
    await pumpCard(tester, OpeningStockImportPhase.classifying);

    expect(find.text('Working… 0s elapsed'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Working… 4s elapsed'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Working… 6s elapsed'), findsOneWidget);

    await disposeCard(tester);
  });

  testWidgets('says no percentage and shows no progress bar', (tester) async {
    await pumpCard(tester, OpeningStockImportPhase.classifying);

    // The claim this card makes is that it does not pretend to know how far
    // along the server is.
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('%'), findsNothing);

    await disposeCard(tester);
  });
}
