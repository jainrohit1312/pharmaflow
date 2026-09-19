/// A field that opens a purchase search and reports what was chosen.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/utils/debouncer.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_search_field.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/purchase/application/purchase_picker_controller.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A tappable field that shows the chosen purchase, or a prompt to choose one.
///
/// A dialog rather than a dropdown, for the reason the product picker is: a
/// pharmacy accumulates invoices without limit, and a dropdown over them is a
/// scroll bar with a text field bolted on — the list screen's own bound of 200
/// (I-3) was exactly where that stopped working. Search is the interaction that
/// finds the invoice.
///
/// The field **carries its own label** rather than deriving it from a list it
/// holds: the old dropdown could only name the purchase it was showing while that
/// purchase was in the page it had loaded, which is why it had a branch that said
/// "Another purchase" about a document the user had just picked. Nothing here
/// depends on the results being on screen.
class PurchasePickerField extends StatelessWidget {
  /// Creates a purchase picker.
  const PurchasePickerField({
    required this.onSelected,
    super.key,
    this.selected,
    this.selectedSupplierName,
    this.enabled = true,
    this.label = 'Purchase',
    this.isRequired = true,
  });

  /// Called with the purchase the user picked.
  final ValueChanged<Purchase> onSelected;

  /// The purchase already chosen, if any.
  final Purchase? selected;

  /// Who [selected] came from, when the name is known.
  ///
  /// Optional because it is resolved separately (`supplierOptionsProvider`), and a
  /// missing name is a thinner label rather than a reason to fail the form — the
  /// same trade `PurchaseCard` makes.
  final String? selectedSupplierName;

  /// Whether the field accepts taps.
  final bool enabled;

  /// Label shown above the value.
  final String label;

  /// Whether an empty state is an error worth marking.
  final bool isRequired;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final purchase = selected;

    return InkWell(
      onTap: enabled ? () => _pick(context) : null,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.receipt_long_outlined),
          suffixIcon: const Icon(Icons.search),
          errorText: isRequired && purchase == null
              ? 'Choose a purchase'
              : null,
        ),
        child: Text(
          purchase == null
              ? 'Search received invoices'
              : purchaseLabel(purchase, selectedSupplierName),
          style: purchase == null
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
    final purchase = await showDialog<Purchase>(
      context: context,
      builder: (dialogContext) => const _PurchaseSearchDialog(),
    );
    if (purchase != null) {
      onSelected(purchase);
    }
  }
}

/// How a purchase is named once it is chosen.
///
/// Shared by the closed field and the rows the user chooses from, so the thing
/// they tapped and the thing the field then shows cannot drift apart. The
/// supplier is appended only when its name is known: the id is not a name, and a
/// label that shows one would be noise.
String purchaseLabel(Purchase purchase, String? supplierName) {
  final name = supplierName?.trim();
  return <String>[
    '${purchase.invoiceNo} · ${Formatters.dateDdMmmYyyy(purchase.invoiceDate)}',
    if (name != null && name.isNotEmpty) name,
  ].join(' · ');
}

/// The search sheet behind [PurchasePickerField].
class _PurchaseSearchDialog extends ConsumerStatefulWidget {
  const _PurchaseSearchDialog();

  @override
  ConsumerState<_PurchaseSearchDialog> createState() =>
      _PurchaseSearchDialogState();
}

class _PurchaseSearchDialogState extends ConsumerState<_PurchaseSearchDialog> {
  final _debounce = Debouncer();
  String _term = '';

  /// Why the last "Load more" failed, and not the search: appending a page is a
  /// different action from searching, so it is a different sentence in a
  /// different place (the search's own failure is the provider's).
  String? _loadMoreError;

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
        setState(() {
          _term = trimmed;
          _loadMoreError = null;
        });
        ref
            .read(purchasePickerFilterControllerProvider.notifier)
            .search(trimmed);
      }
    });
  }

  /// Opens the invoice-date range picker and applies what was chosen.
  ///
  /// A cancelled picker changes nothing, and a picked range always has both ends,
  /// so the window is never half-set — the same rule the list screen's filter bar
  /// follows.
  Future<void> _pickDateRange(PurchasesQuery filter) async {
    final now = DateTime.now();
    final from = filter.from;
    final to = filter.to;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: from == null || to == null
          ? null
          : DateTimeRange(start: from, end: to),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() => _loadMoreError = null);
    ref
        .read(purchasePickerFilterControllerProvider.notifier)
        .dateRange(from: picked.start, to: picked.end);
  }

  /// Asks for the next page, keeping the failure here if it fails.
  Future<void> _loadMore() async {
    try {
      await ref.read(purchasePickerControllerProvider.notifier).loadMore();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _loadMoreError = describeError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(purchasePickerFilterControllerProvider);
    final results = ref.watch(purchasePickerControllerProvider);
    final names = <String, String>{
      for (final supplier
          in ref.watch(supplierOptionsProvider).value ?? const <Supplier>[])
        supplier.id: supplier.name,
    };

    return AlertDialog(
      title: const Text('Find a received invoice'),
      content: SizedBox(
        width: 460,
        height: 480,
        child: Column(
          children: <Widget>[
            AppSearchField(
              hint: 'Invoice number, note or supplier',
              onChanged: _search,
            ),
            Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: () => _pickDateRange(filter),
                  icon: const Icon(Icons.date_range_outlined, size: 18),
                  label: Text(_dateLabel(filter)),
                ),
                if (filter.from != null || filter.to != null)
                  TextButton(
                    onPressed: () => ref
                        .read(purchasePickerFilterControllerProvider.notifier)
                        .dateRange(),
                    child: const Text('Any date'),
                  ),
              ],
            ),
            Expanded(child: _body(results, filter, names)),
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

  /// The four states a search can be in, told apart (T-5).
  Widget _body(
    AsyncValue<PurchasePickerPage> results,
    PurchasesQuery filter,
    Map<String, String> supplierNames,
  ) {
    final theme = Theme.of(context);

    if (results.hasError) {
      return _centred(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Could not search the invoices.',
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              describeError(results.error!),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => ref.invalidate(purchasePickerControllerProvider),
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }

    if (results.hasValue) {
      final page = results.value!;
      if (page.items.isEmpty) {
        // "Nothing matched" and "nothing is there to match" are different
        // situations, and only one of them is something the user did. The test is
        // what the *user* asked for, not `isFiltered`: this picker is scoped to
        // received invoices from the moment it opens, so the coarser question
        // would answer "nothing matched" to somebody who typed nothing.
        return _centred(
          Text(
            filter.hasSearch
                ? 'No invoice matches this search.'
                : 'No received purchases yet. Receive one before returning goods.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        );
      }

      return ListView.builder(
        itemCount: page.items.length + 1,
        itemBuilder: (context, index) {
          if (index == page.items.length) {
            return _tail(page);
          }
          final purchase = page.items[index];
          final name = supplierNames[purchase.supplierId];
          return ListTile(
            title: Text(
              '${purchase.invoiceNo} · '
              '${Formatters.dateDdMmmYyyy(purchase.invoiceDate)}',
            ),
            subtitle: name == null || name.trim().isEmpty ? null : Text(name),
            onTap: () => Navigator.of(context).pop(purchase),
          );
        },
      );
    }

    return _centred(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text('Searching…', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  /// What sits under the last row: the next page, or why it did not arrive.
  Widget _tail(PurchasePickerPage page) {
    final error = _loadMoreError;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: <Widget>[
            Text(error, style: Theme.of(context).textTheme.bodySmall),
            TextButton(onPressed: _loadMore, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (!page.hasMore) {
      return const SizedBox.shrink();
    }
    return ListTile(
      onTap: page.isLoadingMore ? null : _loadMore,
      title: Center(
        child: page.isLoadingMore
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Load more'),
      ),
    );
  }

  /// One centred block, so the dialog's height does not jump between states.
  Widget _centred(Widget child) => Center(child: child);
}

/// The window the date button shows.
///
/// The same wording as the list screen's filter bar, so the two date controls in
/// the app read alike. A half-set window cannot happen — a picked range always has
/// both ends — but the two halves are still named separately, because the branch
/// that would read `null` is the one a careless change introduces.
String _dateLabel(PurchasesQuery filter) {
  final from = filter.from;
  final to = filter.to;
  if (from == null && to == null) {
    return 'All dates';
  }
  final start = from == null ? 'Start' : Formatters.dateDdMmmYyyy(from);
  final end = to == null ? 'Today' : Formatters.dateDdMmmYyyy(to);
  return '$start – $end';
}
