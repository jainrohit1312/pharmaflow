/// The sheet that picks which batch a product comes out of.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/expiry_badge.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/sales/application/sellable_batches_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Asks which batch of [product] is going out, and resolves to it.
///
/// FEFO is the pharmacy's own rule, so the list is already in first-expiry-first-out
/// order and the first row is marked as the one to dispense. The cashier can still
/// override it - a customer asking for a longer expiry is a real request - which is
/// why this is a choice rather than an automatic pick.
///
/// One unit is added at a time: a counter adds what is in the customer's hand and
/// adjusts the quantity in the basket, rather than being asked for a number before
/// it knows what was picked up.
Future<BatchStatus?> showBatchChooser(
  BuildContext context, {
  required Product product,
}) => showModalBottomSheet<BatchStatus>(
  context: context,
  isScrollControlled: true,
  builder: (sheetContext) => _BatchChooserSheet(product: product),
);

/// The batch list.
class _BatchChooserSheet extends ConsumerWidget {
  const _BatchChooserSheet({required this.product});

  /// The product being sold.
  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batches = ref.watch(sellableBatchesProvider(product.id));
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(product.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'First expiry, first out — dispense from the top.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Flexible(child: _Body(batches: batches)),
          ],
        ),
      ),
    );
  }
}

/// Renders whichever of the batch read's states applies.
class _Body extends ConsumerWidget {
  const _Body({required this.batches});

  /// The batches, or the failed read.
  final AsyncValue<List<BatchStatus>> batches;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (batches.hasValue) {
      final rows = batches.value!;
      if (rows.isEmpty) {
        return const AppEmptyView(
          icon: Icons.inventory_2_outlined,
          title: 'Nothing in stock',
          message:
              'No batch of this product holds stock, so there is nothing to '
              'dispense. Receive goods against a purchase first.',
        );
      }
      return ListView.separated(
        shrinkWrap: true,
        itemCount: rows.length,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, index) => _BatchRow(
          batch: rows[index],
          isFirstOut: index == 0,
          onTap: () => Navigator.of(context).pop(rows[index]),
        ),
      );
    }

    if (batches.hasError) {
      return ErrorView(
        message: describeError(batches.error!),
        onRetry: () => ref.invalidate(sellableBatchesProvider),
      );
    }

    return const LoadingView(message: 'Loading the batches…');
  }
}

/// One batch, as a choice.
class _BatchRow extends StatelessWidget {
  const _BatchRow({
    required this.batch,
    required this.isFirstOut,
    required this.onTap,
  });

  /// The batch on offer.
  final BatchStatus batch;

  /// Whether this is the FEFO head.
  final bool isFirstOut;

  /// Called when it is chosen.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Batch ${batch.batchNo}',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  // No badge without a date: the view reports a batch whose expiry
                  // nobody recorded as the 'unknown' bucket, which folds to the
                  // *safe* badge - and "Safe" beside "expiry unknown" would be a
                  // statement about a date that does not exist.
                  if (batch.hasKnownExpiry)
                    ExpiryBadge(status: batch.expiryStatus),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${batch.qty} in stock · ${_expiry(batch)} · '
                '${Formatters.currency(batch.sellingRate > 0 ? batch.sellingRate : batch.mrp)}'
                '${isFirstOut ? ' · dispense this one first' : ''}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// When the batch expires, or that nobody recorded a date.
///
/// `expiry unknown` rather than a blank or an invented date: 145 of the owner's
/// opening-stock batches have no expiry on record (migration 00031), and an empty
/// space there reads as a rendering fault rather than as missing information.
String _expiry(BatchStatus batch) {
  final date = batch.expiryDate;
  return date == null
      ? 'expiry unknown'
      : 'expires ${Formatters.dateDdMmmYyyy(date)}';
}
