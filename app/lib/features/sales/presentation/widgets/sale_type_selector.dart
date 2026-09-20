/// The four sale types, as a choice.
library;

import 'package:app/data/models/sale.dart';
import 'package:flutter/material.dart';

/// Picks which of the four kinds of sale this bill is (D-067).
///
/// Four chips rather than a dropdown because there are four of them and they are
/// the counter's first decision: a type changes what the bill must carry, how its
/// lines are priced, and whether a discount exists at all - so it is worth one row
/// of the screen rather than a menu.
class SaleTypeSelector extends StatelessWidget {
  /// Creates the selector.
  const SaleTypeSelector({
    required this.value,
    required this.onChanged,
    super.key,
    this.enabled = true,
  });

  /// The type currently chosen.
  final SaleType value;

  /// Called when another one is tapped.
  final ValueChanged<SaleType> onChanged;

  /// Whether the choice can be changed.
  ///
  /// False while a basket is rung up on a cost-priced basis: a package or transfer
  /// line is priced from the batch's cost, so the type cannot change under it.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final type in SaleType.values)
              ChoiceChip(
                label: Text(type.label),
                selected: value == type,
                onSelected: enabled ? (_) => onChanged(type) : null,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(_summary(value), style: theme.textTheme.bodySmall),
      ],
    );
  }

  /// One sentence about what the chosen type means for the bill.
  ///
  /// The counter is being asked to choose between four things that differ in ways
  /// that matter later (who owes the money, how the rate is arrived at, whether tax
  /// is charged), so the difference is on screen rather than in a manual.
  static String _summary(SaleType type) => switch (type) {
    SaleType.counter =>
      'A walk-in or outside patient. The shelf price less any discount, and the '
          'patient is required.',
    SaleType.ipdAdmission =>
      'A patient admitted in the hospital. The shelf price, billed to their '
          'admission account.',
    SaleType.package =>
      'The hospital buying for its own package patients. Priced at cost plus the '
          'configured markup, with the hospital\u2019s account as the debtor.',
    SaleType.transfer =>
      'Stock moving between locations: no patient, no payment and no GST.',
  };
}
