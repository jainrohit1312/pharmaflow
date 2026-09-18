/// A field that opens a product search and reports what was chosen.
library;

import 'package:app/core/utils/debouncer.dart';
import 'package:app/core/widgets/app_search_field.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/products/application/product_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A tappable field that shows the chosen product, or a prompt to choose one.
///
/// A dialog rather than a dropdown: a catalogue can run to thousands of products,
/// and a dropdown over that is a scroll bar with a text field bolted on. Search
/// is the interaction that actually finds the product.
class ProductPickerField extends StatelessWidget {
  /// Creates a product picker.
  const ProductPickerField({
    required this.onSelected,
    super.key,
    this.selected,
    this.enabled = true,
    this.label = 'Product',
    this.isRequired = true,
  });

  /// Called with the product the user picked.
  final ValueChanged<Product> onSelected;

  /// The product already on this line, if any.
  final Product? selected;

  /// Whether the field accepts taps.
  final bool enabled;

  /// Label shown above the value.
  final String label;

  /// Whether an empty state is an error worth marking.
  final bool isRequired;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final product = selected;

    return InkWell(
      onTap: enabled ? () => _pick(context) : null,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.medication_outlined),
          suffixIcon: const Icon(Icons.search),
          errorText: isRequired && product == null ? 'Choose a product' : null,
        ),
        child: Text(
          product == null ? 'Search the catalogue' : product.name,
          style: product == null
              ? theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )
              : theme.textTheme.bodyLarge,
        ),
      ),
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
