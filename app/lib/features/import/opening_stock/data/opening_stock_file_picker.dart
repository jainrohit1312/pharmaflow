/// Choosing the opening-stock file: the platform's picker, behind a seam.
///
/// The seam is `bill_picker.dart`'s, applied again (D-035): the rest of the
/// feature never sees a `file_picker` type, so a widget test can drive a chosen
/// file without a file dialog, and nothing above this line has to know which
/// package opened it. `image_picker` is not reused for this: it opens an image
/// gallery or a camera and cannot select a CSV.
///
/// The two jobs that can fail are pure functions below the class - which name is
/// acceptable, and what a file's bytes say - so the cases that used to be
/// invisible (a file handed over with no bytes at all) are exercised by a test
/// rather than by a browser.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/features/import/opening_stock/data/opening_stock_picker_options.dart'
    if (dart.library.js_interop) 'package:app/features/import/opening_stock/data/opening_stock_picker_options_web.dart';
import 'package:file_picker/file_picker.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

// Re-exported so the one thing these options decide - whether the web picker
// abandons a pick on a window focus event - can be asserted on the web itself,
// through the same conditional import this file uses rather than a second copy
// of it (D-073).
export 'package:app/features/import/opening_stock/data/opening_stock_picker_options.dart'
    if (dart.library.js_interop) 'package:app/features/import/opening_stock/data/opening_stock_picker_options_web.dart';

part 'opening_stock_file_picker.g.dart';

/// The app-wide [OpeningStockFilePicker].
@riverpod
OpeningStockFilePicker openingStockFilePicker(Ref ref) =>
    PlatformOpeningStockFilePicker();

/// A chosen file, decoded: everything the parser needs and nothing more.
class PickedOpeningStockFile {
  /// Creates a picked file.
  const PickedOpeningStockFile({
    required this.fileName,
    required this.content,
    required this.byteLength,
  });

  /// The name the file had, for the audit trail and the screen.
  final String fileName;

  /// The file's text, decoded as UTF-8.
  final String content;

  /// How large the file was, in bytes.
  ///
  /// The bytes' length rather than the decoded text's: the owner is shown the
  /// size of the file they chose, and a UTF-8 file whose item names carry
  /// accented characters is longer than its character count says.
  final int byteLength;
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
      // Read on web and ignored everywhere else. Without it the web picker
      // abandons a pick 500 ms after any window focus event and answers with
      // `null`, which is indistinguishable from the user changing their mind -
      // so a real selection vanished with nothing on screen to say so (D-073).
      webOptions: openingStockPickerWebOptions(),
    );
    if (file == null) {
      return null;
    }

    final name = file.name;
    requireOpeningStockCsvName(name);
    final bytes = await file.readAsBytes();

    return PickedOpeningStockFile(
      fileName: name,
      content: decodeOpeningStockBytes(bytes),
      byteLength: bytes.length,
    );
  }
}

/// Accepts [name] as a CSV, or throws a sentence naming what it is instead.
void requireOpeningStockCsvName(String name) {
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();

  if (extension == 'csv') {
    return;
  }
  throw ValidationException(
    message: switch (extension) {
      'xlsx' || 'xls' =>
        'That is a spreadsheet. This import reads the CSV export - save the '
            'sheet as CSV and choose that file.',
      '' =>
        'That file has no extension. The opening stock import reads a .csv '
            'export - choose the file the spreadsheet saved.',
      _ =>
        'That is a .$extension file. The opening stock import reads a .csv '
            'export.',
    },
    code: 'import/not-a-csv',
  );
}

/// Decodes [bytes] as UTF-8, or throws a sentence saying why it cannot be read.
///
/// Bytes with nothing in them are refused here rather than passed on as an empty
/// string. The distinction is the whole reason this is a function: a file of
/// zero bytes reaching the parser reads as "that file is empty", which blames
/// the export for a file that was fine, and - when the read is what failed -
/// leaves the screen looking exactly as it did before anything was chosen.
String decodeOpeningStockBytes(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const ValidationException(
      message:
          'That file arrived with not one byte of content in it. Choose it '
          'again, and if it keeps happening export it from the spreadsheet and '
          'pick the new file.',
      code: 'import/no-bytes',
    );
  }

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
