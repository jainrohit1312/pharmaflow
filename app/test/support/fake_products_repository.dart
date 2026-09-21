/// Shared test doubles for the catalogue features.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_alias.dart';
import 'package:app/data/models/product_draft.dart';
import 'package:app/data/models/product_stock.dart';
import 'package:app/data/models/write_outcome.dart';
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
  ///
  /// [isOwner] defaults to `true`, because most tests care about what a product
  /// screen shows rather than about who may write it; a test that drives the
  /// owner-approval rail passes `false`.
  FakeProductsRepository({required this.products, this.isOwner = true});

  /// The rows the fake knows about.
  final List<Product> products;

  /// Whether a write LANDS or is only asked for.
  ///
  /// `true` is the owner: `save_product()` performs the write and the envelope says
  /// `recorded`. `false` is everybody else - a pharmacist and a cashier alike since D-085 -
  /// whose write raises one approval request and moves nothing.
  bool isOwner;

  /// How many writes were STAGED rather than performed.
  int stagedSubmissions = 0;

  /// The drafts the form handed to the write path, in order.
  final List<ProductDraft> writtenDrafts = <ProductDraft>[];

  /// The product id the last write named.
  String? lastProductId;

  /// The active flag the last toggle asked for.
  bool? lastActiveAsk;

  /// The invoice text the last alias write carried.
  String? lastAliasRawName;

  /// The alias id the last removal named.
  String? lastRemovedAliasId;

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

  /// The aliases [aliasesFor] answers with, by product id.
  final Map<String, List<ProductAlias>> aliasesByProduct =
      <String, List<ProductAlias>>{};

  @override
  Future<Product?> byId({
    required String pharmacyId,
    required String productId,
  }) async => products.where((row) => row.id == productId).firstOrNull;

  @override
  Future<List<BatchStatus>> batchesFor({
    required String pharmacyId,
    required String productId,
  }) async => batchesByProduct[productId] ?? const <BatchStatus>[];

  @override
  Future<List<ProductAlias>> aliasesFor({
    required String pharmacyId,
    required String productId,
  }) async => aliasesByProduct[productId] ?? const <ProductAlias>[];

  @override
  Future<ProductStock?> stockFor({
    required String pharmacyId,
    required String productId,
  }) async => null;

  @override
  Future<WriteOutcome<Product>> create({
    required ProductDraft draft,
    String? idempotencyKey,
  }) async {
    writtenDrafts.add(draft);
    if (!isOwner) {
      stagedSubmissions++;
      return const WriteOutcome<Product>.staged('ask-product-create');
    }

    final saved = buildProduct(
      draft.name,
      scheduleType: draft.scheduleType,
      isActive: draft.isActive,
    );
    // The row the write produced is the row the catalogue now holds, so a screen that
    // navigates to it - which is exactly what the owner's write does - can read it back.
    products.add(saved);
    return WriteOutcome<Product>.recorded(saved);
  }

  @override
  Future<WriteOutcome<Product>> update({
    required String productId,
    required ProductDraft draft,
  }) async {
    lastProductId = productId;
    writtenDrafts.add(draft);
    if (!isOwner) {
      stagedSubmissions++;
      return const WriteOutcome<Product>.staged('ask-product-edit');
    }

    final saved = buildProduct(
      draft.name,
      id: productId,
      scheduleType: draft.scheduleType,
      isActive: draft.isActive,
    );
    _replace(saved);
    return WriteOutcome<Product>.recorded(saved);
  }

  @override
  Future<WriteOutcome<Product>> setActive({
    required String productId,
    required bool isActive,
  }) async {
    lastProductId = productId;
    lastActiveAsk = isActive;
    if (!isOwner) {
      stagedSubmissions++;
      return const WriteOutcome<Product>.staged('ask-product-delete');
    }

    final existing = products.where((row) => row.id == productId).firstOrNull;

    final saved = buildProduct(
      existing?.name ?? 'unknown',
      id: productId,
      scheduleType: existing?.scheduleType ?? ScheduleType.otc,
      isActive: isActive,
      gstPercent: existing?.gstPercent,
      category: existing?.category,
    );
    _replace(saved);
    return WriteOutcome<Product>.recorded(saved);
  }

  /// Puts [saved] where the row it replaced was, so a re-read sees the write.
  void _replace(Product saved) {
    final index = products.indexWhere((row) => row.id == saved.id);
    if (index >= 0) {
      products[index] = saved;
    } else {
      products.add(saved);
    }
  }

  @override
  Future<WriteOutcome<ProductAlias>> addAlias({
    required String productId,
    required String rawName,
    String? supplierId,
  }) async {
    lastProductId = productId;
    lastAliasRawName = rawName;
    if (!isOwner) {
      stagedSubmissions++;
      return const WriteOutcome<ProductAlias>.staged('ask-alias-add');
    }

    return WriteOutcome<ProductAlias>.recorded(
      _alias(
        id: 'alias-1',
        productId: productId,
        rawName: rawName,
        supplierId: supplierId,
      ),
    );
  }

  @override
  Future<WriteOutcome<ProductAlias>> removeAlias({
    required String productId,
    required String aliasId,
  }) async {
    lastProductId = productId;
    lastRemovedAliasId = aliasId;
    if (!isOwner) {
      stagedSubmissions++;
      return const WriteOutcome<ProductAlias>.staged('ask-alias-remove');
    }

    return WriteOutcome<ProductAlias>.recorded(
      _alias(id: aliasId, productId: productId, rawName: 'removed'),
    );
  }

  /// An alias row, with the fields a test does not care about filled in.
  ProductAlias _alias({
    required String id,
    required String productId,
    required String rawName,
    String? supplierId,
  }) => ProductAlias(
    id: id,
    pharmacyId: 'ph-1',
    productId: productId,
    rawName: rawName,
    normalizedName: rawName.toLowerCase(),
    supplierId: supplierId,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
