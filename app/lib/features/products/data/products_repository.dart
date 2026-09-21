/// Supabase-backed repository for the product catalogue.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/postgrest_search.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product.dart';
import 'package:app/data/models/product_alias.dart';
import 'package:app/data/models/product_draft.dart';
import 'package:app/data/models/product_stock.dart';
import 'package:app/data/models/write_outcome.dart';
import 'package:app/features/products/data/product_payload.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'products_repository.g.dart';

/// Exposes the single [ProductsRepository] used by the products feature.
@riverpod
ProductsRepository productsRepository(Ref ref) =>
    ProductsRepository(ref.watch(supabaseClientProvider));

/// What a product list query may filter on.
///
/// Immutable, and mutated only through the `with…` helpers, so a filter change
/// is always a new value rather than an in-place edit that Riverpod could miss.
class ProductsQuery {
  /// Creates a query; the defaults mean "everything, unsorted".
  const ProductsQuery({
    this.search = '',
    this.scheduleType,
    this.isActive,
    this.category,
    this.ids,
  });

  /// Free-text term matched against name, generic name and barcode.
  final String search;

  /// Restrict to one statutory schedule.
  final ScheduleType? scheduleType;

  /// Restrict to active or inactive products; `null` means both.
  final bool? isActive;

  /// Restrict to one category, by exact match; `null` means every category.
  ///
  /// The counter's category strip reads the catalogue's own distinct categories
  /// and offers one per tab, so this is the filter behind a tab rather than a
  /// list of categories written into the app (the owner's F3). The imported
  /// catalogue has `category` NULL throughout, so today the strip has no category
  /// tab at all - and this is what makes one appear when data does.
  final String? category;

  /// Restrict to these product ids, in no particular order; `null` means any.
  ///
  /// For the one caller that holds an ordered list of ids it wants rows for - the
  /// counter's Recent strip, whose order is "most recently sold" and therefore
  /// cannot be expressed as a column.
  final List<String>? ids;

  /// Whether anything is actually being filtered out.
  ///
  /// Lets a screen distinguish "the catalogue is empty" from "your search
  /// matched nothing", which need different copy and different actions.
  bool get isFiltered =>
      search.isNotEmpty ||
      scheduleType != null ||
      isActive != null ||
      category != null ||
      ids != null;

  /// A copy with the search term replaced.
  ProductsQuery withSearch(String value) => ProductsQuery(
    search: value,
    scheduleType: scheduleType,
    isActive: isActive,
    category: category,
    ids: ids,
  );

  /// A copy with the schedule filter replaced (`null` clears it).
  ProductsQuery withSchedule(ScheduleType? value) => ProductsQuery(
    search: search,
    scheduleType: value,
    isActive: isActive,
    category: category,
    ids: ids,
  );

  /// A copy with the active filter replaced (`null` clears it).
  ///
  /// Named for the same reason as the list controller's setter: the argument is
  /// tri-state, and a positional `withActive(false)` does not say whether it
  /// means "inactive only" or "clear the filter".
  ProductsQuery withActive({required bool? value}) => ProductsQuery(
    search: search,
    scheduleType: scheduleType,
    isActive: value,
    category: category,
    ids: ids,
  );

  /// A copy with the category filter replaced (`null` clears it).
  ProductsQuery withCategory(String? value) => ProductsQuery(
    search: search,
    scheduleType: scheduleType,
    isActive: isActive,
    category: value,
    ids: ids,
  );
}

/// Data access for `products`, `product_batches`, `product_aliases` and the
/// two read-only views.
///
/// Every method takes an explicit `pharmacyId` and filters on it even though
/// RLS would scope the rows anyway: relying on a policy as the filter makes the
/// scope invisible at the call site, and an insert has to carry the column
/// regardless.
class ProductsRepository {
  /// Creates a repository backed by the shared Supabase client.
  ProductsRepository(this._client);

  final sb.SupabaseClient _client;

  /// Rows fetched per page by the list screen.
  static const int pageSize = 50;

  /// Columns the free-text search looks at.
  static const List<String> searchColumns = <String>[
    'name',
    'generic_name',
    'barcode',
  ];

  /// The projection every `products` read uses.
  ///
  /// Spelled out rather than left as PostgREST's default `*` because the table
  /// carries an `embedding` column (migration 00022): a 768-dimension vector no
  /// screen displays, which `*` would return on every row - roughly 8 kB of floats
  /// per product on the list, the detail screen, and every picker that names a
  /// product. The matching functions read that column server-side; the client
  /// never needs it.
  ///
  /// Add a column here when a screen needs it. Unlike `*`, this list is a
  /// decision: a column missing from it reaches the app as an absent key, so the
  /// test in `test/features/products/data/products_repository_columns_test.dart`
  /// keeps it in step with what [Product] decodes.
  static const List<String> columns = <String>[
    'id',
    'pharmacy_id',
    'name',
    'generic_name',
    'brand',
    'manufacturer',
    'hsn_code',
    'category',
    'gst_percent',
    'schedule_type',
    'pack_size',
    'unit',
    'min_stock_level',
    'rack_location',
    'barcode',
    'is_active',
    'created_at',
    'updated_at',
  ];

  /// [columns] as a PostgREST projection.
  static String get projection => columns.join(',');

  /// Loads one page of products matching [query], ordered by name.
  Future<List<Product>> list({
    required String pharmacyId,
    required ProductsQuery query,
    int limit = pageSize,
    int offset = 0,
  }) async {
    try {
      var request = _client
          .from('products')
          .select(projection)
          .eq('pharmacy_id', pharmacyId);

      final search = buildIlikeOrFilter(
        columns: searchColumns,
        term: query.search,
      );
      if (search != null) {
        request = request.or(search);
      }
      final scheduleType = query.scheduleType;
      if (scheduleType != null) {
        request = request.eq('schedule_type', scheduleType.dbValue);
      }
      final isActive = query.isActive;
      if (isActive != null) {
        request = request.eq('is_active', isActive);
      }
      final category = query.category;
      if (category != null) {
        request = request.eq('category', category);
      }
      final ids = query.ids;
      if (ids != null) {
        // An empty id list is a query for nothing, and asking PostgREST for it
        // would be asking for every row: the caller guards it, and this makes the
        // guard visible rather than load-bearing.
        if (ids.isEmpty) {
          return const <Product>[];
        }
        request = request.inFilter('id', ids);
      }

      final rows = await request
          .order('name')
          .range(offset, offset + limit - 1);
      return rows.map(Product.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the product list.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the product list.',
        cause: error,
      );
    }
  }

  /// Loads a single product, or `null` when it does not exist (or is not
  /// visible to this tenant).
  Future<Product?> byId({
    required String pharmacyId,
    required String productId,
  }) async {
    try {
      final row = await _client
          .from('products')
          .select(projection)
          .eq('pharmacy_id', pharmacyId)
          .eq('id', productId)
          .maybeSingle();
      return row == null ? null : Product.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load that product.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load that product.',
        cause: error,
      );
    }
  }

  /// Inserts a new product.
  ///
  /// The write goes through `save_product()`, the ONE door to the master (Phase 6.5c chunk 5):
  /// `products` no longer takes a write from a session at all, because a gate that lived in the form
  /// would have been a suggestion. The owner's write lands and answers with the row; anybody else's
  /// raises one `product_create` approval request and writes nothing.
  ///
  /// No `pharmacyId`: the tenant is the server's own, from `get_my_pharmacy_id()` - the same reason
  /// the returns and the GRN take none, and the one part of this payload a caller must not be able
  /// to name.
  Future<WriteOutcome<Product>> create({
    required ProductDraft draft,
    String? idempotencyKey,
  }) => _write(
    payload: ProductPayload.create(
      draft: draft,
      idempotencyKey: idempotencyKey,
    ),
    fallbackMessage: 'Unable to save that product.',
    uniqueViolationMessage: 'A product with those details already exists.',
    decode: Product.fromJson,
  );

  /// Overwrites the writable columns of an existing product.
  ///
  /// The whole draft travels, so a later ask about this product is a revision of the earlier one
  /// rather than a rival to it - the server refreshes an undecided ask instead of stacking a second.
  Future<WriteOutcome<Product>> update({
    required String productId,
    required ProductDraft draft,
  }) => _write(
    payload: ProductPayload.edit(productId: productId, draft: draft),
    fallbackMessage: 'Unable to save that product.',
    uniqueViolationMessage: 'A product with those details already exists.',
    decode: Product.fromJson,
  );

  /// Enables or disables a product.
  ///
  /// Deactivation is the supported "delete": a product that has ever been
  /// purchased or dispensed is referenced by history, so removing the row would
  /// cascade into its batches and detach its purchase lines. For anybody but the owner it is a
  /// `product_delete` REQUEST, and the row stays active until the owner answers.
  Future<WriteOutcome<Product>> setActive({
    required String productId,
    required bool isActive,
  }) => _write(
    payload: ProductPayload.active(productId: productId, isActive: isActive),
    fallbackMessage: 'Unable to update that product.',
    decode: Product.fromJson,
  );

  /// Batches of [productId] in FEFO order (first expiry, first out).
  Future<List<BatchStatus>> batchesFor({
    required String pharmacyId,
    required String productId,
  }) async {
    try {
      final rows = await _client
          .from('batch_status')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('product_id', productId)
          .order('expiry_date')
          .order('batch_no');
      return rows.map(BatchStatus.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the batches for that product.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the batches for that product.',
        cause: error,
      );
    }
  }

  /// How many rows the category scan reads before it stops.
  ///
  /// `category` is a free-text column, and PostgREST has no `distinct`, so the
  /// distinct set is worked out here from one narrow column over the catalogue. A
  /// catalogue larger than this may not show every category it holds - at that size
  /// the tab strip needs a server-side distinct, which is an RPC and a migration.
  static const int categoryScanLimit = 1000;

  /// The distinct categories the catalogue records, sorted.
  ///
  /// Read from the products themselves rather than from a list written into the
  /// app, which is what makes a tab appear the moment a product carries the
  /// category (the owner's F3). Every imported product has `category` NULL, so
  /// this answers an empty list today.
  Future<List<String>> categories({required String pharmacyId}) async {
    try {
      final rows = await _client
          .from('products')
          .select('category')
          .eq('pharmacy_id', pharmacyId)
          .not('category', 'is', null)
          .order('category')
          .limit(categoryScanLimit);

      final distinct = <String>{};
      for (final row in rows) {
        final value = (row['category'] as String?)?.trim();
        if (value != null && value.isNotEmpty) {
          distinct.add(value);
        }
      }
      return distinct.toList()..sort();
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the catalogue\u2019s categories.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the catalogue\u2019s categories.',
        cause: error,
      );
    }
  }

  /// Every batch of [productIds], FEFO within each product, keyed by product id.
  ///
  /// One read rather than one per product, for the one caller that has to show a
  /// list of products *and* what each can be dispensed from: the counter's search
  /// dropdown shows, per hit, the batch FEFO would take, its stock and its expiry,
  /// and a read per row would make typing a name fire a request per keystroke per
  /// match. `batch_status` carries the product id, so the rows group here.
  ///
  /// Products with no batch at all are simply absent from the map, which a caller
  /// reads as "nothing to dispense".
  Future<Map<String, List<BatchStatus>>> batchesForProducts({
    required String pharmacyId,
    required List<String> productIds,
  }) async {
    if (productIds.isEmpty) {
      return const <String, List<BatchStatus>>{};
    }
    try {
      final rows = await _client
          .from('batch_status')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .inFilter('product_id', productIds)
          .order('expiry_date')
          .order('batch_no');

      final grouped = <String, List<BatchStatus>>{};
      for (final row in rows) {
        final batch = BatchStatus.fromJson(row);
        (grouped[batch.productId] ??= <BatchStatus>[]).add(batch);
      }
      return grouped;
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the batches for those products.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the batches for those products.',
        cause: error,
      );
    }
  }

  /// The `product_stock` row for [productId], or `null` when the view has none
  /// (a product with no batches at all still has a row, so this is rare).
  Future<ProductStock?> stockFor({
    required String pharmacyId,
    required String productId,
  }) async {
    try {
      final row = await _client
          .from('product_stock')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('product_id', productId)
          .maybeSingle();
      return row == null ? null : ProductStock.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load stock for that product.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load stock for that product.',
        cause: error,
      );
    }
  }

  /// Names of [productIds], keyed by id.
  ///
  /// For screens that hold a stored product id and have to name it:
  /// `batch_status` and `sale_item` both reference a product without carrying its
  /// name, and one request per screen beats one per row. Lives here rather than in
  /// a feature because products own their names, and three features ask.
  ///
  /// Ids that cannot be read are simply absent from the result, so a caller
  /// decides what to draw for a name it does not have.
  Future<Map<String, String>> namesFor({
    required String pharmacyId,
    required List<String> productIds,
  }) async {
    if (productIds.isEmpty) {
      return const <String, String>{};
    }
    try {
      final rows = await _client
          .from('products')
          .select('id, name')
          .eq('pharmacy_id', pharmacyId)
          .inFilter('id', productIds);
      return <String, String>{
        for (final row in rows) row['id'] as String: row['name'] as String,
      };
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the product names.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the product names.',
        cause: error,
      );
    }
  }

  /// How many units each of [batchIds] holds, keyed by batch id.
  ///
  /// For the one caller that has to check availability against a set of batches
  /// it did not fetch itself: a checkout, which holds a basket of batches chosen
  /// over the previous minutes and has to refuse an out-of-stock line with a
  /// message naming the product rather than the batch's uuid.
  ///
  /// A batch that has since been deleted is simply absent, which a caller reads as
  /// zero.
  Future<Map<String, int>> batchQuantitiesFor({
    required String pharmacyId,
    required List<String> batchIds,
  }) async {
    if (batchIds.isEmpty) {
      return const <String, int>{};
    }
    try {
      final rows = await _client
          .from('product_batches')
          .select('id, qty')
          .eq('pharmacy_id', pharmacyId)
          .inFilter('id', batchIds);
      return <String, int>{
        for (final row in rows) row['id'] as String: row['qty'] as int,
      };
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to check what is left in those batches.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to check what is left in those batches.',
        cause: error,
      );
    }
  }

  /// Aliases recorded for [productId], newest first.
  Future<List<ProductAlias>> aliasesFor({
    required String pharmacyId,
    required String productId,
  }) async {
    try {
      final rows = await _client
          .from('product_aliases')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('product_id', productId)
          .order('created_at', ascending: false);
      return rows.map(ProductAlias.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the aliases for that product.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the aliases for that product.',
        cause: error,
      );
    }
  }

  /// Records that supplier-invoice text [rawName] means [productId].
  ///
  /// `normalized_name` is NOT sent: the database's own `normalize_product_name()` computes it
  /// inside `save_product()`, which is the function the GIN trigram index and the matching engine
  /// both run against - so there is one normalization rather than a copy of it here.
  ///
  /// Re-adding text that already exists re-points the alias at [productId] instead of failing,
  /// which is what the unique key on (pharmacy_id, supplier_id, normalized_name) is for - including
  /// when [supplierId] is null, because that key is NULLS NOT DISTINCT (migration 20260919000030,
  /// which closed N-5).
  ///
  /// For anybody but the owner this is a `product_edit` REQUEST carrying the alias, and nothing is
  /// recorded until the owner answers.
  Future<WriteOutcome<ProductAlias>> addAlias({
    required String productId,
    required String rawName,
    String? supplierId,
  }) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) {
      throw const ValidationException(message: 'Enter the invoice text first.');
    }

    return _write(
      payload: ProductPayload.alias(
        productId: productId,
        rawName: trimmed,
        supplierId: supplierId,
      ),
      fallbackMessage: 'Unable to save that alias.',
      uniqueViolationMessage: 'That alias is already recorded.',
      decode: ProductAlias.fromJson,
    );
  }

  /// Removes one alias from a product.
  ///
  /// The product is named as well as the alias, because the document the owner reads - and the
  /// server's own shape check - wants both: an alias id alone would not say whose alias it is.
  Future<WriteOutcome<ProductAlias>> removeAlias({
    required String productId,
    required String aliasId,
  }) => _write(
    payload: ProductPayload.removeAlias(productId: productId, aliasId: aliasId),
    fallbackMessage: 'Unable to remove that alias.',
    decode: ProductAlias.fromJson,
  );

  /// Runs one `save_product()` call and reads the envelope it answers with.
  ///
  /// One helper for five writes on purpose: they are one door on the server, so a second client-side
  /// shape for them would be the second mechanism this module keeps refusing to grow.
  Future<WriteOutcome<T>> _write<T>({
    required Map<String, dynamic> payload,
    required String fallbackMessage,
    required T Function(Map<String, dynamic>) decode,
    String? uniqueViolationMessage,
  }) async {
    try {
      final answer = await _client.rpc<dynamic>(
        'save_product',
        params: <String, dynamic>{'p_payload': payload},
      );

      return WriteOutcome.fromJson(answer as Map<String, dynamic>, decode);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: fallbackMessage,
        uniqueViolationMessage: uniqueViolationMessage,
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(message: fallbackMessage, cause: error);
    }
  }
}
