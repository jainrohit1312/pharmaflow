/// Returns: what came back to a supplier, and what a customer brought back.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/customers/application/customer_options.dart';
import 'package:app/features/returns/application/purchase_returns_list_controller.dart';
import 'package:app/features/returns/application/sale_returns_list_controller.dart';
import 'package:app/features/returns/presentation/widgets/purchase_return_card.dart';
import 'package:app/features/returns/presentation/widgets/sale_return_card.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The one Returns door: purchases on one tab, sales on the other.
///
/// A pharmacy has a single Returns destination in the shell, and the two sides are
/// the same idea pointing opposite ways - goods going back up the supply chain and
/// goods coming back from a customer - so they share a screen rather than a
/// destination each. The action button follows the tab, because "New return" means
/// two different documents.
class ReturnsScreen extends ConsumerStatefulWidget {
  /// Creates the returns screen.
  const ReturnsScreen({super.key});

  @override
  ConsumerState<ReturnsScreen> createState() => _ReturnsScreenState();
}

class _ReturnsScreenState extends ConsumerState<ReturnsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(_onTabChanged);
  int _index = 0;

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

  /// Keeps the action button in step with the visible tab.
  void _onTabChanged() {
    if (_tabs.index != _index) {
      setState(() => _index = _tabs.index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPurchaseSide = _index == 0;

    return AppScaffold(
      title: 'Returns',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(
          isPurchaseSide ? Routes.returnsForm : Routes.saleReturnForm,
        ),
        icon: const Icon(Icons.add),
        label: Text(isPurchaseSide ? 'New return' : 'New sale return'),
      ),
      bottomNavigationBar: TabBar(
        controller: _tabs,
        tabs: const <Widget>[
          Tab(text: 'To supplier'),
          Tab(text: 'From customer'),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: const <Widget>[_PurchaseReturnsTab(), _SaleReturnsTab()],
      ),
    );
  }
}

/// Purchase returns: goods sent back to a supplier.
class _PurchaseReturnsTab extends ConsumerWidget {
  const _PurchaseReturnsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(purchaseReturnsListControllerProvider);
    // A failed supplier read costs the cards their names, not the list its rows,
    // so it is read leniently here.
    final suppliers =
        ref.watch(supplierOptionsProvider).value ?? const <Supplier>[];
    final names = <String, String>{
      for (final supplier in suppliers) supplier.id: supplier.name,
    };

    ref.listen<AsyncValue<PurchaseReturnListPage>>(
      purchaseReturnsListControllerProvider,
      (previous, next) {
        final error = next.error;
        if (error == null || !context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(describeError(error))));
      },
    );

    if (page.hasValue) {
      final value = page.value!;
      if (value.items.isEmpty) {
        return AppEmptyView(
          icon: Icons.assignment_return_outlined,
          title: 'No returns yet',
          message:
              'Goods sent back to a supplier are recorded here, against the '
              'purchase they came from.',
          actionLabel: 'New return',
          onAction: () => context.go(Routes.returnsForm),
        );
      }
      return _PurchaseReturnList(page: value, names: names);
    }

    if (page.hasError) {
      return ErrorView(
        message: describeError(page.error!),
        onRetry: () => ref.invalidate(purchaseReturnsListControllerProvider),
      );
    }

    return const LoadingView(message: 'Loading returns…');
  }
}

/// The loaded purchase returns, with a trailing control to fetch the next page.
class _PurchaseReturnList extends ConsumerWidget {
  const _PurchaseReturnList({required this.page, required this.names});

  /// The page currently loaded.
  final PurchaseReturnListPage page;

  /// Supplier names by id.
  final Map<String, String> names;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoadingMore = page.isLoadingMore;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
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
        final entry = page.items[index];
        return PurchaseReturnCard(
          purchaseReturn: entry,
          supplierName: names[entry.supplierId] ?? 'Unknown supplier',
          onTap: () => context.go(Routes.returnDetail(entry.id)),
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
      await ref.read(purchaseReturnsListControllerProvider.notifier).loadMore();
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

/// Sale returns: goods a customer brought back.
class _SaleReturnsTab extends ConsumerWidget {
  const _SaleReturnsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(saleReturnsListControllerProvider);
    final customers =
        ref.watch(customerOptionsProvider).value ?? const <Customer>[];
    final names = <String, String>{
      for (final customer in customers) customer.id: customer.name,
    };

    ref.listen<AsyncValue<SaleReturnListPage>>(
      saleReturnsListControllerProvider,
      (previous, next) {
        final error = next.error;
        if (error == null || !context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(describeError(error))));
      },
    );

    if (page.hasValue) {
      final value = page.value!;
      if (value.items.isEmpty) {
        return AppEmptyView(
          icon: Icons.assignment_return_outlined,
          title: 'Nothing has come back yet',
          message:
              'Goods a customer brings back are recorded here, against the bill '
              'they were sold on.',
          actionLabel: 'New sale return',
          onAction: () => context.go(Routes.saleReturnForm),
        );
      }
      return _SaleReturnList(page: value, names: names);
    }

    if (page.hasError) {
      return ErrorView(
        message: describeError(page.error!),
        onRetry: () => ref.invalidate(saleReturnsListControllerProvider),
      );
    }

    return const LoadingView(message: 'Loading sale returns…');
  }
}

/// The loaded sale returns, with a trailing control to fetch the next page.
class _SaleReturnList extends ConsumerWidget {
  const _SaleReturnList({required this.page, required this.names});

  /// The page currently loaded.
  final SaleReturnListPage page;

  /// Customer names by id.
  final Map<String, String> names;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoadingMore = page.isLoadingMore;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
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
        final entry = page.items[index];
        return SaleReturnCard(
          saleReturn: entry,
          customerName: entry.customerId == null
              ? null
              : names[entry.customerId],
          // The bill is what a return is read against, and it also shows the
          // lines the return took its units from.
          onTap: () => context.go(Routes.saleDetail(entry.saleId)),
        );
      },
    );
  }

  /// Fetches the next page, reporting a failure without clearing the list.
  Future<void> _loadMore(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(saleReturnsListControllerProvider.notifier).loadMore();
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
