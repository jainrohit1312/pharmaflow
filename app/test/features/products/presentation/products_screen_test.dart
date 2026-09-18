/// Widget tests for the product list screen.
///
/// These drive the whole vertical slice for reading products - screen, filter
/// bar, list provider and repository - against a fake repository, so a
/// regression in how filtering and paging fit together shows up here rather
/// than in front of a user.
library;

import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/products/presentation/products_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_products_repository.dart';

/// Pumps the list screen over [repository] and lets the first load settle.
Future<void> _pump(
  WidgetTester tester,
  FakeProductsRepository repository,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productsRepositoryProvider.overrideWithValue(repository),
        requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      ],
      child: const MaterialApp(home: ProductsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists every product', (tester) async {
    await _pump(
      tester,
      FakeProductsRepository(
        products: <Product>[
          buildProduct('Dolo 650'),
          buildProduct('Paracetamol'),
        ],
      ),
    );

    expect(find.text('Dolo 650'), findsOneWidget);
    expect(find.text('Paracetamol'), findsOneWidget);
  });

  testWidgets('shows the empty state for an empty catalogue', (tester) async {
    await _pump(tester, FakeProductsRepository(products: const <Product>[]));

    expect(find.byType(AppEmptyView), findsOneWidget);
    expect(find.text('No products found'), findsOneWidget);
    expect(
      find.text('Add your first product to start building the catalogue.'),
      findsOneWidget,
    );
  });

  testWidgets('narrows the list when the user searches', (tester) async {
    await _pump(
      tester,
      FakeProductsRepository(
        products: <Product>[
          buildProduct('Dolo 650'),
          buildProduct('Paracetamol'),
        ],
      ),
    );
    expect(find.text('Paracetamol'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Dolo');
    // Past the debounce, then settle the request it triggers.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Paracetamol'), findsNothing);
    expect(find.text('Dolo 650'), findsOneWidget);
  });

  testWidgets('filters by schedule', (tester) async {
    await _pump(
      tester,
      FakeProductsRepository(
        products: <Product>[
          buildProduct('Dolo 650'),
          buildProduct('Morphine', scheduleType: ScheduleType.h),
        ],
      ),
    );

    // Targeted through the chip rather than its text: a card badge carries the
    // same label, and the chips near the end of the row are off-screen.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Schedule H'));
    await tester.pumpAndSettle();

    expect(find.text('Morphine'), findsOneWidget);
    expect(find.text('Dolo 650'), findsNothing);
  });

  testWidgets('explains an empty result that came from filtering', (
    tester,
  ) async {
    await _pump(
      tester,
      FakeProductsRepository(products: <Product>[buildProduct('Dolo 650')]),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'Schedule H'));
    await tester.pumpAndSettle();

    expect(
      find.text('Nothing matches the current search and filters.'),
      findsOneWidget,
    );
  });
}
