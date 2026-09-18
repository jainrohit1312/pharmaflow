/// Search and filter controls for the customer list.
library;

import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_search_field.dart';
import 'package:app/features/customers/application/customers_list_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Availability options, `null` meaning "both".
const List<bool?> _activeOptions = <bool?>[null, true, false];

/// Drives [CustomersFilterController] from the list screen.
///
/// The controls mutate filter state and nothing else: the list provider watches
/// that state, so no control has to remember to trigger a reload.
class CustomerFilterBar extends ConsumerWidget {
  /// Creates the filter bar.
  const CustomerFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(customersFilterControllerProvider);
    final filters = ref.read(customersFilterControllerProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppSearchField(
            hint: 'Search name, phone or GSTIN',
            onChanged: filters.search,
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      for (final option in _activeOptions) ...<Widget>[
                        ChoiceChip(
                          label: Text(_activeLabel(option)),
                          selected: filter.isActive == option,
                          onSelected: (selected) =>
                              filters.activeFilter(value: option),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
              ),
              if (filter.isFiltered)
                AppButton.text(
                  label: 'Clear',
                  icon: Icons.filter_alt_off_outlined,
                  expand: false,
                  onPressed: filters.clear,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Label for an availability option.
String _activeLabel(bool? option) => switch (option) {
  null => 'All',
  true => 'Active',
  false => 'Inactive',
};
