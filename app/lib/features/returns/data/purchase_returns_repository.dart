/// Supabase-backed repository for purchase returns.
///
/// A return is the only way stock leaves the pharmacy by the purchase side of
/// the ledger, and `stock_update_on_purchase_return()` is live: every item with a
/// `batch_id` decrements its batch in the same transaction and raises
/// `check_violation` rather than letting the batch go negative. Nothing here
/// reverses the receipt, and nothing touches the ledger - a purchase return is a
/// stock and paperwork event until Phase 4 owns supplier payments.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/data/models/purchase_return.dart';
import 'package:app/data/models/purchase_return_item.dart';
import 'package:app/data/models/write_outcome.dart';
import 'package:app/features/returns/data/purchase_return_totals.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'purchase_returns_repository.g.dart';

/// Exposes the single [PurchaseReturnsRepository].
@riverpod
PurchaseReturnsRepository purchaseReturnsRepository(Ref ref) =>
    PurchaseReturnsRepository(ref.watch(supabaseClientProvider));

/// One line of a received purchase, and how much of it can still go back.
///
/// The three quantities are the whole decision a return line makes:
///
///  * what the invoice billed (`item.qty`) - you cannot send back more than you
///    bought;
///  * what has already gone back, summed from this purchase's returns, because a
///    batch balance alone would allow crediting the same units twice (a batch can
///    hold stock from more than one receipt);
///  * what is in the batch right now, which is what the database will check.
///
/// The form shows [returnable] and the write enforces it, from this one value, so
/// the number on screen is the number the write will accept.
class ReturnableLine {
  /// Creates a returnable line.
  const ReturnableLine({
    required this.item,
    required this.alreadyReturned,
    required this.onHand,
  });

  /// The invoice line.
  final PurchaseItem item;

  /// Units of this line that have already been returned.
  final int alreadyReturned;

  /// Units currently in the line's batch.
  final int onHand;

  /// Units that may still go back.
  int get returnable {
    final remaining = item.qty - alreadyReturned;
    if (remaining <= 0) {
      return 0;
    }
    return remaining < onHand ? remaining : onHand;
  }

  /// Whether anything at all can be returned from this line.
  bool get canReturn => blockedReason == null;

  /// Why nothing can be returned, or `null` when something can.
  String? get blockedReason {
    if (item.batchId == null) {
      return 'This line was received without a batch, so there is nothing to '
          'take units out of.';
    }
    if (item.qty - alreadyReturned <= 0) {
      return 'All ${item.qty} units of this line have already gone back.';
    }
    if (onHand <= 0) {
      return 'The batch for this line is empty.';
    }
    return null;
  }
}

/// Data access for `purchase_returns` and `purchase_return_items`.
class PurchaseReturnsRepository {
  /// Creates a repository backed by the shared Supabase client.
  PurchaseReturnsRepository(this._client);

  final sb.SupabaseClient _client;

  /// Rows fetched per page by the returns list.
  static const int pageSize = 50;

  /// Loads one page of returns, newest return date first.
  Future<List<PurchaseReturn>> list({
    required String pharmacyId,
    int limit = pageSize,
    int offset = 0,
  }) async {
    try {
      final rows = await _client
          .from('purchase_returns')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .order('return_date', ascending: false)
          .order('created_at', ascending: false)
          .range(offset, offset + limit - 1);
      return rows.map(PurchaseReturn.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the purchase returns.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the purchase returns.',
        cause: error,
      );
    }
  }

  /// Loads one return, or `null` when it does not exist.
  Future<PurchaseReturn?> byId({
    required String pharmacyId,
    required String returnId,
  }) async {
    try {
      final row = await _client
          .from('purchase_returns')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('id', returnId)
          .maybeSingle();
      return row == null ? null : PurchaseReturn.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load that purchase return.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load that purchase return.',
        cause: error,
      );
    }
  }

  /// The lines of [returnId], in insertion order.
  Future<List<PurchaseReturnItem>> itemsFor({
    required String pharmacyId,
    required String returnId,
  }) async {
    try {
      final rows = await _client
          .from('purchase_return_items')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('purchase_return_id', returnId)
          .order('created_at');
      return rows.map(PurchaseReturnItem.fromJson).toList(growable: false);
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

  /// The lines of a received purchase, with how much of each can go back.
  ///
  /// Four reads rather than a join, because PostgREST joins are relationship
  /// shaped and none of these is one: the items, the ids of this purchase's
  /// returns, the quantities already returned, and the batches the lines point
  /// at. The alternative - trusting the caller's view of "how much is left" -
  /// is what would let a supplier be credited twice.
  Future<List<ReturnableLine>> returnableFor({
    required String pharmacyId,
    required String purchaseId,
  }) async {
    try {
      final itemRows = await _client
          .from('purchase_items')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('purchase_id', purchaseId)
          .order('created_at');
      final items = itemRows.map(PurchaseItem.fromJson).toList(growable: false);
      if (items.isEmpty) {
        return const <ReturnableLine>[];
      }

      final returned = await _returnedQuantities(
        pharmacyId: pharmacyId,
        purchaseId: purchaseId,
      );
      final onHand = await _batchQuantities(
        pharmacyId: pharmacyId,
        batchIds: items
            .map((item) => item.batchId)
            .whereType<String>()
            .toSet()
            .toList(growable: false),
      );

      return items
          .map(
            (item) => ReturnableLine(
              item: item,
              alreadyReturned: returned[item.id] ?? 0,
              onHand: onHand[item.batchId] ?? 0,
            ),
          )
          .toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage:
            'Unable to load what can be returned from that '
            'purchase.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load what can be returned from that purchase.',
        cause: error,
      );
    }
  }

  /// Records a return of [quantities] units, keyed by purchase-item id.
  ///
  /// [quantities] carries only the lines going back, so a `0` or an absent entry
  /// means "this one stays". Everything else is derived here: the amounts from
  /// the purchase line's own stored figures (see [PurchaseReturnTotals]), the
  /// supplier and the batch from the invoice line, and the limit from
  /// [returnableFor] - so a form cannot talk the write into a bigger credit than
  /// the invoice supports.
  ///
  /// **The write is a request for anybody but the owner** (Phase 6.5c), and it is
  /// `record_purchase_return()` that decides which: the owner's return is written and
  /// comes back `recorded`, and anybody else's is raised as an approval request
  /// carrying the whole document, with **nothing written at all**. The answer says
  /// which, so the caller opens the return or says where the work went.
  ///
  /// The header and its lines are one call now, which is strictly safer than the two
  /// statements this used to make: a refused line set can no longer leave a header
  /// with no lines behind it.
  Future<WriteOutcome<PurchaseReturn>> create({
    required String pharmacyId,
    required String purchaseId,
    required DateTime returnDate,
    required Map<String, int> quantities,
    String? reason,
  }) async {
    final requested = Map<String, int>.fromEntries(
      quantities.entries.where((entry) => entry.value > 0),
    );
    if (requested.isEmpty) {
      throw const ValidationException(
        message: 'Enter how many units are going back.',
      );
    }

    final purchase = await _purchaseFor(
      pharmacyId: pharmacyId,
      purchaseId: purchaseId,
    );
    if (purchase.status != PurchaseStatus.received) {
      throw ValidationException(
        message:
            'Goods can only be returned after the purchase has been received, '
            'and this one is ${purchase.status.label.toLowerCase()}.',
      );
    }

    final lines = await returnableFor(
      pharmacyId: pharmacyId,
      purchaseId: purchaseId,
    );
    final byItemId = <String, ReturnableLine>{
      for (final line in lines) line.item.id: line,
    };

    final payloads = <Map<String, dynamic>>[];
    final amounts = <PurchaseReturnLineAmounts>[];
    for (final entry in requested.entries) {
      final line = byItemId[entry.key];
      if (line == null) {
        throw const ValidationException(
          message: 'That purchase no longer has the line being returned.',
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
              '${line.returnable == 1 ? 'unit' : 'units'} of '
              '${_labelOf(line.item)} can still go back.',
        );
      }

      final lineAmounts = PurchaseReturnTotals.forLine(
        item: line.item,
        qty: entry.value,
      );
      amounts.add(lineAmounts);
      payloads.add(<String, dynamic>{
        'purchase_item_id': line.item.id,
        'product_id': line.item.productId,
        'batch_id': line.item.batchId,
        'qty': entry.value,
        'purchase_rate': line.item.purchaseRate,
        'mrp': line.item.mrp,
        'gst_percent': line.item.gstPercent,
        'tax_amount': lineAmounts.tax,
        'total_amount': lineAmounts.total,
      });
    }

    final totals = PurchaseReturnTotals.forLines(amounts);

    try {
      final answer = await _client.rpc<dynamic>(
        'record_purchase_return',
        params: <String, dynamic>{
          'p_payload': <String, dynamic>{
            'purchase_id': purchaseId,
            'return_date': Formatters.dateIso(returnDate),
            'reason': _trimmedOrNull(reason),
            'sub_total': totals.subTotal,
            'tax_total': totals.taxTotal,
            'grand_total': totals.grandTotal,
            // One array for every line: the server writes them in a single INSERT,
            // so the stock trigger's refusal takes the whole set with it rather
            // than leaving half the units returned.
            'items': payloads,
          },
        },
      );

      return WriteOutcome.fromJson(
        answer as Map<String, dynamic>,
        PurchaseReturn.fromJson,
      );
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to record that purchase return.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to record that purchase return.',
        cause: error,
      );
    }
  }

  /// The document a return is being raised against.
  Future<Purchase> _purchaseFor({
    required String pharmacyId,
    required String purchaseId,
  }) async {
    final row = await _client
        .from('purchases')
        .select()
        .eq('pharmacy_id', pharmacyId)
        .eq('id', purchaseId)
        .maybeSingle();
    if (row == null) {
      throw const NotFoundException(message: 'That purchase no longer exists.');
    }
    return Purchase.fromJson(row);
  }

  /// How many units of each of [purchaseId]'s lines have already gone back.
  ///
  /// Keyed by purchase-item id. A return with no lines contributes nothing, which
  /// is exactly what an abandoned header should contribute.
  Future<Map<String, int>> _returnedQuantities({
    required String pharmacyId,
    required String purchaseId,
  }) async {
    final returnRows = await _client
        .from('purchase_returns')
        .select('id')
        .eq('pharmacy_id', pharmacyId)
        .eq('purchase_id', purchaseId);
    final returnIds = returnRows
        .map((row) => row['id'] as String)
        .toList(growable: false);
    if (returnIds.isEmpty) {
      return const <String, int>{};
    }

    final rows = await _client
        .from('purchase_return_items')
        .select('purchase_item_id, qty')
        .eq('pharmacy_id', pharmacyId)
        .inFilter('purchase_return_id', returnIds);

    final returned = <String, int>{};
    for (final row in rows) {
      final itemId = row['purchase_item_id'] as String?;
      if (itemId == null) {
        // `purchase_item_id` has `on delete set null`, so a line whose invoice
        // line was removed reports nothing rather than being counted against a
        // line that is no longer there.
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

  /// The quantity in each of [batchIds], keyed by batch id.
  Future<Map<String, int>> _batchQuantities({
    required String pharmacyId,
    required List<String> batchIds,
  }) async {
    if (batchIds.isEmpty) {
      return const <String, int>{};
    }
    final rows = await _client
        .from('product_batches')
        .select('id, qty')
        .eq('pharmacy_id', pharmacyId)
        .inFilter('id', batchIds);
    return <String, int>{
      for (final row in rows) row['id'] as String: row['qty'] as int,
    };
  }
}

/// How a line is named in a message, preferring what the invoice printed.
String _labelOf(PurchaseItem item) {
  final raw = item.productNameRaw?.trim();
  return raw == null || raw.isEmpty ? 'that line' : raw;
}

/// The trimmed text of [raw], or `null` when it holds nothing.
String? _trimmedOrNull(String? raw) {
  final value = raw?.trim();
  return value == null || value.isEmpty ? null : value;
}
