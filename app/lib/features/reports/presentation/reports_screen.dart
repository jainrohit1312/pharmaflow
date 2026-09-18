/// The reports: what the window took, what it cost, and what is on the shelf.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_date_field.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/report_summary.dart';
import 'package:app/features/reports/application/reports_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The reporting summary for a window of the pharmacy's own dates.
///
/// Every figure on this screen comes from one call (`report_summary`, migration
/// 20260918000021) rather than six: a report whose parts were read at different
/// moments can disagree with itself, and a report nobody trusts is worse than no
/// report. Nothing here sums rows - the server does, because PostgREST cannot
/// aggregate and a total assembled from one capped page is wrong in a way nobody
/// can see.
class ReportsScreen extends ConsumerWidget {
  /// Creates the reports screen.
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(reportSummaryProvider);

    return AppScaffold(
      title: 'Reports',
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.price_change_outlined),
          tooltip: 'Expenses',
          onPressed: () => context.go(Routes.expenses),
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
          onPressed: summary.isLoading
              ? null
              : () => ref.invalidate(reportSummaryProvider),
        ),
      ],
      body: Column(
        children: <Widget>[
          const _WindowBar(),
          // Shown while a moved window is being added up: the previous window's
          // figures stay on screen, so without this a stale number would look
          // like the answer to the question just asked.
          if (summary.isLoading && summary.hasValue)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _SummaryBody(summary: summary)),
        ],
      ),
    );
  }
}

/// The preset chips and the two ends of the window.
class _WindowBar extends ConsumerWidget {
  const _WindowBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final window = ref.watch(reportsWindowControllerProvider);
    final windows = ref.read(reportsWindowControllerProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: SectionCard(
        title: 'Window',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (final preset in reportPresets) ...<Widget>[
                    ChoiceChip(
                      label: Text(preset.label),
                      selected: window.preset == preset,
                      onSelected: (picked) => windows.preset(preset),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: AppDateField(
                    label: 'From',
                    value: window.from,
                    isRequired: true,
                    onChanged: (value) {
                      if (value != null) {
                        windows.from(value);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AppDateField(
                    label: 'To',
                    value: window.to,
                    isRequired: true,
                    onChanged: (value) {
                      if (value != null) {
                        windows.to(value);
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Both days are included. ${Formatters.dateDdMmmYyyy(window.from)} '
              'to ${Formatters.dateDdMmmYyyy(window.to)}.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders whichever of the summary's states applies.
///
/// Deliberately not `AsyncValue.when`: a window change leaves the previous
/// figures in place, and keeping them on screen with a progress line above reads
/// better than blanking the report the user is reading.
class _SummaryBody extends ConsumerWidget {
  const _SummaryBody({required this.summary});

  /// Current summary state.
  final AsyncValue<ReportSummary> summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (summary.hasValue) {
      return _SummaryCards(summary: summary.value!);
    }
    if (summary.hasError) {
      return ErrorView(
        message: describeError(summary.error!),
        onRetry: () => ref.invalidate(reportSummaryProvider),
      );
    }
    return const LoadingView(message: 'Adding up the window…');
  }
}

/// Every card of the loaded summary.
class _SummaryCards extends StatelessWidget {
  const _SummaryCards({required this.summary});

  /// The window's totals.
  final ReportSummary summary;

  @override
  Widget build(BuildContext context) {
    final sales = summary.sales;
    final purchases = summary.purchases;
    final returns = summary.returns;
    final expenses = summary.expenses;
    final stock = summary.stock;
    final expiring = summary.expiring;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: <Widget>[
        SectionCard(
          title: 'Sales',
          child: Column(
            children: <Widget>[
              _StatRow(
                label: 'Billed',
                value: Formatters.currency(sales.grandTotal),
                emphasis: true,
              ),
              _StatRow(label: 'Bills', value: '${sales.count}'),
              _StatRow(
                label: 'Before tax',
                value: Formatters.currency(sales.subTotal),
              ),
              _StatRow(
                label: 'Output tax',
                value: Formatters.currency(sales.taxTotal),
              ),
              _StatRow(
                label: 'Taken at the counter',
                value: Formatters.currency(sales.collected),
              ),
              _StatRow(
                label: 'Still owed by customers',
                value: Formatters.currency(sales.outstanding),
              ),
              _StatRow(
                label: 'Average bill',
                value: Formatters.currency(sales.averageBill),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Purchases received',
          child: Column(
            children: <Widget>[
              _StatRow(
                label: 'Payable',
                value: Formatters.currency(purchases.grandTotal),
                emphasis: true,
              ),
              _StatRow(label: 'Invoices', value: '${purchases.count}'),
              _StatRow(
                label: 'Input tax',
                value: Formatters.currency(purchases.taxTotal),
              ),
              _StatRow(
                label: 'Net tax (output less input)',
                value: Formatters.currency(sales.taxTotal - purchases.taxTotal),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Returns',
          child: Column(
            children: <Widget>[
              _StatRow(
                label: 'Refunded to customers',
                value: Formatters.currency(returns.saleTotal),
              ),
              _StatRow(
                label: 'Customer returns',
                value: '${returns.saleCount}',
              ),
              _StatRow(
                label: 'Credited by suppliers',
                value: Formatters.currency(returns.purchaseTotal),
              ),
              _StatRow(
                label: 'Supplier returns',
                value: '${returns.purchaseCount}',
              ),
              _StatRow(
                label: 'Net',
                value: Formatters.currency(returns.net),
                emphasis: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Expenses',
          trailing: AppButton.text(
            label: 'Manage',
            icon: Icons.edit_outlined,
            expand: false,
            onPressed: () => context.go(Routes.expenses),
          ),
          child: Column(
            children: <Widget>[
              _StatRow(
                label: 'Total',
                value: Formatters.currency(expenses.total),
                emphasis: true,
              ),
              _StatRow(label: 'Recorded', value: '${expenses.count}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'What the window contributed',
          trailing: const StatusBadge(
            label: 'Not a profit',
            icon: Icons.info_outline,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _StatRow(
                label: 'Billed less refunds less expenses',
                value: Formatters.currency(summary.contributedMargin),
                emphasis: true,
              ),
              const SizedBox(height: 8),
              const Text(
                'This knows what was sold and what was spent, and nothing about '
                'what the goods on those bills cost - that arrived on invoices, '
                'not on bills. Gross margin needs the cost of each sale line.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Stock on the shelf',
          trailing: const StatusBadge(
            label: 'As it stands',
            tone: BadgeTone.info,
            icon: Icons.inventory_2_outlined,
          ),
          child: Column(
            children: <Widget>[
              _StatRow(
                label: 'Value at cost (landed)',
                value: Formatters.currency(stock.valueAtCost),
                emphasis: true,
              ),
              _StatRow(
                label: 'Value at MRP',
                value: Formatters.currency(stock.valueAtMrp),
              ),
              _StatRow(label: 'Products', value: '${stock.products}'),
              _StatRow(label: 'Units', value: '${stock.units}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Expiring',
          trailing: const StatusBadge(
            label: 'At MRP',
            tone: BadgeTone.warning,
            icon: Icons.event_busy_outlined,
          ),
          child: Column(
            children: <Widget>[
              _StatRow(
                label: 'Already expired',
                value: Formatters.currency(expiring.expiredValueAtMrp),
              ),
              _StatRow(
                label: 'Within 30 days',
                value: Formatters.currency(expiring.criticalValueAtMrp),
              ),
              _StatRow(
                label: 'Within 90 days',
                value: Formatters.currency(expiring.warningValueAtMrp),
              ),
              _StatRow(
                label: 'Needs a decision',
                value: Formatters.currency(expiring.atRisk),
                emphasis: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One labelled figure.
class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.label,
    required this.value,
    this.emphasis = false,
  });

  /// What the figure is.
  final String label;

  /// The figure, already formatted.
  final String value;

  /// Whether this is the line the card is about.
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          const SizedBox(width: 12),
          Text(
            value,
            style: emphasis
                ? theme.textTheme.titleMedium
                : theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}
