/// Product lookup for pickers.
library;

import 'package:app/data/models/product.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'product_search.g.dart';

/// How many products a picker offers at once.
///
/// A picker answers "which product did they mean", so it wants a short list to
/// choose from, not a browsable catalogue. Past a couple of dozen rows the user
/// should be typing more, not scrolling.
const int productSearchLimit = 20;

/// Products matching [term], for pickers outside the product list screen.
///
/// Separate from the products list provider on purpose: that one carries the
/// list screen's filter state and its paging, and a picker inside a purchase form
/// must not inherit - or disturb - either. Searching runs through the same
/// repository call, so the barcode and generic-name matching comes along for
/// free, and a scanned barcode finds its product from here.
///
/// An empty [term] returns the first active products, so the picker opens with
/// something to tap rather than an empty sheet.
@riverpod
Future<List<Product>> productSearch(Ref ref, String term) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(productsRepositoryProvider)
      .list(
        pharmacyId: pharmacyId,
        query: ProductsQuery(search: term, isActive: true),
        limit: productSearchLimit,
      );
}
