/// The counter's strip: Recent, the catalogue's own categories, and All.
///
/// The strip decides what the list under it shows while the search field is empty,
/// which is the counter's other half of the job: not "find this one thing" but
/// "show me what I am likely to sell". Recent comes first because re-selling what
/// was just sold is the commonest action at a counter, and the middle tabs come
/// from the catalogue rather than from a list written here (the owner's F3) - so a
/// pharmacy whose products carry no category sees Recent and All and nothing in
/// between, which is the honest state of the imported catalogue today.
///
/// A tab **is** a `PosListKey` with no term, so what the strip offers and what the
/// list reads are the same value rather than two descriptions of it that could
/// drift apart.
library;

import 'package:app/features/sales/application/pos_search.dart';
import 'package:flutter/material.dart';

/// The strip of tabs above the counter's list.
class PosStrip extends StatelessWidget {
  /// Creates the strip.
  const PosStrip({
    required this.choice,
    required this.categories,
    required this.onChanged,
    super.key,
  });

  /// The tab that is chosen, as the key for the list it shows.
  final PosListKey choice;

  /// The catalogue's categories, or an empty list while none is recorded.
  final List<String> categories;

  /// Called with the key of the tab that was tapped.
  final ValueChanged<PosListKey> onChanged;

  /// The Recent tab's key.
  static const PosListKey recent = PosListKey(recent: true);

  /// The All tab's key.
  static const PosListKey all = PosListKey();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        _Tab(
          label: 'Recent',
          value: recent,
          choice: choice,
          onChanged: onChanged,
        ),
        for (final category in categories)
          _Tab(
            label: category,
            // A category tab carries no term and is not Recent: the two are what
            // tell it apart from the Recent and All tabs even when it is named
            // after one of them.
            value: PosListKey(category: category),
            choice: choice,
            onChanged: onChanged,
          ),
        _Tab(label: 'All', value: all, choice: choice, onChanged: onChanged),
      ],
    );
  }
}

/// One tab, as a choice.
class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.value,
    required this.choice,
    required this.onChanged,
  });

  /// What the tab reads.
  final String label;

  /// What tapping it chooses.
  final PosListKey value;

  /// The tab that is chosen at the moment.
  final PosListKey choice;

  /// Called with [value] when the tab is tapped.
  final ValueChanged<PosListKey> onChanged;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: choice == value,
      onSelected: (_) => onChanged(value),
    );
  }
}
