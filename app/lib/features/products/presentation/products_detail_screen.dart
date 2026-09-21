/// Product detail screen: identity, stock, batches and aliases.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/logger.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/confirm_dialog.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/expiry_badge.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_alias.dart';
import 'package:app/features/approvals/presentation/sent_to_owner.dart';
import 'package:app/features/inventory/presentation/widgets/stock_adjustment_sheet.dart';
import 'package:app/features/products/application/products_detail_controller.dart';
import 'package:app/features/products/application/products_form_controller.dart';
import 'package:app/features/products/presentation/widgets/product_badges.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Shows everything recorded about one product.
class ProductsDetailScreen extends ConsumerWidget {
  /// Creates the detail screen for [productId].
  const ProductsDetailScreen({required this.productId, super.key});

  /// The product to show.
  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(productDetailControllerProvider(productId));

    // A refresh keeps showing the loaded product; only a first-load failure
    // takes over the screen.
    if (detail.hasError && !detail.hasValue) {
      return AppScaffold(
        title: 'Product',
        leading: const _BackToProducts(),
        body: ErrorView(
          message: describeError(detail.error!),
          onRetry: () =>
              ref.invalidate(productDetailControllerProvider(productId)),
        ),
      );
    }

    final data = detail.value;
    if (data == null) {
      return const AppScaffold(
        title: 'Product',
        leading: _BackToProducts(),
        body: LoadingView(message: 'Loading product…'),
      );
    }

    final product = data.product;
    return DefaultTabController(
      length: 3,
      child: AppScaffold(
        title: product.name,
        leading: const _BackToProducts(),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit product',
            onPressed: () => context.go(Routes.productEdit(productId)),
          ),
          IconButton(
            icon: Icon(
              product.isActive
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            tooltip: product.isActive ? 'Deactivate' : 'Reactivate',
            onPressed: () => _toggleActive(context, ref, product),
          ),
        ],
        body: Column(
          children: <Widget>[
            TabBar(
              tabs: <Widget>[
                const Tab(text: 'Info'),
                Tab(text: 'Batches (${data.batches.length})'),
                Tab(text: 'Aliases (${data.aliases.length})'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: <Widget>[
                  _InfoTab(data: data),
                  _BatchesTab(
                    productId: productId,
                    productName: product.name,
                    data: data,
                  ),
                  _AliasesTab(productId: productId, aliases: data.aliases),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Asks for confirmation, then flips the product's active flag.
  Future<void> _toggleActive(
    BuildContext context,
    WidgetRef ref,
    Product product,
  ) async {
    final deactivating = product.isActive;
    final confirmed = await showConfirmDialog(
      context,
      title: deactivating ? 'Deactivate product?' : 'Reactivate product?',
      message: deactivating
          ? '${product.name} stays in the catalogue and in past documents, but '
                'will not be offered for new sales or purchases.'
          : '${product.name} becomes available for new sales and purchases again.',
      confirmLabel: deactivating ? 'Deactivate' : 'Reactivate',
      isDestructive: deactivating,
    );
    if (!confirmed || !context.mounted) {
      return;
    }

    try {
      final outcome = await ref
          .read(productsFormControllerProvider.notifier)
          .setProductActive(productId: product.id, isActive: !deactivating);
      if (!context.mounted) {
        return;
      }

      // A staged write moved NOTHING: the product is still active (or still inactive), so the
      // detail is deliberately not re-read - a refresh would show the unchanged row and read as a
      // deactivation that had happened.
      if (outcome.isStaged) {
        showSentToOwnerNotice(context, message: sentForApprovalMessage);
        return;
      }

      ref.invalidate(productDetailControllerProvider(productId));
    } on Object catch (error, stackTrace) {
      appLogger.w(
        'Toggling product active failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

/// Back to the catalogue.
class _BackToProducts extends StatelessWidget {
  const _BackToProducts();

  @override
  Widget build(BuildContext context) => const AppBackButton(
    location: Routes.products,
    tooltip: 'Back to products',
  );
}

/// Identity, classification, stock and bookkeeping.
class _InfoTab extends StatelessWidget {
  const _InfoTab({required this.data});

  /// The loaded detail.
  final ProductDetailData data;

  @override
  Widget build(BuildContext context) {
    final product = data.product;
    final stock = data.stock;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        SectionCard(
          title: 'Stock',
          trailing: _StockBadge(data: data),
          child: Column(
            children: <Widget>[
              _Field(label: 'On hand', value: '${data.totalQty}'),
              _Field(
                label: 'Reorder level',
                value: product.minStockLevel == 0
                    ? 'No alert configured'
                    : '${product.minStockLevel}',
              ),
              _Field(
                label: 'Value at cost',
                value: stock == null
                    ? null
                    : Formatters.currency(stock.stockValueAtCost),
              ),
              _Field(
                label: 'Value at MRP',
                value: stock == null
                    ? null
                    : Formatters.currency(stock.stockValueAtMrp),
              ),
              _Field(
                label: 'Already expired',
                value: '${data.qtyExpiringBy(ExpiryStatus.expired)}',
              ),
              _Field(
                label: 'Expiring within 30 days',
                value: '${data.qtyExpiringBy(ExpiryStatus.critical)}',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Identity',
          child: Column(
            children: <Widget>[
              _Field(label: 'Name', value: product.name),
              _Field(label: 'Generic name', value: product.genericName),
              _Field(label: 'Brand', value: product.brand),
              _Field(label: 'Manufacturer', value: product.manufacturer),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Classification',
          trailing: ScheduleBadge(scheduleType: product.scheduleType),
          child: Column(
            children: <Widget>[
              _Field(label: 'Category', value: product.category),
              _Field(label: 'HSN code', value: product.hsnCode),
              _Field(label: 'Pack size', value: product.packSize),
              _Field(label: 'Unit', value: product.unit),
              _Field(
                label: 'Prescription',
                value: product.scheduleType.requiresPrescription
                    ? 'Required'
                    : 'Not required',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Codes and location',
          child: Column(
            children: <Widget>[
              _Field(label: 'Barcode', value: product.barcode),
              _Field(label: 'Rack location', value: product.rackLocation),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Record',
          trailing: StatusBadge(
            label: product.isActive ? 'Active' : 'Inactive',
            tone: product.isActive ? BadgeTone.success : BadgeTone.neutral,
          ),
          child: Column(
            children: <Widget>[
              _Field(
                label: 'Added',
                value: Formatters.dateTimeDdMmmYyyyHm(product.createdAt),
              ),
              _Field(
                label: 'Last updated',
                value: Formatters.dateTimeDdMmmYyyyHm(product.updatedAt),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Stock level, as a badge.
class _StockBadge extends StatelessWidget {
  const _StockBadge({required this.data});

  /// The loaded detail.
  final ProductDetailData data;

  @override
  Widget build(BuildContext context) {
    if (data.totalQty <= 0) {
      return const StatusBadge(
        label: 'Out of stock',
        tone: BadgeTone.danger,
        icon: Icons.remove_shopping_cart_outlined,
      );
    }
    if (data.isLowStock) {
      return const StatusBadge(
        label: 'Low stock',
        tone: BadgeTone.warning,
        icon: Icons.trending_down,
      );
    }
    return const StatusBadge(
      label: 'In stock',
      tone: BadgeTone.success,
      icon: Icons.check_circle_outline,
    );
  }
}

/// Batches in FEFO order.
class _BatchesTab extends ConsumerWidget {
  const _BatchesTab({
    required this.productId,
    required this.productName,
    required this.data,
  });

  /// The product these batches belong to.
  final String productId;

  /// Its name, for the adjustment sheet's heading.
  final String productName;

  /// The loaded detail.
  final ProductDetailData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final batches = data.batches;

    if (batches.isEmpty) {
      return const AppEmptyView(
        icon: Icons.inventory_2_outlined,
        title: 'No batches yet',
        message:
            'Stock arrives in batches. A batch is created when a purchase is '
            'received, so this tab fills up from Purchase \u2192 Goods receipt.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: batches.length + 1,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Text(
            'First expiry, first out — dispense from the top.',
            style: theme.textTheme.bodySmall,
          );
        }
        final batch = batches[index - 1];
        return _BatchCard(
          batch: batch,
          onAdjust: () => _adjust(context, ref, batch),
        );
      },
    );
  }

  /// Opens the stock correction sheet for one batch.
  ///
  /// The sheet belongs to the inventory feature, which owns `stock_adjustments`;
  /// this screen is where every batch of a product is listed, so it is the one
  /// place a batch that is *not* expiring soon can be corrected. The reload is
  /// this screen's job rather than the sheet's, which keeps the dependency one
  /// way - inventory knows nothing about products.
  Future<void> _adjust(
    BuildContext context,
    WidgetRef ref,
    BatchStatus batch,
  ) async {
    final outcome = await showStockAdjustmentSheet(
      context,
      productId: productId,
      productName: productName,
      batchId: batch.id,
      batchNo: batch.batchNo,
      onHand: batch.qty,
    );
    if (outcome == null || !context.mounted) {
      return;
    }
    // A correction is a REQUEST for anybody but the owner, and a request moves no stock:
    // the batch list is re-read only when something actually changed, and the sentence says
    // which of the two happened.
    if (outcome.isStaged) {
      showSentToOwnerNotice(context, message: sentForApprovalMessage);
      return;
    }
    ref.invalidate(productDetailControllerProvider(productId));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Stock adjusted.')));
  }
}

/// One batch row.
class _BatchCard extends StatelessWidget {
  const _BatchCard({required this.batch, this.onAdjust});

  /// The batch to show.
  final BatchStatus batch;

  /// Called when the user wants to correct this batch's quantity.
  final VoidCallback? onAdjust;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final adjust = onAdjust;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(batch.batchNo, style: theme.textTheme.titleSmall),
                ),
                ExpiryBadge(status: batch.expiryStatus),
                if (adjust != null)
                  IconButton(
                    icon: const Icon(Icons.tune),
                    tooltip: 'Adjust this batch',
                    onPressed: adjust,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: <Widget>[
                _Metric(label: 'Qty', value: '${batch.qty}'),
                _Metric(label: 'Expiry', value: _expiryText(batch)),
                _Metric(label: 'MRP', value: Formatters.currency(batch.mrp)),
                _Metric(
                  label: 'Rate',
                  value: Formatters.currency(batch.purchaseRate),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A batch's expiry as `18 Oct 2026`, or `Unknown` when none was recorded.
///
/// `product_batches.expiry_date` is nullable since migration 00031, so a batch
/// imported as opening stock may legitimately have no date. `Unknown` rather than a
/// blank: the metric is a label and a value, and an empty value reads as a fault.
String _expiryText(BatchStatus batch) {
  final date = batch.expiryDate;
  return date == null ? 'Unknown' : Formatters.dateDdMmmYyyy(date);
}

/// A label and value sitting side by side, for compact batch metrics.
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

/// Invoice aliases pointing at this product.
class _AliasesTab extends ConsumerWidget {
  const _AliasesTab({required this.productId, required this.aliases});

  /// The product these aliases belong to.
  final String productId;

  /// The aliases currently recorded.
  final List<ProductAlias> aliases;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        SectionCard(
          title: 'Invoice aliases',
          trailing: AppButton.text(
            label: 'Add',
            icon: Icons.add,
            expand: false,
            onPressed: () => _add(context, ref),
          ),
          child: aliases.isEmpty
              ? Text(
                  'No aliases yet. Add the text a supplier prints on their '
                  'invoice so this product can be recognised automatically.',
                  style: Theme.of(context).textTheme.bodyMedium,
                )
              : Column(
                  children: <Widget>[
                    for (final alias in aliases)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(alias.rawName),
                        subtitle: Text('matches as "${alias.normalizedName}"'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Remove alias',
                          onPressed: () => _remove(context, ref, alias),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  /// Asks for invoice text and records it against this product.
  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final rawName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => const _AddAliasDialog(),
    );
    if (rawName == null || rawName.trim().isEmpty || !context.mounted) {
      return;
    }

    try {
      final outcome = await ref
          .read(productDetailControllerProvider(productId).notifier)
          .addAlias(rawName: rawName);
      if (!context.mounted) {
        return;
      }

      // The alias was only ASKED for: nothing was recorded, so the tab is not refreshed and the
      // sentence says where the ask went.
      if (outcome.isStaged) {
        showSentToOwnerNotice(context, message: sentForApprovalMessage);
      }
    } on Object catch (error, stackTrace) {
      appLogger.w(
        'Adding an alias failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  /// Removes an alias after confirmation.
  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    ProductAlias alias,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove alias?',
      message:
          '"${alias.rawName}" will no longer be recognised as this product.',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed || !context.mounted) {
      return;
    }

    try {
      final outcome = await ref
          .read(productDetailControllerProvider(productId).notifier)
          .removeAlias(alias.id);
      if (!context.mounted) {
        return;
      }

      if (outcome.isStaged) {
        showSentToOwnerNotice(context, message: sentForApprovalMessage);
      }
    } on Object catch (error, stackTrace) {
      appLogger.w(
        'Removing an alias failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

/// Collects the invoice text for a new alias.
class _AddAliasDialog extends StatefulWidget {
  const _AddAliasDialog();

  @override
  State<_AddAliasDialog> createState() => _AddAliasDialogState();
}

class _AddAliasDialogState extends State<_AddAliasDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add invoice alias'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      textCapitalization: TextCapitalization.characters,
      decoration: const InputDecoration(
        labelText: 'Name as printed on the invoice',
        hintText: 'DOLO 650 TAB 15S',
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const Text('Add'),
      ),
    ],
  );
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
