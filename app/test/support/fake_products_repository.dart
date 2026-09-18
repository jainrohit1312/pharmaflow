/// Shared test doubles for the catalogue features.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/product.dart';
import 'package:app/features/products/data/products_repository.dart';

/// Builds a product with only the fields a test cares about.
Product buildProduct(
  String name, {
  ScheduleType scheduleType = ScheduleType.otc,
  bool isActive = true,
}) => Product(
  id: 'id-$name',
  pharmacyId: 'ph-1',
  name: name,
  scheduleType: scheduleType,
  isActive: isActive,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// An in-memory [ProductsRepository] that applies the query the way one page of
/// the real one would.
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing:
/// `implements` does not require a constructor, so the fake never needs a
/// Supabase client - which is the whole point, because a real `SupabaseClient`
/// cannot be constructed without an initialised backend.
class FakeProductsRepository implements ProductsRepository {
  /// Creates a fake holding [products], already in display order.
  FakeProductsRepository({required this.products});

  /// The rows the fake knows about.
  final List<Product> products;

  /// Offsets the controller asked for, in order.
  final List<int> requestedOffsets = <int>[];

  /// The last query the controller sent.
  ProductsQuery? lastQuery;

  /// When true the next `list` call throws.
  bool failNextList = false;

  @override
  Future<List<Product>> list({
    required String pharmacyId,
    required ProductsQuery query,
    int limit = ProductsRepository.pageSize,
    int offset = 0,
  }) async {
    lastQuery = query;
    requestedOffsets.add(offset);
    if (failNextList) {
      failNextList = false;
      throw StateError('the fake was told to fail');
    }

    final term = query.search.toLowerCase();
    final matching = products.where((product) {
      final matchesTerm =
          term.isEmpty || product.name.toLowerCase().contains(term);
      final matchesSchedule =
          query.scheduleType == null ||
          product.scheduleType == query.scheduleType;
      final matchesActive =
          query.isActive == null || product.isActive == query.isActive;
      return matchesTerm && matchesSchedule && matchesActive;
    });

    return matching.skip(offset).take(limit).toList(growable: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
