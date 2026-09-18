/// Search and filter controls for the sales list.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_search_field.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/features/sales/application/sales_list_controller.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The statuses offered as chips, `null` first meaning "any status".
const List<SaleStatus?> _statusOptions = <SaleStatus?>[
  null,
  SaleStatus.completed,
  SaleStatus.credit,
  SaleStatus.cancelled,
];

/// Drives [SalesFilterController] from the list screen.
///
/// The controls mutate filter state and nothing else: the list provider watches
/// that state, so no control has to remember to trigger a reload. The same shape
/// as the purchase list's bar, deliberately.
class SaleFilterBar extends ConsumerWidget {
  /// Creates the filter bar.
  const SaleFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(salesFilterControllerProvider);
    final filters = ref.read(salesFilterControllerProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppSearchField(
            hint: 'Search invoice number',
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
                      for (final option in _statusOptions) ...<Widget>[
                        ChoiceChip(
                          label: Text(_statusLabel(option)),
                          selected: filter.status == option,
                          onSelected: (selected) => filters.status(option),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
              ),
              AppButton.text(
                label: _dateLabel(filter),
                icon: Icons.date_range_outlined,
                expand: false,
                onPressed: () => _pickDateRange(context, filters, filter),
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

  /// Opens the sale-date range picker and applies what was chosen.
  ///
  /// A cancelled picker changes nothing, and a picked range always has both ends,
  /// so the filter never holds a half-set window.
  Future<void> _pickDateRange(
    BuildContext context,
    SalesFilterController filters,
    SalesQuery filter,
  ) async {
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
    if (picked == null) {
      return;
    }
    filters.dateRange(from: picked.start, to: picked.end);
  }
}

/// The label for a status chip.
String _statusLabel(SaleStatus? option) => option?.label ?? 'All';

/// The label for the date-range button.
String _dateLabel(SalesQuery filter) {
  final from = filter.from;
  final to = filter.to;
  if (from == null && to == null) {
    return 'All dates';
  }
  final start = from == null ? 'Start' : Formatters.dateDdMmmYyyy(from);
  final end = to == null ? 'Today' : Formatters.dateDdMmmYyyy(to);
  return '$start – $end';
}
