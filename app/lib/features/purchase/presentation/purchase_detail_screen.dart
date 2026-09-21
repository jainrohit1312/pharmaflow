/// Purchase document detail: the invoice, its lines, and what it posted.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/logger.dart';
import 'package:app/core/widgets/app_back_button.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/confirm_dialog.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/profile.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/approvals/application/approvals_controller.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase/application/purchase_form_controller.dart';
import 'package:app/features/purchase/application/purchases_list_controller.dart';
import 'package:app/features/purchase/presentation/widgets/owner_approval_notice.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_status_badge.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Shows one purchase document, and what may still be done to it.
///
/// One scrolling page rather than tabs, matching the masters: a document has
/// fewer facets than it has states, and the totals belong beside the lines that
/// produced them rather than behind a tap.
class PurchaseDetailScreen extends ConsumerWidget {
  /// Creates the detail screen for [purchaseId].
  const PurchaseDetailScreen({required this.purchaseId, super.key});

  /// The document to show.
  final String purchaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(purchaseWithLinesProvider(purchaseId));

    // A refresh keeps showing the loaded document; only a first-load failure
    // takes over the screen.
    if (target.hasError && !target.hasValue) {
      return AppScaffold(
        title: 'Purchase',
        leading: _backToPurchases,
        body: ErrorView(
          message: describeError(target.error!),
          onRetry: () => ref.invalidate(purchaseWithLinesProvider(purchaseId)),
        ),
      );
    }

    final working = target.value;
    if (working == null) {
      return const AppScaffold(
        title: 'Purchase',
        leading: _backToPurchases,
        body: LoadingView(message: 'Loading purchase…'),
      );
    }

    final purchase = working.purchase;
    final names = <String, String>{
      for (final supplier
          in ref.watch(supplierOptionsProvider).value ?? const <Supplier>[])
        supplier.id: supplier.name,
    };

    ref.listen<AsyncValue<Purchase?>>(purchaseFormControllerProvider, (
      previous,
      next,
    ) {
      final error = next.error;
      if (error == null || !context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    });

    return AppScaffold(
      title: purchase.invoiceNo,
      leading: _backToPurchases,
      actions: <Widget>[
        if (working.isEditable)
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit purchase',
            onPressed: () => context.go(Routes.purchaseEdit(purchaseId)),
          ),
      ],
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          SectionCard(
            title: 'Invoice',
            trailing: PurchaseStatusBadge(
              status: purchase.status,
              stockPostedAt: purchase.stockPostedAt,
            ),
            child: Column(
              children: <Widget>[
                _Field(label: 'Supplier', value: names[purchase.supplierId]),
                _Field(label: 'Invoice number', value: purchase.invoiceNo),
                _Field(
                  label: 'Invoice date',
                  value: Formatters.dateDdMmmYyyy(purchase.invoiceDate),
                ),
                _Field(label: 'Notes', value: purchase.notes),
                _Field(
                  label: 'Recorded',
                  value: Formatters.dateTimeDdMmmYyyyHm(purchase.createdAt),
                ),
                if (purchase.stockPostedAt != null)
                  _Field(
                    label: 'Stock posted',
                    value: Formatters.dateTimeDdMmmYyyyHm(
                      purchase.stockPostedAt!,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (purchase.status.isPendingApproval) ...<Widget>[
            _WaitingForOwner(purchaseId: purchaseId),
            const SizedBox(height: 16),
          ],
          _StoredTotalsCard(purchase: purchase, items: working.items),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Lines',
            child: Column(
              children: <Widget>[
                for (var index = 0; index < working.items.length; index++) ...[
                  if (index > 0) const Divider(height: 24),
                  _LineTile(item: working.items[index]),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _StatusSection(
            purchase: purchase,
            isEditable: working.isEditable,
            canBeReceived: working.isReceivable,
            onReceive: () => context.go(Routes.purchaseGrn(purchaseId)),
            onMarkOrdered: () =>
                _changeStatus(context, ref, PurchaseStatus.ordered),
            onCancel: () => _cancel(context, ref),
          ),
        ],
      ),
    );
  }

  /// Moves the document to a status that posts nothing.
  ///
  /// Both moves are a write like any other, so for a member of staff both are questions
  /// for the owner - the difference being that "mark as ordered" stages the document and a
  /// cancellation leaves it exactly where it is. [reportSentToOwner] says which happened,
  /// in the sentence that matches: a staged document has posted nothing, and a
  /// cancellation has moved nothing.
  Future<void> _changeStatus(
    BuildContext context,
    WidgetRef ref,
    PurchaseStatus status,
  ) async {
    try {
      final saved = await ref
          .read(purchaseFormControllerProvider.notifier)
          .setStatus(purchaseId: purchaseId, status: status);
      if (!context.mounted) {
        return;
      }
      ref
        ..invalidate(purchasesListControllerProvider)
        ..invalidate(purchaseWithLinesProvider(purchaseId))
        // The waiting card reads the ask, and this write may have raised, refreshed or
        // answered one - so it is re-read rather than left showing the previous state.
        ..invalidate(
          approvalForTargetProvider(
            targetTable: 'purchases',
            targetId: purchaseId,
          ),
        );
      final isOwner =
          ref.read(profileStateProvider).value?.role.isOwner ?? false;
      reportSentToOwner(
        context,
        document: saved,
        isOwner: isOwner,
        isCancellation: status == PurchaseStatus.cancelled,
      );
    } on Object catch (error, stackTrace) {
      appLogger.w(
        'Changing the purchase status failed',
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

  /// Confirms, then abandons the document.
  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Cancel this purchase?',
      message:
          'The document stays in your records and keeps its number, but is '
          'taken out of the open orders. Nothing has been posted against it, so '
          'no stock or ledger entry is affected.',
      confirmLabel: 'Cancel purchase',
      cancelLabel: 'Keep it',
      isDestructive: true,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    await _changeStatus(context, ref, PurchaseStatus.cancelled);
  }
}

/// Returns to the purchase list.
const AppBackButton _backToPurchases = AppBackButton(
  location: Routes.purchase,
  tooltip: 'Back to purchases',
);

/// What a document that is waiting for the owner is waiting for.
///
/// Reads the undecided request about this document, so the screen says what the owner is
/// being asked rather than only that something is. Two things it deliberately does not
/// do: it does not promise a decision (the request may be answered, or - for another
/// member of staff's ask - not even visible to this caller), and it does not imply that
/// anything has posted. The one sentence it always shows is the consequence that matters
/// to the counter: a pending GRN's medicines are **not in stock and cannot be sold**
/// until he approves, which is the operational cost of the policy he chose.
class _WaitingForOwner extends ConsumerWidget {
  const _WaitingForOwner({required this.purchaseId});

  /// The document being waited on.
  final String purchaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final request = ref
        .watch(
          approvalForTargetProvider(
            targetTable: 'purchases',
            targetId: purchaseId,
          ),
        )
        .value;

    return SectionCard(
      title: 'Waiting for the owner',
      trailing: const StatusBadge(
        label: 'Nothing posted yet',
        tone: BadgeTone.warning,
        icon: Icons.hourglass_top_outlined,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (request != null) ...<Widget>[
            Text(request.title, style: theme.textTheme.titleSmall),
            if (request.summary case final summary?) ...<Widget>[
              const SizedBox(height: 4),
              Text(summary, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 8),
            Text(
              'Asked ${Formatters.dateTimeDdMmmYyyyHm(request.requestedAt)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
          ],
          Text(
            'Nothing has been posted for this document: the goods are not in stock '
            'and no supplier payable exists until the owner approves it. ',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          AppButton.outlined(
            label: 'Open approvals',
            icon: Icons.approval_outlined,
            onPressed: () => context.go(Routes.approvals),
          ),
        ],
      ),
    );
  }
}

/// The document's own totals, read straight off the stored columns.
///
/// The stored figures are shown rather than recomputed from the lines: they are
/// what `ledger_auto_entry_purchase()` posted as the supplier payable, and a
/// display that recomputed them could disagree with the ledger by a paisa while
/// looking authoritative. The tax head is summed from the lines because it is
/// only stored per line.
class _StoredTotalsCard extends StatelessWidget {
  const _StoredTotalsCard({required this.purchase, required this.items});

  /// The document whose totals these are.
  final Purchase purchase;

  /// Its lines, carrying the per-line tax split.
  final List<PurchaseItem> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cgst = items.fold<double>(0, (sum, item) => sum + item.cgstAmount);
    final sgst = items.fold<double>(0, (sum, item) => sum + item.sgstAmount);
    final igst = items.fold<double>(0, (sum, item) => sum + item.igstAmount);

    return SectionCard(
      title: 'Totals',
      child: Column(
        children: <Widget>[
          _AmountRow(label: 'Taxable value', amount: purchase.subTotal),
          if (purchase.discountTotal > 0)
            _AmountRow(label: 'Discount', amount: -purchase.discountTotal),
          if (igst > 0)
            _AmountRow(label: 'IGST', amount: igst)
          else ...<Widget>[
            _AmountRow(label: 'CGST', amount: cgst),
            _AmountRow(label: 'SGST', amount: sgst),
          ],
          const Divider(height: 24),
          _AmountRow(
            label: 'Grand total',
            amount: purchase.grandTotal,
            emphasise: true,
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            // What the figure *is* depends on where the document got to: a waiting one
            // has a grand total and no payable, and saying otherwise on its own screen
            // would be the one claim this phase keeps having to avoid.
            child: Text(
              purchase.status.isPendingApproval
                  ? 'Nothing owes this yet — the ledger holds it against the '
                        'supplier only once the owner approves the document.'
                  : 'This is the payable the ledger holds against the supplier.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// What has and has not been posted, and what may still be done.
///
/// Kept apart from the totals because it is the part with consequences: the
/// status is not a label, it is whether stock and a payable exist.
class _StatusSection extends StatelessWidget {
  const _StatusSection({
    required this.purchase,
    required this.isEditable,
    required this.canBeReceived,
    required this.onReceive,
    required this.onMarkOrdered,
    required this.onCancel,
  });

  /// The document this section describes.
  final Purchase purchase;

  /// Whether its lines may still be written.
  final bool isEditable;

  /// Whether every line carries the batch details a receipt needs.
  final bool canBeReceived;

  /// Opens the goods receipt.
  final VoidCallback onReceive;

  /// Moves a draft to ordered.
  final VoidCallback onMarkOrdered;

  /// Abandons the document.
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!isEditable) {
      // A cancelled document reached this section too, and telling its reader that its
      // stock is booked in and its grand total is owed would be a plain falsehood - so
      // the two ends are stated separately rather than both described as a receipt.
      if (purchase.status == PurchaseStatus.cancelled) {
        return SectionCard(
          title: 'Stock & ledger',
          child: Text(
            'Cancelled, so nothing was posted: no stock moved and no supplier '
            'payable exists. The document stays in your records and keeps its '
            'number.',
            style: theme.textTheme.bodyMedium,
          ),
        );
      }

      return SectionCard(
        title: 'Stock & ledger',
        child: Text(
          'Received ${Formatters.dateTimeDdMmmYyyyHm(purchase.stockPostedAt ?? purchase.updatedAt)}. '
          'The batches above hold the stock this document brought in, and the '
          'grand total is owed to the supplier. Corrections go through a '
          'purchase return or a stock adjustment — editing the document would '
          'not reverse either.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    return SectionCard(
      title: 'Next step',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _nextStep(purchase: purchase, canBeReceived: canBeReceived),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          AppButton.primary(
            label: 'Receive goods',
            icon: Icons.inventory_2_outlined,
            onPressed: onReceive,
          ),
          if (purchase.status == PurchaseStatus.draft) ...<Widget>[
            const SizedBox(height: 12),
            AppButton.outlined(
              label: 'Mark as ordered',
              icon: Icons.local_shipping_outlined,
              onPressed: onMarkOrdered,
            ),
          ],
          const SizedBox(height: 12),
          AppButton.outlined(
            label: 'Cancel purchase',
            icon: Icons.cancel_outlined,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// What the next step on an editable document is, in the state it is actually in.
String _nextStep({required Purchase purchase, required bool canBeReceived}) {
  if (purchase.status.isPendingApproval) {
    return 'This document is waiting for the owner, and nothing has been posted '
        'for it. It can still be edited — saving it again asks him about what it '
        'says now rather than raising a second question — and until he approves, '
        'its medicines are not in stock and cannot be sold.';
  }

  return canBeReceived
      ? 'Nothing has been posted yet. Receiving the goods books the stock into '
            'batches and raises the supplier payable.'
      : 'Fill in each line on the receipt — product, quantity, batch number and '
            'expiry — before the goods can be booked in.';
}

/// One line as the document stores it.
class _LineTile extends StatelessWidget {
  const _LineTile({required this.item});

  /// The stored line.
  final PurchaseItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = item.productNameRaw?.trim();
    final batchNo = item.batchNo?.trim();
    final expiry = item.expiryDate;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                name == null || name.isEmpty ? 'Product not recorded' : name,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 2),
              Text(_quantityLine(item), style: theme.textTheme.bodySmall),
              if (batchNo != null && batchNo.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    StatusBadge(label: 'Batch $batchNo'),
                    if (expiry != null)
                      StatusBadge(
                        label: 'Exp ${Formatters.dateDdMmmYyyy(expiry)}',
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Text(
              Formatters.currency(item.totalAmount),
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 2),
            Text(
              '${Formatters.currency(item.purchaseRate)} / unit',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }
}

/// Describes a line's quantity, naming the scheme units when there are any.
String _quantityLine(PurchaseItem item) {
  if (item.freeQty > 0) {
    return '${item.qty} + ${item.freeQty} free = ${item.receivedQty} units · '
        'GST ${item.gstPercent}%';
  }
  return '${item.qty} units · GST ${item.gstPercent}%';
}

/// A label and an amount, right aligned.
class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.amount,
    this.emphasise = false,
  });

  /// What the amount is.
  final String label;

  /// The amount, already in rupees.
  final double amount;

  /// Whether to render it as the figure that matters.
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = emphasise
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)
        : theme.textTheme.bodyMedium;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: style)),
          Text(Formatters.currency(amount), style: style),
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
