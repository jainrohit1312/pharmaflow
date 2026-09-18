/// Inventory: what is on hand, what is below its reorder level, what is expiring.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/app_search_field.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/features/inventory/application/expiry_batch.dart';
import 'package:app/features/inventory/application/expiry_dashboard_controller.dart';
import 'package:app/features/inventory/application/low_stock_controller.dart';
import 'package:app/features/inventory/application/stock_list_controller.dart';
import 'package:app/features/inventory/data/inventory_repository.dart';
import 'package:app/features/inventory/presentation/widgets/expiry_batch_card.dart';
import 'package:app/features/inventory/presentation/widgets/expiry_bucket_bar.dart';
import 'package:app/features/inventory/presentation/widgets/product_stock_card.dart';
import 'package:app/features/inventory/presentation/widgets/stock_adjustment_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The three inventory views, in one tabbed screen.
///
/// They are tabs rather than separate destinations because they are three
/// questions about the same rows - what is on hand, what is short, what is
/// expiring - and a pharmacist working an expiry list wants to be one tap from
/// the stock level of the product in front of them.
class InventoryScreen extends ConsumerWidget {
  /// Creates the inventory screen.
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
    length: 3,
    child: AppScaffold(
      title: 'Inventory',
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.calendar_month_outlined),
          tooltip: 'Expiry calendar',
          onPressed: () => context.go(Routes.inventoryCalendar),
        ),
      ],
      body: const Column(
        children: <Widget>[
          TabBar(
            tabs: <Widget>[
              Tab(text: 'Stock'),
              Tab(text: 'Low stock'),
              Tab(text: 'Expiry'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: <Widget>[_StockTab(), _LowStockTab(), _ExpiryTab()],
            ),
          ),
        ],
      ),
    ),
  );
}

/// The stock rollup, searchable and paged.
class _StockTab extends ConsumerWidget {
  const _StockTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(stockListControllerProvider);
    final filter = ref.watch(stockFilterControllerProvider);
    final filters = ref.read(stockFilterControllerProvider.notifier);

    ref.listen<AsyncValue<StockListPage>>(stockListControllerProvider, (
      previous,
      next,
    ) {
      final error = next.error;
      if (error == null || !context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    });

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            children: <Widget>[
              AppSearchField(
                hint: 'Search name, generic or brand',
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
                          for (final option in StockAvailability.values) ...[
                            ChoiceChip(
                              label: Text(_availabilityLabel(option)),
                              selected: filter.availability == option,
                              onSelected: (picked) =>
                                  filters.availability(option),
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
        ),
        Expanded(
          child: _StockBody(page: page, isFiltered: filter.isFiltered),
        ),
      ],
    );
  }
}

/// Renders whichever of the stock list's states applies.
///
/// Deliberately not `AsyncValue.when`: while a filter change is in flight the
/// provider still holds the previous page, and keeping those rows on screen reads
/// far better than flashing a spinner over content that is still valid.
class _StockBody extends ConsumerWidget {
  const _StockBody({required this.page, required this.isFiltered});

  /// Current list state.
  final AsyncValue<StockListPage> page;

  /// Whether any filter or search term is applied.
  final bool isFiltered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (page.hasValue) {
      final value = page.value!;
      if (value.items.isEmpty) {
        if (isFiltered) {
          return AppEmptyView(
            icon: Icons.search_off,
            title: 'Nothing to show',
            message: 'No product matches the current search and filter.',
            actionLabel: 'Clear filters',
            actionIcon: Icons.filter_alt_off_outlined,
            onAction: ref.read(stockFilterControllerProvider.notifier).clear,
          );
        }
        return const AppEmptyView(
          icon: Icons.inventory_2_outlined,
          title: 'No stock yet',
          message:
              'Stock appears here once goods are received against a purchase. '
              'Every product in the catalogue is listed, with 0 on hand until '
              'then.',
        );
      }
      return _StockList(page: value);
    }

    if (page.hasError) {
      return ErrorView(
        message: describeError(page.error!),
        onRetry: () => ref.invalidate(stockListControllerProvider),
      );
    }

    return const LoadingView(message: 'Loading stock…');
  }
}

/// The loaded stock rows, with a trailing control to fetch the next page.
class _StockList extends ConsumerWidget {
  const _StockList({required this.page});

  /// The page currently loaded.
  final StockListPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoadingMore = page.isLoadingMore;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: page.items.length + (page.hasMore ? 1 : 0),
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index >= page.items.length) {
          return Center(
            child: AppButton.outlined(
              label: isLoadingMore ? 'Loading…' : 'Load more',
              icon: Icons.expand_more,
              expand: false,
              isLoading: isLoadingMore,
              onPressed: isLoadingMore ? null : () => _loadMore(context, ref),
            ),
          );
        }
        final stock = page.items[index];
        return ProductStockCard(
          stock: stock,
          onTap: () => context.go(Routes.productDetail(stock.productId)),
        );
      },
    );
  }

  /// Fetches the next page, reporting a failure without clearing the list.
  ///
  /// The controller restores the previous page and rethrows, so the failure has
  /// to be reported here rather than through `ref.listen` on the provider.
  Future<void> _loadMore(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(stockListControllerProvider.notifier).loadMore();
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

/// Products below the reorder level they are meant to keep.
class _LowStockTab extends ConsumerWidget {
  const _LowStockTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(lowStockListProvider);

    if (rows.hasValue) {
      final items = rows.value!;
      if (items.isEmpty) {
        return const AppEmptyView(
          icon: Icons.check_circle_outline,
          title: 'Nothing is below its level',
          message:
              'Set a reorder level on a product and it appears here as soon as '
              'stock falls under it.',
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final stock = items[index];
          return ProductStockCard(
            stock: stock,
            onTap: () => context.go(Routes.productDetail(stock.productId)),
          );
        },
      );
    }

    if (rows.hasError) {
      return ErrorView(
        message: describeError(rows.error!),
        onRetry: () => ref.invalidate(lowStockListProvider),
      );
    }

    return const LoadingView(message: 'Loading the reorder list…');
  }
}

/// Batches that are expired or expiring within 30 or 90 days.
class _ExpiryTab extends ConsumerWidget {
  const _ExpiryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(expiryBoardControllerProvider);

    if (board.hasValue) {
      final value = board.value!;
      return Column(
        children: <Widget>[
          ExpiryBucketBar(batchCounts: value.batchCounts),
          Expanded(
            child: value.rows.isEmpty
                // The bar above names the window, so this copy does not repeat
                // it - it is the same sentence for all three buckets.
                ? const AppEmptyView(
                    icon: Icons.event_available_outlined,
                    title: 'Nothing in this bucket',
                    message: 'No batch holding stock falls in this bucket.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: value.rows.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final entry = value.rows[index];
                      return ExpiryBatchCard(
                        entry: entry,
                        onTap: () => context.go(
                          Routes.productDetail(entry.batch.productId),
                        ),
                        onAdjust: () => _adjust(context, ref, entry),
                      );
                    },
                  ),
          ),
        ],
      );
    }

    if (board.hasError) {
      return ErrorView(
        message: describeError(board.error!),
        onRetry: () => ref.invalidate(expiryBoardControllerProvider),
      );
    }

    return const LoadingView(message: 'Loading expiry…');
  }

  /// Opens the correction sheet for one batch, and confirms the write.
  Future<void> _adjust(
    BuildContext context,
    WidgetRef ref,
    ExpiryBatch entry,
  ) async {
    final written = await showStockAdjustmentSheet(
      context,
      productId: entry.batch.productId,
      productName: entry.productName,
      batchId: entry.batch.id,
      batchNo: entry.batch.batchNo,
      onHand: entry.qty,
    );
    if (!written || !context.mounted) {
      return;
    }
    // The controller has already invalidated the board, so the row's quantity is
    // being refetched; this only confirms the row was written.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Stock adjusted.')));
  }
}

/// The label for an availability chip.
String _availabilityLabel(StockAvailability option) => switch (option) {
  StockAvailability.all => 'All',
  StockAvailability.inStock => 'In stock',
  StockAvailability.outOfStock => 'Out of stock',
};
