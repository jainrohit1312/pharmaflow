/// One label and figure in an account card.
library;

import 'package:flutter/material.dart';

/// A label and a money figure on one line, as every account card prints them.
///
/// Public rather than private to one card because all three balance views show the same
/// four or five figures (`charges`, returns, applied, outstanding) and a per-widget copy
/// would let two of them drift into printing the same figure differently.
class AccountFigure extends StatelessWidget {
  /// Creates a figure.
  const AccountFigure({
    required this.label,
    required this.value,
    this.tone,
    this.emphasis,
    super.key,
  });

  /// What the figure is.
  final String label;

  /// The figure, already formatted.
  final String value;

  /// The colour to print it in, when it carries a meaning the label does not.
  ///
  /// Used for a figure the operator has to act on - money owed, or money the pharmacy
  /// is holding - rather than for decoration.
  final Color? tone;

  /// Style for the amount, for the headline figure.
  final TextStyle? emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            value,
            style:
                emphasis ?? theme.textTheme.bodyMedium?.copyWith(color: tone),
          ),
        ],
      ),
    );
  }
}
