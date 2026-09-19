/// Purchase document list screen.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/purchase/application/purchases_list_controller.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_card.dart';
import 'package:app/features/purchase/presentation/widgets/purchase_filter_bar.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Lists the pharmacy's purchase documents, with search, filters and paging.
class PurchasesScreen extends ConsumerWidget {
  /// Creates the purchase list screen.
  const PurchasesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(purchasesListControllerProvider);
    final isFiltered = ref.watch(purchasesFilterControllerProvider).isFiltered;
    final names = <String, String>{
      for (final supplier
          in ref.watch(supplierOptionsProvider).value ?? const <Supplier>[])
        supplier.id: supplier.name,
    };

    ref.listen<AsyncValue<PurchaseListPage>>(purchasesListControllerProvider, (
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

    return AppScaffold(
      title: 'Purchase',
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.document_scanner_outlined),
          tooltip: 'Read a bill',
          onPressed: () => context.go(Routes.purchaseOcr),
        ),
        IconButton(
          icon: const Icon(Icons.inventory_2_outlined),
          tooltip: 'Receive goods',
          onPressed: () => context.go(Routes.purchaseGrnForm),
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(Routes.purchaseForm),
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
      body: Column(
        children: <Widget>[
          const PurchaseFilterBar(),
          Expanded(
            child: _PurchasesBody(
              page: page,
              isFiltered: isFiltered,
              supplierNames: names,
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders whichever of the list's states applies.
///
/// Deliberately not `AsyncValue.when`: while a filter change is in flight the
/// provider still holds the previous page, and keeping those rows on screen
/// reads far better than flashing a spinner over content that is still valid.
class _PurchasesBody extends ConsumerWidget {
  const _PurchasesBody({
    required this.page,
    required this.isFiltered,
    required this.supplierNames,
  });

  /// Current list state.
  final AsyncValue<PurchaseListPage> page;

  /// Whether any filter or search term is applied.
  final bool isFiltered;

  /// Supplier names keyed by id, for the cards.
  final Map<String, String> supplierNames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (page.hasValue) {
      final value = page.value!;
      if (value.items.isEmpty) {
        return AppEmptyView(
          icon: isFiltered ? Icons.search_off : Icons.receipt_long_outlined,
          title: 'No purchases found',
          message: isFiltered
              ? 'Nothing matches the current search and filters.'
              : 'Record a purchase to start tracking stock and what you owe '
                    'your suppliers.',
          actionLabel: isFiltered ? null : 'New purchase',
          onAction: isFiltered ? null : () => context.go(Routes.purchaseForm),
        );
      }
      return _PurchaseList(page: value, supplierNames: supplierNames);
    }

    if (page.hasError) {
      return ErrorView(
        message: describeError(page.error!),
        onRetry: () => ref.invalidate(purchasesListControllerProvider),
      );
    }

    return const LoadingView(message: 'Loading purchases…');
  }
}

/// The loaded rows, with a trailing control to fetch the next page.
class _PurchaseList extends ConsumerWidget {
  const _PurchaseList({required this.page, required this.supplierNames});

  /// The page currently loaded.
  final PurchaseListPage page;

  /// Supplier names keyed by id, for the cards.
  final Map<String, String> supplierNames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoadingMore = page.isLoadingMore;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
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
        final purchase = page.items[index];
        return PurchaseCard(
          purchase: purchase,
          supplierName: supplierNames[purchase.supplierId],
          onTap: () => context.go(Routes.purchaseDetail(purchase.id)),
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
      await ref.read(purchasesListControllerProvider.notifier).loadMore();
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
