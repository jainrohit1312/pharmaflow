/// The payload `save_purchase()` takes, built in one place.
///
/// A purchase document is written by ONE server-side function (migration
/// `20260921000044`), because `purchases` and `purchase_items` stopped taking writes
/// from a session at all: a gate that lived in the screen would have been a
/// suggestion. So the shape of what that function is handed is part of this feature's
/// contract rather than an implementation detail of one repository method, and it
/// lives here where it can be read and tested on its own.
///
/// Three things about it are load-bearing:
///
///  * **The figures are the invoice's.** `sub_total`, `discount_total`, `tax_total` and
///    `grand_total`, and each line's four tax columns, are sent as the form worked them
///    out (`PurchaseTotals`) and stored as they arrive. The server checks that the
///    document adds up, and does not recompute it - a purchase is a supplier's paper
///    transcribed, not a bill the pharmacy prices, and `grand_total` is what the ledger
///    posts as the payable.
///  * **A stored document is re-saved from its stored figures, never re-derived.** A
///    status change must not restate a document's money, so `saveStored` copies the
///    columns it read rather than calling `PurchaseTotals` again.
///  * **A cancellation carries nothing but the id.** It is not an edit - the server
///    moves the status and touches nothing else - so sending it a document's worth of
///    lines would be describing work that is not being done.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/data/models/purchase.dart';
import 'package:app/data/models/purchase_draft.dart';
import 'package:app/data/models/purchase_item.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';

/// Builds the document `save_purchase()` writes.
abstract final class PurchasePayload {
  /// A save of a form's [lines] on [draft], at the totals they produced.
  ///
  /// [purchaseId] is `null` when the document is new; [status] is what the save is
  /// asking for, which is what the owner's approval will grant (or what the owner
  /// writes immediately, since he is not gated).
  static Map<String, dynamic> save({
    required PurchaseDraft draft,
    required List<PurchaseLineDraft> lines,
    required PurchaseDocumentTotals totals,
    required PurchaseStatus status,
    required TaxSplit split,
    String? purchaseId,
    String? idempotencyKey,
  }) => <String, dynamic>{
    'purchase_id': purchaseId,
    'status': status.dbValue,
    'supplier_id': draft.supplierId,
    'invoice_no': draft.invoiceNo.trim(),
    'invoice_date': Formatters.dateIso(draft.invoiceDate),
    'notes': draft.notes,
    'sub_total': totals.subTotal,
    'discount_total': totals.discountTotal,
    'tax_total': totals.taxTotal,
    'grand_total': totals.grandTotal,
    'items': <Map<String, dynamic>>[
      for (final line in lines) _line(line, split: split),
    ],
    'idempotency_key': idempotencyKey,
  };

  /// A save of a document that is already stored, unchanged except for [status].
  ///
  /// Used for the moves that are not edits of what the document says - "mark as
  /// ordered", and the receipt of a document the form has not touched - where the
  /// only honest thing to send is the document as it stands. Its own figures travel
  /// as stored, so a status change cannot restate a payable.
  static Map<String, dynamic> saveStored({
    required Purchase purchase,
    required List<PurchaseItem> items,
    required PurchaseStatus status,
  }) => <String, dynamic>{
    'purchase_id': purchase.id,
    'status': status.dbValue,
    'supplier_id': purchase.supplierId,
    'invoice_no': purchase.invoiceNo,
    'invoice_date': Formatters.dateIso(purchase.invoiceDate),
    'notes': purchase.notes,
    'sub_total': purchase.subTotal,
    'discount_total': purchase.discountTotal,
    'tax_total': purchase.taxTotal,
    'grand_total': purchase.grandTotal,
    'items': <Map<String, dynamic>>[
      for (final item in items) _storedLine(item),
    ],
  };

  /// A cancellation: the status moves and nothing else does.
  ///
  /// The server neither rewrites the document nor stages it - a received document
  /// saying `pending_approval` over posted stock would be a lie about the ledger -
  /// so a cancellation is asked for, for staff, with the document left exactly where
  /// it is until the owner answers.
  static Map<String, dynamic> cancel({
    required String purchaseId,
    String? idempotencyKey,
  }) => <String, dynamic>{
    'purchase_id': purchaseId,
    'status': PurchaseStatus.cancelled.dbValue,
    'idempotency_key': idempotencyKey,
  };

  /// One form line, as the server takes it.
  ///
  /// The batch's own descriptive fields ride along (`mfg_date` included): they are what
  /// the server upserts a batch row from, and only when the goods are being booked in.
  static Map<String, dynamic> _line(
    PurchaseLineDraft line, {
    required TaxSplit split,
  }) {
    final totals = PurchaseTotals.forLine(line, split: split);
    final expiry = line.expiryDate;
    final mfg = line.mfgDate;

    return <String, dynamic>{
      'product_id': line.productId,
      'product_name_raw': line.productNameRaw,
      'batch_no': line.batchNo,
      'expiry_date': expiry == null ? null : Formatters.dateIso(expiry),
      'mfg_date': mfg == null ? null : Formatters.dateIso(mfg),
      'hsn_code': line.hsnCode,
      'qty': line.qty,
      'free_qty': line.freeQty,
      'purchase_rate': line.purchaseRate,
      'mrp': line.mrp,
      'selling_rate': line.sellingRate,
      'discount_percent': line.discountPercent,
      'gst_percent': line.gstPercent,
      'cgst_amount': totals.cgst,
      'sgst_amount': totals.sgst,
      'igst_amount': totals.igst,
      'tax_amount': totals.tax,
      'total_amount': totals.total,
    };
  }

  /// One stored line, as the server takes it back.
  ///
  /// No `mfg_date`: `purchase_items` does not carry one (it belongs to the batch row),
  /// and a save that is not a receipt writes no batch.
  static Map<String, dynamic> _storedLine(PurchaseItem item) {
    final expiry = item.expiryDate;

    return <String, dynamic>{
      'product_id': item.productId,
      'product_name_raw': item.productNameRaw,
      'batch_no': item.batchNo,
      'expiry_date': expiry == null ? null : Formatters.dateIso(expiry),
      'hsn_code': item.hsnCode,
      'qty': item.qty,
      'free_qty': item.freeQty,
      'purchase_rate': item.purchaseRate,
      'mrp': item.mrp,
      'selling_rate': item.sellingRate,
      'discount_percent': item.discountPercent,
      'gst_percent': item.gstPercent,
      'cgst_amount': item.cgstAmount,
      'sgst_amount': item.sgstAmount,
      'igst_amount': item.igstAmount,
      'tax_amount': item.taxAmount,
      'total_amount': item.totalAmount,
    };
  }
}
