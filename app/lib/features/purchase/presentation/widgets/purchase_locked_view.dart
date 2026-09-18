/// Explains why a received purchase can no longer be written to.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/data/models/purchase.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Shown in place of a form for a document whose stock is already booked in.
///
/// Rendered instead of letting the user fill a form that the write would refuse:
/// once a document is received its lines are what produced the stock and the
/// supplier payable, and the triggers deliberately do not reverse them (D-013),
/// so the correction has to be a purchase return or a stock adjustment. Say that
/// here, and give the user somewhere to go, rather than presenting a dead end.
class PurchaseLockedView extends StatelessWidget {
  /// Creates the locked view for [purchaseId].
  const PurchaseLockedView({
    required this.purchaseId,
    required this.status,
    super.key,
  });

  /// The document that can no longer be written to.
  final String purchaseId;

  /// Its status, named in the explanation.
  final PurchaseStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.lock_outline,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'This purchase is ${status.label.toLowerCase()} already',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Its stock and ledger entry are booked in, and putting the '
              'document back would not reverse them. Correct it with a purchase '
              'return or a stock adjustment instead.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            AppButton.primary(
              label: 'View the purchase',
              icon: Icons.visibility_outlined,
              expand: false,
              onPressed: () => context.go(Routes.purchaseDetail(purchaseId)),
            ),
          ],
        ),
      ),
    );
  }
}
