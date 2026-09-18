/// Renders a sale as a printable GST bill.
///
/// A service rather than a screen's business because printing is a platform
/// capability: `printing` opens the browser's PDF flow on web and the native print
/// dialog on Windows, which is exactly the split D-005 records. The screen only
/// has to know that it asked for a bill.
///
/// The receipt is laid out on an 80mm roll - the width a thermal counter printer
/// takes - so the same artifact prints on a till and saves as a PDF.
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

/// Turns a sale into a bill.
class InvoicePrinter {
  /// Creates a printer.
  const InvoicePrinter();

  /// Renders [data] as an 80mm receipt and hands it to the platform.
  ///
  /// [pharmacy] supplies the seller's half of a GST bill. It is nullable because a
  /// pharmacy row that cannot be read should not stop a customer getting a receipt:
  /// the bill prints with a placeholder header rather than not printing at all.
  Future<void> printReceipt({
    required SaleDetailData data,
    required Pharmacy? pharmacy,
    TaxSplit split = TaxSplit.intraState,
  }) async {
    final document = pw.Document()
      ..addPage(
        pw.Page(
          pageFormat: PdfPageFormat.roll80,
          margin: const pw.EdgeInsets.all(8),
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: <pw.Widget>[
              _header(pharmacy, data.sale),
              pw.SizedBox(height: 6),
              pw.Divider(thickness: 0.5),
              for (final item in data.items) _line(item, data.nameOf(item)),
              pw.Divider(thickness: 0.5),
              _totals(data.sale, split),
              pw.SizedBox(height: 6),
              _payment(data.sale),
              pw.SizedBox(height: 10),
              pw.Text(
                'Goods once sold are not returnable without the bill.',
                style: const pw.TextStyle(fontSize: 7),
                textAlign: pw.TextAlign.center,
              ),
            ],
          ),
        ),
      );

    await Printing.layoutPdf(
      name: 'bill-${data.sale.invoiceNo}',
      onLayout: (format) => document.save(),
    );
  }

  /// The seller's details and the document's own.
  pw.Widget _header(Pharmacy? pharmacy, Sale sale) => pw.Column(
    children: <pw.Widget>[
      pw.Text(
        pharmacy?.name ?? 'Pharmacy',
        style: const pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
        textAlign: pw.TextAlign.center,
      ),
      if ((pharmacy?.displayAddress ?? '').isNotEmpty)
        pw.Text(
          pharmacy!.displayAddress,
          style: const pw.TextStyle(fontSize: 8),
          textAlign: pw.TextAlign.center,
        ),
      if ((pharmacy?.gstin ?? '').isNotEmpty)
        pw.Text(
          'GSTIN ${pharmacy!.gstin}',
          style: const pw.TextStyle(fontSize: 8),
          textAlign: pw.TextAlign.center,
        ),
      if ((pharmacy?.drugLicenseNo ?? '').isNotEmpty)
        pw.Text(
          'D.L. ${pharmacy!.drugLicenseNo}',
          style: const pw.TextStyle(fontSize: 8),
          textAlign: pw.TextAlign.center,
        ),
      pw.SizedBox(height: 4),
      pw.Text(
        'TAX INVOICE',
        style: const pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 2),
      pw.Text('Bill ${sale.invoiceNo}', style: const pw.TextStyle(fontSize: 8)),
      pw.Text(_dateTime(sale.saleDate), style: const pw.TextStyle(fontSize: 8)),
    ],
  );

  /// One sold line: what, where it came from, and what it cost.
  pw.Widget _line(SaleItem item, String name) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 3),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: <pw.Widget>[
        pw.Text(name, style: const pw.TextStyle(fontSize: 9)),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: <pw.Widget>[
            pw.Text(
              '${item.qty} x ${_money(item.rate)}'
              '${item.discountPercent > 0 ? ' less ${_number(item.discountPercent)}%' : ''}'
              '${item.gstPercent > 0 ? ' + ${_number(item.gstPercent)}% GST' : ''}',
              style: const pw.TextStyle(fontSize: 8),
            ),
            pw.Text(
              _money(item.totalAmount),
              style: const pw.TextStyle(fontSize: 8),
            ),
          ],
        ),
      ],
    ),
  );

  /// The bill's arithmetic, with the tax heads the split decided.
  pw.Widget _totals(Sale sale, TaxSplit split) => pw.Column(
    children: <pw.Widget>[
      _row('Taxable value', _money(sale.subTotal)),
      if (sale.discountTotal > 0)
        _row('Discount', '-${_money(sale.discountTotal)}'),
      if (split == TaxSplit.intraState) ...<pw.Widget>[
        _row('CGST', _money(PurchaseTotals.round2(sale.taxTotal / 2))),
        _row(
          'SGST',
          _money(PurchaseTotals.round2(sale.taxTotal - sale.taxTotal / 2)),
        ),
      ] else
        _row('IGST', _money(sale.taxTotal)),
      pw.Divider(thickness: 0.5),
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: <pw.Widget>[
          pw.Text(
            'TOTAL',
            style: const pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.Text(
            _money(sale.grandTotal),
            style: const pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    ],
  );

  /// How it was settled, which is what a customer checks the change against.
  pw.Widget _payment(Sale sale) => pw.Column(
    children: <pw.Widget>[
      _row(sale.paymentMode.label, _money(sale.amountPaid)),
      if (sale.balanceDue > 0) _row('Balance due', _money(sale.balanceDue)),
      if (sale.customerId != null) _row('Customer', 'account sale'),
    ],
  );

  /// A label and an amount on one line.
  pw.Widget _row(String label, String value) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: <pw.Widget>[
        pw.Text(label, style: const pw.TextStyle(fontSize: 8)),
        pw.Text(value, style: const pw.TextStyle(fontSize: 8)),
      ],
    ),
  );

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
