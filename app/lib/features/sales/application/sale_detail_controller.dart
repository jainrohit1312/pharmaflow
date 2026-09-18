/// One sale, its lines, and the names of what it sold.
library;

import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_item.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:app/features/sales/data/sales_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sale_detail_controller.g.dart';

/// A sale with everything a detail screen draws.
///
/// The product names come with the lines because `sale_items` has none: it stores
/// a product id (and a schedule snapshot) but not the name, so a screen showing
/// what was sold has to resolve names from somewhere. Loading them once here, for
/// the whole document, is what keeps the invoice from making one request per line.
///
/// Unlike a purchase line, a sale line keeps no copy of the printed invoice text
/// either - there is no `product_name_raw` on `sale_items` - so the catalogue name
/// is the only name there is, and the invoice is rendered in whatever the product
/// is called today.
class SaleDetailData {
  /// Creates a detail.
  const SaleDetailData({
    required this.sale,
    required this.items,
    required this.productNames,
  });

  /// The sale document itself.
  final Sale sale;

  /// Its lines, in insertion order.
  final List<SaleItem> items;

  /// Product names by id.
  final Map<String, String> productNames;

  /// What was sold on one line.
  String nameOf(SaleItem item) =>
      productNames[item.productId] ?? 'Unnamed product';

  /// Whether any line needs the statutory register's attention.
  bool get hasControlledItems => items.any((item) => item.isControlled);
}

/// The sale named by [saleId], or `null` when it is gone.
@riverpod
Future<SaleDetailData?> saleDetail(Ref ref, String saleId) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  final sales = ref.watch(salesRepositoryProvider);

  final sale = await sales.byId(pharmacyId: pharmacyId, saleId: saleId);
  if (sale == null) {
    return null;
  }

  // Sequential rather than concurrent: `Future.wait` over a record would surface
  // a `ParallelWaitError` instead of the friendly AppException each of these
  // throws, and screens map errors through that.
  final items = await sales.itemsFor(pharmacyId: pharmacyId, saleId: saleId);
  final names = await ref
      .watch(productsRepositoryProvider)
      .namesFor(
        pharmacyId: pharmacyId,
        productIds: items
            .map((item) => item.productId)
            .whereType<String>()
            .toSet()
            .toList(growable: false),
      );

  return SaleDetailData(sale: sale, items: items, productNames: names);
}
