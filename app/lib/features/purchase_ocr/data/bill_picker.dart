/// Choosing a bill: the platform's picker, behind a seam a test can replace.
library;

import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'bill_picker.g.dart';

/// The app-wide [BillPicker].
@riverpod
BillPicker billPicker(Ref ref) => ImageBillPicker();

/// A bill the user chose, in the only form the rest of the feature needs.
///
/// Deliberately not an `XFile`: that is `image_picker`'s type, it cannot be
/// constructed in a test, and nothing above this line should have to know which
/// package opened the file dialog.
class PickedBill {
  /// Creates a picked bill.
  const PickedBill({required this.bytes, this.mimeType, this.fileName});

  /// The file's bytes.
  final Uint8List bytes;

  /// The type the platform reported, when it reported one.
  ///
  /// Null often outside a browser — which is why the screen falls back to the
  /// file name's extension rather than telling the user their file has no type.
  final String? mimeType;

  /// The name the file had, for display.
  final String? fileName;
}

/// Lets the user choose a bill, or photograph one.
// ignore: one_member_abstracts
abstract class BillPicker {
  /// Returns what the user picked, or `null` when they changed their mind.
  ///
  /// [fromCamera] asks for the camera; on a desktop browser that is the same
  /// file dialog, which is a platform fact rather than a bug (D-005).
  Future<PickedBill?> pick({required bool fromCamera});
}

/// A [BillPicker] backed by `image_picker`.
class ImageBillPicker implements BillPicker {
  /// Creates the platform-backed picker.
  ImageBillPicker({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<PickedBill?> pick({required bool fromCamera}) async {
    final file = await _picker.pickImage(
      source: fromCamera ? ImageSource.camera : ImageSource.gallery,
    );
    if (file == null) {
      return null;
    }

    return PickedBill(
      bytes: await file.readAsBytes(),
      mimeType: file.mimeType,
      fileName: file.name,
    );
  }
}
