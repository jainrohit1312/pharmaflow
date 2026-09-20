/// Choosing the opening-stock file: the platform's picker, behind a seam.
///
/// The seam is `bill_picker.dart`'s, applied again (D-035): the rest of the
/// feature never sees a `file_picker` type, so a widget test can drive a chosen
/// file without a file dialog, and nothing above this line has to know which
/// package opened it. `image_picker` is not reused for this: it opens an image
/// gallery or a camera and cannot select a CSV.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:app/core/errors/app_exception.dart';
import 'package:file_picker/file_picker.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'opening_stock_file_picker.g.dart';

/// The app-wide [OpeningStockFilePicker].
@riverpod
OpeningStockFilePicker openingStockFilePicker(Ref ref) =>
    PlatformOpeningStockFilePicker();

/// A chosen file, decoded: everything the parser needs and nothing more.
class PickedOpeningStockFile {
  /// Creates a picked file.
  const PickedOpeningStockFile({required this.fileName, required this.content});

  /// The name the file had, for the audit trail and the screen.
  final String fileName;

  /// The file's text, decoded as UTF-8 with any byte-order mark removed.
  final String content;
}

/// Lets the user choose the opening-stock file, or reports that they did not.
// ignore: one_member_abstracts
abstract class OpeningStockFilePicker {
  /// Returns what the user picked, or `null` when they changed their mind.
  Future<PickedOpeningStockFile?> pick();
}

/// An [OpeningStockFilePicker] backed by `file_picker`.
class PlatformOpeningStockFilePicker implements OpeningStockFilePicker {
  @override
  Future<PickedOpeningStockFile?> pick() async {
    // Any file, filtered here rather than by the dialog: a strict MIME filter
    // for `text/csv` hides the export outright on some Android pickers, and a
    // file the user cannot select is a worse bug than a file this code refuses
    // with a sentence saying why.
    final file = await FilePicker.pickFile(
      dialogTitle: 'Choose the opening stock file',
    );
    if (file == null) {
      return null;
    }

    final name = file.name;
    final extension = name.contains('.')
        ? name.split('.').last.toLowerCase()
        : '';
    if (extension != 'csv') {
      throw ValidationException(
        message: extension == 'xlsx' || extension == 'xls'
            ? 'That is a spreadsheet. This import reads the CSV export - save '
                  'the sheet as CSV and choose that file.'
            : 'That is a .$extension file. The opening stock import reads a '
                  '.csv export.',
        code: 'import/not-a-csv',
      );
    }

    return PickedOpeningStockFile(
      fileName: name,
      content: _decode(await file.readAsBytes()),
    );
  }
}

/// Decodes [bytes] as UTF-8, or reports why it cannot be read.
String _decode(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const ValidationException(
      message:
          'That file is not UTF-8 text, so its columns cannot be read. '
          'Export the sheet as CSV with UTF-8 encoding and try again.',
      code: 'import/not-utf8',
    );
  }
}
