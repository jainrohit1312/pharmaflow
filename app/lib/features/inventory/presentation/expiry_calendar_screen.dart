/// The expiry calendar: a month of shelf life, and what falls on each day.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/features/approvals/presentation/sent_to_owner.dart';
import 'package:app/features/inventory/application/expiry_batch.dart';
import 'package:app/features/inventory/application/expiry_calendar_controller.dart';
import 'package:app/features/inventory/presentation/widgets/expiry_batch_card.dart';
import 'package:app/features/inventory/presentation/widgets/stock_adjustment_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// A month grid of expiries, with the batches behind each day.
///
/// The dashboard's three buckets answer "what needs attention"; this answers
/// "when", which is the question a pharmacy plans a return or a discount around.
/// Both read `batch_status`, so a batch cannot be in one and missing from the
/// other.
class ExpiryCalendarScreen extends ConsumerWidget {
  /// Creates the expiry calendar screen.
  const ExpiryCalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calendar = ref.watch(expiryCalendarControllerProvider);
    final month = ref.watch(expiryMonthControllerProvider);
    final controller = ref.read(expiryCalendarControllerProvider.notifier);

    return AppScaffold(
      title: 'Expiry calendar',
      leading: const AppBackButton(
        location: Routes.inventory,
        tooltip: 'Back to inventory',
      ),
      body: Column(
        children: <Widget>[
          _MonthHeader(state: calendar, controller: controller),
          Expanded(
            child: _CalendarBody(month: month, state: calendar),
          ),
        ],
      ),
    );
  }
}

/// The month heading and the arrows that step through months.
class _MonthHeader extends StatelessWidget {
  const _MonthHeader({required this.state, required this.controller});

  /// Which month is on screen.
  final ExpiryCalendarState state;

  /// Steps the month.
  final ExpiryCalendarController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: <Widget>[
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous month',
            onPressed: controller.previousMonth,
          ),
          Expanded(
            child: Text(
              Formatters.monthYear(state.month),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next month',
            onPressed: controller.nextMonth,
          ),
          AppButton.text(
            label: 'Today',
            expand: false,
            onPressed: controller.thisMonth,
          ),
        ],
      ),
    );
  }
}

/// Renders whichever of the month's states applies.
class _CalendarBody extends ConsumerWidget {
  const _CalendarBody({required this.month, required this.state});

  /// Current month state.
  final AsyncValue<ExpiryMonth> month;

  /// Which month and day are selected.
  final ExpiryCalendarState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (month.hasValue) {
      final data = month.value!;
      final selected = state.selectedDay;
      final rows = selected == null ? data.rows : data.rowsOn(selected);

      return Column(
        children: <Widget>[
          _MonthGrid(
            month: state.month,
            data: data,
            selectedDay: selected,
            onSelect: ref
                .read(expiryCalendarControllerProvider.notifier)
                .selectDay,
          ),
          _SelectionSummary(rows: rows, selectedDay: selected),
          Expanded(
            child: rows.isEmpty
                ? AppEmptyView(
                    icon: Icons.event_available_outlined,
                    title: selected == null
                        ? 'Nothing expires this month'
                        : 'Nothing expires that day',
                    message: selected == null
                        ? 'Step to another month, or check the expiry tab for '
                              'batches that are already past their date.'
                        : 'Pick another day, or tap the highlighted day again to '
                              'see the whole month.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: rows.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 12),
                    itemBuilder: (context, index) => ExpiryBatchCard(
                      entry: rows[index],
                      onTap: () => context.go(
                        Routes.productDetail(rows[index].batch.productId),
                      ),
                      onAdjust: () => _adjust(context, ref, rows[index]),
                    ),
                  ),
          ),
        ],
      );
    }

    if (month.hasError) {
      return ErrorView(
        message: describeError(month.error!),
        onRetry: () => ref.invalidate(expiryMonthControllerProvider),
      );
    }

    return const LoadingView(message: 'Loading that month…');
  }

  /// Opens the correction sheet for one batch, and confirms the write.
  Future<void> _adjust(
    BuildContext context,
    WidgetRef ref,
    ExpiryBatch entry,
  ) async {
    final outcome = await showStockAdjustmentSheet(
      context,
      productId: entry.batch.productId,
      productName: entry.productName,
      batchId: entry.batch.id,
      batchNo: entry.batch.batchNo,
      onHand: entry.qty,
    );
    if (outcome == null || !context.mounted) {
      return;
    }
    // A correction is a REQUEST for anybody but the owner, and a request moves no stock,
    // so the confirmation has to say which of the two happened.
    if (outcome.isStaged) {
      showSentToOwnerNotice(context, message: sentForApprovalMessage);
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Stock adjusted.')));
  }
}

/// How much the current selection covers.
class _SelectionSummary extends ConsumerWidget {
  const _SelectionSummary({required this.rows, required this.selectedDay});

  /// The rows the list is showing.
  final List<ExpiryBatch> rows;

  /// The day they are filtered to, or `null` for the whole month.
  final DateTime? selectedDay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final units = rows.fold<int>(0, (total, row) => total + row.qty);
    final day = selectedDay;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              day == null
                  ? '${_batchCount(rows.length)} this month · '
                        '$units ${units == 1 ? 'unit' : 'units'}'
                  : '${_batchCount(rows.length)} on '
                        '${Formatters.dateDdMmmYyyy(day)} · '
                        '$units ${units == 1 ? 'unit' : 'units'}',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (day != null)
            AppButton.text(
              label: 'Whole month',
              icon: Icons.calendar_view_month_outlined,
              expand: false,
              onPressed: () => ref
                  .read(expiryCalendarControllerProvider.notifier)
                  .selectDay(null),
            ),
        ],
      ),
    );
  }
}

/// `3 batches`, `1 batch` or `no batches`.
String _batchCount(int count) => switch (count) {
  0 => 'no batches',
  1 => '1 batch',
  _ => '$count batches',
};

/// The weekday labels, in `DateTime.weekday` order.
const List<String> _weekdays = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

/// A month laid out as weeks, each day carrying the units expiring on it.
///
/// Built as rows of cells rather than a `GridView` so it takes its height from
/// its content: it sits above a scrolling list, and a scrollable grid would
/// either fight that list for gestures or need a fixed height that a 6-week month
/// overflows.
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.data,
    required this.selectedDay,
    required this.onSelect,
  });

  /// The month being drawn.
  final DateTime month;

  /// The month's expiries.
  final ExpiryMonth data;

  /// The selected day, if any.
  final DateTime? selectedDay;

  /// Called with a day the user tapped.
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Days before the 1st fall in the previous month's week, so the grid starts
    // on a Monday and the columns keep their weekday meaning.
    final leading = month.weekday - 1;
    final daysInMonth = lastOfMonth(month).day;
    final cells = leading + daysInMonth;
    final weeks = (cells / 7).ceil();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              for (final label in _weekdays)
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
            ],
          ),
          for (var week = 0; week < weeks; week++)
            Row(
              children: <Widget>[
                for (var column = 0; column < 7; column++)
                  Expanded(
                    child: _DayCell(
                      day: week * 7 + column - leading + 1,
                      units: data.unitsOn(week * 7 + column - leading + 1),
                      month: month,
                      selectedDay: selectedDay,
                      onSelect: onSelect,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// One day in the grid.
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.units,
    required this.month,
    required this.selectedDay,
    required this.onSelect,
  });

  /// Day of the month, or a value outside it for the padding cells.
  final int day;

  /// Units expiring on this day.
  final int units;

  /// The month being drawn.
  final DateTime month;

  /// The selected day, if any.
  final DateTime? selectedDay;

  /// Called with the day when it is tapped.
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    if (day < 1 || day > lastOfMonth(month).day) {
      return const SizedBox(height: 56);
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final date = DateTime(month.year, month.month, day);
    final selected = selectedDay != null && selectedDay!.day == day;
    final today = _isSameDate(DateTime.now(), date);

    return InkWell(
      onTap: () => onSelect(date),
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 56,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              height: 28,
              width: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? scheme.primary
                    : units > 0
                    ? scheme.surfaceContainerHighest
                    : null,
                border: today && !selected
                    ? Border.all(color: scheme.primary)
                    : null,
              ),
              child: Text(
                '$day',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected ? scheme.onPrimary : null,
                  fontWeight: today || selected ? FontWeight.w600 : null,
                ),
              ),
            ),
            const SizedBox(height: 2),
            // The count, not a bare dot: "how much expires that day" is the
            // question this screen exists to answer.
            Text(
              units > 0 ? '$units' : '',
              style: theme.textTheme.labelSmall?.copyWith(
                color: units > 0 ? scheme.primary : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Whether [a] and [b] are the same calendar day.
  static bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
