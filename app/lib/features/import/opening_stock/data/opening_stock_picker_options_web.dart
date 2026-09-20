/// The picker's platform options on the web.
///
/// Conditional-imported from `opening_stock_file_picker.dart`, so this file is
/// compiled into a web build only and the `dart:js_interop` that
/// `file_picker_web` sits on is never reached by another platform (D-073).
library;

import 'package:file_picker/file_picker.dart';
import 'package:file_picker_web/file_picker_web.dart';

/// Platform options for the web picker, with its window-focus cancellation off.
///
/// Off, because on: the web picker treats any window `focus` event within a pick
/// as the user having gone away, waits 500 ms, and then answers a pick that is
/// still in progress with `null` - discarding a file the user did select, and
/// reporting it exactly as a cancellation. A browser extension that scans the
/// chosen file steals focus by design, and a plain native dialog on Windows
/// hands focus back on its way in, so a real selection ends as "the user changed
/// their mind" (D-073).
///
/// There is no way to turn it off through `file_picker` alone: 13.0.0 removed the
/// parameter from `pickFile()`, and the `WebOptions` the facade exports declares
/// no fields at all, so the setting only exists on this subclass. Hence the
/// direct dependency and this file.
WebOptions openingStockPickerWebOptions() =>
    const FilePickerWebOptions(cancelUploadOnWindowBlur: false);
