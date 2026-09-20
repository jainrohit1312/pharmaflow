/// The counter's search dropdown: the top few products, and what Enter would add.
///
/// Each row shows the batch FEFO would take, its expiry, what is left in it and its
/// MRP, so pressing Enter is an informed choice rather than a blind one - the whole
/// point of the dropdown replacing an interrupting chooser for the common case. A
/// row that holds no stock is shown but not addable, because "we don't have it" is
/// a different answer from "no such product" and the counter needs to tell them
/// apart.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/sales/application/pos_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the counter is showing, and the rows for it.
class PosSearchResults extends ConsumerWidget {
  /// Creates the dropdown.
  const PosSearchResults({
    required this.listKey,
    required this.highlighted,
    required this.onAdd,
    required this.onChooseBatch,
    super.key,
  });

  /// Which list to show: the search, Recent, a category or All.
  final PosListKey listKey;

  /// Which row Enter would add, as an index into the results.
  final int highlighted;

  /// Called with the product a row was tapped for.
  final ValueChanged<PosSearchHit> onAdd;

  /// Called when the row's affordance asks for a different batch.
  final ValueChanged<Product> onChooseBatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(posListProvider(listKey));
    final theme = Theme.of(context);

    return results.when(
      data: (hits) => hits.isEmpty
          ? Text(
              // An empty term is the counter opening on an empty list, which is not
              // a failed search - "no product matches" would blame a term nobody
              // typed.
              listKey.term.isEmpty
                  ? _emptyMessage(listKey)
                  : 'No product matches "${listKey.term}".',
              style: theme.textTheme.bodySmall,
            )
          : _List(
              hits: hits,
              highlighted: highlighted,
              onAdd: onAdd,
              onChooseBatch: onChooseBatch,
            ),
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      ),
      error: (error, _) =>
          Text(describeError(error), style: theme.textTheme.bodySmall),
    );
  }

  /// What an empty list says, which depends on why it is empty.
  static String _emptyMessage(PosListKey key) {
    if (key.recent) {
      return 'Nothing sold yet. Search by name, or pick All or a category.';
    }
    if (key.category != null) {
      return 'Nothing in "${key.category}".';
    }
    return 'Nothing in the catalogue to sell yet.';
  }
}

/// The rows themselves.
class _List extends StatelessWidget {
  const _List({
    required this.hits,
    required this.highlighted,
    required this.onAdd,
    required this.onChooseBatch,
  });

  /// The products to offer.
  final List<PosSearchHit> hits;

  /// Which row Enter would add.
  final int highlighted;

  /// Called with the product a row was tapped for.
  final ValueChanged<PosSearchHit> onAdd;

  /// Called when a row asks for a different batch.
  final ValueChanged<Product> onChooseBatch;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          for (var index = 0; index < hits.length; index++)
            _Row(
              hit: hits[index],
              isHighlighted: index == highlighted,
              onAdd: () => onAdd(hits[index]),
              onChooseBatch: () => onChooseBatch(hits[index].product),
            ),
        ],
      ),
    );
  }
}

/// One product, with what pressing Enter would do to it.
class _Row extends StatelessWidget {
  const _Row({
    required this.hit,
    required this.isHighlighted,
    required this.onAdd,
    required this.onChooseBatch,
  });

  /// The product and its batches.
  final PosSearchHit hit;

  /// Whether this is the row Enter would add.
  final bool isHighlighted;

  /// Called when the row itself is tapped.
  final VoidCallback onAdd;

  /// Called when the row's affordance asks for a different batch.
  final VoidCallback onChooseBatch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dispensable = hit.dispensable;
    // A row with nothing to dispense is offered but not addable: the counter still
    // learns the product exists, and Enter on it says so rather than silently doing
    // nothing.
    final addable = dispensable != null;

    return Material(
      color: isHighlighted
          ? theme.colorScheme.primaryContainer
          : Colors.transparent,
      child: InkWell(
        onTap: addable ? onAdd : null,
        child: ConstrainedBox(
          // The counter's own floor: a row is at least a fingertip high, which is
          // what makes this tappable on a phone as well as on a keyboard.
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          hit.product.name,
                          style: theme.textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _detail(hit),
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
                // The one gesture that keeps the chooser reachable without
                // interrupting the default case: Enter takes the FEFO batch, and
                // this asks for a different one.
                IconButton(
                  icon: const Icon(Icons.swap_horiz),
                  tooltip: 'Choose batch',
                  // Material's default is 40; a thumb wants a fingertip.
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  onPressed: onChooseBatch,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// What the row says about the batch Enter would add.
  ///
  /// Stock, MRP, batch and expiry, in the order the counter reads them off the
  /// keyboard: which batch, when it expires, how much of it there is, and what it
  /// costs.
  static String _detail(PosSearchHit hit) {
    final batch = hit.dispensable;
    if (batch == null) {
      return 'Nothing in stock';
    }
    // The date itself, not the view's bucket: a null expiry folds to the 'safe'
    // badge, and "Safe" beside "expiry unknown" would be a claim about a date that
    // does not exist.
    final expiry = batch.hasKnownExpiry
        ? 'exp ${Formatters.monthYearShort(batch.expiryDate!)}'
        : 'expiry unknown';
    return <String>[
      'Batch ${batch.batchNo}',
      expiry,
      '${hit.stock} in stock',
      'MRP ${Formatters.currency(batch.mrp)}',
    ].join(' · ');
  }
}
