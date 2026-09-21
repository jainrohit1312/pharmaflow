/// Supabase-backed repository for the cross-product stock views and manual
/// stock corrections.
///
/// Two repositories read the same two views, and the split is by question
/// rather than by table: `ProductsRepository` answers "what about *this*
/// product" (its batches in FEFO order, its stock row) for the product detail
/// screen, while this one answers "what about the whole pharmacy" (what is on
/// hand, what is below its reorder level, what is expiring), which is what the
/// inventory screens ask. `product_stock` in particular is the same view either
/// way; asking it once per screen keeps the answer consistent.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/postgrest_search.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/alert_payloads.dart';
import 'package:app/data/models/batch_status.dart';
import 'package:app/data/models/product_stock.dart';
import 'package:app/data/models/stock_adjustment.dart';
import 'package:app/data/models/write_outcome.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'inventory_repository.g.dart';

/// Exposes the single [InventoryRepository].
@riverpod
InventoryRepository inventoryRepository(Ref ref) =>
    InventoryRepository(ref.watch(supabaseClientProvider));

/// Which side of zero stock the list is showing.
enum StockAvailability {
  /// Everything, in stock or not.
  all,

  /// Only rows with something on hand.
  inStock,

  /// Only rows with nothing on hand.
  outOfStock,
}

/// What the stock list may filter on.
///
/// Immutable, mutated only through the `with…` helpers, so a filter change is a
/// new value rather than an edit Riverpod could miss.
class StockQuery {
  /// Creates a query; the defaults mean "everything, by name".
  const StockQuery({
    this.search = '',
    this.availability = StockAvailability.all,
  });

  /// Free-text term matched against name, generic name and brand.
  final String search;

  /// Which side of zero stock to show.
  final StockAvailability availability;

  /// Whether anything is actually being filtered out.
  bool get isFiltered =>
      search.isNotEmpty || availability != StockAvailability.all;

  /// A copy with the search term replaced.
  StockQuery withSearch(String value) =>
      StockQuery(search: value, availability: availability);

  /// A copy with the availability filter replaced.
  StockQuery withAvailability(StockAvailability value) =>
      StockQuery(search: search, availability: value);
}

/// Data access for `product_stock`, `batch_status`, the product names those
/// views do not carry, and the `stock_adjustments` write.
class InventoryRepository {
  /// Creates a repository backed by the shared Supabase client.
  InventoryRepository(this._client);

  final sb.SupabaseClient _client;

  /// Rows fetched per page by the stock list.
  static const int pageSize = 50;

  /// Columns the stock list's free-text search looks at.
  static const List<String> searchColumns = <String>[
    'name',
    'generic_name',
    'brand',
  ];

  /// How many reorder alerts one read asks for.
  ///
  /// 200 is the server's own ceiling - `low_stock_products` clamps `p_limit`
  /// into `1..200` - so one read is the whole list rather than a page of it,
  /// and a pharmacy past that has a problem a list will not solve. There is no
  /// bound the screen can silently fall off the end of any more: that was the
  /// scan limit this replaced (I-1).
  static const int lowStockLimit = 200;

  /// How many batches one expiry read will look at.
  ///
  /// An expiry bucket is bounded by its nature (batches within 90 days of
  /// expiring), and the calendar is bounded by a month, so this is a safety net
  /// rather than a page size.
  static const int batchScanLimit = 1000;

  /// Loads one page of the stock rollup matching [query], ordered by name.
  Future<List<ProductStock>> stockList({
    required String pharmacyId,
    required StockQuery query,
    int limit = pageSize,
    int offset = 0,
  }) async {
    try {
      var request = _client
          .from('product_stock')
          .select()
          .eq('pharmacy_id', pharmacyId);

      final search = buildIlikeOrFilter(
        columns: searchColumns,
        term: query.search,
      );
      if (search != null) {
        request = request.or(search);
      }
      request = switch (query.availability) {
        StockAvailability.all => request,
        StockAvailability.inStock => request.gt('total_qty', 0),
        StockAvailability.outOfStock => request.lte('total_qty', 0),
      };

      final rows = await request
          .order('name')
          .range(offset, offset + limit - 1);
      return rows.map(ProductStock.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the stock list.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the stock list.',
        cause: error,
      );
    }
  }

  /// Products below the level they are meant to keep, worst shortfall first.
  ///
  /// The ordering is the point of this list: a pharmacist reading it is
  /// deciding what to reorder, so the product furthest below its level leads -
  /// and the answer carries the shortfall, so the list can say how many units
  /// close the gap rather than only what is low.
  ///
  /// One round trip to `low_stock_products()` (migration 20260919000027), the
  /// same RPC the notifications list and the chatbot read (D-047): the
  /// comparison PostgREST cannot express, the order and the shortfall all
  /// arrive decided, so nothing here scans a page and compares two columns in
  /// Dart (I-1).
  ///
  /// [pharmacyId] is deliberately **not** sent - the RPC takes the tenant from
  /// the caller's own JWT (`get_my_pharmacy_id()`, D-004), which is what keeps
  /// the tenant out of the request body. The argument stays in the signature
  /// because every read on this repository is scoped by its caller the same
  /// way, and the provider that calls it still waits for the scope to be known
  /// before asking: a tab that answered "nothing is low" while the profile was
  /// still loading would be T-5's mistake in a new place.
  Future<List<LowStockProduct>> lowStock({required String pharmacyId}) async {
    try {
      final data = await _client.rpc<dynamic>(
        'low_stock_products',
        params: <String, dynamic>{'p_limit': lowStockLimit},
      );
      return lowStockProductsFrom(data);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the low-stock list.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the low-stock list.',
        cause: error,
      );
    }
  }

  /// Batches in [statuses] that still hold stock, soonest expiry first.
  ///
  /// The bucket is the database's own (`batch_status.expiry_status`), evaluated
  /// against its today, so the screen and the query cannot disagree about which
  /// side of the 30/90 day line a batch sits on.
  Future<List<BatchStatus>> expiringBatches({
    required String pharmacyId,
    required Set<ExpiryStatus> statuses,
  }) async {
    if (statuses.isEmpty) {
      return const <BatchStatus>[];
    }
    try {
      final rows = await _client
          .from('batch_status')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .inFilter(
            'expiry_status',
            statuses.map((status) => status.dbValue).toList(growable: false),
          )
          // A batch with nothing left cannot expire into anything: writing the
          // last unit off is the stock adjustment's job, not this list's.
          .gt('qty', 0)
          .order('expiry_date')
          .order('batch_no')
          .limit(batchScanLimit);
      return rows.map(BatchStatus.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the expiry list.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the expiry list.',
        cause: error,
      );
    }
  }

  /// Batches holding stock whose expiry falls within [from] and [to].
  ///
  /// The calendar asks for one month at a time rather than for every batch in
  /// the pharmacy: the answer it needs is bounded by the month on screen, and
  /// reading a year of history to draw a grid would get slower every month the
  /// pharmacy trades.
  Future<List<BatchStatus>> batchesExpiringBetween({
    required String pharmacyId,
    required DateTime from,
    required DateTime to,
  }) async {
    try {
      final rows = await _client
          .from('batch_status')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .gt('qty', 0)
          .gte('expiry_date', Formatters.dateIso(from))
          .lte('expiry_date', Formatters.dateIso(to))
          .order('expiry_date')
          .order('batch_no')
          .limit(batchScanLimit);
      return rows.map(BatchStatus.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load that month of expiries.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load that month of expiries.',
        cause: error,
      );
    }
  }

  /// Records a manual stock correction.
  ///
  /// **The write is a request for anybody but the owner** (Phase 6.5c), and
  /// `record_stock_adjustment()` decides which: the owner's correction is written and comes
  /// back `recorded`, and anybody else's is raised as an approval request with **nothing
  /// written and no stock moved**. The answer says which, so the caller reports the
  /// correction or says where the work went.
  ///
  /// When it is written, the row is the whole write: `stock_apply_adjustment()` moves the
  /// batch in the same transaction and raises `check_violation` when a decrease would take
  /// the batch below zero, so a failure means nothing moved. That error is deliberately left
  /// to [mapPostgrestException], which surfaces the database's own message ("would take batch
  /// … below zero") rather than inventing a vaguer one - and when the write is a REQUEST the
  /// same sentence is what the owner meets if he approves a correction the stock cannot take.
  Future<WriteOutcome<StockAdjustment>> adjustStock({
    required String pharmacyId,
    required String productId,
    required AdjustmentType type,
    required int qty,
    String? batchId,
    String? reason,
  }) async {
    if (qty <= 0) {
      throw const ValidationException(
        message: 'Enter how many units to adjust by.',
      );
    }

    try {
      final answer = await _client.rpc<dynamic>(
        'record_stock_adjustment',
        params: <String, dynamic>{
          'p_payload': <String, dynamic>{
            'product_id': productId,
            'batch_id': batchId,
            'adjustment_type': type.dbValue,
            'qty': qty,
            'reason': _trimmedOrNull(reason),
          },
        },
      );

      return WriteOutcome.fromJson(
        answer as Map<String, dynamic>,
        StockAdjustment.fromJson,
      );
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to record that stock adjustment.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to record that stock adjustment.',
        cause: error,
      );
    }
  }
}

/// The trimmed text of [raw], or `null` when it holds nothing.
///
/// Empty strings are sent as null so the column is cleared rather than set to
/// `''`, which would read differently from "no reason given".
String? _trimmedOrNull(String? raw) {
  final value = raw?.trim();
  return value == null || value.isEmpty ? null : value;
}
