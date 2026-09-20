/// A file picker and an audit saver that answer from a script.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it. Both seams
/// exist for this: a platform file dialog cannot be driven from a widget test,
/// and a save dialog would otherwise have to be stepped around rather than
/// asserted on.
library;

import 'dart:convert';

import 'package:app/features/import/opening_stock/data/opening_stock_audit_csv.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_file_picker.dart';

/// The header every opening-stock export starts with.
const String openingStockHeaderLine =
    'item_name,batch_no,expiry_date,qty,purchase_rate,mrp';

/// A CSV body of [rows] data rows under the real header, for a fake picker to
/// answer with.
String openingStockCsv(List<String> rows) =>
    <String>[openingStockHeaderLine, ...rows].join('\n');

/// Two ordinary rows, as the smallest realistic file.
const List<String> twoRowCsvBody = <String>[
  'Dolo 650mg,DOBS4434,2030-03-31,1292,1.38,2.15',
  'AB Gel,,,0,80.00,104.00',
];

/// A [OpeningStockFilePicker] that answers with whatever the test set.
class FakeOpeningStockFilePicker implements OpeningStockFilePicker {
  /// Creates a fake answering with [file] (or nothing, when null).
  FakeOpeningStockFilePicker({PickedOpeningStockFile? file}) : next = file;

  /// What the next pick answers, or `null` for "the user changed their mind".
  PickedOpeningStockFile? next;

  /// When set, the pick throws it until the test clears it.
  Exception? errorToThrow;

  /// How many times a pick was asked for.
  int pickCount = 0;

  @override
  Future<PickedOpeningStockFile?> pick() async {
    pickCount++;
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    return next;
  }
}

/// A picked CSV named like the owner's export.
///
/// The size is the UTF-8 length of the content rather than its character count,
/// because that is what the platform reports and what the screen shows.
PickedOpeningStockFile pickedOpeningStockCsv({
  String fileName = 'PharmaFlow_Opening_Stock.csv',
  String? content,
}) {
  final text = content ?? openingStockCsv(twoRowCsvBody);
  return PickedOpeningStockFile(
    fileName: fileName,
    content: text,
    byteLength: utf8.encode(text).length,
  );
}

/// An [OpeningStockCsvSaver] that keeps what it was asked to save.
class FakeOpeningStockCsvSaver implements OpeningStockCsvSaver {
  /// Creates a fake that answers with [savedTo].
  FakeOpeningStockCsvSaver({this.savedTo = '/tmp/audit.csv'});

  /// What a save answers - `null` meaning the user cancelled the dialog.
  String? savedTo;

  /// When set, the save throws it until the test clears it.
  Exception? errorToThrow;

  /// Every file name that was saved, in order.
  final List<String> savedFileNames = <String>[];

  /// Every body that was saved, in order.
  final List<String> savedContents = <String>[];

  @override
  Future<String?> save({
    required String fileName,
    required String content,
  }) async {
    savedFileNames.add(fileName);
    savedContents.add(content);
    final error = errorToThrow;
    if (error != null) {
      throw error;
    }
    return savedTo;
  }
}
