/// Live totals for a purchase document being edited.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/section_card.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:flutter/material.dart';

/// Shows what the document will total, and where its tax goes.
///
/// Computed with the same `PurchaseTotals` the write uses, so the figure on
/// screen is the figure that gets stored rather than a second implementation of
/// the arithmetic that could disagree with it.
class PurchaseTotalsPreview extends StatelessWidget {
  /// Creates the preview for [lines] under [split].
  const PurchaseTotalsPreview({
    required this.lines,
    required this.split,
    super.key,
  });

  /// The lines as they currently stand.
  final List<PurchaseLineDraft> lines;

  /// Whether the tax is intra-state or inter-state.
  final TaxSplit split;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totals = PurchaseTotals.forLines(lines, split: split);
    // Summed from the per-line figures, because those are what the
    // cgst_amount/sgst_amount columns receive: halving the document total here
    // can disagree with them by a paisa, and the screen would then be showing a
    // number the database does not hold.
    final lineTotals = lines
        .map((line) => PurchaseTotals.forLine(line, split: split))
        .toList(growable: false);
    final cgstTotal = lineTotals.fold(0.0, (sum, line) => sum + line.cgst);
    final sgstTotal = lineTotals.fold(0.0, (sum, line) => sum + line.sgst);

    return SectionCard(
      title: 'Totals',
      child: Column(
        children: <Widget>[
          _Row(label: 'Taxable value', amount: totals.subTotal),
          if (totals.discountTotal > 0)
            _Row(label: 'Discount', amount: -totals.discountTotal),
          switch (split) {
            TaxSplit.intraState => Column(
              children: <Widget>[
                _Row(label: 'CGST', amount: cgstTotal),
                _Row(label: 'SGST', amount: sgstTotal),
              ],
            ),
            TaxSplit.interState => _Row(
              label: 'IGST',
              amount: totals.taxTotal,
            ),
          },
          const Divider(height: 24),
          _Row(
            label: 'Grand total',
            amount: totals.grandTotal,
            emphasise: true,
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              split == TaxSplit.intraState
                  ? 'Tax split as CGST + SGST (same state as the supplier).'
                  : 'Tax charged as IGST (supplier is in another state).',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

}

/// A label and an amount, right aligned.
class _Row extends StatelessWidget {
  const _Row({required this.label, required this.amount, this.emphasise = false});

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
