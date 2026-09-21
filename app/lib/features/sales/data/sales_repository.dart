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

/// One line of a sale document, as `sale_document()` returns it.
///
/// The batch detail is carried **beside** the stored `sale_items` row rather than
/// merged into [SaleItem]: `batch_no`, `expiry_date` and `is_unknown_batch` are
/// columns of `product_batches`, not of the line, and a `SaleItem` that grew three
/// fields no table has would be a model of nothing.
class SaleDocumentLine {
  /// Creates a document line.
  const SaleDocumentLine({
    required this.item,
    required this.batchNo,
    required this.expiryDate,
    required this.isUnknownBatch,
  });

  /// Decodes one element of `sale_document()`'s `lines` array.
  factory SaleDocumentLine.fromJson(Map<String, dynamic> json) {
    final item = json['item'];
    return SaleDocumentLine(
      item: SaleItem.fromJson((item as Map).cast<String, dynamic>()),
      batchNo: json['batch_no'] as String? ?? '',
      expiryDate: parseDateOrNull(json['expiry_date']),
      isUnknownBatch: json['is_unknown_batch'] as bool? ?? false,
    );
  }

  /// The stored sale line.
  final SaleItem item;

  /// The number of the pack it came out of.
  final String batchNo;

  /// When that pack expires, or `null` when nobody recorded it.
  final DateTime? expiryDate;

  /// Whether the batch number itself is unknown.
  ///
  /// `product_batches.batch_no` is `not null` (00004), so an opening-stock row whose
  /// source had no number carries an empty string *and* this flag. The two together
  /// are what "no batch number" means, and a receipt prints an em dash for it rather
  /// than the blank.
  final bool isUnknownBatch;

  /// Whether there is a batch number worth printing.
  bool get hasKnownBatch => !isUnknownBatch && batchNo.trim().isNotEmpty;

  /// Whether the pack's expiry was recorded at all.
  ///
  /// The question to ask, rather than reading [expiryDate] as "not expired": 145 of
  /// the owner's opening-stock batches carry no date, so this is the common case
  /// here rather than a corner.
  bool get hasKnownExpiry => expiryDate != null;
}

/// One sale as the receipt prints it: the document, its lines and the patient's code.
///
/// The shape `sale_document()` returns (migration `20260920000039`), read in **one**
/// round trip so a receipt cannot be assembled from two reads that disagree. It
/// carries no product names - the function returns the stored rows and nothing else -
/// so a screen still resolves those separately.
class SaleDocument {
  /// Creates a document.
  const SaleDocument({
    required this.sale,
    required this.patientCode,
    required this.lines,
  });

  /// Decodes the object `sale_document()` returns.
  factory SaleDocument.fromJson(Map<String, dynamic> json) {
    final sale = json['sale'];
    final lines = json['lines'];
    return SaleDocument(
      sale: Sale.fromJson((sale as Map).cast<String, dynamic>()),
      patientCode: json['patient_code'] as String?,
      lines: <SaleDocumentLine>[
        if (lines is List)
          for (final line in lines)
            SaleDocumentLine.fromJson((line as Map).cast<String, dynamic>()),
      ],
    );
  }

  /// The sale's own stored row.
  final Sale sale;

  /// The patient's code, or `null` when the party has none.
  ///
  /// Joined from `customers` on `sales.customer_id`, so a counter or an IPD sale
  /// answers the patient's own code, while a **package** sale answers none: its party
  /// is the hospital's account row, and the patient on such a bill is the sale's own
  /// name-and-mobile snapshot with no patient row of their own. A customer registered
  /// before Phase 7a has none either, until `save_patient()` first touches them
  /// (D-074, D-079). A receipt prints a dash rather than a fabricated code.
  final String? patientCode;

  /// Its lines, in insertion order.
  final List<SaleDocumentLine> lines;
}

/// Parses a Postgres `date` (or `timestamp`) into a [DateTime], or `null`.
///
/// Tolerant on purpose: `expiry_date` is nullable and a batch whose source had no date
/// is a real row, so an absent or unparseable value is an answer rather than an error.
DateTime? parseDateOrNull(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return DateTime.tryParse(value);
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

  /// One sale as the receipt prints it, or `null` when it is not in this pharmacy.
  ///
  /// One RPC, because the per-line batch and expiry are not on the sale: `sale_items`
  /// records `batch_id` alone, and the client must not join `sale_items` to
  /// `product_batches` itself (D-079) - a mis-join there would print one pack's number
  /// and date against another pack's line, on a document a customer keeps.
  ///
  /// **No `pharmacyId` argument**, unlike every other read here: `sale_document()`
  /// derives the tenant from `get_my_pharmacy_id()` and is `security invoker`, so the
  /// caller's own RLS applies on top of that guard. A tenant filter sent from the
  /// client would be ignored by the function, and one ignored parameter is worse than
  /// none. An id outside the caller's pharmacy answers `null` rather than someone
  /// else's document.
  Future<SaleDocument?> saleDocument({required String saleId}) async {
    try {
      final response = await _client.rpc<dynamic>(
        'sale_document',
        params: <String, dynamic>{'p_sale_id': saleId},
      );
      // The function returns one jsonb value rather than a set, so a `null` body is
      // how it answers "no such sale in this pharmacy" - not an empty list.
      if (response is! Map) {
        return null;
      }
      return SaleDocument.fromJson(response.cast<String, dynamic>());
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load that bill.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(message: 'Unable to load that bill.', cause: error);
    }
  }

  /// How many recent sales the "recent products" read looks back over.
  ///
  /// More than the ten products the counter wants, on purpose: the same product sold
  /// ten times running is ten sales and one product, so the scan has to look past
  /// those ten to find ten distinct products.
  static const int recentSaleScanLimit = 40;

  /// The distinct products sold most recently by [pharmacyId], newest first.
  ///
  /// Two reads - the last few sales, then their lines - because `sales` carries no
  /// product and its lines are the only place one is named. A cancelled sale is
  /// skipped: it was never sold.
  Future<List<String>> recentlySoldProductIds({
    required String pharmacyId,
    int limit = 10,
  }) async {
    try {
      final recentSales = await _client
          .from('sales')
          .select('id')
          .eq('pharmacy_id', pharmacyId)
          .neq('status', 'cancelled')
          .order('sale_date', ascending: false)
          .limit(recentSaleScanLimit);
      if (recentSales.isEmpty) {
        return const <String>[];
      }

      final items = await _client
          .from('sale_items')
          .select('product_id, created_at')
          .eq('pharmacy_id', pharmacyId)
          .inFilter(
            'sale_id',
            recentSales
                .map((row) => row['id'] as String)
                .toList(growable: false),
          )
          .order('created_at', ascending: false);

      final seen = <String>{};
      final ordered = <String>[];
      for (final row in items) {
        final productId = row['product_id'] as String?;
        if (productId == null || !seen.add(productId)) {
          continue;
        }
        ordered.add(productId);
        if (ordered.length == limit) {
          break;
        }
      }
      return ordered;
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the recent sales.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the recent sales.',
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
