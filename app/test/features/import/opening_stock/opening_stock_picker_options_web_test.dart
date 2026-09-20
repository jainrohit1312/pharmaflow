/// What the web picker is configured with, asserted on the web itself.
///
/// The conditional import in `opening_stock_file_picker.dart` picks this file
/// only when compiling for the web, and a file that was silently not picked would
/// leave the fix a no-op with every other test still green - which is the shape
/// of the bug being fixed, not a different one. So the branch is asserted where
/// it is taken, on the browser platform:
///
///     flutter test --platform chrome test/features/import/opening_stock/opening_stock_picker_options_web_test.dart
///
/// The ordinary `flutter test` run (the Dart VM) does not collect this file, and
/// that is the point of it: the VM cannot take this branch.
@TestOn('browser')
library;

import 'package:app/features/import/opening_stock/data/opening_stock_file_picker.dart';
import 'package:file_picker_web/file_picker_web.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("the options handed to the picker are the web picker's", () {
    // The class, not a look-alike: `FilePickerWeb` only honours its own
    // `WebOptions` subclass and falls back to its defaults for anything else,
    // which is why the dependency exists at all.
    expect(openingStockPickerWebOptions(), isA<FilePickerWebOptions>());
  });

  test('the pick abandons nothing on a window focus event', () {
    final options = openingStockPickerWebOptions() as FilePickerWebOptions;

    // The fix itself. True - the package's default - is what answered a real
    // selection with `null` and left the screen looking untouched (D-073).
    expect(options.cancelUploadOnWindowBlur, isFalse);
  });
}
