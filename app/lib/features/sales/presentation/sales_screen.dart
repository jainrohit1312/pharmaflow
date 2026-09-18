/// The sales list: what went out of the door today and before.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/features/customers/application/customer_options.dart';
import 'package:app/features/sales/application/sales_list_controller.dart';
import 'package:app/features/sales/presentation/widgets/sale_card.dart';
import 'package:app/features/sales/presentation/widgets/sale_filter_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Lists the pharmacy's sales, newest first, with the counter one tap away.
class SalesScreen extends ConsumerWidget {
  /// Creates the sales list screen.
  const SalesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(salesListControllerProvider);
    final isFiltered = ref.watch(salesFilterControllerProvider).isFiltered;
    // A failed customer read costs the cards their names, not the list its rows,
    // so it is read leniently here.
    final customers =
        ref.watch(customerOptionsProvider).value ?? const <Customer>[];
    final names = <String, String>{
      for (final customer in customers) customer.id: customer.name,
    };

    ref.listen<AsyncValue<SaleListPage>>(salesListControllerProvider, (
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
      title: 'Sales',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(Routes.pos),
        icon: const Icon(Icons.point_of_sale_outlined),
        label: const Text('New sale'),
      ),
      body: Column(
        children: <Widget>[
          const SaleFilterBar(),
          Expanded(
            child: _SalesBody(page: page, isFiltered: isFiltered, names: names),
          ),
        ],
      ),
    );
  }
}

/// Renders whichever of the list's states applies.
///
/// Deliberately not `AsyncValue.when`: while a filter change is in flight the
/// provider still holds the previous page, and keeping those rows on screen reads
/// far better than flashing a spinner over content that is still valid.
class _SalesBody extends ConsumerWidget {
  const _SalesBody({
    required this.page,
    required this.isFiltered,
    required this.names,
  });

  /// Current list state.
  final AsyncValue<SaleListPage> page;

  /// Whether any filter or search term is applied.
  final bool isFiltered;

  /// Customer names by id, for the cards.
  final Map<String, String> names;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (page.hasValue) {
      final value = page.value!;
      if (value.items.isEmpty) {
        return AppEmptyView(
          icon: isFiltered ? Icons.search_off : Icons.point_of_sale_outlined,
          title: 'No sales found',
          message: isFiltered
              ? 'Nothing matches the current search and filters.'
              : 'Ring up the first sale at the counter.',
          actionLabel: isFiltered ? null : 'New sale',
          actionIcon: Icons.point_of_sale_outlined,
          onAction: isFiltered ? null : () => context.go(Routes.pos),
        );
      }
      return _SaleList(page: value, names: names);
    }

    if (page.hasError) {
      return ErrorView(
        message: describeError(page.error!),
        onRetry: () => ref.invalidate(salesListControllerProvider),
      );
    }

    return const LoadingView(message: 'Loading sales…');
  }
}

/// The loaded rows, with a trailing control to fetch the next page.
class _SaleList extends ConsumerWidget {
  const _SaleList({required this.page, required this.names});

  /// The page currently loaded.
  final SaleListPage page;

  /// Customer names by id.
  final Map<String, String> names;

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
        final sale = page.items[index];
        return SaleCard(
          sale: sale,
          customerName: sale.customerId == null ? null : names[sale.customerId],
          onTap: () => context.go(Routes.saleDetail(sale.id)),
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
      await ref.read(salesListControllerProvider.notifier).loadMore();
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
