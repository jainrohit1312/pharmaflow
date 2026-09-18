/// Widget tests for [ProductCard].
library;

import 'package:app/data/models/product.dart';
import 'package:app/features/products/presentation/widgets/product_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_products_repository.dart';

/// Pumps [card] inside the smallest tree that can render it.
Future<void> _pumpCard(WidgetTester tester, ProductCard card) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: card)));

void main() {
  testWidgets('shows the name and the schedule', (tester) async {
    await _pumpCard(tester, ProductCard(product: buildProduct('Dolo 650')));

    expect(find.text('Dolo 650'), findsOneWidget);
    expect(find.text('OTC'), findsOneWidget);
  });

  testWidgets('marks a prescription-only schedule', (tester) async {
    await _pumpCard(
      tester,
      ProductCard(
        product: buildProduct('Morphine', scheduleType: ScheduleType.narcotic),
      ),
    );

    expect(find.text('Narcotic'), findsOneWidget);
  });

  testWidgets('marks an inactive product', (tester) async {
    await _pumpCard(
      tester,
      ProductCard(product: buildProduct('Old syrup', isActive: false)),
    );

    expect(find.text('Inactive'), findsOneWidget);
  });

  testWidgets('reports taps', (tester) async {
    var tapped = false;
    await _pumpCard(
      tester,
      ProductCard(
        product: buildProduct('Dolo 650'),
        onTap: () => tapped = true,
      ),
    );

    await tester.tap(find.text('Dolo 650'));
    await tester.pump();

    expect(tapped, isTrue);
  });
}
