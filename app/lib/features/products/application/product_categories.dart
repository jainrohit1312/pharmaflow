/// The catalogue's own categories, for the tab strips that browse by one.
library;

import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/products/data/products_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'product_categories.g.dart';

/// The distinct categories this pharmacy's catalogue records, sorted.
///
/// Read from the products rather than from a list written into the app, so a tab
/// appears the moment a product carries its category and disappears with the last
/// one - which is the whole of the owner's F3. Today it answers an empty list: the
/// imported catalogue has `category` NULL throughout, so the counter's strip shows
/// Recent and All and nothing between them.
@riverpod
Future<List<String>> productCategories(Ref ref) async {
  final pharmacyId = ref.watch(requirePharmacyIdProvider);
  return ref
      .watch(productsRepositoryProvider)
      .categories(pharmacyId: pharmacyId);
}
