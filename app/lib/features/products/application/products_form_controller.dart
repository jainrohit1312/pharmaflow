/// Create, edit and deactivate for the product catalogue.
library;

import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_draft.dart';
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
/// `state` holds the product most recently saved, so a screen can react to a
/// successful save through `ref.listen` without the method's return value being
/// threaded through the widget. A failed write publishes an [AsyncError] and
/// rethrows, matching how `AuthController` reports failures: the state drives
/// the SnackBar, the rethrow keeps the awaiting button handler honest.
///
/// The method names are deliberately specific (`createProduct`, not `create`).
/// Riverpod's generated base class already defines `update` and `setState`-style
/// helpers, and a method that shadows one of those is either a compile error or
/// a silent change of meaning when the framework grows another.
@riverpod
class ProductsFormController extends _$ProductsFormController {
  @override
  Future<Product?> build() async => null;

  /// Creates a product and stores it in `state`.
  Future<Product> createProduct(ProductDraft draft) => _write(
    () async => ref
        .read(productsRepositoryProvider)
        .create(pharmacyId: ref.read(requirePharmacyIdProvider), draft: draft),
  );

  /// Overwrites a product and stores it in `state`.
  Future<Product> updateProduct({
    required String productId,
    required ProductDraft draft,
  }) => _write(
    () async => ref
        .read(productsRepositoryProvider)
        .update(
          pharmacyId: ref.read(requirePharmacyIdProvider),
          productId: productId,
          draft: draft,
        ),
  );

  /// Enables or disables a product and stores its new state.
  ///
  /// Returns the re-read product, or `null` when the write landed but the row
  /// could not be read back. That is not a failure: the write either succeeded
  /// or threw, and reporting a successful deactivation as an error because a
  /// follow-up read came back empty would send the user to fix something that
  /// is already correct.
  Future<Product?> setProductActive({
    required String productId,
    required bool isActive,
  }) async {
    final pharmacyId = ref.read(requirePharmacyIdProvider);
    final repository = ref.read(productsRepositoryProvider);

    state = const AsyncLoading<Product?>();
    try {
      await repository.setActive(
        pharmacyId: pharmacyId,
        productId: productId,
        isActive: isActive,
      );
      final updated = await repository.byId(
        pharmacyId: pharmacyId,
        productId: productId,
      );
      state = AsyncData<Product?>(updated);
      return updated;
    } on Object catch (error, stackTrace) {
      state = AsyncError<Product?>(error, stackTrace);
      rethrow;
    }
  }

  /// Runs a write, mapping its outcome onto `state`.
  Future<Product> _write(Future<Product> Function() write) async {
    state = const AsyncLoading<Product?>();
    try {
      final saved = await write();
      return _publish(saved);
    } on Object catch (error, stackTrace) {
      state = AsyncError<Product?>(error, stackTrace);
      rethrow;
    }
  }

  /// Publishes a successful write and returns its product.
  Product _publish(Product product) {
    state = AsyncData<Product?>(product);
    return product;
  }
}
