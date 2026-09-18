/// Tests for the expiry calendar: the month arithmetic, and the screen.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/inventory/application/expiry_batch.dart';
import 'package:app/features/inventory/application/expiry_calendar_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_inventory_repository.dart';
import '../../support/fake_products_repository.dart';
import '../../support/inventory_test_app.dart';

/// The current month, which is the one the calendar opens on.
final DateTime _thisMonth = firstOfMonth(DateTime.now());

/// A day in the current month that will not collide with another cell's digits.
final DateTime _busyDay = DateTime(_thisMonth.year, _thisMonth.month, 20);

void main() {
  group('month arithmetic', () {
    test('normalises a month to its first day', () {
      expect(firstOfMonth(DateTime(2026, 9, 18)), DateTime(2026, 9));
    });

    test('finds the last day, leap years included', () {
      expect(lastOfMonth(DateTime(2026, 9)), DateTime(2026, 9, 30));
      expect(lastOfMonth(DateTime(2026, 2)), DateTime(2026, 2, 28));
      expect(lastOfMonth(DateTime(2028, 2)), DateTime(2028, 2, 29));
      expect(lastOfMonth(DateTime(2026, 12)), DateTime(2026, 12, 31));
    });

    test('steps to the next and previous month', () {
      final state = ExpiryCalendarState(month: DateTime(2026));

      expect(state.withMonth(DateTime(2026, 2, 15)).month, DateTime(2026, 2));
      // December to January is the wrap that a naive `month + 1` gets wrong.
      expect(state.withMonth(DateTime(2026, 12)).month, DateTime(2026, 12));
    });

    test('changing the month drops the selected day', () {
      // A day selected in September means nothing in October, and carrying it
      // over would filter the list to a day the user never picked.
      final state = ExpiryCalendarState(
        month: DateTime(2026, 9),
      ).withDay(DateTime(2026, 9, 20));

      expect(state.selectedDay, DateTime(2026, 9, 20));
      expect(state.withMonth(DateTime(2026, 10)).selectedDay, isNull);
    });

    test('reports the units and the rows for a day', () {
      final month = ExpiryMonth(
        rows: <ExpiryBatch>[
          ExpiryBatch(
            batch: buildBatch(id: 'b1', expiryDate: DateTime(2026, 9, 20)),
            productName: 'Dolo 650',
          ),
          ExpiryBatch(
            batch: buildBatch(id: 'b2', expiryDate: DateTime(2026, 9, 20)),
            productName: 'Amoxicillin',
          ),
        ],
        unitsByDay: const <int, int>{20: 15},
      );

      expect(month.unitsOn(20), 15);
      expect(month.unitsOn(21), 0);
      expect(month.rowsOn(DateTime(2026, 9, 20)), hasLength(2));
      expect(month.rowsOn(DateTime(2026, 9, 21)), isEmpty);
    });
  });

  group('the calendar screen', () {
    testWidgets('shows the month, its units and the batches behind them', (
      tester,
    ) async {
      await pumpInventoryApp(
        tester,
        repository: FakeInventoryRepository(
          batches: <BatchStatus>[
            buildBatch(
              expiryDate: _busyDay,
              qty: 3,
              expiryStatus: ExpiryStatus.warning,
            ),
          ],
        ),
        products: FakeProductsRepository(
          products: <Product>[buildProduct('Dolo 650', id: 'product-1')],
        ),
        initialLocation: Routes.inventoryCalendar,
      );

      expect(find.text(Formatters.monthYear(_thisMonth)), findsOneWidget);
      expect(find.text('Dolo 650'), findsOneWidget);
      expect(find.text('1 batch this month · 3 units'), findsOneWidget);
      // The 20th, and only the 20th: the cell's unit count is 3, so no other
      // cell renders those two digits.
      expect(find.text('20'), findsOneWidget);
    });

    testWidgets('filters the list to a tapped day, and clears it again', (
      tester,
    ) async {
      await pumpInventoryApp(
        tester,
        repository: FakeInventoryRepository(
          batches: <BatchStatus>[
            buildBatch(
              expiryDate: _busyDay,
              qty: 3,
              expiryStatus: ExpiryStatus.warning,
            ),
          ],
        ),
        products: FakeProductsRepository(
          products: <Product>[buildProduct('Dolo 650', id: 'product-1')],
        ),
        initialLocation: Routes.inventoryCalendar,
      );

      await tester.tap(find.text('20'));
      await tester.pumpAndSettle();

      expect(
        find.text('1 batch on ${Formatters.dateDdMmmYyyy(_busyDay)} · 3 units'),
        findsOneWidget,
      );
      expect(find.text('Whole month'), findsOneWidget);

      // A day with nothing on it says so rather than showing the month's rows.
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing expires that day'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Whole month'));
      await tester.pumpAndSettle();
      expect(find.text('Dolo 650'), findsOneWidget);
    });

    testWidgets('says so when the month has nothing in it', (tester) async {
      await pumpInventoryApp(
        tester,
        repository: FakeInventoryRepository(),
        initialLocation: Routes.inventoryCalendar,
      );

      expect(find.text('Nothing expires this month'), findsOneWidget);
    });
  });
}
