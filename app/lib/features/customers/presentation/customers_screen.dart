/// Customer master list screen.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/features/customers/application/customers_list_controller.dart';
import 'package:app/features/customers/presentation/widgets/customer_card.dart';
import 'package:app/features/customers/presentation/widgets/customer_filter_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Lists the pharmacy's customers, with search, filters and paging.
class CustomersScreen extends ConsumerWidget {
  /// Creates the customer list screen.
  const CustomersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(customersListControllerProvider);
    final isFiltered = ref.watch(customersFilterControllerProvider).isFiltered;

    ref.listen<AsyncValue<CustomerListPage>>(customersListControllerProvider, (
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
      title: 'Customers',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(Routes.customerForm),
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
      body: Column(
        children: <Widget>[
          const CustomerFilterBar(),
          Expanded(
            child: _CustomersBody(page: page, isFiltered: isFiltered),
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
class _CustomersBody extends ConsumerWidget {
  const _CustomersBody({required this.page, required this.isFiltered});

  /// Current list state.
  final AsyncValue<CustomerListPage> page;

  /// Whether any filter or search term is applied.
  final bool isFiltered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (page.hasValue) {
      final value = page.value!;
      if (value.items.isEmpty) {
        return AppEmptyView(
          icon: isFiltered ? Icons.search_off : Icons.people_outline,
          title: 'No customers found',
          message: isFiltered
              ? 'Nothing matches the current search and filters.'
              : 'Add your first customer to start billing and keeping a ledger.',
          actionLabel: isFiltered ? null : 'New customer',
          onAction: isFiltered ? null : () => context.go(Routes.customerForm),
        );
      }
      return _CustomerList(page: value);
    }

    if (page.hasError) {
      return ErrorView(
        message: describeError(page.error!),
        onRetry: () => ref.invalidate(customersListControllerProvider),
      );
    }

    return const LoadingView(message: 'Loading customers…');
  }
}

/// The loaded rows, with a trailing control to fetch the next page.
class _CustomerList extends ConsumerWidget {
  const _CustomerList({required this.page});

  /// The page currently loaded.
  final CustomerListPage page;

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
        final customer = page.items[index];
        return CustomerCard(
          customer: customer,
          onTap: () => context.go(Routes.customerDetail(customer.id)),
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
      await ref.read(customersListControllerProvider.notifier).loadMore();
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
