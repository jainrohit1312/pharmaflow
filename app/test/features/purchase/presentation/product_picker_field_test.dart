/// Widget tests for the product field: the search dialog it has always had, and
/// the matcher's suggestions under it.
///
/// The rule under test throughout is **offered, never applied**: nothing about the
/// line changes until a candidate is tapped, because a wrong auto-fill on a
/// received invoice is a stock error rather than a typo.
library;

import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_match.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/purchase/presentation/widgets/product_picker_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_match_service.dart';
import '../../../support/fake_products_repository.dart';

/// What a pump recorded.
typedef FieldProbe = ({List<MatchCandidate> accepted, List<Product> picked});

/// Pumps one field with [suggestions] offered and [products] searchable.
Future<FieldProbe> pumpField(
  WidgetTester tester, {
  List<MatchCandidate> suggestions = const <MatchCandidate>[],
  bool offerSuggestions = true,
  bool enabled = true,
  String? selectedName,
  List<Product> products = const <Product>[],
}) async {
  final accepted = <MatchCandidate>[];
  final picked = <Product>[];

  await tester.pumpWidget(
    ProviderScope(
      // Inferred, not `<Override>[...]`: `Override` is not exported by
      // `flutter_riverpod`.
      overrides: [
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
        productsRepositoryProvider.overrideWithValue(
          FakeProductsRepository(products: products),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ProductPickerField(
            onSelected: picked.add,
            selectedName: selectedName,
            enabled: enabled,
            suggestions: suggestions,
            onSuggestionSelected: offerSuggestions ? accepted.add : null,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return (accepted: accepted, picked: picked);
}

void main() {
  testWidgets('offers the ranked head, with the reason each is offered', (
    tester,
  ) async {
    final field = await pumpField(
      tester,
      suggestions: <MatchCandidate>[
        buildCandidate(
          'Dolo 650',
          reason: MatchReason.alias,
          score: 1,
          packSize: '15',
          aliasName: 'DOLO-650 TAB',
        ),
        buildCandidate('Dolo 500', score: 0.44),
        buildCandidate('Dolo 125', score: 0.31),
        buildCandidate('Zetamac 500', score: 0.2),
        buildCandidate('Cetirizine 10', reason: MatchReason.vector, score: 0.9),
      ],
    );

    expect(find.text('In your catalogue — tap to use'), findsOneWidget);
    expect(
      find.text('Dolo 650 · 15'),
      findsOneWidget,
      reason: 'the pack is how two strengths of one brand are told apart',
    );
    expect(find.text('Also called DOLO-650 TAB'), findsOneWidget);
    expect(find.text('Dolo 500'), findsOneWidget);
    expect(find.text('44% similar'), findsOneWidget);

    expect(
      find.text('Dolo 125'),
      findsOneWidget,
      reason: 'three rows is the cap on a twenty-line bill',
    );
    expect(
      find.text('Zetamac 500'),
      findsNothing,
      reason: 'the search dialog is one tap away for the rest',
    );
    expect(find.text('Cetirizine 10'), findsNothing);

    // Offered, never applied: the field is untouched until something is tapped.
    expect(field.accepted, isEmpty);
    expect(field.picked, isEmpty);
    expect(find.text('Search the catalogue'), findsOneWidget);
  });

  testWidgets('reports a candidate when it is the one tapped', (tester) async {
    final field = await pumpField(
      tester,
      suggestions: <MatchCandidate>[buildCandidate('Dolo 650')],
    );

    await tester.tap(find.text('87% similar'));
    await tester.pumpAndSettle();

    expect(field.accepted.single.name, 'Dolo 650');
    expect(field.accepted.single.reasonLabel, '87% similar');
    expect(
      field.picked,
      isEmpty,
      reason:
          'a suggestion is not a catalogue row; the caller decides what to do',
    );
  });

  testWidgets('says nothing at all when there is nothing to suggest', (
    tester,
  ) async {
    await pumpField(tester);

    expect(find.text('In your catalogue — tap to use'), findsNothing);
    expect(find.text('Search the catalogue'), findsOneWidget);
  });

  testWidgets('shows no candidates when nobody can apply them', (tester) async {
    // A screen with no way to accept a suggestion must not be shown one: the
    // manual purchase form gets exactly this widget.
    await pumpField(
      tester,
      suggestions: <MatchCandidate>[buildCandidate('Dolo 650')],
      offerSuggestions: false,
    );

    expect(find.text('Dolo 650'), findsNothing);
  });

  testWidgets('shows no candidates on a field that is not accepting taps', (
    tester,
  ) async {
    await pumpField(
      tester,
      suggestions: <MatchCandidate>[buildCandidate('Dolo 650')],
      enabled: false,
    );

    expect(find.text('Dolo 650'), findsNothing);
  });

  testWidgets('still opens the search when the field itself is tapped', (
    tester,
  ) async {
    // The candidates sit *under* the field, not inside its tap target: a tap on
    // the field has to keep doing what it always did.
    await pumpField(
      tester,
      suggestions: <MatchCandidate>[buildCandidate('Dolo 650')],
      products: <Product>[buildProduct('Dolo 650')],
    );

    await tester.tap(find.text('Search the catalogue'));
    await tester.pumpAndSettle();

    expect(find.text('Find a product'), findsOneWidget);
    expect(find.text('Dolo 650'), findsWidgets);
  });
}
