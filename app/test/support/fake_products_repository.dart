/// Shared test doubles for the catalogue features.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/features/products/data/products_repository.dart';

/// Builds a product with only the fields a test cares about.
///
/// [id] defaults to `id-<name>`, which is what makes `buildProduct('Dolo 650')`
/// usable as a stable reference in assertions. Pass it explicitly when a test has
/// to match a product id that something else already knows, such as a batch or a
/// sale line fixture.
///
/// [gstPercent] defaults to `null` - the product nobody has recorded a slab for,
/// which is what most of the tests want, since it is the case that exercises the
/// named 5% POS default. Pass `0` to prove a recorded zero is a rate rather than an
/// absence.
Product buildProduct(
  String name, {
  String? id,
  ScheduleType scheduleType = ScheduleType.otc,
  bool isActive = true,
  double? gstPercent,
  String? category,
}) => Product(
  id: id ?? 'id-$name',
  pharmacyId: 'ph-1',
  name: name,
  scheduleType: scheduleType,
  isActive: isActive,
  gstPercent: gstPercent,
  category: category,
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

  /// The quantities [batchQuantitiesFor] answers with, by batch id.
  ///
  /// Set by a test that has to make a checkout see stock: the POS re-reads these
  /// before it writes, so a test can make a basket look short.
  final Map<String, int> batchQuantities = <String, int>{};

  /// The batches [batchesForProducts] answers with, by product id.
  ///
  /// For the counter's dropdown, which reads the batches of every product its page
  /// matched in one go. A product absent here has no batch at all - which the
  /// dropdown reads as "nothing to dispense", not as a failed read.
  final Map<String, List<BatchStatus>> batchesByProduct =
      <String, List<BatchStatus>>{};

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
      final matchesCategory =
          query.category == null || product.category == query.category;
      final ids = query.ids;
      final matchesIds = ids == null || ids.contains(product.id);
      return matchesTerm &&
          matchesSchedule &&
          matchesActive &&
          matchesCategory &&
          matchesIds;
    });

    return matching.skip(offset).take(limit).toList(growable: false);
  }

  /// The categories [categories] answers with.
  ///
  /// Set by a test that wants the counter's strip to have a middle tab: the real
  /// read works them out from the catalogue's `category` column, which the fixtures
  /// mostly leave NULL (as the imported catalogue does).
  List<String> categoriesAnswer = const <String>[];

  @override
  Future<List<String>> categories({required String pharmacyId}) async =>
      categoriesAnswer;

  @override
  Future<Map<String, String>> namesFor({
    required String pharmacyId,
    required List<String> productIds,
  }) async => <String, String>{
    for (final product in products)
      if (productIds.contains(product.id)) product.id: product.name,
  };

  @override
  Future<Map<String, int>> batchQuantitiesFor({
    required String pharmacyId,
    required List<String> batchIds,
  }) async => <String, int>{
    for (final entry in batchQuantities.entries)
      if (batchIds.contains(entry.key)) entry.key: entry.value,
  };

  @override
  Future<Map<String, List<BatchStatus>>> batchesForProducts({
    required String pharmacyId,
    required List<String> productIds,
  }) async => <String, List<BatchStatus>>{
    for (final id in productIds)
      if (batchesByProduct.containsKey(id)) id: batchesByProduct[id]!,
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
