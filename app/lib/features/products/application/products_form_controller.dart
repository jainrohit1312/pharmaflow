/// Create, edit and deactivate for the product catalogue.
library;

import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_draft.dart';
import 'package:app/data/models/write_outcome.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'products_form_controller.g.dart';

/// The product a form is editing, or `null` when no such product is visible.
///
/// Separate from the detail controller on purpose: the edit form needs the
/// product's own columns and nothing else, and reusing the detail provider would
/// drag three extra queries (batches, aliases, stock) behind a form field.
@riverpod
Future<Product?> productForEdit(Ref ref, String productId) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(productsRepositoryProvider)
      .byId(pharmacyId: pharmacyId, productId: productId);
}

/// Performs product writes for the create and edit screens.
///
/// `state` holds the product most recently WRITTEN, so a screen can react to a successful save
/// through `ref.listen` without the method's return value being threaded through the widget. It is
/// `null` when the write was staged rather than performed: a staged write wrote nothing, so there is
/// no product to hold - and the returned [WriteOutcome] is what says which happened.
///
/// A failed write publishes an [AsyncError] and rethrows, matching how `AuthController` reports
/// failures: the state drives the SnackBar, the rethrow keeps the awaiting button handler honest.
///
/// The method names are deliberately specific (`createProduct`, not `create`).
/// Riverpod's generated base class already defines `update` and `setState`-style
/// helpers, and a method that shadows one of those is either a compile error or
/// a silent change of meaning when the framework grows another.
@riverpod
class ProductsFormController extends _$ProductsFormController {
  @override
  Future<Product?> build() async => null;

  /// Creates a product, or - for anybody but the owner - asks him to.
  Future<WriteOutcome<Product>> createProduct(ProductDraft draft) =>
      _save(() => ref.read(productsRepositoryProvider).create(draft: draft));

  /// Overwrites a product, or asks the owner to.
  Future<WriteOutcome<Product>> updateProduct({
    required String productId,
    required ProductDraft draft,
  }) => _save(
    () => ref
        .read(productsRepositoryProvider)
        .update(productId: productId, draft: draft),
  );

  /// Enables or disables a product, or asks the owner to.
  ///
  /// The answer's `isStaged` is what a screen branches on: a staged deactivation moved nothing, so
  /// there is no new state to read back and no detail to refresh.
  Future<WriteOutcome<Product>> setProductActive({
    required String productId,
    required bool isActive,
  }) => _save(
    () => ref
        .read(productsRepositoryProvider)
        .setActive(productId: productId, isActive: isActive),
  );

  /// Runs a write, mapping its outcome onto `state`.
  Future<WriteOutcome<Product>> _save(
    Future<WriteOutcome<Product>> Function() write,
  ) async {
    state = const AsyncLoading<Product?>();
    try {
      final outcome = await write();
      state = AsyncData<Product?>(outcome.document);
      return outcome;
    } on Object catch (error, stackTrace) {
      state = AsyncError<Product?>(error, stackTrace);
      rethrow;
    }
  }
}
