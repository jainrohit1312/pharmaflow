/// Renders a sale as a printable GST bill.
///
/// A service rather than a screen's business because printing is a platform
/// capability: `printing` opens the browser's PDF flow on web and the native print
/// dialog on Windows, which is exactly the split D-005 records. The screen only
/// has to know that it asked for a bill.
///
/// The receipt is laid out on an 80mm roll - the width a thermal counter printer
/// takes - so the same artifact prints on a till and saves as a PDF.
///
/// It is built in two steps on purpose. [InvoicePrinter.buildSheet] turns the sale
/// into the bill's **content** and touches nothing platform-shaped;
/// [InvoicePrinter.buildDocument] lays that content out; `printReceipt` hands it to
/// the platform. A bill is a tax document, so what it says is worth asserting -
/// and while the two steps were one method, the only way to look at any of it from
/// a test was to mock a print channel. The content is where the arithmetic and the
/// statutory headings live, so the content is what the tests check.
library;

import 'package:app/core/utils/formatters.dart';
import 'package:app/data/models/pharmacy.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/sale_item.dart';
import 'package:app/features/purchase/data/purchase_totals.dart';
import 'package:app/features/sales/application/sale_detail_controller.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'invoice_printer.g.dart';

/// Exposes the single [InvoicePrinter].
///
/// A provider rather than a bare const so a test can replace it: the real one
/// talks to the platform's print sheet, which is not something a widget test can
/// drive.
@riverpod
InvoicePrinter invoicePrinter(Ref ref) => const InvoicePrinter();

/// One sold line as the bill prints it.
class InvoiceLine {
  /// Creates a printed line.
  const InvoiceLine({
    required this.name,
    required this.detail,
    required this.amount,
    required this.batch,
    required this.expiry,
  });

  /// What the product is called.
  final String name;

  /// How the line was priced: `2 x Rs 100.00 less 10% + 12% GST`.
  final String detail;

  /// What the line came to.
  final String amount;

  /// Which pack it came out of, or [InvoicePrinter.unknownMark].
  ///
  /// A Drug-Rules bill has to name the batch the goods came out of. This is the only
  /// place it is knowable: `sale_items` records a `batch_id`, so the number comes from
  /// the document `sale_document()` returns and never from a join the client does.
  final String batch;

  /// When that pack expires as `MM/yy`, or [InvoicePrinter.unknownMark].
  ///
  /// `MM/yy` rather than a full date because the roll is 80mm and the batch and the
  /// expiry share one line.
  final String expiry;
}

/// One label and amount.
class InvoiceRow {
  /// Creates a printed row.
  const InvoiceRow(this.label, this.value, {this.emphasis, this.ruleAbove});

  /// The name of the figure.
  final String label;

  /// The figure, already formatted.
  final String value;

  /// Whether this row is the document's headline figure.
  ///
  /// Only the total is: it is the one number a customer, an auditor and a GST
  /// return all agree on, so it is set apart rather than left in the list.
  final bool? emphasis;

  /// Whether a rule is printed above this row.
  ///
  /// The line that separates the tax breakdown from the total. It is part of what
  /// a GST bill looks like rather than something the renderer should decide, so it
  /// travels with the row it belongs to.
  final bool? ruleAbove;
}

/// The bill's content, before it is anything on paper.
///
/// Deliberately not a widget tree and not Freezed: nothing here is a table row or
/// an RPC envelope, and the point of it is to be the half of a receipt that can be
/// asserted without a printer, a PDF or a platform channel.
class InvoiceSheet {
  /// Creates a sheet.
  const InvoiceSheet({
    required this.heading,
    required this.title,
    required this.reference,
    required this.issuedAt,
    required this.lines,
    required this.totals,
    required this.payment,
    required this.footer,
    this.patient,
    this.doctor,
  });

  /// The seller's block: the pharmacy's name first, then the details it has.
  ///
  /// One positional list rather than separate fields, because this is the order the
  /// block is read in - the name is the headline at the top of the roll and the rest
  /// is the small print under it. The first element is styled as the headline; an
  /// empty pharmacy still yields one element, so a customer always gets a bill
  /// (a header row that could not be read is not a reason to print nothing).
  final List<String> heading;

  /// What kind of document this is - `TAX INVOICE`.
  final String title;

  /// The document's own identifier, e.g. `Bill INV-1`.
  final String reference;

  /// When it was raised, as `18/09/2026 14:05`.
  final String issuedAt;

  /// Who it is for, as `Rohit Jain · PT-00001`, or `null` when the sale records nobody.
  ///
  /// The name is the sale's own snapshot and the code is the one `sale_document()`
  /// joined. A sale whose party has no code prints a dash rather than a code - a
  /// package bill, whose party is the hospital's account row, and anyone registered
  /// before Phase 7a until `save_patient()` first touches them.
  final String? patient;

  /// Who prescribed it, or `null` when the sale names nobody.
  ///
  /// **This is a Drug-Rules line, not a courtesy.** A Schedule H, H1, X or narcotic medicine
  /// may not be dispensed without a prescriber, and the bill is the record of who wrote it
  /// (D-072) - so it prints whenever the sale named one, whatever the line's schedule. Nothing
  /// is invented when it did not: a bill with no prescriber simply has no prescriber line.
  final String? doctor;

  /// What was sold.
  final List<InvoiceLine> lines;

  /// The arithmetic: taxable value, discount, the tax heads, and the total.
  final List<InvoiceRow> totals;

  /// How it was settled.
  final List<InvoiceRow> payment;

  /// The sentence at the foot of the roll.
  final String footer;
}

/// Turns a sale into a bill.
class InvoicePrinter {
  /// Creates a printer.
  const InvoicePrinter();

  /// The sentence printed at the foot of every bill.
  static const String footerNote =
      'Goods once sold are not returnable without the bill.';

  /// What a bill prints where a value was never recorded.
  ///
  /// An **em dash**, never a plausible stand-in. 145 of the owner's opening-stock
  /// batches have no expiry date and 138 have no batch number, so "not recorded" is the
  /// common case at this counter rather than a corner - and a bill that invented
  /// `OPENING-…` or a date would be stating something the pharmacy cannot stand behind.
  static const String unknownMark = '\u2014';

  /// The bill's content. Pure: no PDF, no platform, no clock.
  ///
  /// [pharmacy] supplies the seller's half of a GST bill. It is nullable because a
  /// pharmacy row that cannot be read should not stop a customer getting a receipt:
  /// the bill prints with a placeholder header rather than not printing at all.
  ///
  /// [split] decides the tax heads. It is a parameter rather than something read
  /// off the sale because `sales` stores one `tax_total` and does not record which
  /// state the goods went to in a form this can rely on; the counter's own GST
  /// settings and the place of supply are what decide it there.
  InvoiceSheet buildSheet({
    required SaleDetailData data,
    required Pharmacy? pharmacy,
    TaxSplit split = TaxSplit.intraState,
  }) {
    final sale = data.sale;
    return InvoiceSheet(
      heading: <String>[
        pharmacy?.name ?? 'Pharmacy',
        if (_present(pharmacy?.displayAddress)) pharmacy!.displayAddress,
        if (_present(pharmacy?.gstin)) 'GSTIN ${pharmacy!.gstin}',
        if (_present(pharmacy?.drugLicenseNo))
          'D.L. ${pharmacy!.drugLicenseNo}',
      ],
      title: 'TAX INVOICE',
      reference: 'Bill ${sale.invoiceNo}',
      issuedAt: _dateTime(sale.saleDate),
      patient: _patient(sale, data.patientCode),
      doctor: _prescriber(sale),
      // Iterated over the document's **lines** rather than its items, because a bill
      // has to name the pack each line came out of and the batch detail lives beside
      // the line rather than on it (`SaleDocumentLine`).
      lines: <InvoiceLine>[
        for (final line in data.lines)
          InvoiceLine(
            name: data.nameOf(line.item),
            detail: _lineDetail(line.item),
            amount: _money(line.item.totalAmount),
            batch: line.hasKnownBatch ? line.batchNo.trim() : unknownMark,
            expiry: line.hasKnownExpiry
                ? Formatters.monthYearShort(line.expiryDate!)
                : unknownMark,
          ),
      ],
      totals: <InvoiceRow>[
        InvoiceRow('Taxable value', _money(sale.subTotal)),
        if (sale.discountTotal > 0)
          InvoiceRow('Discount', '-${_money(sale.discountTotal)}'),
        // Half each when the sale is intra-state. The *rounded* half is
        // subtracted, not the unrounded one, so the two always add back up to the
        // stored `tax_total`: a tax total with an odd number of paise has no exact
        // half, and rounding both halves of `t` separately gave `t + 0.01` - a bill
        // whose own tax heads did not sum to the tax it charged.
        if (split == TaxSplit.intraState) ...<InvoiceRow>[
          InvoiceRow('CGST', _money(_cgst(sale.taxTotal))),
          InvoiceRow(
            'SGST',
            _money(PurchaseTotals.round2(sale.taxTotal - _cgst(sale.taxTotal))),
          ),
        ] else
          InvoiceRow('IGST', _money(sale.taxTotal)),
        InvoiceRow(
          'TOTAL',
          _money(sale.grandTotal),
          emphasis: true,
          ruleAbove: true,
        ),
      ],
      payment: <InvoiceRow>[
        InvoiceRow(sale.paymentMode.label, _money(sale.amountPaid)),
        if (sale.balanceDue > 0)
          InvoiceRow('Balance due', _money(sale.balanceDue)),
        // A credit sale names no customer on the roll: the bill is printed at the
        // counter, and who owes it is the ledger's business, not the paper's.
        if (sale.customerId != null)
          const InvoiceRow('Customer', 'account sale'),
      ],
      footer: footerNote,
    );
  }

  /// [buildSheet] laid out on an 80mm roll.
  ///
  /// Returns the document rather than printing it, so the layout can be built (and
  /// a smoke test can build it) without a platform in reach.
  pw.Document buildDocument({
    required SaleDetailData data,
    required Pharmacy? pharmacy,
    TaxSplit split = TaxSplit.intraState,
  }) {
    final sheet = buildSheet(data: data, pharmacy: pharmacy, split: split);

    return pw.Document()..addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.all(8),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: <pw.Widget>[
            pw.Column(
              children: <pw.Widget>[
                for (var index = 0; index < sheet.heading.length; index++)
                  pw.Text(
                    sheet.heading[index],
                    style: index == 0
                        ? const pw.TextStyle(
                            fontSize: 14,
                            fontWeight: pw.FontWeight.bold,
                          )
                        : const pw.TextStyle(fontSize: 8),
                    textAlign: pw.TextAlign.center,
                  ),
                pw.SizedBox(height: 4),
                pw.Text(
                  sheet.title,
                  style: const pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  sheet.reference,
                  style: const pw.TextStyle(fontSize: 8),
                ),
                pw.Text(sheet.issuedAt, style: const pw.TextStyle(fontSize: 8)),
                if (sheet.patient != null) ...<pw.Widget>[
                  pw.SizedBox(height: 2),
                  pw.Text(
                    sheet.patient!,
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                ],
                // Under the patient, because it answers the same question: who this bill is
                // about, and who wrote it. A register that has to be produced on demand reads
                // the prescriber off the bill, not off a screen (D-072).
                if (sheet.doctor != null) ...<pw.Widget>[
                  pw.SizedBox(height: 2),
                  pw.Text(
                    'Prescribed by ${sheet.doctor}',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                ],
              ],
            ),
            pw.SizedBox(height: 6),
            pw.Divider(thickness: 0.5),
            for (final line in sheet.lines) _lineWidget(line),
            pw.Divider(thickness: 0.5),
            for (final row in sheet.totals) ...<pw.Widget>[
              if (row.ruleAbove ?? false) pw.Divider(thickness: 0.5),
              _rowWidget(row),
            ],
            pw.SizedBox(height: 6),
            for (final row in sheet.payment) _rowWidget(row),
            pw.SizedBox(height: 10),
            pw.Text(
              sheet.footer,
              style: const pw.TextStyle(fontSize: 7),
              textAlign: pw.TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Renders [data] as an 80mm receipt and hands it to the platform.
  Future<void> printReceipt({
    required SaleDetailData data,
    required Pharmacy? pharmacy,
    TaxSplit split = TaxSplit.intraState,
  }) async {
    final document = buildDocument(
      data: data,
      pharmacy: pharmacy,
      split: split,
    );

    await Printing.layoutPdf(
      name: 'bill-${data.sale.invoiceNo}',
      onLayout: (format) => document.save(),
    );
  }

  /// One sold line.
  pw.Widget _lineWidget(InvoiceLine line) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 3),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: <pw.Widget>[
        pw.Text(line.name, style: const pw.TextStyle(fontSize: 9)),
        // The batch and its expiry on a row of their own: a number and a date do not fit
        // beside the pricing detail at 80mm, and they describe the pack the customer is
        // taking home rather than how it was priced.
        pw.Text(
          'Batch ${line.batch} · exp ${line.expiry}',
          style: const pw.TextStyle(fontSize: 8),
        ),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: <pw.Widget>[
            pw.Text(line.detail, style: const pw.TextStyle(fontSize: 8)),
            pw.Text(line.amount, style: const pw.TextStyle(fontSize: 8)),
          ],
        ),
      ],
    ),
  );

  /// A label and an amount on one line.
  pw.Widget _rowWidget(InvoiceRow row) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: <pw.Widget>[
        pw.Text(row.label, style: _rowStyle(row)),
        pw.Text(row.value, style: _rowStyle(row)),
      ],
    ),
  );

  /// The style a row's text is set in.
  static pw.TextStyle _rowStyle(InvoiceRow row) => (row.emphasis ?? false)
      ? const pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)
      : const pw.TextStyle(fontSize: 8);

  /// The central half of the tax, rounded once.
  ///
  /// The rounded value rather than `taxTotal / 2`, so that subtracting it gives the
  /// state half exactly and the two add back up to the stored total.
  static double _cgst(double taxTotal) => PurchaseTotals.round2(taxTotal / 2);

  /// Who the bill is for as `Rohit Jain · PT-00001`, or `null` when it records nobody.
  ///
  /// The name is the sale's own snapshot; the code is the one `sale_document()` joined
  /// on `sales.customer_id`. A dash stands in when the pharmacy has none - a package
  /// bill's party is the hospital's account row, and a customer registered before
  /// Phase 7a has none until `save_patient()` first touches them (D-079) - so the
  /// receipt never prints a code it was not given. A sale that names nobody at all (a
  /// transfer) prints no patient line rather than an empty one.
  static String? _patient(Sale sale, String? patientCode) {
    final name = _present(sale.patientName) ? sale.patientName!.trim() : null;
    final hasCode = _present(patientCode);
    if (name == null && !hasCode) {
      return null;
    }
    return '${name ?? 'Patient'} · ${hasCode ? patientCode!.trim() : unknownMark}';
  }

  /// Who prescribed it, or `null` when the sale names nobody.
  ///
  /// The sale's own snapshot, not a read of the doctors master: the master converges spellings
  /// (D-072) and the bill keeps the one it was written with.
  static String? _prescriber(Sale sale) {
    final name = sale.doctorName?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  /// How one line was priced.
  static String _lineDetail(SaleItem item) =>
      '${item.qty} x ${_money(item.rate)}'
      '${item.discountPercent > 0 ? ' less ${_number(item.discountPercent)}%' : ''}'
      '${item.gstPercent > 0 ? ' + ${_number(item.gstPercent)}% GST' : ''}';

  /// Whether [value] holds anything worth printing.
  static bool _present(String? value) =>
      value != null && value.trim().isNotEmpty;

  /// An amount as `Rs 1,234.00`.
  ///
  /// Deliberately not the rupee sign: the PDF package's built-in fonts have no
  /// glyph for it, and a thermal printer's code page frequently does not either, so
  /// `Rs` is the spelling that prints on the hardware this is for. The digits
  /// themselves still get the app's Indian grouping, from the same formatter the
  /// screens use.
  static String _money(double amount) => 'Rs ${Formatters.amount(amount)}';

  /// A percentage without a trailing `.0`.
  static String _number(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  /// A timestamp as `18/09/2026 14:05`.
  static String _dateTime(DateTime value) {
    final date = Formatters.dateDdMmYyyy(value);
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$date $hour:$minute';
  }
}
