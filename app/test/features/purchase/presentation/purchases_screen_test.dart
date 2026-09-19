/// Widget tests for the purchase list screen.
///
/// These drive the whole vertical slice for reading purchases - screen, filter
/// bar, list provider and repository - against a fake repository, so a
/// regression in how filtering and paging fit together shows up here rather than
/// in front of a user.
library;

import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_card.dart';
import 'package:app/features/purchase_ocr/presentation/purchase_ocr_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_purchases_repository.dart';
import '../../../support/purchase_test_app.dart';

void main() {
  testWidgets('offers reading a bill, beside the other two ways in', (
    tester,
  ) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(purchases: <Purchase>[]),
    );

    await tester.tap(find.byTooltip('Read a bill'));
    await tester.pumpAndSettle();

    expect(find.byType(PurchaseOcrScreen), findsOneWidget);
  });

  testWidgets('lists every purchase with the supplier it came from', (
    tester,
  ) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(
        purchases: <Purchase>[
          buildPurchase(),
          buildPurchase(
            id: 'purchase-2',
            supplierId: 'sup-2',
            invoiceNo: 'INV-2',
          ),
        ],
      ),
      suppliers: <Supplier>[
        buildSupplier(),
        buildSupplier(id: 'sup-2', name: 'MedPlus Wholesale'),
      ],
    );

    // Scoped to the card: a `DropdownButton` keeps every item it was given in
    // its tree, so a bare `find.text` would also match the supplier filter.
    expect(
      find.widgetWithText(PurchaseCard, 'Arihant Distributors'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(PurchaseCard, 'MedPlus Wholesale'),
      findsOneWidget,
    );
    expect(find.textContaining('INV-1'), findsOneWidget);
    expect(find.textContaining('INV-2'), findsOneWidget);
  });

  testWidgets('shows the empty state for a pharmacy with no purchases', (
    tester,
  ) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(purchases: const <Purchase>[]),
    );

    expect(find.byType(AppEmptyView), findsOneWidget);
    expect(find.text('No purchases found'), findsOneWidget);
  });

  testWidgets('narrows the list when the user searches', (tester) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(
        purchases: <Purchase>[
          buildPurchase(),
          buildPurchase(id: 'purchase-2', invoiceNo: 'INV-2'),
        ],
      ),
    );
    expect(find.byType(PurchaseCard), findsNWidgets(2));

    await tester.enterText(find.byType(TextField).first, 'INV-2');
    // Past the debounce, then settle the request it triggers.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.byType(PurchaseCard), findsOneWidget);
    // Asserted on the invoice that should be *gone*: `INV-2` now also sits in
    // the search field, so a `textContaining` on it would match twice.
    expect(find.textContaining('INV-1'), findsNothing);
  });

  testWidgets('filters the list by status', (tester) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(
        purchases: <Purchase>[
          buildPurchase(),
          buildPurchase(
            id: 'purchase-2',
            invoiceNo: 'INV-2',
            status: PurchaseStatus.received,
            stockPostedAt: DateTime(2026),
          ),
        ],
      ),
    );

    // Targeted through the chip rather than its text: the received card carries
    // the same label in its status badge.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Received'));
    await tester.pumpAndSettle();

    expect(find.textContaining('INV-1'), findsNothing);
    expect(find.textContaining('INV-2'), findsOneWidget);
  });

  testWidgets('opens a purchase when its card is tapped', (tester) async {
    await pumpPurchaseApp(
      tester,
      repository: FakePurchasesRepository(
        purchases: <Purchase>[buildPurchase()],
        items: <PurchaseItem>[buildItem()],
      ),
    );

    await tester.tap(find.byType(PurchaseCard));
    await tester.pumpAndSettle();

    // The detail screen has sections the list does not, so finding them proves
    // the tap landed where it should.
    expect(find.text('Totals'), findsOneWidget);
    expect(find.text('Lines'), findsOneWidget);
  });
}
