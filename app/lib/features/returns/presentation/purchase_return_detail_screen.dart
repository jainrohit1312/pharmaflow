/// One purchase return: what went back, and what it credits.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/purchase_return.dart';
import 'package:app/data/models/purchase_return_item.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/returns/application/purchase_return_detail_controller.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Shows one return, the invoice it credits, and the money involved.
class PurchaseReturnDetailScreen extends ConsumerWidget {
  /// Creates the detail screen for [returnId].
  const PurchaseReturnDetailScreen({required this.returnId, super.key});

  /// The return to show.
  final String returnId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(purchaseReturnDetailProvider(returnId));
    final suppliers =
        ref.watch(supplierOptionsProvider).value ?? const <Supplier>[];

    // A refresh keeps showing the loaded document; only a first-load failure
    // takes over the screen.
    if (detail.hasError && !detail.hasValue) {
      return AppScaffold(
        title: 'Purchase return',
        leading: _backToReturns,
        body: ErrorView(
          message: describeError(detail.error!),
          onRetry: () => ref.invalidate(purchaseReturnDetailProvider(returnId)),
        ),
      );
    }

    final data = detail.value;
    if (data == null) {
      return const AppScaffold(
        title: 'Purchase return',
        leading: _backToReturns,
        body: LoadingView(message: 'Loading the return…'),
      );
    }

    final document = data.purchaseReturn;
    final supplierName = _supplierName(suppliers, document.supplierId);

    return AppScaffold(
      title: 'Purchase return',
      leading: _backToReturns,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          SectionCard(
            title: 'Return',
            trailing: StatusBadge(
              label: document.isCompleted ? 'Completed' : document.status,
              tone: document.isCompleted
                  ? BadgeTone.success
                  : BadgeTone.neutral,
            ),
            child: Column(
              children: <Widget>[
                _Field(label: 'Supplier', value: supplierName),
                _Field(
                  label: 'Returned on',
                  value: Formatters.dateDdMmmYyyy(document.returnDate),
                ),
                _Field(label: 'Reason', value: document.reason),
                _Field(
                  label: 'Recorded',
                  value: Formatters.dateTimeDdMmmYyyyHm(document.createdAt),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Against',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _Field(label: 'Invoice', value: data.sourcePurchase?.invoiceNo),
                _Field(
                  label: 'Invoice date',
                  value: data.sourcePurchase == null
                      ? null
                      : Formatters.dateDdMmmYyyy(
                          data.sourcePurchase!.invoiceDate,
                        ),
                ),
                const SizedBox(height: 8),
                AppButton.outlined(
                  label: 'Open the purchase',
                  icon: Icons.receipt_long_outlined,
                  expand: false,
                  onPressed: () =>
                      context.go(Routes.purchaseDetail(document.purchaseId)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Credit',
            child: Column(
              children: <Widget>[
                // Read off the document's own columns: they are what was written
                // with the lines, and recomputing them here is how a screen ends
                // up disagreeing with what was stored.
                _AmountRow(
                  label: 'Value',
                  value: Formatters.currency(document.subTotal),
                ),
                _AmountRow(
                  label: 'Tax',
                  value: Formatters.currency(document.taxTotal),
                ),
                const Divider(height: 20),
                _AmountRow(
                  label: 'Total credit',
                  value: Formatters.currency(document.grandTotal),
                  emphasis: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Lines',
            child: data.items.isEmpty
                ? Text(
                    'This return has no lines. Goods can only be returned from '
                    'a received purchase, so raise another return from the '
                    'invoice.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                : Column(
                    children: <Widget>[
                      for (
                        var index = 0;
                        index < data.items.length;
                        index++
                      ) ...<Widget>[
                        _ReturnLine(
                          item: data.items[index],
                          name: data.nameOf(data.items[index]),
                        ),
                        if (index < data.items.length - 1)
                          const Divider(height: 24),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Back to the returns list.
const AppBackButton _backToReturns = AppBackButton(
  location: Routes.returns,
  tooltip: 'Back to returns',
);

/// The name of [supplierId], or a placeholder when the list has not loaded.
String _supplierName(List<Supplier> suppliers, String supplierId) {
  for (final supplier in suppliers) {
    if (supplier.id == supplierId) {
      return supplier.name;
    }
  }
  return 'Supplier';
}

/// One returned line.
class _ReturnLine extends StatelessWidget {
  const _ReturnLine({required this.item, required this.name});

  /// The line.
  final PurchaseReturnItem item;

  /// The name the invoice printed, when the invoice line still exists.
  final String? name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = name ?? 'Product';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.titleSmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: <Widget>[
            _Metric(label: 'Returned', value: '${item.qty}'),
            _Metric(
              label: 'Rate',
              value: Formatters.currency(item.purchaseRate),
            ),
            _Metric(label: 'MRP', value: Formatters.currency(item.mrp)),
            _Metric(label: 'GST', value: '${item.gstPercent}%'),
            _Metric(label: 'Tax', value: Formatters.currency(item.taxAmount)),
            _Metric(
              label: 'Line total',
              value: Formatters.currency(item.totalAmount),
            ),
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

/// One label and amount in the credit card.
class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.value,
    this.emphasis = false,
  });

  /// What the amount is.
  final String label;

  /// The amount, already formatted.
  final String value;

  /// Whether this is the total.
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            value,
            style: emphasis
                ? theme.textTheme.titleMedium
                : theme.textTheme.bodyMedium,
          ),
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
