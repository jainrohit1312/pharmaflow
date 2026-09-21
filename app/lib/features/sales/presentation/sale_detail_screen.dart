/// One sale, rendered as the invoice the customer gets.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/logger.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_item.dart';
import 'package:app/data/repositories/pharmacy_repository.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/balances/presentation/widgets/sale_allocations_card.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/sale_detail_controller.dart';
import 'package:app/features/sales/application/sale_tax_split.dart';
import 'package:app/features/sales/presentation/widgets/sale_status_badge.dart';
import 'package:app/services/invoice_printer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The invoice for one sale: what was sold, what it came to, and how it was paid.
///
/// Rendered from the document's own stored columns rather than recomputed - the
/// totals are what the ledger posted and what the customer was charged, so a screen
/// that recalculated them could only disagree with the record.
class SaleDetailScreen extends ConsumerWidget {
  /// Creates the detail screen for [saleId].
  const SaleDetailScreen({required this.saleId, super.key});

  /// The sale to show.
  final String saleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(saleDetailProvider(saleId));

    if (detail.hasError && !detail.hasValue) {
      return AppScaffold(
        title: 'Bill',
        leading: _backToSales,
        body: ErrorView(
          message: describeError(detail.error!),
          onRetry: () => ref.invalidate(saleDetailProvider(saleId)),
        ),
      );
    }

    final data = detail.value;
    if (data == null) {
      // `saleDetail` answers `null` for an id that is no longer there, and a spinner
      // is not an answer to that - the bill is not loading, it is not in the
      // pharmacy's records. Checked *after* `isLoading` because a retry holds no
      // value while it is in flight either, and reporting a missing bill during one
      // would be the same conflation the other way round.
      if (detail.isLoading) {
        return const AppScaffold(
          title: 'Bill',
          leading: _backToSales,
          body: LoadingView(message: 'Loading the bill…'),
        );
      }
      return const AppScaffold(
        title: 'Bill',
        leading: _backToSales,
        body: AppEmptyView(
          icon: Icons.receipt_long_outlined,
          title: 'Bill not found',
          message:
              'This bill is no longer in the pharmacy’s records. It may have '
              'been opened from a link that is out of date.',
        ),
      );
    }

    final sale = data.sale;
    final split =
        ref.watch(saleTaxSplitProvider(sale.placeOfSupply)).value ??
        TaxSplit.intraState;

    return AppScaffold(
      title: 'Bill ${sale.invoiceNo}',
      leading: _backToSales,
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.print_outlined),
          tooltip: 'Print this bill',
          onPressed: () => _print(context, ref, data, split),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          SectionCard(
            title: 'Sale',
            trailing: SaleStatusBadge(status: sale.status),
            child: Column(
              children: <Widget>[
                _Field(label: 'Invoice', value: sale.invoiceNo),
                _Field(
                  label: 'Sold',
                  value: Formatters.dateTimeDdMmmYyyyHm(sale.saleDate),
                ),
                _Field(
                  label: 'Customer',
                  value: sale.customerId == null ? 'Walk-in' : 'On account',
                ),
                _Field(label: 'Place of supply', value: sale.placeOfSupply),
                if (data.hasControlledItems)
                  const _Field(
                    label: 'Register',
                    value:
                        'This bill contains a prescription-only schedule, so it '
                        'belongs in the drug register.',
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Items',
            child: data.items.isEmpty
                ? Text(
                    'This bill has no lines.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                : Column(
                    children: <Widget>[
                      for (
                        var index = 0;
                        index < data.items.length;
                        index++
                      ) ...<Widget>[
                        _ItemRow(
                          item: data.items[index],
                          name: data.nameOf(data.items[index]),
                        ),
                        if (index < data.items.length - 1)
                          const Divider(height: 24),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Bill',
            child: Column(
              children: <Widget>[
                // The document's own columns: these are what the ledger posted.
                _AmountRow(
                  label: 'Taxable value',
                  value: Formatters.currency(sale.subTotal),
                ),
                if (sale.discountTotal > 0)
                  _AmountRow(
                    label: 'Discount',
                    value: '-${Formatters.currency(sale.discountTotal)}',
                  ),
                _AmountRow(
                  label: split == TaxSplit.intraState ? 'CGST + SGST' : 'IGST',
                  value: Formatters.currency(sale.taxTotal),
                ),
                const Divider(height: 20),
                _AmountRow(
                  label: 'Total',
                  value: Formatters.currency(sale.grandTotal),
                  emphasis: Theme.of(context).textTheme.titleMedium,
                ),
                _AmountRow(
                  label: sale.paymentMode.label,
                  value: Formatters.currency(sale.amountPaid),
                ),
                if (sale.balanceDue > 0)
                  _AmountRow(
                    label: 'Balance due',
                    value: Formatters.currency(sale.balanceDue),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // What has actually been applied to this bill, which is a different question
          // from what was handed over: money that was never aimed at a bill stays an
          // unapplied deposit on the party's account.
          SaleAllocationsCard(saleId: saleId),
          if (sale.admissionId != null) ...<Widget>[
            const SizedBox(height: 16),
            SectionCard(
              title: 'Admission',
              child: AppButton.text(
                label: 'Open the admission account',
                icon: Icons.local_hospital_outlined,
                expand: false,
                onPressed: () =>
                    context.go(Routes.admission(sale.admissionId!)),
              ),
            ),
          ],
          const SizedBox(height: 24),
          AppButton.outlined(
            label: 'Back to sales',
            icon: Icons.receipt_long_outlined,
            // `go`, not `maybePop`: this screen is reached by navigating **to a location**,
            // so the stack has nothing to pop and the button did nothing at all.
            onPressed: () => context.go(Routes.sales),
          ),
        ],
      ),
    );
  }

  /// Renders the bill and hands it to the platform.
  Future<void> _print(
    BuildContext context,
    WidgetRef ref,
    SaleDetailData data,
    TaxSplit split,
  ) async {
    try {
      final pharmacy = await ref
          .read(pharmacyRepositoryProvider)
          .byId(ref.read(requirePharmacyIdProvider));
      await ref
          .read(invoicePrinterProvider)
          .printReceipt(data: data, pharmacy: pharmacy, split: split);
    } on Object catch (error, stackTrace) {
      appLogger.w(
        'Printing the bill failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Could not print the bill: ${describeError(error)}'),
          ),
        );
    }
  }
}

/// Back to the sales list.
const AppBackButton _backToSales = AppBackButton(
  location: Routes.sales,
  tooltip: 'Back to sales',
);

/// One sold line.
class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.name});

  /// The line.
  final SaleItem item;

  /// What was sold.
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                name,
                style: theme.textTheme.titleSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              Formatters.currency(item.totalAmount),
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: <Widget>[
            _Metric(label: 'Qty', value: '${item.qty}'),
            _Metric(label: 'Rate', value: Formatters.currency(item.rate)),
            if (item.discountPercent > 0)
              _Metric(label: 'Discount', value: '${item.discountPercent}%'),
            if (item.gstPercent > 0)
              _Metric(label: 'GST', value: '${item.gstPercent}%'),
            _Metric(label: 'Tax', value: Formatters.currency(item.taxAmount)),
            if (item.isControlled)
              _Metric(label: 'Schedule', value: item.scheduleType.label),
          ],
        ),
      ],
    );
  }
}

/// A label and value sitting side by side, for compact line metrics.
class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  /// What the number is.
  final String label;

  /// The number, already formatted.
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RichText(
      text: TextSpan(
        style: theme.textTheme.bodySmall,
        children: <InlineSpan>[
          TextSpan(text: '$label '),
          TextSpan(
            text: value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// One label and amount in the bill card.
class _AmountRow extends StatelessWidget {
  const _AmountRow({required this.label, required this.value, this.emphasis});

  /// What the amount is.
  final String label;

  /// The amount, already formatted.
  final String value;

  /// Style for the amount, for the total.
  final TextStyle? emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(value, style: emphasis ?? theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// A labelled value, stacked so it stays readable at any width.
class _Field extends StatelessWidget {
  const _Field({required this.label, this.value});

  /// What the value is.
  final String label;

  /// The value, or `null`/blank to render an em dash.
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = value;
    final display = text == null || text.trim().isEmpty ? '—' : text;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(display, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}
