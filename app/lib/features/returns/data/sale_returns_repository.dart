/// Supabase-backed repository for sale returns.
///
/// The mirror of the purchase side, with three differences the schema decides:
///
///  * **restock is the caller's choice per return**, not a per-line one:
///    `sale_returns.restock` decides whether every line goes back on the shelf, and
///    `stock_restore_on_sale_return()` reads it. Damaged goods come back to the
///    paperwork but not the shelf.
///  * **nothing can be oversold on a restock** - an increment cannot fail - so the
///    only limit here is that a customer cannot be refunded more units of a line
///    than they bought, which is answered from the returns already raised against
///    that sale.
///  * the credit note posts itself: `ledger_auto_entry_sale_return()` writes the
///    customer's credit from `grand_total`.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_item.dart';
import 'package:app/data/models/sale_return.dart';
import 'package:app/features/returns/data/sale_return_totals.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'sale_returns_repository.g.dart';

/// Exposes the single [SaleReturnsRepository].
@riverpod
SaleReturnsRepository saleReturnsRepository(Ref ref) =>
    SaleReturnsRepository(ref.watch(supabaseClientProvider));

/// One sold line, and how much of it can still come back.
///
/// Carries no product name: naming a product is the products repository's job
/// (`ProductsRepository.namesFor`), and the form's controller joins the two rather
/// than this repository reading a table it does not own.
class SaleReturnableLine {
  /// Creates a returnable line.
  const SaleReturnableLine({required this.item, required this.alreadyReturned});

  /// The sold line.
  final SaleItem item;

  /// Units of this line that have already come back.
  final int alreadyReturned;

  /// Units that may still come back.
  int get returnable {
    final remaining = item.qty - alreadyReturned;
    return remaining <= 0 ? 0 : remaining;
  }

  /// Whether anything can be returned from this line.
  bool get canReturn => blockedReason == null;

  /// Why nothing can be returned, or `null` when something can.
  String? get blockedReason {
    if (item.qty - alreadyReturned <= 0) {
      return 'All ${item.qty} units of this line have already come back.';
    }
    if (item.batchId.isEmpty) {
      return 'This line has no batch recorded, so a restock has nowhere to go.';
    }
    return null;
  }
}

/// Data access for `sale_returns` and `sale_return_items`.
class SaleReturnsRepository {
  /// Creates a repository backed by the shared Supabase client.
  SaleReturnsRepository(this._client);

  final sb.SupabaseClient _client;

  /// Rows fetched per page by the returns list.
  static const int pageSize = 50;

  /// Loads one page of sale returns, newest first.
  Future<List<SaleReturn>> list({
    required String pharmacyId,
    int limit = pageSize,
    int offset = 0,
  }) async {
    try {
      final rows = await _client
          .from('sale_returns')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .order('return_date', ascending: false)
          .range(offset, offset + limit - 1);
      return rows.map(SaleReturn.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the sale returns.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the sale returns.',
        cause: error,
      );
    }
  }

  /// Loads one sale return, or `null` when it does not exist.
  Future<SaleReturn?> byId({
    required String pharmacyId,
    required String returnId,
  }) async {
    try {
      final row = await _client
          .from('sale_returns')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('id', returnId)
          .maybeSingle();
      return row == null ? null : SaleReturn.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load that sale return.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load that sale return.',
        cause: error,
      );
    }
  }

  /// The lines of [returnId], in insertion order.
  Future<List<SaleReturnItem>> itemsFor({
    required String pharmacyId,
    required String returnId,
  }) async {
    try {
      final rows = await _client
          .from('sale_return_items')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('sale_return_id', returnId)
          .order('created_at');
      return rows.map(SaleReturnItem.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the lines of that return.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the lines of that return.',
        cause: error,
      );
    }
  }

  /// The lines of [saleId], with how much of each can still come back.
  Future<List<SaleReturnableLine>> returnableFor({
    required String pharmacyId,
    required String saleId,
  }) async {
    try {
      final itemRows = await _client
          .from('sale_items')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('sale_id', saleId)
          .order('created_at');
      final items = itemRows.map(SaleItem.fromJson).toList(growable: false);
      if (items.isEmpty) {
        return const <SaleReturnableLine>[];
      }

      final returned = await _returnedQuantities(
        pharmacyId: pharmacyId,
        saleId: saleId,
      );

      return items
          .map(
            (item) => SaleReturnableLine(
              item: item,
              alreadyReturned: returned[item.id] ?? 0,
            ),
          )
          .toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load what can be returned from that sale.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load what can be returned from that sale.',
        cause: error,
      );
    }
  }

  /// Records a return of [quantities] units, keyed by sale-item id.
  ///
  /// [quantities] carries only the lines coming back, so an absent entry means
  /// "this one stays". The amounts are derived here from the sale line's own stored
  /// figures (`SaleReturnTotals`), and the limit from [returnableFor], so a form
  /// cannot refund more than was bought.
  ///
  /// **Two statements, not one.** The header is written first, because the lines
  /// reference it, and the lines are one INSERT - which Postgres applies atomically,
  /// so every restock happens together or none of them does. A refused set can
  /// therefore leave a header with no lines, deliberately not deleted: the same
  /// reasoning as the purchase side, where an insert that reached the database but
  /// whose response was lost is indistinguishable from one that never ran.
  Future<SaleReturn> create({
    required String pharmacyId,
    required String saleId,
    required DateTime returnDate,
    required Map<String, int> quantities,
    required bool restock,
    required PaymentMode refundMode,
    String? reason,
  }) async {
    final requested = Map<String, int>.fromEntries(
      quantities.entries.where((entry) => entry.value > 0),
    );
    if (requested.isEmpty) {
      throw const ValidationException(
        message: 'Enter how many units are coming back.',
      );
    }

    final sale = await _saleFor(pharmacyId: pharmacyId, saleId: saleId);
    if (sale.status == SaleStatus.cancelled) {
      throw const ValidationException(
        message: 'That sale was cancelled, so nothing can come back from it.',
      );
    }

    final lines = await returnableFor(pharmacyId: pharmacyId, saleId: saleId);
    final byItemId = <String, SaleReturnableLine>{
      for (final line in lines) line.item.id: line,
    };

    final amounts = <SaleReturnLineAmounts>[];
    final payloads = <Map<String, dynamic>>[];
    for (final entry in requested.entries) {
      final line = byItemId[entry.key];
      if (line == null) {
        throw const ValidationException(
          message: 'That sale no longer has the line being returned.',
        );
      }
      final blocked = line.blockedReason;
      if (blocked != null) {
        throw ValidationException(message: blocked);
      }
      if (entry.value > line.returnable) {
        throw ValidationException(
          message:
              'Only ${line.returnable} '
              '${line.returnable == 1 ? 'unit' : 'units'} of that line '
              'can still come back.',
        );
      }

      final lineAmounts = SaleReturnTotals.forLine(
        item: line.item,
        qty: entry.value,
      );
      amounts.add(lineAmounts);
      payloads.add(<String, dynamic>{
        'sale_item_id': line.item.id,
        'product_id': line.item.productId,
        // Only a restock needs the batch; a write-off still records it, so the
        // return line and the sale line can be read side by side.
        'batch_id': line.item.batchId,
        'qty': entry.value,
        'rate': line.item.rate,
        'gst_percent': line.item.gstPercent,
        'tax_amount': lineAmounts.tax,
        'total_amount': lineAmounts.total,
      });
    }

    final totals = SaleReturnTotals.forLines(amounts);

    try {
      final headerRow = await _client
          .from('sale_returns')
          .insert(<String, dynamic>{
            'pharmacy_id': pharmacyId,
            'sale_id': saleId,
            'customer_id': sale.customerId,
            'return_date': Formatters.dateIso(returnDate),
            'reason': _trimmedOrNull(reason),
            'refund_mode': refundMode.dbValue,
            'restock': restock,
            'sub_total': totals.subTotal,
            'tax_total': totals.taxTotal,
            'grand_total': totals.grandTotal,
          })
          .select()
          .single();
      final returnId = headerRow['id'] as String;

      await _client.from('sale_return_items').insert(<Map<String, dynamic>>[
        for (final payload in payloads)
          <String, dynamic>{
            ...payload,
            'pharmacy_id': pharmacyId,
            'sale_return_id': returnId,
          },
      ]);

      return SaleReturn.fromJson(headerRow);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to record that sale return.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to record that sale return.',
        cause: error,
      );
    }
  }

  /// The sale a return is being raised against.
  Future<Sale> _saleFor({
    required String pharmacyId,
    required String saleId,
  }) async {
    final row = await _client
        .from('sales')
        .select()
        .eq('pharmacy_id', pharmacyId)
        .eq('id', saleId)
        .maybeSingle();
    if (row == null) {
      throw const NotFoundException(message: 'That sale no longer exists.');
    }
    return Sale.fromJson(row);
  }

  /// How many units of each of [saleId]'s lines have already come back.
  Future<Map<String, int>> _returnedQuantities({
    required String pharmacyId,
    required String saleId,
  }) async {
    final returnRows = await _client
        .from('sale_returns')
        .select('id')
        .eq('pharmacy_id', pharmacyId)
        .eq('sale_id', saleId);
    final returnIds = returnRows
        .map((row) => row['id'] as String)
        .toList(growable: false);
    if (returnIds.isEmpty) {
      return const <String, int>{};
    }

    final rows = await _client
        .from('sale_return_items')
        .select('sale_item_id, qty')
        .eq('pharmacy_id', pharmacyId)
        .inFilter('sale_return_id', returnIds);

    final returned = <String, int>{};
    for (final row in rows) {
      final itemId = row['sale_item_id'] as String?;
      if (itemId == null) {
        // `sale_item_id` has `on delete set null`: a line whose sale line was
        // removed reports nothing rather than being counted against a line that is
        // no longer there.
        continue;
      }
      returned.update(
        itemId,
        (qty) => qty + (row['qty'] as int),
        ifAbsent: () => row['qty'] as int,
      );
    }
    return returned;
  }
}

/// The trimmed text of [raw], or `null` when it holds nothing.
String? _trimmedOrNull(String? raw) {
  final value = raw?.trim();
  return value == null || value.isEmpty ? null : value;
}
