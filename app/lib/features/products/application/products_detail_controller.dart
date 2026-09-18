/// The product detail screen's data, and the alias edits it supports.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_alias.dart';
import 'package:app/data/models/product_stock.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'products_detail_controller.g.dart';

/// Everything the detail screen shows about one product.
class ProductDetailData {
  /// Creates a detail snapshot.
  const ProductDetailData({
    required this.product,
    required this.batches,
    required this.aliases,
    this.stock,
  });

  /// The product itself.
  final Product product;

  /// Its batches, in FEFO order.
  final List<BatchStatus> batches;

  /// Aliases pointing at it.
  final List<ProductAlias> aliases;

  /// The `product_stock` rollup, when the view returned one.
  final ProductStock? stock;

  /// On-hand quantity.
  ///
  /// The view is authoritative because it is what the rest of the app reports;
  /// the fallback sums the batches only if the view returned nothing at all.
  int get totalQty =>
      stock?.totalQty ?? batches.fold(0, (sum, batch) => sum + batch.qty);

  /// Whether on-hand quantity is below the product's reorder level.
  bool get isLowStock => stock?.isLowStock ?? false;

  /// On-hand quantity in the nearest expiry bucket at or beyond [status].
  int qtyExpiringBy(ExpiryStatus status) => batches
      .where((batch) => batch.expiryStatus == status)
      .fold(0, (sum, batch) => sum + batch.qty);
}

/// Loads and refreshes one product's detail, and owns its alias writes.
@riverpod
class ProductDetailController extends _$ProductDetailController {
  @override
  Future<ProductDetailData> build(String productId) async {
    final pharmacyId = ref.watch(requirePharmacyIdProvider);
    final repository = ref.watch(productsRepositoryProvider);

    final product = await repository.byId(
      pharmacyId: pharmacyId,
      productId: productId,
    );
    if (product == null) {
      throw const NotFoundException(
        message: 'That product no longer exists in your catalogue.',
      );
    }

    // Sequential rather than concurrent on purpose: `Future.wait` over a record
    // would surface a `ParallelWaitError` instead of the friendly AppException
    // each of these throws, and the error mapping on screen depends on that.
    final batches = await repository.batchesFor(
      pharmacyId: pharmacyId,
      productId: productId,
    );
    final aliases = await repository.aliasesFor(
      pharmacyId: pharmacyId,
      productId: productId,
    );
    final stock = await repository.stockFor(
      pharmacyId: pharmacyId,
      productId: productId,
    );

    return ProductDetailData(
      product: product,
      batches: batches,
      aliases: aliases,
      stock: stock,
    );
  }

  /// Records invoice text as an alias of this product, then refreshes.
  Future<void> addAlias({required String rawName, String? supplierId}) async {
    final pharmacyId = ref.read(requirePharmacyIdProvider);
    await ref
        .read(productsRepositoryProvider)
        .addAlias(
          pharmacyId: pharmacyId,
          productId: productId,
          rawName: rawName,
          supplierId: supplierId,
        );
    ref.invalidateSelf();
  }

  /// Removes an alias, then refreshes.
  Future<void> removeAlias(String aliasId) async {
    final pharmacyId = ref.read(requirePharmacyIdProvider);
    await ref
        .read(productsRepositoryProvider)
        .removeAlias(pharmacyId: pharmacyId, aliasId: aliasId);
    ref.invalidateSelf();
  }
}
