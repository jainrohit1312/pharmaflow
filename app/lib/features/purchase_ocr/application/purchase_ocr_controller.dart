/// The OCR flow's state: the picked bill, the parse, and whether it is worth
/// another try.
library;

import 'dart:typed_data';

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/ocr_purchase_bill.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase_ocr/data/bill_picker.dart';
import 'package:app/features/purchase_ocr/data/purchase_ocr_repository.dart';
import 'package:app/services/ocr_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'purchase_ocr_controller.g.dart';

/// How long to wait before the one automatic retry (D-032).
///
/// A provider rather than a constant so a test does not spend real seconds:
/// waiting is the whole behaviour under test, and a test that waits is a test
/// that is slow for no reason.
@riverpod
Duration ocrRetryDelay(Ref ref) => const Duration(seconds: 3);

/// A bill that has been picked and uploaded, and what the reader made of it.
///
/// Plain rather than Freezed for `PosCart`'s reason: it is a screen's working
/// state, not a table row, and no migration owns its shape. All three parts are
/// kept together because they are only meaningful together — the bytes are what
/// the user sees, the path is what the reader can be asked about again, and the
/// parse is what came back.
class OcrScan {
  /// Creates a scan.
  const OcrScan({
    required this.bytes,
    required this.mimeType,
    required this.storagePath,
    required this.bill,
  });

  /// The picked image, for showing while the reader works and afterwards beside
  /// what it read.
  final Uint8List bytes;

  /// The picked file's type.
  final String mimeType;

  /// Where the bill was stored (`<pharmacy_id>/<year>/<file>`, D-028). Kept so a
  /// re-read does not upload a second copy of the same bill.
  final String storagePath;

  /// What the reader made of it, or `null` while it is being read — or after a
  /// read that failed.
  ///
  /// Nullable rather than absent on purpose: the bill is *up there* from the
  /// moment the upload returns, and a first read that fails must still be
  /// retryable from the stored object (D-033). Without this, "read it again"
  /// after a failure would have nothing to read and would have to upload a second
  /// copy of the same bill.
  final OcrPurchaseBill? bill;
}

/// What the OCR screen is showing.
class PurchaseOcrState {
  /// Creates a state.
  const PurchaseOcrState({
    this.scan,
    this.isBusy = false,
    this.isRetrying = false,
    this.error,
    this.errorIsRetryable = false,
  });

  /// The bill being worked on, once it has been read.
  final OcrScan? scan;

  /// Whether a bill is being uploaded or read right now.
  final bool isBusy;

  /// Whether the reader is being given its second chance (D-032).
  ///
  /// Separate from [isBusy] because the two need different words on screen: "the
  /// reader is busy — retrying" is a wait with a reason, and a user who is told
  /// nothing would tap again, which is exactly what the free-tier quota cannot
  /// afford.
  final bool isRetrying;

  /// Why the last attempt failed, when it did.
  final Object? error;

  /// Whether [error] is worth another try.
  final bool errorIsRetryable;

  /// Whether anything can be shown yet.
  bool get hasScan => scan != null;

  /// Whether the bill has actually been read.
  ///
  /// Distinct from [hasScan]: a bill can be up in the bucket with a failed read
  /// behind it, which the screen shows as "we could not read it" plus a retry
  /// rather than as an empty form.
  bool get hasBill => scan?.bill != null;

  /// A copy holding [value], with nothing in flight and no failure.
  PurchaseOcrState withSuccess(OcrScan value) => PurchaseOcrState(scan: value);

  /// A copy that is busy, and no longer failed.
  PurchaseOcrState withBusy({required bool retrying}) =>
      PurchaseOcrState(scan: scan, isBusy: true, isRetrying: retrying);

  /// A copy carrying [failure].
  ///
  /// Any parse already on screen is kept: a re-read that fails leaves the first
  /// parse visible rather than blanking the form, which is why the screen has to
  /// show [error] itself rather than trusting "there is a scan" to mean "it is
  /// fine" (T-3's shape, one feature over).
  PurchaseOcrState withError(Object failure) => PurchaseOcrState(
    scan: scan,
    error: failure,
    errorIsRetryable: isRetryableOcrError(failure),
  );
}

/// Drives one bill from the picker to a parse.
///
/// The write is elsewhere on purpose: creating the purchase goes through
/// `PurchaseFormController` and the receipt through `GrnController`, the same
/// paths the manual screens use (D-011/D-013). This controller's only job is the
/// image and the reader.
@riverpod
class PurchaseOcrController extends _$PurchaseOcrController {
  /// How many times one read is attempted, the automatic retry included.
  ///
  /// Two, not more: the reader's refusal on a free-tier quota is a per-minute
  /// budget (D-032), and a third attempt inside the same minute buys nothing but
  /// another wait.
  static const int attempts = 2;

  @override
  PurchaseOcrState build() => const PurchaseOcrState();

  /// Asks the platform for a bill, checks it, uploads it and reads it.
  ///
  /// The whole decision lives here rather than in the widget, including the two
  /// things that are easy to get wrong on the screen side: a file whose type the
  /// platform did not report is typed from its name (rather than refused as "no
  /// type at all"), and a file the bucket would refuse is turned away before the
  /// round trip, in the same words the write would use.
  Future<void> pickBill({required bool fromCamera}) async {
    final picked = await ref
        .read(billPickerProvider)
        .pick(fromCamera: fromCamera);
    if (picked == null) {
      return; // The user changed their mind, which is not a failure.
    }

    final mimeType =
        picked.mimeType ??
        PurchaseOcrRepository.mimeForFileName(picked.fileName ?? '');
    final refusal = PurchaseOcrRepository.validatePick(
      mimeType: mimeType,
      sizeInBytes: picked.bytes.length,
    );
    if (refusal != null) {
      if (!ref.mounted) {
        return;
      }
      state = state.withError(ValidationException(message: refusal));
      return;
    }

    await pickAndScan(bytes: picked.bytes, mimeType: mimeType!);
  }

  /// Uploads a picked bill, reads it, and stores the result.
  ///
  /// The upload happens once. A retry re-reads the object that is already there.
  Future<void> pickAndScan({
    required List<int> bytes,
    required String mimeType,
    String? fileName,
  }) async {
    final image = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    state = const PurchaseOcrState().withBusy(retrying: false);

    try {
      final path = await ref
          .read(purchaseOcrRepositoryProvider)
          .uploadBill(
            // Synchronous, and it throws if there is no tenant (D-015).
            pharmacyId: ref.read(requirePharmacyIdProvider),
            bytes: image,
            mimeType: mimeType,
            fileName: fileName,
          );
      if (!ref.mounted) {
        return;
      }
      // The bill is up in the bucket from here, even if the read that follows
      // fails: that is what makes a first-read failure retryable without a second
      // upload (D-033).
      state = state.withSuccess(
        OcrScan(
          bytes: image,
          mimeType: mimeType,
          storagePath: path,
          bill: null,
        ),
      );
      await _read(storagePath: path, bytes: image, mimeType: mimeType);
    } on Object catch (error) {
      // A screen that navigated away mid-upload stops watching this provider, and
      // Riverpod then disposes it: writing state afterwards would throw from a
      // future nobody is awaiting. Leaving is the whole job at that point.
      if (!ref.mounted) {
        return;
      }
      state = state.withError(error);
    }
  }

  /// Reads the same bill again, without uploading it a second time.
  Future<void> rescan() async {
    final scan = state.scan;
    if (scan == null) {
      return;
    }

    state = state.withBusy(retrying: false);
    await _read(
      storagePath: scan.storagePath,
      bytes: scan.bytes,
      mimeType: scan.mimeType,
    );
  }

  /// Forgets the bill.
  void clear() => state = const PurchaseOcrState();

  /// Reads [storagePath], retrying once when the reader was merely busy.
  Future<void> _read({
    required String storagePath,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    final repository = ref.read(purchaseOcrRepositoryProvider);

    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final bill = await repository.parseBill(storagePath: storagePath);
        if (!ref.mounted) {
          return;
        }
        state = state.withSuccess(
          OcrScan(
            bytes: bytes,
            mimeType: mimeType,
            storagePath: storagePath,
            bill: bill,
          ),
        );
        return;
      } on Object catch (error) {
        if (!ref.mounted) {
          return;
        }
        final retryable = isRetryableOcrError(error);
        if (!retryable || attempt == attempts) {
          state = state.withError(error);
          return;
        }

        // The reader is busy, not broken: say so, wait, and try once more.
        state = state.withBusy(retrying: true);
        await Future<void>.delayed(ref.read(ocrRetryDelayProvider));
        if (!ref.mounted) {
          // Gone from the screen: the second attempt would spend a shared quota
          // on an answer nobody is waiting for.
          return;
        }
      }
    }
  }
}
