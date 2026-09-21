/// The counter's confirmation step, and the notice when the server disagrees.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/pos_controller.dart';
import 'package:app/features/sales/data/sale_totals.dart';
import 'package:flutter/material.dart';

/// Asks the counter to confirm what is about to be written, and answers whether it did.
///
/// Step one of the two this slice adds. The figures here are the **client's** own,
/// computed on the server's basis (D-075) - the server recomputes from its own reading
/// of the slabs and trusts none of them - which is why the dialog says in as many words
/// that the server will verify the totals. Nothing has been written when this is shown,
/// and nothing is shown as written until the server answers.
///
/// A dismissed dialog - a tap outside, the platform's back - is **not** a confirmation.
Future<bool> showPaymentConfirmation(
  BuildContext context, {
  required PosCart cart,
  required SaleDocumentTotals totals,
}) async {
  final paid = cart.paidFor(totals.grandTotal);
  // The same raw tender the counter's own totals panel works the change from, so the
  // figure the operator just looked at and the one this dialog repeats cannot differ.
  final change = SaleTotals.changeFor(
    tendered: SaleTotals.tenderedFor(
      grandTotal: totals.grandTotal,
      tendered: cart.tendered,
      isOnAccount: cart.paymentMode.isOnAccount,
    ),
    total: totals.grandTotal,
  );

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return AlertDialog(
        title: Text('Take ${Formatters.currency(totals.grandTotal)}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Figure(
              label: 'Total',
              value: Formatters.currency(totals.grandTotal),
            ),
            _Figure(
              label: cart.paymentMode.label,
              value: Formatters.currency(paid),
            ),
            if (change > 0)
              _Figure(label: 'Change', value: Formatters.currency(change)),
            if (paid < totals.grandTotal)
              _Figure(
                label: 'Balance due',
                value: Formatters.currency(
                  PurchaseTotals.round2(totals.grandTotal - paid),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'Server will verify totals.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        actions: <Widget>[
          AppButton.text(
            label: 'Cancel',
            expand: false,
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          AppButton.primary(
            label: 'Confirm & Submit',
            icon: Icons.check,
            expand: false,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      );
    },
  );

  return confirmed ?? false;
}

/// Says the server's figures are not the ones the counter showed.
///
/// The rare path, and the reason it is not silent: the client computes on the server's
/// basis and the server recomputes from its own reading, so a disagreement means the
/// receipt the customer is about to be handed differs from the amount the operator just
/// took. The notice carries the **server's** figures, because they are what the bill and
/// the ledger hold, and names the one the counter had shown.
Future<void> showVerifiedTotals(
  BuildContext context, {
  required SaleDocumentTotals shown,
  required Sale stored,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) {
    final theme = Theme.of(dialogContext);
    return AlertDialog(
      title: const Text('Verified'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'The server\u2019s figures for this bill are the ones that will print.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          _Figure(
            label: 'Total',
            value: Formatters.currency(stored.grandTotal),
          ),
          _Figure(
            label: 'Taxable value',
            value: Formatters.currency(stored.subTotal),
          ),
          _Figure(label: 'Tax', value: Formatters.currency(stored.taxTotal)),
          if (shown.grandTotal != stored.grandTotal) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              'The counter showed ${Formatters.currency(shown.grandTotal)}.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: <Widget>[
        AppButton.primary(
          label: 'OK',
          expand: false,
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
      ],
    );
  },
);

/// A label and a figure on one line, as both dialogs print them.
class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});

  /// What the figure is.
  final String label;

  /// The figure, already formatted.
  final String value;

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
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
