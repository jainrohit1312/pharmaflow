/// The window the reports cover, and the summary that reads it.
///
/// The window lives here rather than in a widget so that a write which moves a
/// figure - recording an expense, for one - can invalidate the summary without
/// knowing which screen is showing it (`ExpenseFormController.createExpense`).
library;

import 'package:app/data/models/report_summary.dart';
import 'package:app/features/reports/data/reports_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'reports_controller.g.dart';

/// A window the reports screen offers, or the window one becomes.
enum ReportPreset {
  /// Today alone: the day book.
  today,

  /// The current calendar month.
  thisMonth,

  /// The calendar month before the current one.
  lastMonth,

  /// The current calendar quarter.
  thisQuarter,

  /// The current calendar year.
  thisYear,

  /// A window one of whose ends was moved by hand.
  ///
  /// Not offered as a chip - it is a description of the window, not a choice.
  custom,
}

/// Maps [ReportPreset] to what the user reads.
extension ReportPresetX on ReportPreset {
  /// The label shown on the chip.
  String get label => switch (this) {
    ReportPreset.today => 'Today',
    ReportPreset.thisMonth => 'This month',
    ReportPreset.lastMonth => 'Last month',
    ReportPreset.thisQuarter => 'This quarter',
    ReportPreset.thisYear => 'This year',
    ReportPreset.custom => 'Custom',
  };
}

/// The presets offered as chips, in order.
///
/// [ReportPreset.custom] is absent on purpose: it is what a window *becomes*
/// once an end is moved, and a chip that cannot be chosen from is noise.
const List<ReportPreset> reportPresets = <ReportPreset>[
  ReportPreset.today,
  ReportPreset.thisMonth,
  ReportPreset.lastMonth,
  ReportPreset.thisQuarter,
  ReportPreset.thisYear,
];

/// An inclusive date window, and the preset that produced it.
class ReportWindow {
  /// Creates a window.
  const ReportWindow({
    required this.from,
    required this.to,
    this.preset = ReportPreset.custom,
  });

  /// The first day included.
  final DateTime from;

  /// The last day included.
  final DateTime to;

  /// The preset this window came from, or [ReportPreset.custom] once one of its
  /// ends has been moved by hand.
  final ReportPreset preset;
}

/// The inclusive window [preset] covers as of [now].
///
/// Pure and public so the calendar arithmetic is tested without a clock: a report
/// that quietly spans the wrong days is wrong in a way nobody can see, and month
/// ends are exactly where hand-written arithmetic goes wrong. The `day: 0`
/// arguments below are Dart's own normalisation - day 0 is the last day of the
/// previous month, which is what makes `lastMonth` end on the 31st when it should
/// and the 30th when it should.
ReportWindow windowFor(ReportPreset preset, DateTime now) {
  final year = now.year;
  final month = now.month;
  final quarterStart = ((month - 1) ~/ 3) * 3 + 1;

  return switch (preset) {
    ReportPreset.today => ReportWindow(
      from: DateTime(year, month, now.day),
      to: DateTime(year, month, now.day),
      preset: preset,
    ),
    ReportPreset.thisMonth => ReportWindow(
      from: DateTime(year, month),
      to: DateTime(year, month + 1, 0),
      preset: preset,
    ),
    ReportPreset.lastMonth => ReportWindow(
      from: DateTime(year, month - 1),
      to: DateTime(year, month, 0),
      preset: preset,
    ),
    ReportPreset.thisQuarter => ReportWindow(
      from: DateTime(year, quarterStart),
      to: DateTime(year, quarterStart + 3, 0),
      preset: preset,
    ),
    ReportPreset.thisYear => ReportWindow(
      from: DateTime(year),
      to: DateTime(year, 13, 0),
      preset: preset,
    ),
    // Nothing to derive: a custom window is whatever the user last set, so the
    // current month is only what it starts as.
    ReportPreset.custom => ReportWindow(
      from: DateTime(year, month),
      to: DateTime(year, month + 1, 0),
    ),
  };
}

/// Which window the reports cover.
///
/// Kept alive so that opening a bill from a sales figure and coming back lands on
/// the same window, rather than resetting to the current month mid-read.
@Riverpod(keepAlive: true)
class ReportsWindowController extends _$ReportsWindowController {
  @override
  ReportWindow build() => windowFor(ReportPreset.thisMonth, DateTime.now());

  /// Switches to a preset window.
  void preset(ReportPreset value) {
    if (value == ReportPreset.custom || state.preset == value) {
      return;
    }
    state = windowFor(value, DateTime.now());
  }

  /// Moves the first day of the window.
  ///
  /// The other end is dragged along rather than left inverted: a window that ends
  /// before it starts is a request for a range the database cannot answer, and a
  /// pair of date fields that can be put into that state is a pair of date fields
  /// that will be. Moving an end makes the window `custom`, because the chip it
  /// came from no longer describes it.
  void from(DateTime value) {
    final day = _dayOf(value);
    if (state.preset == ReportPreset.custom && day == state.from) {
      return;
    }
    state = ReportWindow(from: day, to: day.isAfter(state.to) ? day : state.to);
  }

  /// Moves the last day of the window, dragging the first along with it.
  void to(DateTime value) {
    final day = _dayOf(value);
    if (state.preset == ReportPreset.custom && day == state.to) {
      return;
    }
    state = ReportWindow(
      from: day.isBefore(state.from) ? day : state.from,
      to: day,
    );
  }
}

/// The same instant at midnight, so a picked date compares and sends as a day.
///
/// `showDatePicker` returns midnight already, but a window handed in from
/// elsewhere need not - and the RPC takes `date`s, so a stray time would be
/// dropped by Postgres while silently comparing as a different day for anything
/// that compared it locally first.
DateTime _dayOf(DateTime value) => DateTime(value.year, value.month, value.day);

/// Every total for the selected window, in one round trip.
///
/// Watches the window, so moving it reloads. The lifetime is the default
/// (auto-dispose) rather than kept alive: the expense form invalidates this
/// provider from another feature, and a kept-alive provider may only depend on
/// kept-alive ones (D-015), which the repository and the scope are not.
@riverpod
Future<ReportSummary> reportSummary(Ref ref) async {
  final window = ref.watch(reportsWindowControllerProvider);
  return ref
      .watch(reportsRepositoryProvider)
      .summary(from: window.from, to: window.to);
}
