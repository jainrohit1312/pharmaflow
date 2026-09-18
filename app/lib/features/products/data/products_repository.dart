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
  const ProductsQuery({this.search = '', this.scheduleType, this.isActive});

  /// Free-text term matched against name, generic name and barcode.
  final String search;

  /// Restrict to one statutory schedule.
  final ScheduleType? scheduleType;

  /// Restrict to active or inactive products; `null` means both.
  final bool? isActive;

  /// Whether anything is actually being filtered out.
  ///
  /// Lets a screen distinguish "the catalogue is empty" from "your search
  /// matched nothing", which need different copy and different actions.
  bool get isFiltered =>
      search.isNotEmpty || scheduleType != null || isActive != null;

  /// A copy with the search term replaced.
  ProductsQuery withSearch(String value) => ProductsQuery(
    search: value,
    scheduleType: scheduleType,
    isActive: isActive,
  );

  /// A copy with the schedule filter replaced (`null` clears it).
  ProductsQuery withSchedule(ScheduleType? value) =>
      ProductsQuery(search: search, scheduleType: value, isActive: isActive);

  /// A copy with the active filter replaced (`null` clears it).
  ///
  /// Named for the same reason as the list controller's setter: the argument is
  /// tri-state, and a positional `withActive(false)` does not say whether it
  /// means "inactive only" or "clear the filter".
  ProductsQuery withActive({required bool? value}) => ProductsQuery(
    search: search,
    scheduleType: scheduleType,
    isActive: value,
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
          .select()
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
          .select()
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

  /// Inserts a new product owned by [pharmacyId].
  Future<Product> create({
    required String pharmacyId,
    required ProductDraft draft,
  }) async {
    try {
      final row = await _client
          .from('products')
          .insert(<String, dynamic>{
            ...draft.toJson(),
            'pharmacy_id': pharmacyId,
          })
          .select()
          .single();
      return Product.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to save that product.',
        uniqueViolationMessage: 'A product with those details already exists.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to save that product.',
        cause: error,
      );
    }
  }

  /// Overwrites the writable columns of an existing product.
  Future<Product> update({
    required String pharmacyId,
    required String productId,
    required ProductDraft draft,
  }) async {
    try {
      final row = await _client
          .from('products')
          .update(draft.toJson())
          .eq('pharmacy_id', pharmacyId)
          .eq('id', productId)
          .select()
          .single();
      return Product.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to save that product.',
        uniqueViolationMessage: 'A product with those details already exists.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to save that product.',
        cause: error,
      );
    }
  }

  /// Enables or disables a product.
  ///
  /// Deactivation is the supported "delete": a product that has ever been
  /// purchased or dispensed is referenced by history, so removing the row would
  /// cascade into its batches and detach its purchase lines.
  Future<void> setActive({
    required String pharmacyId,
    required String productId,
    required bool isActive,
  }) async {
    try {
      await _client
          .from('products')
          .update(<String, dynamic>{'is_active': isActive})
          .eq('pharmacy_id', pharmacyId)
          .eq('id', productId);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to update that product.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to update that product.',
        cause: error,
      );
    }
  }

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
  /// `normalized_name` comes from the database's own `normalize_product_name()`
  /// rather than being reimplemented here, because that is the function the GIN
  /// trigram index and (in Phase 5) the matching engine both run against.
  ///
  /// Re-adding text that already exists re-points the alias at [productId]
  /// instead of failing, which is what the unique key on
  /// (pharmacy_id, supplier_id, normalized_name) is for.
  Future<ProductAlias> addAlias({
    required String pharmacyId,
    required String productId,
    required String rawName,
    String? supplierId,
  }) async {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) {
      throw const ValidationException(message: 'Enter the invoice text first.');
    }

    try {
      final normalized = await _client.rpc<String>(
        'normalize_product_name',
        params: <String, dynamic>{'p_input': trimmed},
      );
      if (normalized.trim().isEmpty) {
        throw const ValidationException(
          message: 'That alias needs at least one letter or digit.',
        );
      }

      final row = await _client
          .from('product_aliases')
          .upsert(<String, dynamic>{
            'pharmacy_id': pharmacyId,
            'product_id': productId,
            'raw_name': trimmed,
            'normalized_name': normalized,
            'supplier_id': supplierId,
          }, onConflict: 'pharmacy_id,supplier_id,normalized_name')
          .select()
          .single();
      return ProductAlias.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to save that alias.',
        uniqueViolationMessage: 'That alias is already recorded.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to save that alias.',
        cause: error,
      );
    }
  }

  /// Removes an alias.
  Future<void> removeAlias({
    required String pharmacyId,
    required String aliasId,
  }) async {
    try {
      await _client
          .from('product_aliases')
          .delete()
          .eq('pharmacy_id', pharmacyId)
          .eq('id', aliasId);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to remove that alias.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to remove that alias.',
        cause: error,
      );
    }
  }
}
