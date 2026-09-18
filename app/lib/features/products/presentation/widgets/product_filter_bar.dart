/// Search and filter controls for the product list.
library;

import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_search_field.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/products/application/products_list_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Schedules offered as filters, `null` meaning "no restriction".
const List<ScheduleType?> _scheduleOptions = <ScheduleType?>[
  null,
  ScheduleType.otc,
  ScheduleType.h,
  ScheduleType.h1,
  ScheduleType.x,
  ScheduleType.narcotic,
];

/// Availability options, `null` meaning "both".
const List<bool?> _activeOptions = <bool?>[null, true, false];

/// Drives [ProductsFilterController] from the list screen.
///
/// The controls mutate filter state and nothing else: the list provider watches
/// that state, so no control has to remember to trigger a reload.
class ProductFilterBar extends ConsumerWidget {
  /// Creates the filter bar.
  const ProductFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(productsFilterControllerProvider);
    final filters = ref.read(productsFilterControllerProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppSearchField(
            hint: 'Search name, generic or barcode',
            onChanged: filters.search,
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final option in _scheduleOptions) ...<Widget>[
                  ChoiceChip(
                    label: Text(option?.label ?? 'All schedules'),
                    selected: filter.scheduleType == option,
                    onSelected: (selected) => filters.scheduleType(option),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
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
