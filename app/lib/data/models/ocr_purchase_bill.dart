/// Plain models for what the bill reader returns.
///
/// Not Freezed, and deliberately so, for `ReportSummary`'s reason: this is an
/// RPC's response envelope rather than a table row, no migration owns its shape,
/// and four nested Freezed classes would generate more code than the decode below.
/// What matters is that the payload is read exactly once, here, so a screen never
/// reaches into raw JSON.
///
/// The decode is deliberately as tolerant as the Edge Function's normalizer is on
/// the other side of the wire (D-030/D-031): a number may arrive as a `num` or as
/// a `String`, every field may be `null` — which means **the screen must ask**,
/// never zero — and a date is an ISO `String` that may be absent. The two sides
/// are paranoid for the same reason: the model's answer is the one input in this
/// feature that nobody wrote.
library;

import 'package:app/data/models/purchase_draft.dart';

/// What the reader made of the invoice header.
///
/// The supplier here is *text* the reader saw (`ARIHANT DISTRIBUTORS`), not a
/// supplier row: matching it to the pharmacy's own supplier list is a human's job
/// in this chunk, and Chunk C's business afterwards.
class OcrDocument {
  /// Creates a header.
  const OcrDocument({
    this.supplierName,
    this.gstin,
    this.invoiceNo,
    this.invoiceDate,
    this.subTotal,
    this.taxTotal,
    this.grandTotal,
  });

  /// Decodes the `document` object.
  factory OcrDocument.fromJson(Map<String, dynamic> json) => OcrDocument(
    supplierName: _text(json['supplier_name']),
    gstin: _text(json['gstin']),
    invoiceNo: _text(json['invoice_no']),
    invoiceDate: _date(json['invoice_date']),
    subTotal: _number(json['sub_total']),
    taxTotal: _number(json['tax_total']),
    grandTotal: _number(json['grand_total']),
  );

  /// The supplier's name as printed, or `null` when it could not be read.
  final String? supplierName;

  /// The supplier's GSTIN as printed.
  final String? gstin;

  /// The invoice number as printed.
  final String? invoiceNo;

  /// The invoice date, already converted to ISO by the function.
  final DateTime? invoiceDate;

  /// Value before tax, as printed.
  final double? subTotal;

  /// Tax charged, as printed.
  final double? taxTotal;

  /// What the bill says is payable.
  final double? grandTotal;
}

/// One line the reader found on the bill.
class OcrLine {
  /// Creates a line.
  const OcrLine({
    this.rawName,
    this.qty,
    this.freeQty,
    this.rate,
    this.mrp,
    this.gstPercent,
    this.batchNo,
    this.expiryDate,
    this.hsnCode,
    this.confidence,
  });

  /// Decodes one entry of `lines`.
  factory OcrLine.fromJson(Map<String, dynamic> json) => OcrLine(
    rawName: _text(json['raw_name']),
    qty: _number(json['qty'])?.round(),
    freeQty: _number(json['free_qty'])?.round(),
    rate: _number(json['rate']),
    mrp: _number(json['mrp']),
    gstPercent: _number(json['gst_percent']),
    batchNo: _text(json['batch_no']),
    expiryDate: _date(json['expiry_date']),
    hsnCode: _text(json['hsn_code']),
    confidence: _number(json['confidence']),
  );

  /// The invoice text for this line — what a human recognises the product by,
  /// and what Chunk C will match against the catalogue.
  final String? rawName;

  /// Billed quantity.
  final int? qty;

  /// Scheme quantity, when the bill printed one.
  final int? freeQty;

  /// Per-unit purchase rate before tax.
  final double? rate;

  /// Printed MRP.
  final double? mrp;

  /// The line's tax **rate** (5, 12, 18), never a tax amount.
  final double? gstPercent;

  /// Batch number, when the bill printed one.
  final String? batchNo;

  /// Expiry, already converted to ISO by the function.
  final DateTime? expiryDate;

  /// HSN code, when the bill printed one.
  final String? hsnCode;

  /// The reader's own 0..1 estimate that it read this line correctly.
  final double? confidence;

  /// Whether the reader was not sure about this line.
  ///
  /// A line below 0.7 is worth a look before it is saved, which is what the
  /// verify screen uses this for.
  bool get isUnsure => confidence != null && confidence! < 0.7;

  /// This line as the purchase draft the manual form would have built.
  ///
  /// `productId` is `null` on purpose: the reader never sees the pharmacy's
  /// catalogue, so a human picks the product on the verify screen (Chunk C
  /// suggests one). A quantity the reader could not read stays `0` rather than
  /// a plausible-looking `1`, so the form's own rule refuses it until somebody
  /// says what it was.
  PurchaseLineDraft toDraft() => PurchaseLineDraft(
    qty: qty ?? 0,
    purchaseRate: rate ?? 0,
    mrp: mrp ?? 0,
    freeQty: freeQty ?? 0,
    gstPercent: gstPercent ?? defaultOcrGstPercent,
    productNameRaw: rawName,
    batchNo: batchNo,
    expiryDate: expiryDate,
    hsnCode: hsnCode,
  );
}

/// The tax slab a line starts on when the reader could not read one.
///
/// The same 12 the purchase line editor uses for a blank line, and for the same
/// reason: `products` has no slab column, and 0 asserts nothing while being wrong
/// for almost every medicine. The field is on screen and editable either way.
const double defaultOcrGstPercent = 12;

/// What the reader said about the read itself.
class OcrMeta {
  /// Creates the metadata.
  const OcrMeta({
    this.model,
    this.warnings = const <String>[],
    this.imagePath,
    this.finishReason,
  });

  /// Decodes the `meta` object.
  factory OcrMeta.fromJson(Map<String, dynamic> json) {
    final warnings = json['warnings'];

    return OcrMeta(
      model: _text(json['model']),
      warnings: warnings is List
          ? <String>[
              // Strings only: a warning is a sentence somebody wrote for the
              // user, and a stray number in the list is not one.
              for (final warning in warnings)
                if (warning is String && warning.trim().isNotEmpty)
                  warning.trim(),
            ]
          : const <String>[],
      imagePath: _text(json['image_path']),
      finishReason: _text(json['finish_reason']),
    );
  }

  /// The vision model that read the bill (D-030).
  final String? model;

  /// Sentences written for a person: what the reader rounded, guessed or could
  /// not read. The verify screen shows these — they are the difference between a
  /// parse somebody can check and one they have to trust.
  final List<String> warnings;

  /// The stored object the parse came from.
  final String? imagePath;

  /// Why the model stopped. `STOP` is a complete answer; anything else means the
  /// bill may have had more lines than were read.
  final String? finishReason;

  /// Whether the answer was cut short rather than completed.
  bool get isTruncated => finishReason != null && finishReason != 'STOP';
}

/// One supplier bill, as read.
class OcrPurchaseBill {
  /// Creates a read bill.
  const OcrPurchaseBill({
    required this.document,
    required this.lines,
    required this.meta,
  });

  /// Decodes the function's 200 body.
  factory OcrPurchaseBill.fromJson(Map<String, dynamic> json) {
    final document = json['document'];
    final lines = json['lines'];

    return OcrPurchaseBill(
      document: OcrDocument.fromJson(
        document is Map ? document.cast<String, dynamic>() : const {},
      ),
      lines: lines is List
          ? <OcrLine>[
              for (final line in lines)
                if (line is Map) OcrLine.fromJson(line.cast<String, dynamic>()),
            ]
          : const <OcrLine>[],
      meta: OcrMeta.fromJson(
        json['meta'] is Map
            ? (json['meta'] as Map).cast<String, dynamic>()
            : const {},
      ),
    );
  }

  /// What the bill's header said.
  final OcrDocument document;

  /// Its lines, in the order the bill printed them.
  final List<OcrLine> lines;

  /// What the reader said about the read.
  final OcrMeta meta;

  /// Whether the read produced nothing worth showing.
  ///
  /// True when no line came back at all: the screen has something to say about
  /// that (it is usually legibility), and an empty table says nothing.
  bool get isEmpty => lines.isEmpty;

  /// Every line as a purchase draft line, ready to edit.
  List<PurchaseLineDraft> toLineDrafts() => <PurchaseLineDraft>[
    for (final line in lines) line.toDraft(),
  ];
}

/// A trimmed string, or `null` for anything missing or empty.
String? _text(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is num) {
    return value.toString();
  }
  return null;
}

/// A number that may arrive as `num` or as text.
///
/// The function normalizes text numbers before sending them (`"₹1,120.00"` →
/// `1120`), so this is a second net rather than the first: a grouped figure is
/// read with the same rule the function uses — a comma groups thousands in
/// `1,25,000` and is a decimal point in `1,25` — because two sides that disagree
/// about a number are two answers to one question (D-030).
double? _number(Object? value) => switch (value) {
  final num number => number.toDouble(),
  final String text => _parseNumber(text),
  _ => null,
};

/// The number in [text], or `null` when it holds none.
double? _parseNumber(String text) {
  final token = RegExp(r'-?\d[\d.,]*').firstMatch(text.trim())?.group(0);
  return token == null ? null : double.tryParse(_plainNumber(token));
}

/// [token] with its grouping separators resolved.
String _plainNumber(String token) {
  if (!token.contains(',')) {
    return token;
  }
  if (token.contains('.')) {
    return token.replaceAll(',', '');
  }

  final afterLastComma = token.substring(token.lastIndexOf(',') + 1);
  return afterLastComma.length == 3
      ? token.replaceAll(',', '')
      : token.replaceAll(',', '.');
}

/// An ISO date, or `null` when it is missing or unreadable.
DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value.trim()) : null;
