/// A [BillPicker] that answers from a script.
///
/// The default bytes are a real 1×1 PNG, not filler: the verify screen renders
/// the picked file with `Image.memory`, and bytes that are not an image would make
/// every screen test fail on a decode error that has nothing to do with what the
/// test is about.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:app/features/purchase_ocr/data/bill_picker.dart';

/// A valid 1×1 PNG.
final Uint8List tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

/// A fake picker.
class FakeBillPicker implements BillPicker {
  /// Creates a fake that answers with [bill] (or nothing, when null).
  FakeBillPicker({PickedBill? bill}) : next = bill ?? pickedJpeg();

  /// What the next pick answers, or `null` for "the user changed their mind".
  PickedBill? next;

  /// Whether each pick asked for the camera or the gallery.
  final List<bool> askedForCamera = <bool>[];

  @override
  Future<PickedBill?> pick({required bool fromCamera}) async {
    askedForCamera.add(fromCamera);
    return next;
  }
}

/// A picked JPEG named like a phone's camera roll.
PickedBill pickedJpeg({Uint8List? bytes}) => PickedBill(
  bytes: bytes ?? tinyPngBytes,
  mimeType: 'image/jpeg',
  fileName: 'IMG_0042.jpg',
);

/// A picked file whose platform reported no type, as happens off the browser.
PickedBill pickedUntyped({required String fileName}) =>
    PickedBill(bytes: tinyPngBytes, fileName: fileName);
