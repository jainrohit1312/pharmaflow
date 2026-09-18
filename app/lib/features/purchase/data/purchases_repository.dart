/// Supabase-backed repository for purchase documents.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/utils/postgrest_search.dart';
import 'package:app/data/datasources/postgrest_error_mapper.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'purchases_repository.g.dart';

/// Exposes the single [PurchasesRepository].
@riverpod
PurchasesRepository purchasesRepository(Ref ref) =>
    PurchasesRepository(ref.watch(supabaseClientProvider));

/// What a purchase list may filter on.
///
/// Immutable, mutated only through the `with…` helpers, so a filter change is a
/// new value rather than an edit Riverpod could miss.
class PurchasesQuery {
  /// Creates a query; the defaults mean "everything, newest invoice first".
  const PurchasesQuery({
    this.search = '',
    this.supplierId,
    this.status,
    this.from,
    this.to,
  });

  /// Free-text term matched against the invoice number and notes.
  final String search;

  /// Restrict to one supplier.
  final String? supplierId;

  /// Restrict to one document status.
  final PurchaseStatus? status;

  /// Earliest invoice date to include.
  final DateTime? from;

  /// Latest invoice date to include.
  final DateTime? to;

  /// Whether anything is actually being filtered out.
  bool get isFiltered =>
      search.isNotEmpty ||
      supplierId != null ||
      status != null ||
      from != null ||
      to != null;

  /// A copy with the search term replaced.
  PurchasesQuery withSearch(String value) => PurchasesQuery(
    search: value,
    supplierId: supplierId,
    status: status,
    from: from,
    to: to,
  );

  /// A copy with the supplier filter replaced (`null` clears it).
  PurchasesQuery withSupplier(String? value) => PurchasesQuery(
    search: search,
    supplierId: value,
    status: status,
    from: from,
    to: to,
  );

  /// A copy with the status filter replaced (`null` clears it).
  PurchasesQuery withStatus(PurchaseStatus? value) => PurchasesQuery(
    search: search,
    supplierId: supplierId,
    status: value,
    from: from,
    to: to,
  );

  /// A copy with the invoice-date window replaced.
  PurchasesQuery withDateRange({DateTime? from, DateTime? to}) =>
      PurchasesQuery(
        search: search,
        supplierId: supplierId,
        status: status,
        from: from,
        to: to,
      );
}

/// Data access for `purchases`, `purchase_items` and the batches a receipt
/// creates.
class PurchasesRepository {
  /// Creates a repository backed by the shared Supabase client.
  PurchasesRepository(this._client);

  final sb.SupabaseClient _client;

  /// Rows fetched per page by the list screen.
  static const int pageSize = 50;

  /// Columns the free-text search looks at.
  static const List<String> searchColumns = <String>['invoice_no', 'notes'];

  /// Loads one page of purchases matching [query], newest invoice first.
  Future<List<Purchase>> list({
    required String pharmacyId,
    required PurchasesQuery query,
    int limit = pageSize,
    int offset = 0,
  }) async {
    try {
      var request = _client
          .from('purchases')
          .select()
          .eq('pharmacy_id', pharmacyId);

      final search = buildIlikeOrFilter(
        columns: searchColumns,
        term: query.search,
      );
      if (search != null) {
        request = request.or(search);
      }
      final supplierId = query.supplierId;
      if (supplierId != null) {
        request = request.eq('supplier_id', supplierId);
      }
      final status = query.status;
      if (status != null) {
        request = request.eq('status', status.dbValue);
      }
      final from = query.from;
      if (from != null) {
        request = request.gte('invoice_date', Formatters.dateIso(from));
      }
      final to = query.to;
      if (to != null) {
        request = request.lte('invoice_date', Formatters.dateIso(to));
      }

      final rows = await request
          .order('invoice_date', ascending: false)
          .order('created_at', ascending: false)
          .range(offset, offset + limit - 1);
      return rows.map(Purchase.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load purchases.',
      );
    } on Object catch (error) {
      throw ServerException(message: 'Unable to load purchases.', cause: error);
    }
  }

  /// Loads one purchase, or `null` when it does not exist.
  Future<Purchase?> byId({
    required String pharmacyId,
    required String purchaseId,
  }) async {
    try {
      final row = await _client
          .from('purchases')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('id', purchaseId)
          .maybeSingle();
      return row == null ? null : Purchase.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load that purchase.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load that purchase.',
        cause: error,
      );
    }
  }

  /// The lines of [purchaseId], in insertion order.
  Future<List<PurchaseItem>> itemsFor({
    required String pharmacyId,
    required String purchaseId,
  }) async {
    try {
      final rows = await _client
          .from('purchase_items')
          .select()
          .eq('pharmacy_id', pharmacyId)
          .eq('purchase_id', purchaseId)
          .order('created_at');
      return rows.map(PurchaseItem.fromJson).toList(growable: false);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to load the lines of that purchase.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to load the lines of that purchase.',
        cause: error,
      );
    }
  }

  /// Creates a purchase document in `draft`, with its lines and no batches.
  ///
  /// A draft has no batches on purpose: batches are what a *receipt* creates, and
  /// nothing about stock should move before goods arrive (D-013).
  Future<Purchase> create({
    required String pharmacyId,
    required PurchaseDraft header,
    required List<PurchaseLineDraft> lines,
    required TaxSplit split,
  }) async {
    final invalid = validateLines(lines, requireBatches: false);
    if (invalid != null) {
      throw ValidationException(message: invalid);
    }

    try {
      final headerRow = await _client
          .from('purchases')
          .insert(<String, dynamic>{
            'pharmacy_id': pharmacyId,
            ..._headerFields(header),
            ..._totalsPayload(
              PurchaseTotals.forLines(lines, split: split),
              status: PurchaseStatus.draft,
            ),
          })
          .select()
          .single();
      final purchaseId = headerRow['id'] as String;

      await _replaceLines(
        pharmacyId: pharmacyId,
        purchaseId: purchaseId,
        lines: lines,
        split: split,
      );

      return Purchase.fromJson(headerRow);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to save that purchase.',
        uniqueViolationMessage:
            'That supplier already has a purchase with that invoice number.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to save that purchase.',
        cause: error,
      );
    }
  }

  /// Rewrites a purchase's header and lines while it is still editable.
  ///
  /// Refuses once the document is received: its lines are what produced the
  /// stock and the ledger entry, and the triggers deliberately do not reverse
  /// those, so editing them would leave the two disagreeing.
  ///
  /// **The status it leaves behind depends on what changed (D-019).** An
  /// `ordered` document has been sent to the supplier, so a change to its lines
  /// makes the copy the supplier confirmed stale and puts it back to `draft` -
  /// which `PurchaseFormScreen` reports rather than letting the reset happen
  /// quietly. A header-only edit (notes, invoice number, invoice date) leaves the
  /// status alone, because nothing the supplier holds has changed.
  /// [statusAfterEdit] is that decision.
  Future<Purchase> updateDraft({
    required String pharmacyId,
    required String purchaseId,
    required PurchaseDraft header,
    required List<PurchaseLineDraft> lines,
    required TaxSplit split,
  }) async {
    final invalid = validateLines(lines, requireBatches: false);
    if (invalid != null) {
      throw ValidationException(message: invalid);
    }
    final existing = await _requireEditable(
      pharmacyId: pharmacyId,
      purchaseId: purchaseId,
    );
    // Read before the write, because the comparison is against the lines that
    // are about to be replaced.
    final stored = await itemsFor(
      pharmacyId: pharmacyId,
      purchaseId: purchaseId,
    );
    final status = statusAfterEdit(
      current: existing.status,
      lines: lines,
      items: stored,
    );

    try {
      final headerRow = await _client
          .from('purchases')
          .update(<String, dynamic>{
            ..._headerFields(header),
            ..._totalsPayload(
              PurchaseTotals.forLines(lines, split: split),
              status: status,
            ),
          })
          .eq('pharmacy_id', pharmacyId)
          .eq('id', purchaseId)
          .select()
          .single();

      await _replaceLines(
        pharmacyId: pharmacyId,
        purchaseId: purchaseId,
        lines: lines,
        split: split,
      );

      return Purchase.fromJson(headerRow);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to save that purchase.',
        uniqueViolationMessage:
            'That supplier already has a purchase with that invoice number.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to save that purchase.',
        cause: error,
      );
    }
  }

  /// Moves a document between the statuses that post nothing.
  ///
  /// Only `draft`, `ordered` and `cancelled` may be reached this way: `received`
  /// is not a status change, it is the receipt itself, and it has to write
  /// batches and lines in the same breath - see [receive].
  Future<Purchase> setStatus({
    required String pharmacyId,
    required String purchaseId,
    required PurchaseStatus status,
  }) async {
    if (status.isPosted) {
      throw const ValidationException(
        message: 'Receiving a purchase has to go through the goods receipt.',
      );
    }

    try {
      final row = await _client
          .from('purchases')
          .update(<String, dynamic>{'status': status.dbValue})
          .eq('pharmacy_id', pharmacyId)
          .eq('id', purchaseId)
          .select()
          .single();
      return Purchase.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to change the status of that purchase.',
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to change the status of that purchase.',
        cause: error,
      );
    }
  }

  /// Books a purchase in: creates its batches, writes its lines, then receives it.
  ///
  /// **The order is the whole point, and the database enforces it:**
  ///
  /// 1. `product_batches` rows first, keyed on
  ///    `(pharmacy_id, product_id, batch_no)`, **without `qty`**. The stock
  ///    trigger joins on `purchase_items.batch_id` and increments an existing
  ///    batch, so a line written first would reference nothing and the stock
  ///    would silently never arrive. Leaving `qty` out means a new batch takes
  ///    the column default of 0, and - the part that matters - an upsert against
  ///    an existing batch leaves its balance untouched instead of zeroing stock
  ///    that no trigger would restore.
  /// 2. The lines, now carrying `batch_id`.
  /// 3. The status change to `received`, which is the single event that posts
  ///    stock, its landed cost, and the supplier ledger entry. It is last so that
  ///    a failure before it leaves a document which can simply be received
  ///    again, rather than a half-posted one.
  ///
  /// [split] decides whether the tax goes to CGST+SGST or IGST; the caller reads
  /// the pharmacy's and supplier's states to choose.
  Future<Purchase> receive({
    required String pharmacyId,
    required String purchaseId,
    required PurchaseDraft header,
    required List<PurchaseLineDraft> lines,
    required TaxSplit split,
  }) async {
    final invalid = validateLines(lines, requireBatches: true);
    if (invalid != null) {
      throw ValidationException(message: invalid);
    }
    await _requireEditable(pharmacyId: pharmacyId, purchaseId: purchaseId);

    try {
      // 1. Batches, without qty (see the doc comment).
      final batchPayloads = lines
          .map((line) => line.toBatchJson(pharmacyId: pharmacyId))
          .toList(growable: false);
      final batchRows = await _client
          .from('product_batches')
          .upsert(batchPayloads, onConflict: 'pharmacy_id,product_id,batch_no')
          .select('id, product_id, batch_no');
      final batchIds = <String, String>{
        for (final row in batchRows)
          _batchKey(row['product_id'] as String, row['batch_no'] as String):
              row['id'] as String,
      };

      // 2. Lines, replaced wholesale and now pointing at their batches.
      await _replaceLines(
        pharmacyId: pharmacyId,
        purchaseId: purchaseId,
        lines: lines,
        split: split,
        batchIds: batchIds,
      );

      // 3. Receipt: totals and status in one statement, because the ledger
      //    trigger reads grand_total from the row it is handed.
      final row = await _client
          .from('purchases')
          .update(<String, dynamic>{
            ..._headerFields(header),
            ..._totalsPayload(
              PurchaseTotals.forLines(lines, split: split),
              status: PurchaseStatus.received,
            ),
          })
          .eq('pharmacy_id', pharmacyId)
          .eq('id', purchaseId)
          .select()
          .single();
      return Purchase.fromJson(row);
    } on sb.PostgrestException catch (error) {
      throw mapPostgrestException(
        error,
        fallbackMessage: 'Unable to receive that purchase.',
        uniqueViolationMessage:
            'That supplier already has a purchase with that invoice number.',
      );
    } on Object catch (error) {
      if (error is AppException) {
        rethrow;
      }
      throw ServerException(
        message: 'Unable to receive that purchase.',
        cause: error,
      );
    }
  }

  /// Rejects a line set the write could not honour, or returns `null` when it is
  /// sound.
  ///
  /// [requireBatches] is the difference between the two halves of a purchase's
  /// life: a purchase *order* line is a product and a quantity, with no batch
  /// details yet (no batch row is created until goods arrive), while a receipt
  /// line has to name the batch it belongs to.
  ///
  /// Pure and public so it can be tested without a client. The duplicate check is
  /// not cosmetic: two lines naming the same batch of the same product would make
  /// the batch upsert try to affect one row twice in a single statement, which
  /// Postgres refuses outright.
  static String? validateLines(
    List<PurchaseLineDraft> lines, {
    required bool requireBatches,
  }) {
    if (lines.isEmpty) {
      return 'Add at least one line before saving.';
    }

    final seen = <String>{};
    for (final line in lines) {
      if (line.qty <= 0) {
        return 'Every line needs a quantity greater than zero.';
      }
      final productId = line.productId;
      if (productId == null) {
        return 'Every line needs a product.';
      }
      if (!requireBatches) {
        continue;
      }

      final batchNo = line.batchNo?.trim();
      if (batchNo == null || batchNo.isEmpty) {
        return 'Every line needs a batch number before the goods can be '
            'received.';
      }
      if (line.expiryDate == null) {
        return 'Every line needs an expiry date before the goods can be '
            'received.';
      }
      if (!seen.add(_batchKey(productId, batchNo))) {
        return 'The same batch of one product appears twice. '
            'Combine the two lines or give them different batch numbers.';
      }
    }
    return null;
  }

  /// The status an edit leaves behind (D-019).
  ///
  /// Only `ordered` is at stake, because it is the one status that means the
  /// document has left the pharmacy's hands: the supplier holds a copy. Changing
  /// what that copy says makes it stale, so the document goes back to `draft` to
  /// be confirmed again; a header-only edit leaves the order standing.
  ///
  /// Pure and public for the same reason as [validateLines]: the fake repository
  /// the screen tests run against calls this exact function, so a screen cannot
  /// be tested against a friendlier rule than the one the real write applies.
  static PurchaseStatus statusAfterEdit({
    required PurchaseStatus current,
    required List<PurchaseLineDraft> lines,
    required List<PurchaseItem> items,
  }) {
    if (current == PurchaseStatus.ordered &&
        linesDiffer(lines: lines, items: items)) {
      return PurchaseStatus.draft;
    }
    return current;
  }

  /// Whether [lines] say something different from the stored [items].
  ///
  /// A value comparison, not an identity one: an edit rewrites the document's
  /// lines wholesale, so the arriving drafts carry no ids to match on.
  ///
  /// It compares a *multiset* of per-line signatures, deliberately ignoring
  /// order. `purchase_items.created_at` is a transaction timestamp, so rows
  /// written in one statement share it and the order a read returns them in is
  /// not the order they were written in - an order-sensitive comparison would
  /// report a change on a document nobody touched, which is the false revert
  /// D-019 exists to prevent.
  static bool linesDiffer({
    required List<PurchaseLineDraft> lines,
    required List<PurchaseItem> items,
  }) {
    if (lines.length != items.length) {
      return true;
    }
    final draftSignatures = lines.map(_draftSignature).toList(growable: false)
      ..sort();
    final itemSignatures = items.map(_itemSignature).toList(growable: false)
      ..sort();
    for (var index = 0; index < draftSignatures.length; index++) {
      if (draftSignatures[index] != itemSignatures[index]) {
        return true;
      }
    }
    return false;
  }

  /// The key that ties a line to its batch row.
  static String _batchKey(String productId, String batchNo) =>
      '$productId|$batchNo';

  /// What a draft line contributes to [linesDiffer].
  static String _draftSignature(PurchaseLineDraft line) => _signature(
    productId: line.productId,
    qty: line.qty,
    freeQty: line.freeQty,
    purchaseRate: line.purchaseRate,
    mrp: line.mrp,
    discountPercent: line.discountPercent,
    gstPercent: line.gstPercent,
    batchNo: line.batchNo,
    expiryDate: line.expiryDate,
  );

  /// What a stored line contributes to [linesDiffer].
  static String _itemSignature(PurchaseItem item) => _signature(
    productId: item.productId,
    qty: item.qty,
    freeQty: item.freeQty,
    purchaseRate: item.purchaseRate,
    mrp: item.mrp,
    discountPercent: item.discountPercent,
    gstPercent: item.gstPercent,
    batchNo: item.batchNo,
    expiryDate: item.expiryDate,
  );

  /// The comparable text of one line, over the fields the supplier would have to
  /// re-confirm: what was ordered, how many, at what price, and on which batch.
  ///
  /// `selling_rate` is absent on purpose - it is the pharmacy's own counter
  /// price, so changing it says nothing about the order. `product_name_raw` and
  /// `hsn_code` are absent for the same reason: they describe the invoice as
  /// printed, not what was asked for.
  static String _signature({
    required String? productId,
    required int qty,
    required int freeQty,
    required double purchaseRate,
    required double mrp,
    required double discountPercent,
    required double gstPercent,
    required String? batchNo,
    required DateTime? expiryDate,
  }) => <String>[
    productId ?? '',
    '$qty',
    '$freeQty',
    _amount(purchaseRate),
    _amount(mrp),
    _amount(discountPercent),
    _amount(gstPercent),
    batchNo?.trim() ?? '',
    _date(expiryDate),
  ].join('|');

  /// An optional date as a comparable string, empty when there is none.
  ///
  /// Always an element, never omitted: the signature is positional, so a missing
  /// value has to keep its slot.
  static String _date(DateTime? value) =>
      value == null ? '' : Formatters.dateIso(value);

  /// A money or percentage value at the precision its column stores
  /// (`numeric(12,2)`), with a near-zero value normalised so `-0.00` cannot
  /// disagree with `0.00`.
  static String _amount(double value) =>
      (value.abs() < 0.005 ? 0.0 : value).toStringAsFixed(2);

  /// The editable document with [purchaseId], or a throw if there is none.
  Future<Purchase> _requireEditable({
    required String pharmacyId,
    required String purchaseId,
  }) async {
    final existing = await byId(pharmacyId: pharmacyId, purchaseId: purchaseId);
    if (existing == null) {
      throw const NotFoundException(message: 'That purchase no longer exists.');
    }
    if (!existing.status.isEditable) {
      throw ValidationException(
        message:
            'This purchase is ${existing.status.label.toLowerCase()} '
            'already, and its stock is booked in. Correct it with a purchase '
            'return or a stock adjustment instead.',
      );
    }
    return existing;
  }

  /// Deletes the document's lines and writes [lines] in their place.
  ///
  /// Replace rather than diff: a GRN can change a line's batch, quantity and
  /// rates, and a partial update would leave the document's totals describing a
  /// line set that no longer exists. Safe only while the document is editable,
  /// which the callers check first.
  Future<void> _replaceLines({
    required String pharmacyId,
    required String purchaseId,
    required List<PurchaseLineDraft> lines,
    required TaxSplit split,
    Map<String, String> batchIds = const <String, String>{},
  }) async {
    await _client
        .from('purchase_items')
        .delete()
        .eq('pharmacy_id', pharmacyId)
        .eq('purchase_id', purchaseId);

    final payloads = <Map<String, dynamic>>[];
    for (final line in lines) {
      final totals = PurchaseTotals.forLine(line, split: split);
      // A draft line has no batch yet, so its batch_id stays null. Only a
      // receipt has an entry in `batchIds`, keyed by product and batch number.
      final productId = line.productId;
      final batchNo = line.batchNo?.trim();
      final batchId = productId == null || batchNo == null || batchNo.isEmpty
          ? null
          : batchIds[_batchKey(productId, batchNo)];

      payloads.add(<String, dynamic>{
        ...line.toItemJson(
          pharmacyId: pharmacyId,
          purchaseId: purchaseId,
          batchId: batchId,
        ),
        'cgst_amount': totals.cgst,
        'sgst_amount': totals.sgst,
        'igst_amount': totals.igst,
        'tax_amount': totals.tax,
        'total_amount': totals.total,
      });
    }

    await _client.from('purchase_items').insert(payloads);
  }

  /// The header columns a form owns.
  Map<String, dynamic> _headerFields(PurchaseDraft header) => <String, dynamic>{
    'supplier_id': header.supplierId,
    'invoice_no': header.invoiceNo.trim(),
    'invoice_date': Formatters.dateIso(header.invoiceDate),
    'notes': header.notes,
  };

  /// The stored totals plus the status they belong to.
  Map<String, dynamic> _totalsPayload(
    PurchaseDocumentTotals totals, {
    required PurchaseStatus status,
  }) => <String, dynamic>{
    'sub_total': totals.subTotal,
    'discount_total': totals.discountTotal,
    'tax_total': totals.taxTotal,
    'grand_total': totals.grandTotal,
    'status': status.dbValue,
  };
}
