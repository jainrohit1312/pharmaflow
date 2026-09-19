/// A field that opens a product search and reports what was chosen.
library;

import 'package:app/core/utils/debouncer.dart';
import 'package:app/core/widgets/app_search_field.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_match.dart';
import 'package:app/features/products/application/product_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A tappable field that shows the chosen product, or a prompt to choose one.
///
/// A dialog rather than a dropdown: a catalogue can run to thousands of products,
/// and a dropdown over that is a scroll bar with a text field bolted on. Search
/// is the interaction that actually finds the product.
///
/// The field is also where the matcher's suggestions are offered, because that is
/// what they are about — this line's product — and a screen that has nothing to
/// suggest renders exactly what it rendered before they existed. **A suggestion
/// is offered, never applied:** nothing changes until one is tapped, because a
/// wrong auto-fill on a received invoice is a stock error rather than a typo.
class ProductPickerField extends StatelessWidget {
  /// Creates a product picker.
  const ProductPickerField({
    required this.onSelected,
    super.key,
    this.selected,
    this.selectedName,
    this.enabled = true,
    this.label = 'Product',
    this.isRequired = true,
    this.suggestions = const <MatchCandidate>[],
    this.onSuggestionSelected,
  });

  /// Called with the product the user picked.
  final ValueChanged<Product> onSelected;

  /// The product already on this line, if any.
  final Product? selected;

  /// The name to show when there is no [selected] to show.
  ///
  /// An existing document stores a line's product id and a displayed name, not
  /// the catalogue row itself, so a form seeded from one has a name without a
  /// product. Without this the field would claim the line has no product and
  /// mark it as an error.
  final String? selectedName;

  /// Whether the field accepts taps.
  final bool enabled;

  /// Label shown above the value.
  final String label;

  /// Whether an empty state is an error worth marking.
  final bool isRequired;

  /// Candidates to offer for this line, best first.
  ///
  /// The caller decides *whether* to offer them — a line that already has a
  /// product does not need advice about which product it is — and this widget
  /// decides how they read.
  final List<MatchCandidate> suggestions;

  /// Called when the user accepts a suggestion.
  ///
  /// Separate from [onSelected] because a suggestion is not a [Product]: the
  /// matcher answers with a product id, its catalogue name and the reason it is
  /// being offered, and loading the whole catalogue row just to throw the rest
  /// away would be a round trip per tap. When this is `null` no suggestions are
  /// rendered at all, which is what the manual purchase form gets.
  final ValueChanged<MatchCandidate>? onSuggestionSelected;

  /// How many suggestions are shown.
  ///
  /// The matcher returns at most five, but a twenty-line bill would then carry a
  /// hundred rows of advice across the busiest screen in the flow. Three is the
  /// ranked head, and the search dialog is one tap away for anything past it.
  static const int maxSuggestions = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rawName = selected?.name ?? selectedName;
    // Blank counts as absent: a document whose product name was never recorded
    // is as unset as one with no product at all.
    final name = rawName != null && rawName.trim().isNotEmpty ? rawName : null;
    final onSuggestion = onSuggestionSelected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        InkWell(
          onTap: enabled ? () => _pick(context) : null,
          borderRadius: BorderRadius.circular(12),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: const Icon(Icons.medication_outlined),
              suffixIcon: const Icon(Icons.search),
              errorText: isRequired && name == null ? 'Choose a product' : null,
            ),
            child: Text(
              name ?? 'Search the catalogue',
              style: name == null
                  ? theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )
                  : theme.textTheme.bodyLarge,
            ),
          ),
        ),
        if (enabled && onSuggestion != null && suggestions.isNotEmpty)
          _Suggestions(suggestions: suggestions, onSelected: onSuggestion),
      ],
    );
  }

  /// Opens the search dialog and reports the choice.
  Future<void> _pick(BuildContext context) async {
    final product = await showDialog<Product>(
      context: context,
      builder: (dialogContext) => const _ProductSearchDialog(),
    );
    if (product != null) {
      onSelected(product);
    }
  }
}

/// The candidates the matcher offered, under the field they are about.
///
/// Each row says the product and **why** it is being offered, because a
/// suggestion nobody can check is a suggestion that gets ignored: an alias is a
/// mapping a human confirmed here once, a trigram hit is a spelling similarity
/// with a number attached, and a vector hit is a model's opinion. The reason
/// itself is [MatchCandidate.reasonLabel]'s, so it is asserted in a unit test
/// rather than only by eye.
class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.suggestions, required this.onSelected});

  final List<MatchCandidate> suggestions;
  final ValueChanged<MatchCandidate> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = suggestions
        .take(ProductPickerField.maxSuggestions)
        .toList(growable: false);

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
              child: Text(
                'In your catalogue — tap to use',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final candidate in shown)
              InkWell(
                onTap: () => onSelected(candidate),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.add_circle_outline,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              _label(candidate),
                              style: theme.textTheme.bodyMedium,
                            ),
                            Text(
                              candidate.reasonLabel,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  /// The candidate's name, with its pack size when it has one.
  ///
  /// A pharmacy tells two strengths of one brand apart by the pack more often
  /// than by the name, so a candidate offered without it is a candidate the user
  /// has to open the dialog to check.
  static String _label(MatchCandidate candidate) {
    final pack = candidate.packSize;
    return pack == null || pack.trim().isEmpty
        ? candidate.name
        : '${candidate.name} · $pack';
  }
}

/// The search sheet behind [ProductPickerField].
class _ProductSearchDialog extends ConsumerStatefulWidget {
  const _ProductSearchDialog();

  @override
  ConsumerState<_ProductSearchDialog> createState() =>
      _ProductSearchDialogState();
}

class _ProductSearchDialogState extends ConsumerState<_ProductSearchDialog> {
  final _debounce = Debouncer();
  String _term = '';

  @override
  void dispose() {
    _debounce.dispose();
    super.dispose();
  }

  /// Applies a term once the user stops typing.
  void _search(String value) {
    final trimmed = value.trim();
    if (trimmed == _term) {
      return;
    }
    _debounce.run(() {
      if (mounted) {
        setState(() => _term = trimmed);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(productSearchProvider(_term));
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Find a product'),
      content: SizedBox(
        width: 440,
        height: 440,
        child: Column(
          children: <Widget>[
            AppSearchField(
              hint: 'Name, generic name or barcode',
              onChanged: _search,
            ),
            const SizedBox(height: 12),
            Expanded(child: _results(results, theme)),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  /// The result list, keeping the previous rows visible while a new term loads.
  Widget _results(AsyncValue<List<Product>> results, ThemeData theme) {
    if (results.hasValue) {
      final products = results.value!;
      if (products.isEmpty) {
        return Center(
          child: Text(
            'No product matches "$_term".',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        );
      }
      return ListView.builder(
        itemCount: products.length,
        itemBuilder: (context, index) {
          final product = products[index];
          final subtitle = <String>[
            if (product.genericName != null) product.genericName!,
            if (product.packSize != null) product.packSize!,
          ].join(' · ');

          return ListTile(
            title: Text(product.name),
            subtitle: subtitle.isEmpty ? null : Text(subtitle),
            onTap: () => Navigator.of(context).pop(product),
          );
        },
      );
    }

    if (results.hasError) {
      return Center(
        child: Text(
          'Could not search the catalogue.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }
}
