/// Tests for the reports window and the summary that reads it.
///
/// The calendar arithmetic is tested against fixed dates rather than "now": a
/// month end is exactly where hand-written arithmetic goes wrong, and a test that
/// asked the clock would only check the month it happened to run in.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/errors/error_message.dart';
import 'package:app/data/models/report_summary.dart';
import 'package:app/features/reports/application/reports_controller.dart';
import 'package:app/features/reports/data/reports_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_reports_repository.dart';

/// A container with the repository stubbed out.
///
/// The override list is inferred rather than annotated: `Override` is declared in
/// the `riverpod` package, which is a transitive dependency here, so naming it
/// would mean importing a package this app does not depend on directly.
ProviderContainer _container(ReportsRepository repository) {
  final container = ProviderContainer(
    overrides: [reportsRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);
  return container;
}

/// The window controller behind [container].
ReportsWindowController _windows(ProviderContainer container) =>
    container.read(reportsWindowControllerProvider.notifier);

/// The window [container] currently holds.
ReportWindow _window(ProviderContainer container) =>
    container.read(reportsWindowControllerProvider);

void main() {
  group('windowFor', () {
    test('this month runs from the 1st to its last day', () {
      final window = windowFor(ReportPreset.thisMonth, DateTime(2026, 9, 18));

      expect(window.from, DateTime(2026, 9));
      expect(window.to, DateTime(2026, 9, 30));
      expect(window.preset, ReportPreset.thisMonth);
    });

    test('this month in February ends on the 28th', () {
      final window = windowFor(ReportPreset.thisMonth, DateTime(2026, 2, 3));

      expect(window.to, DateTime(2026, 2, 28));
    });

    test('last month ends on the 30th after a 31-day month', () {
      final window = windowFor(ReportPreset.lastMonth, DateTime(2026, 5, 9));

      expect(window.from, DateTime(2026, 4));
      expect(window.to, DateTime(2026, 4, 30));
    });

    test('last month ends on the 31st after a 30-day month', () {
      final window = windowFor(ReportPreset.lastMonth, DateTime(2026, 8, 9));

      expect(window.from, DateTime(2026, 7));
      expect(window.to, DateTime(2026, 7, 31));
    });

    test('last month in January is the previous December', () {
      final window = windowFor(ReportPreset.lastMonth, DateTime(2026, 1, 4));

      expect(window.from, DateTime(2025, 12));
      expect(window.to, DateTime(2025, 12, 31));
    });

    test('this quarter is the three months the date falls in', () {
      final second = windowFor(ReportPreset.thisQuarter, DateTime(2026, 5, 20));

      expect(second.from, DateTime(2026, 4));
      expect(second.to, DateTime(2026, 6, 30));
    });

    test('the last quarter of a year ends on 31 December', () {
      final window = windowFor(
        ReportPreset.thisQuarter,
        DateTime(2026, 12, 31),
      );

      expect(window.from, DateTime(2026, 10));
      expect(window.to, DateTime(2026, 12, 31));
    });

    test('the first quarter starts on 1 January', () {
      final window = windowFor(ReportPreset.thisQuarter, DateTime(2026, 1, 5));

      expect(window.from, DateTime(2026));
      expect(window.to, DateTime(2026, 3, 31));
    });

    test('this year runs to 31 December', () {
      final window = windowFor(ReportPreset.thisYear, DateTime(2026, 9, 18));

      expect(window.from, DateTime(2026));
      expect(window.to, DateTime(2026, 12, 31));
    });

    test('today is one day', () {
      final window = windowFor(ReportPreset.today, DateTime(2026, 9, 18, 14));

      expect(window.from, DateTime(2026, 9, 18));
      expect(window.to, DateTime(2026, 9, 18));
      expect(window.preset, ReportPreset.today);
    });
  });

  group('ReportsWindowController', () {
    test('opens on the current month', () {
      final container = _container(FakeReportsRepository());
      final expected = windowFor(ReportPreset.thisMonth, DateTime.now());

      final window = _window(container);

      expect(window.from, expected.from);
      expect(window.to, expected.to);
      expect(window.preset, ReportPreset.thisMonth);
    });

    test('a preset replaces the whole window', () {
      final container = _container(FakeReportsRepository());
      final expected = windowFor(ReportPreset.thisYear, DateTime.now());

      _windows(container).preset(ReportPreset.thisYear);

      final window = _window(container);
      expect(window.from, expected.from);
      expect(window.to, expected.to);
      expect(window.preset, ReportPreset.thisYear);
    });

    test('the preset already showing is left alone', () {
      final container = _container(FakeReportsRepository());
      final before = _window(container);

      _windows(container).preset(ReportPreset.thisMonth);

      expect(
        identical(_window(container), before),
        isTrue,
        reason: 're-selecting the current chip must not rebuild the summary',
      );
    });

    test('custom is not a choice a chip can make', () {
      final container = _container(FakeReportsRepository());
      final before = _window(container);

      _windows(container).preset(ReportPreset.custom);

      expect(identical(_window(container), before), isTrue);
    });

    test('a picked date keeps only the day', () {
      final container = _container(FakeReportsRepository());

      _windows(container).from(DateTime(2026, 9, 15, 14, 30, 5));

      expect(
        _window(container).from,
        DateTime(2026, 9, 15),
        reason: 'the RPC takes dates; a stray time would compare as a day',
      );
    });

    test('moving one end past the other drags it along', () {
      final container = _container(FakeReportsRepository());

      _windows(container)
        ..from(DateTime(2026, 9))
        ..to(DateTime(2026, 9, 30))
        ..from(DateTime(2026, 10, 5));

      final window = _window(container);
      expect(window.from, DateTime(2026, 10, 5));
      expect(window.to, DateTime(2026, 10, 5));
    });

    test('moving the last end back drags the first one with it', () {
      final container = _container(FakeReportsRepository());

      _windows(container)
        ..from(DateTime(2026, 9))
        ..to(DateTime(2026, 9, 30))
        ..to(DateTime(2026, 8, 31));

      final window = _window(container);
      expect(window.from, DateTime(2026, 8, 31));
      expect(window.to, DateTime(2026, 8, 31));
    });

    test('a window moved by hand is no longer the preset it came from', () {
      final container = _container(FakeReportsRepository());

      _windows(container).from(DateTime(2026, 8));

      expect(
        _window(container).preset,
        ReportPreset.custom,
        reason: 'the chip it started from no longer describes it',
      );
    });
  });

  group('reportSummaryProvider', () {
    test('asks for the window that is selected', () async {
      final repository = FakeReportsRepository();
      final container = _container(repository);

      _windows(container)
        ..from(DateTime(2026, 9))
        ..to(DateTime(2026, 9, 30));
      await container.read(reportSummaryProvider.future);

      expect(repository.requests.single.from, DateTime(2026, 9));
      expect(repository.requests.single.to, DateTime(2026, 9, 30));
    });

    test('is fetched again when the window moves', () async {
      final repository = FakeReportsRepository();
      final container = _container(repository);
      final windows = _windows(container)
        ..from(DateTime(2026, 9))
        ..to(DateTime(2026, 9, 30));
      await container.read(reportSummaryProvider.future);

      windows.to(DateTime(2026, 8, 31));
      await container.read(reportSummaryProvider.future);

      expect(repository.requests.first.from, DateTime(2026, 9));
      expect(repository.requests.last.from, DateTime(2026, 8, 31));
      expect(repository.requests.last.to, DateTime(2026, 8, 31));
    });

    test('a failed read reaches the caller as its own error', () async {
      final repository = FakeReportsRepository()
        ..errorToThrow = const ServerException(message: 'Unable to read.');
      final container = _container(repository);

      // The provider is kept alive while it fails: an auto-dispose provider read
      // once can be disposed mid-build, and awaiting `.future` on a provider that
      // failed never completes in Riverpod 3 (D-015), so the state is read after
      // the build has had a turn instead.
      final subscription = container.listen(reportSummaryProvider, (p, n) {});
      addTearDown(subscription.close);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(reportSummaryProvider);
      expect(state.hasError, isTrue);
      expect(state.error, isA<ServerException>());
      expect(describeError(state.error!), 'Unable to read.');
    });

    test('hands the caller the repository summary untouched', () async {
      final summary = buildSummary(
        expenses: const ReportExpenseTotals(count: 2, total: 500),
      );
      final container = _container(FakeReportsRepository(result: summary));

      final loaded = await container.read(reportSummaryProvider.future);

      expect(loaded.expenses.total, 500);
    });
  });
}
