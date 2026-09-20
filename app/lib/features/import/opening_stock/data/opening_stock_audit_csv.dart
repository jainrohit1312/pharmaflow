/// The audit trail as a file: rendering an import job to CSV, and saving it.
///
/// The audit CSV is the owner's evidence of what the import wrote, so it is
/// rendered from what the database holds rather than from what the screen had in
/// hand - `get_import_job` answers the rows with the product names and batch
/// numbers they wrote, and everything below is that answer, laid out.
///
/// Saving goes through `file_picker`'s own save dialog, which is the same plugin
/// that chose the file: on the web it hands the browser a download, on Android it
/// opens the system save sheet, and on Windows a Save-as dialog. That is why this
/// needs no `dart:html` and no conditional import - the platform's answer to
/// "where should this go" is already behind one API.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:app/features/import/opening_stock/data/opening_stock_models.dart';
import 'package:file_picker/file_picker.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'opening_stock_audit_csv.g.dart';

/// The app-wide [OpeningStockCsvSaver].
@riverpod
OpeningStockCsvSaver openingStockCsvSaver(Ref ref) =>
    PlatformOpeningStockCsvSaver();

/// The columns of the audit CSV, in order.
const List<String> openingStockAuditColumns = <String>[
  'row_number',
  'item_name',
  'batch_no',
  'expiry_date',
  'qty',
  'purchase_rate',
  'mrp',
  'product_name',
  'stored_batch_no',
  'stored_expiry_date',
  'action',
];

/// Renders [job] as a CSV, one line per imported row.
///
/// The file's own text is kept beside what was stored, so a row whose batch
/// number was generated is visible as such: `batch_no` holds what the file said
/// (empty) and `stored_batch_no` what the import wrote (the generated identity).
/// Money is written to two places and quantities as whole numbers, which is the
/// precision the columns hold.
String buildOpeningStockAuditCsv(ImportJob job) {
  final lines = <String>[openingStockAuditColumns.join(',')];

  for (final row in job.rows) {
    lines.add(
      <String>[
        '${row.rowNumber}',
        row.rawItemName,
        row.rawBatchNo ?? '',
        row.rawExpiry ?? '',
        '${row.qty}',
        row.purchaseRate.toStringAsFixed(2),
        row.mrp.toStringAsFixed(2),
        row.productName ?? '',
        row.batchNo ?? '',
        row.expiryDate ?? '',
        row.action,
      ].map(_cell).join(','),
    );
  }

  return '${lines.join('\n')}\n';
}

/// The file name an audit download defaults to.
///
/// Dated, because an owner who fixes a file and imports again ends up with two
/// jobs and would otherwise have two identically named documents.
String openingStockAuditFileName(ImportJob job) {
  final committed = job.committedAt;
  final stamp = committed == null
      ? 'import'
      : '${committed.year}-${_two(committed.month)}-${_two(committed.day)}';
  return 'opening-stock-audit-$stamp.csv';
}

/// Writes a rendered file where the user asks for it.
// ignore: one_member_abstracts
abstract class OpeningStockCsvSaver {
  /// Saves [content] as [fileName], or answers `null` if the user cancelled.
  Future<String?> save({required String fileName, required String content});
}

/// An [OpeningStockCsvSaver] backed by `file_picker`.
class PlatformOpeningStockCsvSaver implements OpeningStockCsvSaver {
  @override
  Future<String?> save({
    required String fileName,
    required String content,
  }) async {
    final saved = await FilePicker.saveFile(
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(content)),
      mimeType: 'text/csv',
      dialogTitle: 'Save the import audit',
    );
    return saved?.toString();
  }
}

/// One CSV cell: quoted when it has to be, and never mangled when it does not.
String _cell(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

/// Two digits, for a date stamp.
String _two(int value) => value.toString().padLeft(2, '0');
