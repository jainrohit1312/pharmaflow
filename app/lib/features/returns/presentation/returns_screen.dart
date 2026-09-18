/// Purchase returns: goods sent back to a supplier.
library;

import 'package:app/core/errors/error_message.dart';
import 'package:app/core/router/routes.dart';
import 'package:app/core/widgets/app_button.dart';
import 'package:app/core/widgets/app_empty_view.dart';
import 'package:app/core/widgets/app_scaffold.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/core/widgets/loading_view.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/features/returns/application/purchase_returns_list_controller.dart';
import 'package:app/features/returns/presentation/widgets/purchase_return_card.dart';
import 'package:app/features/suppliers/application/supplier_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Lists the pharmacy's purchase returns, newest first.
///
/// The sale side of returns is Phase 3, so this screen is the purchase side only
/// - which is also why its route sits on the shell's one Returns destination:
/// there is nothing else yet for that destination to show.
class ReturnsScreen extends ConsumerWidget {
  /// Creates the returns list screen.
  const ReturnsScreen({super.key});

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

    return AppScaffold(
      title: 'Returns',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(Routes.returnsForm),
        icon: const Icon(Icons.add),
        label: const Text('New return'),
      ),
      body: _ReturnsBody(page: page, names: names),
    );
  }
}

/// Renders whichever of the list's states applies.
class _ReturnsBody extends ConsumerWidget {
  const _ReturnsBody({required this.page, required this.names});

  /// Current list state.
  final AsyncValue<PurchaseReturnListPage> page;

  /// Supplier names by id, for the cards.
  final Map<String, String> names;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      return _ReturnList(page: value, names: names);
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

/// The loaded rows, with a trailing control to fetch the next page.
class _ReturnList extends ConsumerWidget {
  const _ReturnList({required this.page, required this.names});

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
