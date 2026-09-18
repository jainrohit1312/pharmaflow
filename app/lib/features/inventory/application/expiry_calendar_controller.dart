/// Which month the expiry calendar shows, and what expires in it.
library;

import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/inventory/application/expiry_batch.dart';
import 'package:app/features/inventory/data/inventory_repository.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'expiry_calendar_controller.g.dart';

/// The first day of the month [date] falls in.
///
/// The calendar's unit is a month, and a `DateTime` that carries a month plus a
/// stray day is how "which month am I on" answers the wrong question after two
/// taps. Every month value in this file is normalised through here.
DateTime firstOfMonth(DateTime date) => DateTime(date.year, date.month);

/// The last day of the month [date] falls in.
///
/// Day 0 of the next month is the last day of this one, so this needs no
/// knowledge of month lengths or leap years.
DateTime lastOfMonth(DateTime date) => DateTime(date.year, date.month + 1, 0);

/// Which month, and which day within it, the calendar is showing.
class ExpiryCalendarState {
  /// Creates a calendar state.
  const ExpiryCalendarState({required this.month, this.selectedDay});

  /// The month on screen, normalised to its first day.
  final DateTime month;

  /// The day the list below the grid is filtered to, or `null` for the month.
  final DateTime? selectedDay;

  /// A copy with individual fields replaced.
  ///
  /// `selectedDay` is cleared explicitly rather than through a nullable
  /// parameter, because `copyWith(selectedDay: null)` cannot be told from
  /// "leave it alone".
  ExpiryCalendarState withMonth(DateTime value) =>
      ExpiryCalendarState(month: firstOfMonth(value));

  /// A copy filtered to [day], or to the whole month when [day] is `null`.
  ExpiryCalendarState withDay(DateTime? day) =>
      ExpiryCalendarState(month: month, selectedDay: day);
}

/// The expiry calendar's month and selected day.
///
/// Kept alive: stepping to a month is deliberate work, and losing the month
/// because the user opened a batch's product and came back would be worse than
/// refetching.
@Riverpod(keepAlive: true)
class ExpiryCalendarController extends _$ExpiryCalendarController {
  @override
  ExpiryCalendarState build() =>
      ExpiryCalendarState(month: firstOfMonth(DateTime.now()));

  /// Steps a month forward.
  void nextMonth() => state = state.withMonth(
    DateTime(state.month.year, state.month.month + 1),
  );

  /// Steps a month back.
  void previousMonth() => state = state.withMonth(
    DateTime(state.month.year, state.month.month - 1),
  );

  /// Returns to the month containing today.
  void thisMonth() => state = state.withMonth(DateTime.now());

  /// Filters the list below the grid to [day], or clears the filter with `null`.
  ///
  /// Tapping the selected day again clears it, which is what makes the grid
  /// usable without a separate "show all" control.
  void selectDay(DateTime? day) {
    final selected = state.selectedDay;
    final sameDay =
        selected != null &&
        day != null &&
        selected.year == day.year &&
        selected.month == day.month &&
        selected.day == day.day;
    state = state.withDay(sameDay ? null : day);
  }
}

/// One month of expiries: the batches, and units per day for the grid.
class ExpiryMonth {
  /// Creates a month.
  const ExpiryMonth({required this.rows, required this.unitsByDay});

  /// The month's batches holding stock, soonest expiry first.
  final List<ExpiryBatch> rows;

  /// Units expiring on each day that has any, keyed by day-of-month.
  ///
  /// Keyed by the day number rather than a `DateTime` so the grid can look a
  /// cell up directly, without building a date per cell and hoping the two
  /// agree about time-of-day.
  final Map<int, int> unitsByDay;

  /// Units expiring on day [day] of the month, or 0.
  int unitsOn(int day) => unitsByDay[day] ?? 0;

  /// The batches expiring on [day], in FEFO order.
  List<ExpiryBatch> rowsOn(DateTime day) => rows
      .where(
        (row) =>
            row.batch.expiryDate.year == day.year &&
            row.batch.expiryDate.month == day.month &&
            row.batch.expiryDate.day == day.day,
      )
      .toList(growable: false);
}

/// The batches holding stock that expire in the month on screen.
///
/// One month at a time on purpose: the grid only asks about the month it draws,
/// and reading a pharmacy's whole expiry history to render 30 cells would get
/// slower every month it trades.
@riverpod
class ExpiryMonthController extends _$ExpiryMonthController {
  @override
  Future<ExpiryMonth> build() async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final month = ref.watch(expiryCalendarControllerProvider).month;
    final repository = ref.watch(inventoryRepositoryProvider);

    final batches = await repository.batchesExpiringBetween(
      pharmacyId: pharmacyId,
      from: month,
      to: lastOfMonth(month),
    );
    final names = await ref
        .watch(productsRepositoryProvider)
        .namesFor(
          pharmacyId: pharmacyId,
          productIds: batches
              .map((batch) => batch.productId)
              .toSet()
              .toList(growable: false),
        );

    final unitsByDay = <int, int>{};
    for (final batch in batches) {
      unitsByDay.update(
        batch.expiryDate.day,
        (units) => units + batch.qty,
        ifAbsent: () => batch.qty,
      );
    }

    return ExpiryMonth(
      rows: batches
          .map(
            (batch) => ExpiryBatch(
              batch: batch,
              productName: names[batch.productId] ?? 'Unknown product',
            ),
          )
          .toList(growable: false),
      unitsByDay: unitsByDay,
    );
  }
}
