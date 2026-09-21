/// What has been applied to one bill.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/core/widgets/status_badge.dart';
import 'package:app/data/models/account_balance.dart';
import 'package:app/features/balances/application/balances.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The receipts applied to this bill, read from `payment_allocations`.
///
/// **What this answers and what it does not.** These are the slices of money actually
/// applied to this document. A bill with no rows here has had nothing applied to it -
/// which is not the same as "nothing was paid": money handed over that was never aimed
/// at a bill is an **unallocated deposit** on the party's account, and it stays visible
/// there until it is applied (`allocate_payment()`), which writes no second receipt.
///
/// A **package** bill's money comes from the hospital's account row, and its
/// allocations are still allocations against this sale - they name the bill, not the
/// party, so they show here either way.
class SaleAllocationsCard extends ConsumerWidget {
  /// Creates the card for [saleId].
  const SaleAllocationsCard({required this.saleId, super.key});

  /// The bill to show.
  final String saleId;

  /// What the card is called wherever it appears.
  static const String title = 'Settled by';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final allocations = ref.watch(saleAllocationsProvider(saleId));

    if (allocations.hasError && !allocations.hasValue) {
      return SectionCard(
        title: title,
        child: ErrorView(
          message: describeError(allocations.error!),
          onRetry: () => ref.invalidate(saleAllocationsProvider(saleId)),
        ),
      );
    }

    final rows = allocations.value;
    if (rows == null) {
      return const SectionCard(
        title: title,
        child: Text('Loading what settled this bill…'),
      );
    }

    if (rows.isEmpty) {
      return const SectionCard(
        title: title,
        trailing: StatusBadge(label: 'Nothing applied'),
        child: Text(
          'No receipt has been applied to this bill yet. Money taken at the counter '
          'that was not aimed at a bill stays an unapplied deposit on the party\u2019s '
          'account until it is applied to one.',
        ),
      );
    }

    return SectionCard(
      title: title,
      trailing: StatusBadge(
        label: rows.length == 1 ? '1 receipt' : '${rows.length} receipts',
        tone: BadgeTone.success,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // The server's rows, printed as they came. **No total is added up here**: a sum
          // of rows is a figure no server computed, and the ledger and the account would
          // be the two places to disagree with it.
          for (var index = 0; index < rows.length; index++) ...<Widget>[
            _AllocationRow(allocation: rows[index]),
            if (index < rows.length - 1) const Divider(height: 20),
          ],
          const SizedBox(height: 8),
          Text(
            'Each row is one receipt applied to this bill. A receipt that appears more '
            'than once was split across several documents.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// One receipt's slice of this bill.
class _AllocationRow extends StatelessWidget {
  const _AllocationRow({required this.allocation});

  /// The allocation to print.
  final SaleAllocation allocation;

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
                'Receipt ${_short(allocation.paymentId)}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Text(
              Formatters.currency(allocation.amount),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        if (allocation.createdAt != null)
          Text(
            'Applied ${Formatters.dateTimeDdMmmYyyyHm(allocation.createdAt!)}',
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }

  /// The first segment of a uuid, which is enough to tell two receipts apart on screen.
  static String _short(String id) => id.length <= 8 ? id : id.substring(0, 8);
}
