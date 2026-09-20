/// The picker's platform options everywhere that is not the web.
///
/// Conditional-imported from `opening_stock_file_picker.dart`; the web build
/// takes `opening_stock_picker_options_web.dart` instead (D-073). The base
/// [WebOptions] carries nothing, which is exactly right off the web: the type is
/// only in the signature because `FilePicker.pickFile` takes it on every
/// platform.
library;

import 'package:file_picker/file_picker.dart';

/// Platform options for the picker on desktop and mobile: none.
WebOptions openingStockPickerWebOptions() => const WebOptions();
