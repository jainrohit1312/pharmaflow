/// Supabase-backed repository for sales.
///
/// The write is one RPC (`checkout_sale`, migration 20260918000019) rather than
/// the header-then-lines sequence the purchase side uses, and that is the point:
/// a sale's stock posts as each line is inserted, so a refused line in a
/// multi-statement write would leave some units taken, some not, and a header
/// that had already posted a customer receivable. Inside the function it is one
/// transaction, and a sale either exists in full or does not exist at all.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/postgrest_search.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_item.dart';
import 'package:app/features/sales/data/sale_checkout.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'sales_repository.g.dart';

/// Exposes the single [SalesRepository].
@riverpod
SalesRepository salesRepository(Ref ref) =>
    SalesRepository(ref.watch(supabaseClientProvider));

/// What a sale list may filter on.
///
/// Immutable, mutated only through the `with…` helpers, so a filter change is a
/// new value rather than an edit Riverpod could miss.
class SalesQuery {
  /// Creates a query; the defaults mean "everything, newest first".
  const SalesQuery({this.search = '', this.status, this.from, this.to});

  /// Free-text term matched against the invoice number.
  final String search;

  /// Restrict to one document status.
  final SaleStatus? status;

  /// Earliest sale date to include.
  final DateTime? from;

  /// Latest sale date to include.
  final DateTime? to;

  /// Whether anything is actually being filtered out.
  bool get isFiltered =>
      search.isNotEmpty || status != null || from != null || to != null;

  /// A copy with the search term replaced.
  SalesQuery withSearch(String value) =>
      SalesQuery(search: value, status: status, from: from, to: to);

  /// A copy with the status filter replaced (`null` clears it).
  SalesQuery withStatus(SaleStatus? value) =>
      SalesQuery(search: search, status: value, from: from, to: to);

  /// A copy with the sale-date window replaced.
  SalesQuery withDateRange({DateTime? from, DateTime? to}) =>
      SalesQuery(search: search, status: status, from: from, to: to);
}

/// Data access for `sales` and `sale_items`.
class SalesRepository {
  /// Creates a repository backed by the shared Supabase client.
  SalesRepository(this._client);

  final sb.SupabaseClient _client;

  /// Rows fetched per page by the list screen.
  static const int pageSize = 50;

  /// Columns the free-text search looks at.
  ///
  /// The invoice number only. Notes do not exist on a sale, and `place_of_supply`
  /// is a state name rather than something anyone searches by.
  static const List<String> searchColumns = <String>['invoice_no'];

  /// Loads one page of sales matching [query], newest first.
  Future<List<Sale>> list({
    required String pharmacyId,
    required SalesQuery query,
    int limit = pageSize,
    int offset = 0,
  }) async {
    try {
      var request = _client
          .from('sales')
          .select()
          .eq('pharmacy_id', pharmacyId);

      final search = buildIlikeOrFilter(
        columns: searchColumns,
        term: query.search,
      );
      if (search != null) {
        request = request.or(search);
      }
      final status = query.status;
      if (status != null) {
        request = request.eq('status', status.dbValue);
      }
      final from = query.from;
      if (from != null) {
        request = request.gte('sale_date', Formatters.dateIso(from));
      }
      final to = query.to;
      if (to != null) {
        // A sale_date is a timestamp, so an upper bound has to reach the end of
        // the day: `lte midnight` would drop everything sold today.
        request = request.lt(
          'sale_date',
          '${Formatters.dateIso(to)}T23:59:59.999',
        );
      }

      final rows = await request
          .order('sale_date', ascending: false)
          .range(offset, offset + limit - 1);
      return rows.map(Sale.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the sales list.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the sales list.',
        cause: error,
      );
    }
  }

  /// Loads one sale, or `null` when it does not exist.
  Future<Sale?> byId({
    required String pharmacyId,
    required String saleId,
  }) async {
    try {
      final row = await _client
          .from('sales')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('id', saleId)
          .maybeSingle();
      return row == null ? null : Sale.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load that sale.',
      );
    } on Object catch (error) {
      throw ServerException(message: 'Unable to load that sale.', cause: error);
    }
  }

  /// The lines of [saleId], in insertion order.
  Future<List<SaleItem>> itemsFor({
    required String pharmacyId,
    required String saleId,
  }) async {
    try {
      final rows = await _client
          .from('sale_items')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('sale_id', saleId)
          .order('created_at');
      return rows.map(SaleItem.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the lines of that sale.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the lines of that sale.',
        cause: error,
      );
    }
  }

  /// Writes a sale and its lines, and returns the stored document.
  ///
  /// [checkout] carries the line money, computed by `SaleTotals` - the same
  /// helper the screen that showed it used. The document totals are not sent: the
  /// function sums the lines itself, so a stored grand total cannot disagree with
  /// the lines it describes.
  ///
  /// A failure here leaves nothing behind. In particular an out-of-stock line
  /// surfaces the stock trigger's own `check_violation` (naming the batch), and
  /// the whole sale is rolled back with it, which is why the counter checks
  /// availability before calling this rather than relying on the refusal.
  Future<Sale> checkout({
    required String pharmacyId,
    required SaleCheckout checkout,
  }) async {
    if (checkout.lines.isEmpty) {
      throw const ValidationException(
        message: 'Add at least one line before taking payment.',
      );
    }

    try {
      final response = await _client.rpc<dynamic>(
        'checkout_sale',
        params: <String, dynamic>{'p_payload': checkout.toPayload()},
      );
      // PostgREST returns a composite-returning function as one JSON object; a
      // `setof` would arrive as a list. The function returns a single row, so the
      // list branch is tolerance for a shape difference rather than a case the
      // function can produce.
      final row = switch (response) {
        final List<dynamic> rows when rows.isNotEmpty =>
          (rows.first as Map).cast<String, dynamic>(),
        final Map<dynamic, dynamic> map => map.cast<String, dynamic>(),
        _ => throw const ServerException(
          message: 'The till did not return the sale it wrote.',
        ),
      };
      return Sale.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to record that sale.',
        uniqueViolationMessage:
            'That invoice number has already been used. Try again.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to record that sale.',
        cause: error,
      );
    }
  }
}
