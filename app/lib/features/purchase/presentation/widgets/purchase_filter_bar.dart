/// Search and filter controls for the purchase list.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_dropdown_field.dart';
import 'package:app/core/widgets/app_search_field.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/purchase/application/purchases_list_controller.dart';
import 'package:app/features/purchase/data/purchases_repository.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The statuses offered as chips, `null` first meaning "any status".
const List<PurchaseStatus?> _statusOptions = <PurchaseStatus?>[
  null,
  PurchaseStatus.draft,
  PurchaseStatus.ordered,
  PurchaseStatus.received,
  PurchaseStatus.cancelled,
];

/// Drives [PurchasesFilterController] from the list screen.
///
/// The controls mutate filter state and nothing else: the list provider watches
/// that state, so no control has to remember to trigger a reload.
class PurchaseFilterBar extends ConsumerWidget {
  /// Creates the filter bar.
  const PurchaseFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(purchasesFilterControllerProvider);
    final filters = ref.read(purchasesFilterControllerProvider.notifier);
    // A failed supplier read costs the dropdown its options, not the list its
    // rows, so it is read leniently here.
    final suppliers =
        ref.watch(supplierOptionsProvider).value ?? const <Supplier>[];
    final names = <String, String>{
      for (final supplier in suppliers) supplier.id: supplier.name,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppSearchField(
            hint: 'Search invoice number or notes',
            onChanged: filters.search,
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: AppDropdownField<String>(
                  label: 'Supplier',
                  hint: 'All suppliers',
                  prefixIcon: Icons.local_shipping_outlined,
                  value: filter.supplierId,
                  values: suppliers
                      .map((supplier) => supplier.id)
                      .toList(growable: false),
                  labelOf: (id) => names[id] ?? 'Unknown supplier',
                  allowNone: true,
                  onChanged: filters.supplier,
                ),
              ),
              const SizedBox(width: 8),
              AppButton.outlined(
                label: _dateLabel(filter),
                icon: Icons.date_range_outlined,
                expand: false,
                onPressed: () => _pickDateRange(context, filters, filter),
              ),
            ],
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

  /// Opens the invoice-date range picker and applies what was chosen.
  ///
  /// A cancelled picker changes nothing, and a picked range always has both
  /// ends, so the filter never holds a half-set window.
  Future<void> _pickDateRange(
    BuildContext context,
    PurchasesFilterController filters,
    PurchasesQuery filter,
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
String _statusLabel(PurchaseStatus? option) => option?.label ?? 'All';

/// The label for the date-range button.
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
